#!/usr/bin/env bash
# modules/watchtower/healthcheck.sh — verify Watchtower is running.
# Exit 0 = healthy. Watchtower is a background poller with NO network port /
# HTTP endpoint, so the only meaningful liveness signal is its run-state: it must
# be 'running' and not restarting/exited (which would indicate a crash loop,
# e.g. it can't reach the Docker socket).

set -euo pipefail

CONTAINER="forge_watchtower"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "watchtower: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
case "$state" in
  running)          echo "watchtower: PASS — running (polls for updates on labeled containers)"; exit 0 ;;
  restarting)       fail "container is restarting (crash loop — can it reach the Docker socket?)" ;;
  exited|dead)      fail "container is $state; check 'docker logs $CONTAINER'" ;;
  missing)          fail "container '$CONTAINER' does not exist" ;;
  *)                fail "unexpected state '$state'" ;;
esac
