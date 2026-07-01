#!/usr/bin/env bash
# modules/n8n/healthcheck.sh — verify n8n is up.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
tuninforge_http_ready n8n tuninforge_n8n tuninforge_internal "http://tuninforge_n8n:5678/healthz"
