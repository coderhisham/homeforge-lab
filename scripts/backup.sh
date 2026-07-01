#!/usr/bin/env bash
# scripts/backup.sh — encrypted backups of the tuninforge data layer via Restic.
#
# What it backs up:
#   - Every Docker volume named tuninforge_*_data (postgres, redis, minio, qdrant,
#     caddy, portainer, …), tarred from a throwaway alpine container.
#   - A Postgres logical dump (pg_dumpall) when tuninforge_postgres is running — kept
#     for manual / cross-version recovery. On a normal restore the data VOLUME
#     is the source; the dump is only auto-applied as a fallback when the volume
#     is missing from the snapshot (applying both would duplicate rows).
#
# Repository (encrypted, deduplicated, by Restic):
#   - Default: a LOCAL repo at $TUNINFORGE_BACKUP_REPO (default /var/lib/tuninforge/restic).
#   - Redirect to S3 / Backblaze B2 / SFTP / rest-server by exporting standard
#     Restic env before running (see docs/backup.md), e.g.:
#         export RESTIC_REPOSITORY="s3:s3.amazonaws.com/my-bucket/tuninforge"
#         export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
#     Anything in the environment overrides the local default below.
#
# Encryption password:
#   - $TUNINFORGE_RESTIC_PASSWORD_FILE (default /var/lib/tuninforge/restic.pass), 0600,
#     git-ignored, auto-generated on first run and shown ONCE. WITHOUT THIS
#     PASSWORD YOUR BACKUPS CANNOT BE DECRYPTED — save it.
#
# Honors DRY_RUN. Restore is scripts/restore.sh.

set -euo pipefail

TUNINFORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/log.sh
source "$TUNINFORGE_ROOT/lib/log.sh"

: "${DRY_RUN:=0}"
TUNINFORGE_BACKUP_REPO="${TUNINFORGE_BACKUP_REPO:-/var/lib/tuninforge/restic}"
TUNINFORGE_RESTIC_PASSWORD_FILE="${TUNINFORGE_RESTIC_PASSWORD_FILE:-/var/lib/tuninforge/restic.pass}"
STAGING_PARENT="${TUNINFORGE_BACKUP_STAGING:-/var/lib/tuninforge/staging}"
HELPER_IMAGE="alpine:3.20"

# Docker invocation (sudo if needed).
_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else sudo docker "$@"; fi
}

# This script must run as root: the Restic repo + password file live under
# /var/lib/tuninforge (root, 0600) and staging reads container volumes. Running as
# root also means restic sees the exported RESTIC_* env directly — so we call
# `restic` plainly, never via sudo (sudo would drop the env without -E, and
# run_cmd_sudo doesn't take sudo flags).
require_root() {
  if [[ "$(id -u)" -ne 0 && "$DRY_RUN" != "1" ]]; then
    log_die "Run as root: sudo ./scripts/backup.sh"
  fi
}

require_restic() {
  if command -v restic >/dev/null 2>&1; then return 0; fi
  log_step "Installing Restic"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would install restic (apt-get install -y restic)."
    return 0
  fi
  confirm "Restic is not installed. Install it now (apt-get install -y restic)?" yes \
    || log_die "Restic is required for backups."
  run_cmd_sudo apt-get update -qq
  run_cmd_sudo apt-get install -y restic
  command -v restic >/dev/null 2>&1 || log_die "Restic install failed."
}

