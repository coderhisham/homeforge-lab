#!/usr/bin/env bash
# modules/qdrant/healthcheck.sh — verify Qdrant is ready.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh): bounded
# retry through startup, no fail-open. Qdrant's /readyz is auth-exempt.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
tuninforge_http_ready qdrant tuninforge_qdrant tuninforge_internal "http://tuninforge_qdrant:6333/readyz"
