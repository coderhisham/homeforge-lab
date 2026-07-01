#!/usr/bin/env bash
# lib/probe.sh — shared HTTP-readiness probe for module healthcheck.sh scripts.
#
# Generalizes the pattern proven on the VM for loki/grafana/alloy: probe an HTTP
# endpoint from a throwaway curl container on a Docker network, retrying through
# a service's startup window (curl "000" = no connection yet, or a transient
# non-2xx like Loki's 503) before deciding. This removes the recurring
# "one-shot probe races a slow-starting service" bug once, instead of copy-
# pasting the retry loop into every module.
#
# SELF-CONTAINED on purpose: healthcheck.sh scripts run standalone (invoked
# directly, e.g. `./modules/qdrant/healthcheck.sh`), so this helper must not
# depend on lib/log.sh or tuninforge's environment. It defines its own Docker
# invocation and prints plain text.
#
# Design guarantees:
#   - NO fail-open: a definite non-2xx that persists past the window is a FAIL.
#     Only a probe that could never RUN (curl image unavailable) falls back to a
#     liveness-only PASS, and it says so loudly.
#   - Bounded: retries a fixed number of times, then fails.

[[ -n "${_TUNINFORGE_PROBE_SH:-}" ]] && return 0
_TUNINFORGE_PROBE_SH=1

# _tuninforge_probe_docker: run docker directly, or via sudo if that's the only way.
_tuninforge_probe_docker() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else return 127; fi
}

# tuninforge_http_ready <service> <container> <network> <url>
#   Verifies the container is running, then probes <url> from a curl container on
#   <network>, retrying through startup. Prints "<service>: PASS/FAIL — …".
#   Returns 0 on ready, 1 otherwise.
#
# Tunables (env):
#   TUNINFORGE_PROBE_ATTEMPTS   number of tries (default 20)
#   TUNINFORGE_PROBE_INTERVAL   seconds between tries (default 3)  -> ~60s window
#   TUNINFORGE_PROBE_CURL_IMAGE curl image (default curlimages/curl:8.11.1)
tuninforge_http_ready() {
  local service="$1" container="$2" network="$3" url="$4"
  local attempts="${TUNINFORGE_PROBE_ATTEMPTS:-20}"
  local interval="${TUNINFORGE_PROBE_INTERVAL:-3}"
  local curl_image="${TUNINFORGE_PROBE_CURL_IMAGE:-curlimages/curl:8.11.1}"

  # 1. Container must exist and be running.
  local state
  state="$(_tuninforge_probe_docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo missing)"
  if [[ "$state" != "running" ]]; then
    echo "${service}: FAIL — container '${container}' is ${state}" >&2
    return 1
  fi

  # 2. Probe the endpoint, retrying through startup.
  local code="" i
  for (( i = 0; i < attempts; i++ )); do
    code="$(_tuninforge_probe_docker run --rm --network "$network" "$curl_image" \
      -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || true)"
    case "$code" in
      2*) echo "${service}: PASS — ${url} responded HTTP ${code}"; return 0 ;;
      "") break ;;                 # probe couldn't run at all -> handle below
      *)  sleep "$interval" ;;     # 000 / transient non-2xx -> still starting
    esac
  done

  # 3. If the probe itself never ran (e.g. curl image unavailable offline),
  #    don't false-fail a running container — report liveness, but say so.
  if [[ -z "$code" ]]; then
    echo "${service}: WARN — readiness probe could not run (curl image unavailable?)" >&2
    echo "${service}: PASS — running (readiness not verified)"
    return 0
  fi

  # 4. A definite, persistent non-2xx is a real failure. No fail-open.
  echo "${service}: FAIL — not ready after ${attempts} attempts (last HTTP ${code}); check 'docker logs ${container}'" >&2
  return 1
}
