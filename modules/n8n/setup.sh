#!/usr/bin/env bash
# modules/n8n/setup.sh — pre-deploy hook (run by forge_deploy_module before
# n8n starts). Wires n8n into the already-running Postgres + Redis WITHOUT
# duplicating or regenerating their secrets:
#   1. Read Postgres's + Redis's generated passwords from their own .env
#      (via forge_get_env) and write them into modules/n8n/.env.
#   2. Ensure the 'n8n' database + role exist in the running Postgres.
#
# Idempotent and DRY_RUN-aware. Requires postgres (and ideally redis) already
# deployed — the menu's dependency check enforces selection order.

set -euo pipefail

: "${FORGE_LIB:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)}"
: "${FORGE_MODULES:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../../lib/log.sh
source "$FORGE_LIB/log.sh"
# shellcheck source=../../lib/env.sh
source "$FORGE_LIB/env.sh"

N8N_ENV="$FORGE_MODULES/n8n/.env"
N8N_DB_NAME="n8n"

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else sudo docker "$@"; fi
}

# Set KEY=value in n8n/.env, replacing any existing assignment (in place).
set_env_kv() {
  local key="$1" val="$2"
  [[ -f "$N8N_ENV" ]] || { log_warn "n8n/.env not found; cannot set $key"; return 1; }
  if grep -qE "^[[:space:]]*${key}=" "$N8N_ENV"; then
    # Replace the line. Use a temp file (portable, no sed -i quoting hazards).
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$val" '
      $0 ~ "^[[:space:]]*"k"=" { print k"="v; next } { print }
    ' "$N8N_ENV" > "$tmp"
    cat "$tmp" > "$N8N_ENV"   # preserve original perms/inode (0600 from env.sh)
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >> "$N8N_ENV"
  fi
}

main() {
  log_info "n8n setup: wiring Postgres + Redis credentials…"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] would read Postgres/Redis passwords via forge_get_env and write them into n8n/.env."
    log_info "[dry-run] would ensure database '$N8N_DB_NAME' + role exist in forge_postgres."
    return 0
  fi

  # 1. Postgres password (must match what Postgres generated).
  local pg_pass pg_user
  pg_pass="$(forge_get_env postgres POSTGRES_PASSWORD || true)"
  pg_user="$(forge_get_env postgres POSTGRES_USER || echo forge)"
  if [[ -z "$pg_pass" ]]; then
    log_die "Could not read Postgres password (is the postgres module installed?). n8n needs it."
  fi
  set_env_kv N8N_DB_PASSWORD "$pg_pass"
  set_env_kv N8N_DB_USER "$pg_user"

  # 2. Redis password (optional — only if redis is present).
  local redis_pass
  redis_pass="$(forge_get_env redis REDIS_PASSWORD || true)"
  [[ -n "$redis_pass" ]] && set_env_kv N8N_REDIS_PASSWORD "$redis_pass"

  # 3. Ensure the n8n database + role exist in the running Postgres. The role
  #    reuses the superuser (pg_user) for simplicity in a single-tenant homelab;
  #    n8n connects as that user to its own database.
  if ! _dk inspect forge_postgres >/dev/null 2>&1; then
    log_die "forge_postgres is not running; deploy postgres before n8n."
  fi
  log_info "Ensuring Postgres database '$N8N_DB_NAME' exists…"
  # Create the database if absent (createdb is a no-op-safe guard via SELECT).
  if _dk exec forge_postgres sh -c "psql -U \"$pg_user\" -tAc \"SELECT 1 FROM pg_database WHERE datname='$N8N_DB_NAME'\"" 2>/dev/null | grep -q 1; then
    log_ok "Database '$N8N_DB_NAME' already exists."
  else
    _dk exec forge_postgres sh -c "createdb -U \"$pg_user\" -O \"$pg_user\" \"$N8N_DB_NAME\"" \
      && log_ok "Created database '$N8N_DB_NAME'." \
      || log_die "Failed to create database '$N8N_DB_NAME'."
  fi

  log_ok "n8n setup complete."
}

main "$@"
