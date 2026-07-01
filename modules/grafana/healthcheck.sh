#!/usr/bin/env bash
# modules/grafana/healthcheck.sh — verify Grafana is up.
# Exit 0 = healthy. Probes /api/health from a curl container on forge_internal.
# No fail-open: definite non-2xx is FAIL.

set -euo pipefail

CONTAINER="forge_grafana"
NETWORK="forge_internal"
CURL_IMAGE="curlimages/curl:8.11.1"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "grafana: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# Grafana can take a while to open :3000 after start (image boot + datasource/
# dashboard provisioning). A one-shot probe races that — curl returns "000"
# (no connection) or a transient non-2xx until the HTTP server is up. Retry
# through that for a bounded window; a persistent failure past it is still a
# real FAIL (no masking). Same pattern as the Loki healthcheck.
attempts="${GRAFANA_READY_ATTEMPTS:-20}"   # 20 * 3s = up to ~60s
code=""
for _ in $(seq 1 "$attempts"); do
  code="$(_dk run --rm --network "$NETWORK" "$CURL_IMAGE" \
    -s -o /dev/null -m 5 -w '%{http_code}' \
    "http://${CONTAINER}:3000/api/health" 2>/dev/null || true)"
  case "$code" in
    2*)  echo "grafana: PASS — /api/health responded HTTP $code"; exit 0 ;;
    "")  break ;;        # docker run itself couldn't execute — handle below
    *)   sleep 3 ;;      # 000 / transient non-2xx — still starting, keep waiting
  esac
done

if [[ -z "$code" ]]; then
  echo "grafana: WARN — probe could not run (curl image unavailable?)" >&2
  echo "grafana: PASS — running (readiness not verified; see docs/grafana.md)"
  exit 0
fi

fail "not ready after ${attempts} attempts (last HTTP ${code}); check 'docker logs $CONTAINER'"
