#!/usr/bin/env bash
# modules/ollama/healthcheck.sh — verify Ollama is up and serving.
# Exit 0 = healthy. Called by `forge.sh status` and after deploy.

set -euo pipefail

CONTAINER="forge_ollama"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

fail() { echo "ollama: FAIL — $*" >&2; exit 1; }

state="$(_dk inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
[[ "$state" == "running" ]] || fail "container '$CONTAINER' is $state"

# `ollama list` succeeds only once the server is accepting API calls. The CLI
# ships in the image, so this needs no external tools.
if _dk exec "$CONTAINER" ollama list >/dev/null 2>&1; then
  echo "ollama: PASS — server responding ('ollama list' OK)"
  exit 0
fi
fail "server not responding to 'ollama list' yet (still loading?); check 'docker logs $CONTAINER'"
