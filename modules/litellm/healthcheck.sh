#!/usr/bin/env bash
# modules/litellm/healthcheck.sh — verify the LiteLLM gateway is up.
# Exit 0 = healthy. Called by `forge.sh status` and after deploy.
#
# Probes /health/liveliness from a throwaway curl container on the internal
# network (independent of what tools the LiteLLM image ships). No fail-open: a
# definite non-2xx is FAIL; only an un-runnable probe falls back to liveness.

set -euo pipefail

CONTAINER="forge_litellm"
NETWORK="forge_internal"
CURL_IMAGE="curlimages/curl:8.11.1"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "litellm: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

code="$(_dk run --rm --network "$NETWORK" "$CURL_IMAGE" \
  -s -o /dev/null -m 5 -w '%{http_code}' \
  "http://${CONTAINER}:4000/health/liveliness" 2>/dev/null || true)"

if [[ -z "$code" ]]; then
  echo "litellm: WARN — readiness probe could not run (curl image unavailable?)" >&2
  echo "litellm: PASS — running (readiness not verified; see docs/litellm.md)"
  exit 0
fi

case "$code" in
  2*) echo "litellm: PASS — /health/liveliness responded HTTP $code"; exit 0 ;;
  *)  fail "reachable but /health/liveliness returned HTTP ${code}" ;;
esac
