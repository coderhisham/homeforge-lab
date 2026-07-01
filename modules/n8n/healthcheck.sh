#!/usr/bin/env bash
# modules/n8n/healthcheck.sh — verify n8n is up.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
forge_http_ready n8n forge_n8n forge_internal "http://forge_n8n:5678/healthz"
