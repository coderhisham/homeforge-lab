#!/usr/bin/env bash
# modules/postgres/healthcheck.sh — verify Postgres is accepting connections.
# Exit 0 = healthy. Called by `forge.sh status` and after deploy.

set -euo pipefail

CONTAINER="forge_postgres"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "postgres: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# pg_isready inside the container is the authoritative readiness signal.
if _dk exec "$CONTAINER" pg_isready -q 2>/dev/null; then
  echo "postgres: PASS — accepting connections"
  exit 0
fi
fail "pg_isready reports not ready"
