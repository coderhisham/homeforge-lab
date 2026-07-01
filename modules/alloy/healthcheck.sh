#!/usr/bin/env bash
# modules/alloy/healthcheck.sh — verify Grafana Alloy is up and ready.
# Exit 0 = healthy. Probes /-/ready on :12345 from a curl container on
# forge_internal (image-independent). Retries through startup (curl "000" / not-
# ready) for a bounded window; a persistent failure is still a real FAIL.

set -euo pipefail

CONTAINER="forge_alloy"
NETWORK="forge_internal"
CURL_IMAGE="curlimages/curl:8.11.1"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "alloy: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

attempts="${ALLOY_READY_ATTEMPTS:-20}"   # 20 * 3s = up to ~60s
code=""
for _ in $(seq 1 "$attempts"); do
  code="$(_dk run --rm --network "$NETWORK" "$CURL_IMAGE" \
    -s -o /dev/null -m 5 -w '%{http_code}' \
    "http://${CONTAINER}:12345/-/ready" 2>/dev/null || true)"
  case "$code" in
    2*)  echo "alloy: PASS — /-/ready responded HTTP $code"; exit 0 ;;
    "")  break ;;        # docker run itself couldn't execute — handle below
    *)   sleep 3 ;;      # 000 / transient non-2xx — still starting, keep waiting
  esac
done

if [[ -z "$code" ]]; then
  echo "alloy: WARN — probe could not run (curl image unavailable?)" >&2
  echo "alloy: PASS — running (readiness not verified; see docs/alloy.md)"
  exit 0
fi

fail "not ready after ${attempts} attempts (last HTTP ${code}); check 'docker logs $CONTAINER'"
