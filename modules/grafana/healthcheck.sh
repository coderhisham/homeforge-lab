#!/usr/bin/env bash
# modules/grafana/healthcheck.sh — verify Grafana is up.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh). Grafana can
# take a while to open :3000 (boot + provisioning); the shared retry handles it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
tuninforge_http_ready grafana tuninforge_grafana tuninforge_internal "http://tuninforge_grafana:3000/api/health"
