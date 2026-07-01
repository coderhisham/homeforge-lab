#!/usr/bin/env bash
# lib/compose.sh — docker compose wrappers with per-module .env wiring.
#
# Each service module is a directory under modules/<name>/ containing a
# docker-compose.yml, an .env.example, and a healthcheck.sh. This library runs
# compose for a module with its own .env loaded, and orchestrates the standard
# deploy sequence: materialize .env -> ensure networks -> pull -> up -> wait
# healthy.
#
# Detects the modern `docker compose` (plugin) and falls back to the legacy
# `docker-compose` binary. All state-changing calls honor DRY_RUN.
#
# Depends on: lib/log.sh, lib/secrets.sh, lib/env.sh, lib/network.sh, lib/health.sh.

[[ -n "${_FORGE_COMPOSE_SH:-}" ]] && return 0
_FORGE_COMPOSE_SH=1

# _FORGE_COMPOSE_CMD is resolved once to an array: ("docker" "compose") or
# ("docker-compose"). Empty until probed.
_FORGE_COMPOSE_CMD=()
_forge_compose_probe_done=0

_forge_compose_probe() {
  [[ "$_forge_compose_probe_done" == "1" ]] && return 0
  _forge_compose_probe_done=1
  # Prefer the v2 plugin (`docker compose`); it shares Docker's sudo posture.
  if forge_docker_q compose version >/dev/null 2>&1; then
    if [[ -n "$_FORGE_DOCKER_SUDO" ]]; then
      _FORGE_COMPOSE_CMD=(sudo docker compose)
    else
      _FORGE_COMPOSE_CMD=(docker compose)
    fi
  elif command -v docker-compose >/dev/null 2>&1; then
    if [[ -n "$_FORGE_DOCKER_SUDO" ]]; then
      _FORGE_COMPOSE_CMD=(sudo docker-compose)
    else
      _FORGE_COMPOSE_CMD=(docker-compose)
    fi
  fi
}

# forge_have_compose -> 0 if a compose implementation is available.
forge_have_compose() {
  _forge_docker_probe
  _forge_compose_probe
  [[ "${#_FORGE_COMPOSE_CMD[@]}" -gt 0 ]]
}

# _module_dir <name> -> absolute module directory path.
_module_dir() { echo "${FORGE_MODULES:-modules}/$1"; }

# forge_compose <module> <compose-args...> — run compose for a module, scoped to
# its directory + .env, with a stable project name (forge_<module>). Honors
# DRY_RUN for state-changing subcommands.
forge_compose() {
  local module="$1"; shift
  local dir; dir="$(_module_dir "$module")"
  local file="$dir/docker-compose.yml" envfile="$dir/.env"

  [[ -f "$file" ]] || log_die "compose: $file not found for module '$module'."
  _forge_docker_probe
  _forge_compose_probe
  forge_have_compose || log_die "compose: neither 'docker compose' nor 'docker-compose' is available."

  local -a base=("${_FORGE_COMPOSE_CMD[@]}" -p "forge_${module}" -f "$file")
  [[ -f "$envfile" ]] && base+=(--env-file "$envfile")

  run_cmd "${base[@]}" "$@"
}

# forge_module_containers <module> -> names of containers for the module (running
# or not). Used to feed the health waiter and status. Read-only.
forge_module_containers() {
  local module="$1"
  local dir; dir="$(_module_dir "$module")"
  local file="$dir/docker-compose.yml" envfile="$dir/.env"
  [[ -f "$file" ]] || return 0
  _forge_docker_probe; _forge_compose_probe
  forge_have_compose || return 0
  local -a base=("${_FORGE_COMPOSE_CMD[@]}" -p "forge_${module}" -f "$file")
  [[ -f "$envfile" ]] && base+=(--env-file "$envfile")
  "${base[@]}" ps --format '{{.Names}}' 2>/dev/null || true
}

# --- Standard deploy sequence ------------------------------------------------
# forge_deploy_module <module> — the full, idempotent bring-up for one module:
#   1. materialize .env (generate secrets on first run)
#   2. ensure shared networks exist
#   3. pull images
#   4. up -d
#   5. wait for health, report PASS/FAIL
# Returns non-zero if the module does not end up healthy.
forge_deploy_module() {
  local module="$1"
  local dir; dir="$(_module_dir "$module")"
  [[ -d "$dir" ]] || log_die "deploy: module directory $dir does not exist."

  log_step "Deploying '$module'"

  # 1. .env (secrets). The one-time secret notice is flushed by the caller after
  #    all modules are materialized, so a multi-service install shows them once.
  env_materialize "$dir" "$module"

  # 2. networks.
  forge_ensure_networks

  # 3. pull (best-effort; a pull failure shouldn't abort if an image is cached).
  log_info "Pulling images for '$module'…"
  forge_compose "$module" pull || log_warn "Pull reported issues for '$module'; continuing (image may be cached)."

  # 4. up.
  log_info "Starting '$module'…"
  forge_compose "$module" up -d || log_die "compose up failed for '$module'."

  # 5. health.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] would wait for '$module' containers to become healthy."
    return 0
  fi
  local -a containers=()
  local c
  while IFS= read -r c; do [[ -n "$c" ]] && containers+=("$c"); done < <(forge_module_containers "$module")
  if [[ "${#containers[@]}" -eq 0 ]]; then
    log_warn "No containers reported for '$module'; cannot verify health."
    return 1
  fi
  forge_wait_healthy_all "${containers[@]}"
}

# forge_teardown_module <module> [--purge-volumes] — stop & remove a module's
# containers. With --purge-volumes also deletes named volumes (DESTRUCTIVE).
forge_teardown_module() {
  local module="$1" purge="${2:-}"
  local dir; dir="$(_module_dir "$module")"
  [[ -f "$dir/docker-compose.yml" ]] || { log_warn "teardown: no compose file for '$module'."; return 0; }

  if [[ "$purge" == "--purge-volumes" ]]; then
    log_warn "Removing '$module' containers AND named volumes (data will be lost)."
    forge_compose "$module" down --volumes
  else
    log_info "Removing '$module' containers (volumes preserved)."
    forge_compose "$module" down
  fi
}
