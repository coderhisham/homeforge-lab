#!/usr/bin/env bash
# modules/prometheus/healthcheck.sh — verify Prometheus is up.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
tuninforge_http_ready prometheus tuninforge_prometheus tuninforge_internal "http://tuninforge_prometheus:9090/-/healthy"
