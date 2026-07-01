#!/usr/bin/env bash
# modules/portainer/healthcheck.sh — verify Portainer is up and serving.
#
# Exit 0 = healthy, non-zero = not. Called by `forge.sh status` and after deploy.

set -euo pipefail

CONTAINER="forge_portainer"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "portainer: FAIL — $*" >&2; exit 1; }

# 1. Running?
state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# 2. Docker health status if defined.
health="$(_dk inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo none)"
[[ "$health" == "unhealthy" ]] && fail "container reports unhealthy"

# 3. Status API responds inside the container.
if _dk exec "$CONTAINER" wget --quiet --tries=1 --spider http://localhost:9000/api/status 2>/dev/null; then
  echo "portainer: PASS — running; status API responding (health=$health)"
  exit 0
fi

fail "status API on localhost:9000 not responding"
