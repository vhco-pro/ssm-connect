# Performance harness

`measure.sh` measures SSM Connect for the shared-core migration's performance
budgets (AC-22 in `docs/specs/cross-platform-client.spec.md`). It applies the
same method on every platform:

| Metric | Start | End |
| --- | --- | --- |
| `startup_ms` | launch | the main window or tray accepts input |
| `ui_ms` | one UI command (opening the menu) | its visible effect |
| `cold_ms` | the first connect after launch | the ready state |
| `warm_ms` | a later connect in the same session | the ready state |
| `idle_rss_kib` | after the settle period (300 s) | RSS summed over the measured processes |
| `idle_cpu_percent` | after the settle period | CPU averaged over 60 one-second samples |

Each timing is one discarded warm-up and ten runs, reported as the median. The
measured processes are SSM Connect's own (the macOS app, or a shell and its
helper); Session Manager plugin, SSH, DCV Viewer, VS Code and browsers are not
counted. The output starts with the host, OS build, workload and app version.

## Running

```sh
scripts/perf/measure.sh scripts/perf/workloads/macos.env --out baseline.txt
scripts/perf/measure.sh scripts/perf/workloads/macos.env startup   # one metric
scripts/perf/measure.sh scripts/perf/workloads/macos.env --dry-run # load hooks only
scripts/perf/measure.sh scripts/perf/workloads/selftest.env        # harness self-test
```

Comparison conditions: measure the baseline and the refactored macOS app on the
same Mac and OS build, on mains power with Low Power Mode off and no other user
apps open. Windows and Linux use the hosts recorded in the spec before the
baseline. A changed host or OS build means measuring the baseline again.

## Workloads

A workload file is sourced by `measure.sh` and defines shell functions:

| Hook | Required | Meaning |
| --- | --- | --- |
| `launch`, `quit` | yes | start the app; stop it and wait until it is gone |
| `ready` | yes | succeeds once the main window or tray accepts input |
| `app_pids` | yes | prints the PIDs of the measured processes |
| `ui_command`, `ui_done`, `ui_reset` | for `ui` | issue the command, detect its effect, undo it |
| `connect`, `connected`, `disconnect`, `disconnected` | for `cold`, `warm` | start and stop a connection and detect each state |
| `sample_hook` | no | prints `<rss_kib> <cpu_percent>` for a comma-separated PID list where `ps` cannot |
| `app_version` | no | printed in the header |

A workload may override `RUNS`, `SETTLE_SECONDS`, `IDLE_SAMPLES` and
`TIMEOUT_SECONDS`; real measurements keep the defaults.

`workloads/macos.env` drives the installed app through its menu bar extra and
reads connection states from its unified log, so it works with the current
release unchanged. The Mac needs the Xcode command line tools, Accessibility
permission for the process running the script (for the menu clicks), and, for
`cold` and `warm`, a profile that connects without an interactive sign-in.
