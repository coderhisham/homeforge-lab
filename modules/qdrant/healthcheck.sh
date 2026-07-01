#!/usr/bin/env bash
# modules/qdrant/healthcheck.sh — verify Qdrant is ready.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh): bounded
# retry through startup, no fail-open. Qdrant's /readyz is auth-exempt.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
forge_http_ready qdrant forge_qdrant forge_internal "http://forge_qdrant:6333/readyz"
