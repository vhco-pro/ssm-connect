#!/bin/sh
# web-forwards.sh: reach web UIs behind an SSM-only EC2 host from a local browser.
#
# Reference client for docs/specs/web-forwards.spec.md. It does by hand what the app
# will do natively: push a short-lived key through EC2 Instance Connect, open one SSH
# connection inside an SSM session, and hang a SOCKS5 proxy and local forwards off it.
#
# Needs here: aws cli v2 with a live SSO session, session-manager-plugin, ssh, ssh-keygen.
# Needs on the host: sshd with the EC2 Instance Connect AuthorizedKeysCommand (the
# Amazon Linux default). Nothing per client.
#
# Configuration is environment variables, optionally kept in a file that is sourced
# first (default ~/.config/web-forwards/env, override with WEB_FORWARDS_ENV):
#
#   WF_TAG       required  value of the instance's Name tag
#   WF_USER      required  Linux user on the host
#   WF_PROFILE   optional  aws profile (default: the CLI's own default)
#   WF_REGION    optional  aws region (default: the profile's)
#   WF_SOCKS     optional  local SOCKS5 port (default 1080, 0 disables)
#   WF_SUFFIXES  optional  space-separated domain suffixes for the PAC file,
#                          e.g. ".internal.example.com"
#   WF_FORWARDS  optional  space-separated local forwards, ssh -L syntax without the
#                          bind address, e.g. "4466:127.0.0.1:4466"
#   WF_CHECK_URL optional  an internal https URL that `status` fetches through SOCKS
#   WF_DIR       optional  state directory (default ~/.web-forwards, keep it short:
#                          it holds a Unix socket)
set -eu

ENV_FILE=${WEB_FORWARDS_ENV:-$HOME/.config/web-forwards/env}
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

: "${WF_TAG:?set WF_TAG to the instance Name tag}"
: "${WF_USER:?set WF_USER to the Linux user on the host}"
WF_SOCKS=${WF_SOCKS:-1080}
WF_SUFFIXES=${WF_SUFFIXES:-}
WF_FORWARDS=${WF_FORWARDS:-}
WF_DIR=${WF_DIR:-$HOME/.web-forwards}
CTL=$WF_DIR/ctl.sock

AWS_ARGS=""
[ -n "${WF_PROFILE:-}" ] && AWS_ARGS="$AWS_ARGS --profile $WF_PROFILE"
[ -n "${WF_REGION:-}" ] && AWS_ARGS="$AWS_ARGS --region $WF_REGION"
# shellcheck disable=SC2086
awsq() { aws $AWS_ARGS "$@"; }

is_up() { ssh -S "$CTL" -O check web-forwards 2>/dev/null; }

up() {
  if is_up; then echo "already up"; return 0; fi
  mkdir -p "$WF_DIR"; chmod 700 "$WF_DIR"
  [ -f "$WF_DIR/key" ] || ssh-keygen -q -t ed25519 -N '' -C web-forwards -f "$WF_DIR/key"
  ID=$(awsq ec2 describe-instances \
    --filters "Name=tag:Name,Values=$WF_TAG" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -n "$ID" ] && [ "$ID" != "None" ] || { echo "no running instance tagged Name=$WF_TAG" >&2; exit 1; }
  awsq ec2-instance-connect send-ssh-public-key --instance-id "$ID" \
    --instance-os-user "$WF_USER" --ssh-public-key "file://$WF_DIR/key.pub" >/dev/null

  set -- -f -N -M -S "$CTL" -i "$WF_DIR/key" -o IdentitiesOnly=yes \
    -o ProxyCommand="aws $AWS_ARGS ssm start-session --target $ID --document-name AWS-StartSSHSession --parameters portNumber=%p" \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  [ "$WF_SOCKS" != "0" ] && set -- "$@" -D "127.0.0.1:$WF_SOCKS"
  for f in $WF_FORWARDS; do set -- "$@" -L "127.0.0.1:$f"; done
  ssh "$@" "$WF_USER@$ID"

  echo "up: $ID"
  [ "$WF_SOCKS" != "0" ] && echo "  SOCKS5 127.0.0.1:$WF_SOCKS"
  for f in $WF_FORWARDS; do echo "  http://127.0.0.1:${f%%:*} -> ${f#*:}"; done
  return 0
}

down() { ssh -S "$CTL" -O exit web-forwards 2>/dev/null && echo "down" || echo "not running"; }

status() {
  is_up || { echo "down"; return 1; }
  if [ -n "${WF_CHECK_URL:-}" ] && [ "$WF_SOCKS" != "0" ]; then
    curl -s -m 15 -o /dev/null -w "socks  http=%{http_code} %{time_total}s  $WF_CHECK_URL\n" \
      --socks5-hostname "127.0.0.1:$WF_SOCKS" "$WF_CHECK_URL" || true
  fi
  for f in $WF_FORWARDS; do
    curl -s -m 15 -o /dev/null -w "local  http=%{http_code} %{time_total}s  127.0.0.1:${f%%:*}\n" \
      "http://127.0.0.1:${f%%:*}/" || true
  done
}

pac() {
  echo 'function FindProxyForURL(url, host) {'
  for s in $WF_SUFFIXES; do
    echo "  if (dnsDomainIs(host, \"$s\")) return \"SOCKS5 127.0.0.1:$WF_SOCKS\";"
  done
  echo '  return "DIRECT";'
  echo '}'
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  pac) pac ;;
  *) echo "usage: web-forwards.sh up|down|status|pac" >&2; exit 2 ;;
esac
