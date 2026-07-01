#!/usr/bin/env bash
# lib/network.sh — shared Docker networks + the Docker invocation helper.
#
# tuninforge uses two networks (created idempotently):
#   tuninforge_public   — bridge; Caddy-fronted, internet/tailnet-reachable services
#                    attach here. Caddy joins it and reverse-proxies the rest.
#   tuninforge_internal — bridge with --internal (NO outbound/gateway); the data
#                    layer (Postgres/Redis/…) lives here so it is reachable only
#                    by services that explicitly join it, never from outside.
#
# This is also the first lib to run Docker, so it defines tuninforge_docker(): the
# canonical way every module invokes Docker (handles the sudo-vs-docker-group
# question once). health.sh and compose.sh reuse it.
#
# Depends on: lib/log.sh.

[[ -n "${_TUNINFORGE_NETWORK_SH:-}" ]] && return 0
_TUNINFORGE_NETWORK_SH=1

TUNINFORGE_NET_PUBLIC="tuninforge_public"
TUNINFORGE_NET_INTERNAL="tuninforge_internal"

# --- Docker invocation -------------------------------------------------------
# _TUNINFORGE_DOCKER_SUDO is resolved once: "" if we can talk to Docker directly
# (root, or user in the docker group), "sudo" if we must escalate.
_TUNINFORGE_DOCKER_SUDO=""
_tuninforge_docker_probe_done=0

_tuninforge_docker_probe() {
  [[ "$_tuninforge_docker_probe_done" == "1" ]] && return 0
  _tuninforge_docker_probe_done=1
  if ! command -v docker >/dev/null 2>&1; then
    return 0   # absence handled by callers via tuninforge_require_docker
  fi
  if docker info >/dev/null 2>&1; then
    _TUNINFORGE_DOCKER_SUDO=""
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    _TUNINFORGE_DOCKER_SUDO="sudo"
  fi
}

# tuninforge_docker <args...> — run docker, escalating with sudo only if required.
# Honors DRY_RUN via run_cmd. Use this everywhere instead of bare `docker`.
tuninforge_docker() {
  _tuninforge_docker_probe
  if [[ -n "$_TUNINFORGE_DOCKER_SUDO" ]]; then
    run_cmd sudo docker "$@"
  else
    run_cmd docker "$@"
  fi
}

# tuninforge_docker_q <args...> — non-dry-run, quiet query form for read-only checks
# (inspect/ps) whose OUTPUT we need even in dry-run. Never mutates state.
tuninforge_docker_q() {
  _tuninforge_docker_probe
  if [[ -n "$_TUNINFORGE_DOCKER_SUDO" ]]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

# tuninforge_require_docker — ensure Docker is usable; die with guidance otherwise.
tuninforge_require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log_die "Docker is not installed. The core layer installs it; run the Docker module first."
  fi
  _tuninforge_docker_probe
  if ! tuninforge_docker_q info >/dev/null 2>&1; then
    log_die "Cannot talk to the Docker daemon (not running, or permission denied). Try: sudo systemctl start docker"
  fi
}

# --- Network creation --------------------------------------------------------
# _net_exists <name> -> 0 if the network already exists.
_net_exists() {
  tuninforge_docker_q network inspect "$1" >/dev/null 2>&1
}

# tuninforge_ensure_network <name> [--internal] — create the network if missing.
# Idempotent: existing networks are left untouched (never recreated).
tuninforge_ensure_network() {
  local name="$1" internal="${2:-}"
  if _net_exists "$name"; then
    log_debug "network: $name already exists."
    return 0
  fi
  if [[ "$internal" == "--internal" ]]; then
    log_info "Creating internal Docker network '$name' (no outbound; data layer only)."
    tuninforge_docker network create --driver bridge --internal "$name" >/dev/null
  else
    log_info "Creating Docker network '$name'."
    tuninforge_docker network create --driver bridge "$name" >/dev/null
  fi
  [[ "${DRY_RUN:-0}" == "1" ]] || log_ok "Network '$name' ready."
}

# tuninforge_ensure_networks — create both shared networks. Called before bringing up
# any Caddy-fronted or data-layer service.
tuninforge_ensure_networks() {
  tuninforge_require_docker
  tuninforge_ensure_network "$TUNINFORGE_NET_PUBLIC"
  tuninforge_ensure_network "$TUNINFORGE_NET_INTERNAL" --internal
}
