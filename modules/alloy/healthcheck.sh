#!/usr/bin/env bash
# modules/alloy/healthcheck.sh — verify Grafana Alloy is up and ready.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
tuninforge_http_ready alloy tuninforge_alloy tuninforge_internal "http://tuninforge_alloy:12345/-/ready"
