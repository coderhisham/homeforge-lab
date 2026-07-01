#!/usr/bin/env bash
# lib/health.sh — wait for containers to become healthy and report PASS/FAIL.
#
# The installer reports success only after a service is actually healthy. We use
# Docker's own healthcheck where the image/compose defines one; if a container
# declares no healthcheck, "healthy" is defined as "running and not restarting"
# after a short settle — so we never hang forever waiting on a status that will
# never appear.
#
# Depends on: lib/log.sh, lib/network.sh (for tuninforge_docker_q).

[[ -n "${_TUNINFORGE_HEALTH_SH:-}" ]] && return 0
_TUNINFORGE_HEALTH_SH=1

TUNINFORGE_HEALTH_TIMEOUT="${TUNINFORGE_HEALTH_TIMEOUT:-120}"  # seconds per container
TUNINFORGE_HEALTH_INTERVAL="${TUNINFORGE_HEALTH_INTERVAL:-3}"  # poll cadence

# _container_state <name> -> prints the .State.Status (running/restarting/exited…)
_container_state() {
  tuninforge_docker_q inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "missing"
}

# _container_health <name> -> prints health status, or "none" if no healthcheck:
#   starting | healthy | unhealthy | none | missing
_container_health() {
  local out
  out="$(tuninforge_docker_q inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null)" || { echo "missing"; return; }
  echo "${out:-none}"
}

# tuninforge_wait_healthy <container> [timeout] -> 0 if healthy, 1 otherwise.
# Polls until the container is healthy (or, if no healthcheck, stably running),
# printing a single progress line that updates in place.
tuninforge_wait_healthy() {
  local name="$1" timeout="${2:-$TUNINFORGE_HEALTH_TIMEOUT}"
  local waited=0 state health stable=0

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] would wait up to ${timeout}s for '$name' to become healthy."
    return 0
  fi

  while [[ "$waited" -lt "$timeout" ]]; do
    state="$(_container_state "$name")"
    health="$(_container_health "$name")"

    case "$state" in
      missing)
        log_error "Container '$name' does not exist."
        return 1 ;;
      exited|dead)
        log_error "Container '$name' is $state (crashed on startup?)."
        return 1 ;;
    esac

    case "$health" in
      healthy)
        log_ok "'$name' is healthy (${waited}s)."
        return 0 ;;
      unhealthy)
        log_error "'$name' reports unhealthy after ${waited}s."
        return 1 ;;
      none)
        # No healthcheck defined: require the container to stay 'running' across
        # two consecutive polls before calling it good (guards against a crash
        # loop that is momentarily 'running').
        if [[ "$state" == "running" ]]; then
          stable=$((stable + 1))
          if [[ "$stable" -ge 2 ]]; then
            log_ok "'$name' is running (no healthcheck defined; ${waited}s)."
            return 0
          fi
        else
          stable=0
        fi ;;
      starting|*)
        stable=0 ;;
    esac

    printf '\r  %swaiting for %s… %ss (state=%s health=%s)%s' \
      "${C_DIM}" "$name" "$waited" "$state" "$health" "${C_RESET}" >&2
    sleep "$TUNINFORGE_HEALTH_INTERVAL"
    waited=$((waited + TUNINFORGE_HEALTH_INTERVAL))
  done

  printf '\n' >&2
  log_error "'$name' did not become healthy within ${timeout}s (last: state=$state health=$health)."
  return 1
}

# tuninforge_wait_healthy_all <container...> -> 0 only if every one is healthy.
# Prints a per-service PASS/FAIL summary at the end.
tuninforge_wait_healthy_all() {
  local overall=0 name
  local -a passed=() failed=()
  for name in "$@"; do
    if tuninforge_wait_healthy "$name"; then
      passed+=("$name")
    else
      failed+=("$name"); overall=1
    fi
  done

  printf '\n' >&2
  log_step "Health summary"
  for name in "${passed[@]}"; do log_ok  "PASS  $name"; done
  for name in "${failed[@]}"; do log_error "FAIL  $name"; done
  return "$overall"
}
