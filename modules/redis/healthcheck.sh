#!/usr/bin/env bash
# modules/redis/healthcheck.sh — verify Redis is up and authenticating.
# Exit 0 = healthy. Called by `forge.sh status` and after deploy.

set -euo pipefail

CONTAINER="forge_redis"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "redis: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# Run redis-cli INSIDE the container so it uses the container's own
# $REDIS_PASSWORD env var — the password never touches the host process list.
if _dk exec "$CONTAINER" sh -c 'redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG'; then
  echo "redis: PASS — responding to authenticated PING"
  exit 0
fi
fail "authenticated PING did not return PONG"
