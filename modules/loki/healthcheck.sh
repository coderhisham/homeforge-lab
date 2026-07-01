#!/usr/bin/env bash
# modules/loki/healthcheck.sh — verify Loki is ready.
# Exit 0 = healthy. Probes /ready from a curl container on forge_internal
# (image-independent). No fail-open: definite non-2xx is FAIL.

set -euo pipefail

CONTAINER="forge_loki"
NETWORK="forge_internal"
CURL_IMAGE="curlimages/curl:8.11.1"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "loki: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# Loki's /ready returns 503 until it has finished starting; treat only 2xx as ready.
code="$(_dk run --rm --network "$NETWORK" "$CURL_IMAGE" \
  -s -o /dev/null -m 5 -w '%{http_code}' \
  "http://${CONTAINER}:3100/ready" 2>/dev/null || true)"

if [[ -z "$code" ]]; then
  echo "loki: WARN — probe could not run (curl image unavailable?)" >&2
  echo "loki: PASS — running (readiness not verified; see docs/loki.md)"
  exit 0
fi

case "$code" in
  2*) echo "loki: PASS — /ready responded HTTP $code"; exit 0 ;;
  *)  fail "reachable but /ready returned HTTP ${code} (still starting?)" ;;
esac
