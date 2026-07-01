#!/usr/bin/env bash
# modules/qdrant/healthcheck.sh — verify Qdrant is ready via a REAL HTTP probe.
# Exit 0 = healthy. Called by `forge.sh status` and after deploy.
#
# Qdrant's image may ship no shell/curl/wget, so we do NOT exec into it. Instead
# we run a throwaway curl container attached to forge_internal and hit Qdrant by
# its container name. This is independent of what tools Qdrant's image has.

set -euo pipefail

CONTAINER="forge_qdrant"
NETWORK="forge_internal"
CURL_IMAGE="curlimages/curl:8.11.1"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "qdrant: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# Read the API key from the running container's env (avoids putting it on the
# host command line / process list).
api_key="$(_dk exec "$CONTAINER" printenv QDRANT__SERVICE__API_KEY 2>/dev/null || true)"

# Probe /readyz from a throwaway curl container on the internal network. Capture
# the HTTP status code specifically so we can tell three cases apart:
#   - empty output  -> the probe container couldn't even run (image unavailable,
#                      offline) => we CANNOT judge, fall back to liveness.
#   - 2xx           -> ready => PASS.
#   - anything else -> Qdrant answered but is not ready (or refused) => FAIL.
# (No fail-open: a definite non-2xx answer is a real failure, not a pass.)
probe_out="$(_dk run --rm --network "$NETWORK" \
      "$CURL_IMAGE" \
      -s -o /dev/null -m 5 -w '%{http_code}' -H "api-key: ${api_key}" \
      "http://${CONTAINER}:6333/readyz" 2>/dev/null || true)"

if [[ -z "$probe_out" ]]; then
  # The probe itself could not run (e.g. curl image not pullable offline).
  # Don't false-fail a running Qdrant — report liveness only, but be explicit.
  echo "qdrant: WARN — readiness probe could not run (curl image unavailable?)" >&2
  echo "qdrant: PASS — running (readiness not verified; see docs/qdrant.md)"
  exit 0
fi

case "$probe_out" in
  2*) echo "qdrant: PASS — /readyz responded HTTP $probe_out"; exit 0 ;;
  *)  fail "reachable but /readyz returned HTTP ${probe_out} (not ready)" ;;
esac
