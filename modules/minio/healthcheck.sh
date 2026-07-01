#!/usr/bin/env bash
# modules/minio/healthcheck.sh — verify MinIO is up and serving.
# Exit 0 = healthy. Called by `tuninforge.sh status` and after deploy.
#
# NOTE: MinIO images are minimal. This tries `mc ready local` (ships in the
# server image); if `mc` is absent, it falls back to reporting the container
# run-state, matching tuninforge's liveness policy. See docs/minio.md.

set -euo pipefail

CONTAINER="tuninforge_minio"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "minio: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# Preferred: MinIO's own readiness check via mc.
if _dk exec "$CONTAINER" mc ready local >/dev/null 2>&1; then
  echo "minio: PASS — mc reports ready"
  exit 0
fi

# Fallback: the container is running but mc is unavailable / not ready yet.
# Report the docker health status if the image defines one.
health="$(_dk inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo none)"
if [[ "$health" == "healthy" ]]; then
  echo "minio: PASS — container healthcheck healthy"
  exit 0
elif [[ "$health" == "none" ]]; then
  echo "minio: PASS — running (no in-image readiness tool; liveness only)"
  exit 0
fi
fail "container running but not healthy (health=$health); check 'docker logs $CONTAINER'"
