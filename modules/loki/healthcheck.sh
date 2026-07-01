#!/usr/bin/env bash
# modules/loki/healthcheck.sh — verify Loki is ready.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh). Loki's
# /ready returns 503 during startup; the shared retry rides through it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
forge_http_ready loki forge_loki forge_internal "http://forge_loki:3100/ready"
