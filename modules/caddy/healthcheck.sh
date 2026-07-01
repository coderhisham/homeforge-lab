#!/usr/bin/env bash
# modules/caddy/healthcheck.sh — verify Caddy is up and serving.
#
# Exit 0 = healthy, non-zero = not. Called by `forge.sh status` and after
# deploy. Uses the shared Docker helper if sourced within forge, else falls
# back to a bare `docker`.

set -euo pipefail

CONTAINER="forge_caddy"

# Resolve a docker invocation (respects sudo if needed), independent of forge.
_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "caddy: FAIL — $*" >&2; exit 1; }

# 1. Container exists and is running.
state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# 2. Docker health status, if the image defines one.
health="$(_dk inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo none)"
if [[ "$health" == "unhealthy" ]]; then fail "container reports unhealthy"; fi

# 3. Admin API responds inside the container (authoritative liveness signal).
if _dk exec "$CONTAINER" wget --quiet --tries=1 --spider http://localhost:2019/config/ 2>/dev/null; then
  echo "caddy: PASS — running; admin API responding (health=$health)"
  exit 0
fi

fail "admin API on localhost:2019 not responding"
