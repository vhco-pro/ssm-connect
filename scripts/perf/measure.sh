#!/usr/bin/env bash
# Performance harness for the shared-core migration (cross-platform-client spec, AC-22).
#
# Measures SSM Connect's own processes the same way on every platform:
#   startup    launch until the main window or tray accepts input
#   ui         one UI command until its visible effect
#   cold       connect, first after launch, until the ready state
#   warm       connect again in the same app session until the ready state
#   idle       RSS summed over the measured processes after the settle period,
#              and CPU averaged over one-second samples after that
# Each timing is one discarded warm-up plus RUNS measured runs, reported by median.
#
# Platform behavior comes from a workload file (see workloads/ and README.md) that
# defines shell hooks; this script owns timing, sampling and the statistics.
#
# Usage: measure.sh WORKLOAD [all|startup|ui|cold|warm|idle] [--out FILE] [--dry-run]
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
WORKLOAD=$1; shift
METRIC=all
OUT=
DRY_RUN=0
while [ $# -gt 0 ]; do
  case $1 in
    all|startup|ui|cold|warm|idle) METRIC=$1 ;;
    --out) OUT=$2; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
  shift
done

RUNS=10
SETTLE_SECONDS=300
IDLE_SAMPLES=60
TIMEOUT_SECONDS=180
# shellcheck source=/dev/null
. "$WORKLOAD"
for hook in launch quit ready app_pids; do
  declare -F "$hook" >/dev/null || { echo "workload must define $hook()" >&2; exit 2; }
done

now_ms() {
  if date +%s%3N 2>/dev/null | grep -qv N; then date +%s%3N
  else perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; fi
}

# Wait until the named hook succeeds, polling every 50 ms. Prints elapsed ms since $1.
wait_for() {
  local start=$1 hook=$2 deadline=$(( $(now_ms) + TIMEOUT_SECONDS * 1000 ))
  until "$hook"; do
    [ "$(now_ms)" -lt "$deadline" ] || { echo "timed out waiting for $hook" >&2; return 1; }
    sleep 0.05
  done
  echo $(( $(now_ms) - start ))
}

median() { sort -n | awk '{v[NR]=$1} END {if (NR==0) exit 1; if (NR%2) print v[(NR+1)/2]; else print (v[NR/2]+v[NR/2+1])/2}'; }

# One discarded warm-up, then RUNS measured values of the given single-run function.
repeat() {
  local fn=$1 values=() i
  "$fn" >/dev/null
  for i in $(seq 1 "$RUNS"); do values+=("$("$fn")"); done
  printf '%s\n' "${values[@]}" | median
}

run_startup() {
  quit; sleep 2
  local t; t=$(now_ms); launch
  wait_for "$t" ready
}

run_ui() {
  declare -F ui_command >/dev/null || { echo "workload has no ui_command" >&2; return 1; }
  ready || { launch; wait_for "$(now_ms)" ready >/dev/null; }
  local t; t=$(now_ms); ui_command
  local ms; ms=$(wait_for "$t" ui_done)
  declare -F ui_reset >/dev/null && ui_reset
  echo "$ms"
}

run_cold() {
  quit; sleep 2; launch; wait_for "$(now_ms)" ready >/dev/null
  local t; t=$(now_ms); connect
  local ms; ms=$(wait_for "$t" connected)
  disconnect; wait_for "$(now_ms)" disconnected >/dev/null
  echo "$ms"
}

run_warm() {
  ready || { launch; wait_for "$(now_ms)" ready >/dev/null; }
  local t; t=$(now_ms); connect
  local ms; ms=$(wait_for "$t" connected)
  disconnect; wait_for "$(now_ms)" disconnected >/dev/null
  echo "$ms"
}

# Prints "<rss_kib> <cpu_percent>" summed over the measured processes.
sample() {
  local pids; pids=$(app_pids | paste -sd, -)
  [ -n "$pids" ] || { echo "no measured process is running" >&2; return 1; }
  if declare -F sample_hook >/dev/null; then sample_hook "$pids"; return; fi
  ps -o rss=,%cpu= -p "$pids" | awk '{r+=$1; c+=$2} END {printf "%d %.2f\n", r, c}'
}

run_idle() {
  ready || { quit; sleep 2; launch; wait_for "$(now_ms)" ready >/dev/null; }
  sleep "$SETTLE_SECONDS"
  local rss cpu_total=0 i line
  rss=$(sample | awk '{print $1}')
  for i in $(seq 1 "$IDLE_SAMPLES"); do
    line=$(sample); cpu_total=$(awk -v a="$cpu_total" -v b="${line#* }" 'BEGIN {print a+b}')
    sleep 1
  done
  echo "idle_rss_kib=$rss"
  echo "idle_cpu_percent=$(awk -v t="$cpu_total" -v n="$IDLE_SAMPLES" 'BEGIN {printf "%.2f", t/n}')"
}

header() {
  echo "# ssm-connect perf $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
  echo "os=$(os_build)"
  echo "workload=$(basename "$WORKLOAD") runs=$RUNS settle_s=$SETTLE_SECONDS idle_samples=$IDLE_SAMPLES"
  declare -F app_version >/dev/null && echo "app_version=$(app_version)"
  return 0
}

os_build() {
  case $(uname -s) in
    Darwin) echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)" ;;
    Linux) . /etc/os-release; echo "$PRETTY_NAME $(uname -r) $(uname -m)" ;;
    MINGW*|MSYS*|CYGWIN*) cmd.exe /c ver | tr -d '\r' | grep -v '^$' ;;
    *) uname -a ;;
  esac
}

main() {
  header
  if [ "$DRY_RUN" = 1 ]; then echo "dry-run: hooks loaded, nothing measured"; return; fi
  local m
  for m in startup ui cold warm; do
    if [ "$METRIC" = all ] || [ "$METRIC" = "$m" ]; then
      if [ "$m" = ui ] && ! declare -F ui_command >/dev/null; then echo "${m}_ms=skipped (no ui_command hook)"; continue; fi
      if [ "$m" != startup ] && [ "$m" != ui ] && ! declare -F connect >/dev/null; then echo "${m}_ms=skipped (no connect hook)"; continue; fi
      echo "${m}_ms=$(repeat "run_$m")"
    fi
  done
  if [ "$METRIC" = all ] || [ "$METRIC" = idle ]; then run_idle; fi
  quit
}

if [ -n "$OUT" ]; then main | tee "$OUT"; else main; fi
