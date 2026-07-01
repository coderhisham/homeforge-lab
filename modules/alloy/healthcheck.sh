#!/usr/bin/env bash
# modules/alloy/healthcheck.sh — verify Grafana Alloy is up and ready.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
forge_http_ready alloy forge_alloy forge_internal "http://forge_alloy:12345/-/ready"
