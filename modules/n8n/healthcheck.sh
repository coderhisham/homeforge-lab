#!/usr/bin/env bash
# modules/n8n/healthcheck.sh — verify n8n is up and serving.
# Exit 0 = healthy. Called by `forge.sh status` and after deploy.
#
# Probes /healthz from a throwaway curl container on the internal network
# (independent of the n8n image's tooling). No fail-open: a definite non-2xx is
# FAIL; only an un-runnable probe falls back to liveness.

set -euo pipefail

CONTAINER="forge_n8n"
NETWORK="forge_internal"
CURL_IMAGE="curlimages/curl:8.11.1"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "n8n: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

code="$(_dk run --rm --network "$NETWORK" "$CURL_IMAGE" \
  -s -o /dev/null -m 5 -w '%{http_code}' \
  "http://${CONTAINER}:5678/healthz" 2>/dev/null || true)"

if [[ -z "$code" ]]; then
  echo "n8n: WARN — readiness probe could not run (curl image unavailable?)" >&2
  echo "n8n: PASS — running (readiness not verified; see docs/n8n.md)"
  exit 0
fi

case "$code" in
  2*) echo "n8n: PASS — /healthz responded HTTP $code"; exit 0 ;;
  *)  fail "reachable but /healthz returned HTTP ${code}; check 'docker logs $CONTAINER'" ;;
esac
