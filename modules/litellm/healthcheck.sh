#!/usr/bin/env bash
# modules/litellm/healthcheck.sh — verify the LiteLLM gateway is up.
# Thin wrapper over the shared HTTP-readiness probe (lib/probe.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/probe.sh
source "$DIR/../../lib/probe.sh"
forge_http_ready litellm forge_litellm forge_internal "http://forge_litellm:4000/health/liveliness"