# Resolve the Restic repo + password into the environment restic reads.
# If the user exported RESTIC_REPOSITORY, respect it (remote redirect). Else use
# the local default and ensure a password file exists.
setup_repo_env() {
  if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
    log_info "Using RESTIC_REPOSITORY from environment: $RESTIC_REPOSITORY"
  else
    export RESTIC_REPOSITORY="$TUNINFORGE_BACKUP_REPO"
    log_info "Using local Restic repo: $RESTIC_REPOSITORY"
  fi

  # Password: prefer an already-exported RESTIC_PASSWORD/RESTIC_PASSWORD_FILE.
  if [[ -n "${RESTIC_PASSWORD:-}" || -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would ensure a password file at $TUNINFORGE_RESTIC_PASSWORD_FILE."
    export RESTIC_PASSWORD_FILE="$TUNINFORGE_RESTIC_PASSWORD_FILE"
    return 0
  fi

  if [[ ! -f "$TUNINFORGE_RESTIC_PASSWORD_FILE" ]]; then
    run_cmd_sudo mkdir -p "$(dirname "$TUNINFORGE_RESTIC_PASSWORD_FILE")"
    # Generate a strong passphrase, write 0600 root-owned.
    local pw; pw="$(openssl rand -base64 48 | tr -d '\n')"
    printf '%s\n' "$pw" | run_cmd_sudo tee "$TUNINFORGE_RESTIC_PASSWORD_FILE" >/dev/null
    run_cmd_sudo chmod 600 "$TUNINFORGE_RESTIC_PASSWORD_FILE"
    log_alert \
      "GENERATED RESTIC ENCRYPTION PASSWORD — SAVE THIS NOW." \
      "File: $TUNINFORGE_RESTIC_PASSWORD_FILE (root, 0600)" \
      "Without this password your backups CANNOT be decrypted or restored." \
      "Copy it to your password manager and to an OFF-box location."
    printf '    %s\n' "$pw" >&2
  fi
  export RESTIC_PASSWORD_FILE="$TUNINFORGE_RESTIC_PASSWORD_FILE"
}

# Initialize the repo if it hasn't been (idempotent).
init_repo_if_needed() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would 'restic snapshots' and, if uninitialized, 'restic init'."
    return 0
  fi
  if restic snapshots >/dev/null 2>&1; then
    log_debug "Restic repo already initialized."
  else
    log_info "Initializing Restic repository…"
    restic init
    log_ok "Repository initialized."
  fi
}

# List tuninforge data volumes present on the host.
tuninforge_volumes() {
  _dk volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^tuninforge_.*_data$' || true
}

# Stage: dump Postgres logically + copy each volume's contents into staging.
stage_data() {
  local staging="$1"
  # Postgres logical dump (fallback restore source + manual/cross-version recovery).
  if _dk inspect --format '{{.State.Status}}' tuninforge_postgres >/dev/null 2>&1; then
    log_info "Dumping Postgres (pg_dumpall)…"
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would run pg_dumpall inside tuninforge_postgres -> $staging/postgres/all.sql"
    else
      run_cmd_sudo mkdir -p "$staging/postgres"
      # pg_dumpall as the container's POSTGRES_USER.
      _dk exec tuninforge_postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' \
        | run_cmd_sudo tee "$staging/postgres/all.sql" >/dev/null \
        || log_warn "pg_dumpall failed; the postgres volume tar (below) is the fallback."
    fi
  fi

  # Every tuninforge_*_data volume -> a tarball in staging via an alpine helper.
  local vol
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    log_info "Archiving volume $vol…"
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would tar $vol -> $staging/volumes/$vol.tar"
      continue
    fi
    run_cmd_sudo mkdir -p "$staging/volumes"
    # Mount the named volume read-only, tar its contents to the staging dir
    # (also mounted). Runs as the alpine container; no host tools needed.
    _dk run --rm \
      -v "$vol":/src:ro \
      -v "$staging/volumes":/dst \
      "$HELPER_IMAGE" \
      tar cf "/dst/$vol.tar" -C /src . \
      || log_warn "Archiving $vol failed; continuing with other volumes."
  done < <(tuninforge_volumes)
}

main() {
  log_step "tuninforge backup (Restic)"
  require_root
  require_restic
  setup_repo_env
  init_repo_if_needed

  local ts staging
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
  staging="$STAGING_PARENT/$ts"

  if [[ "$DRY_RUN" != "1" ]]; then run_cmd_sudo mkdir -p "$staging"; fi
  stage_data "$staging"

  log_info "Running restic backup…"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would run: restic backup --tag tuninforge --host \$(hostname) $staging"
  else
    run_cmd restic backup --tag tuninforge "$staging" \
      || log_die "restic backup failed."
    # Retention: keep last 7 daily, 4 weekly, 6 monthly (tunable via env).
    run_cmd restic forget --tag tuninforge \
      --keep-daily "${TUNINFORGE_KEEP_DAILY:-7}" \
      --keep-weekly "${TUNINFORGE_KEEP_WEEKLY:-4}" \
      --keep-monthly "${TUNINFORGE_KEEP_MONTHLY:-6}" \
      --prune || log_warn "restic forget/prune reported an issue (backup itself succeeded)."
    # Clean the plaintext staging dir now that it's safely in the encrypted repo.
    run_cmd rm -rf "$staging"
    log_ok "Backup complete. Verify with: restic snapshots"
  fi
}

main "$@"
