#!/usr/bin/env bash
# scripts/restore.sh — restore the homelab-forge data layer from a Restic snapshot.
#
# This is the counterpart to scripts/backup.sh and it is DESTRUCTIVE: it stops
# the affected services, replaces volume contents, and re-imports the Postgres
# logical dump. It requires an explicit typed confirmation.
#
# Usage:
#   scripts/restore.sh                 # restore from the latest snapshot
#   scripts/restore.sh <snapshot-id>   # restore from a specific snapshot
#   scripts/restore.sh --list          # list snapshots and exit
#
# Repo + password are resolved the same way as backup.sh (local default, or
# RESTIC_REPOSITORY/RESTIC_PASSWORD* from the environment for remote repos).
# Honors DRY_RUN.

set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/log.sh
source "$FORGE_ROOT/lib/log.sh"

: "${DRY_RUN:=0}"
FORGE_BACKUP_REPO="${FORGE_BACKUP_REPO:-/var/lib/forge/restic}"
FORGE_RESTIC_PASSWORD_FILE="${FORGE_RESTIC_PASSWORD_FILE:-/var/lib/forge/restic.pass}"
RESTORE_SCRATCH="${FORGE_RESTORE_SCRATCH:-/var/lib/forge/restore-scratch}"
HELPER_IMAGE="alpine:3.20"

SNAPSHOT="latest"
LIST_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) log_warn "restore: ignoring unknown option '$1'" ;;
    *)  SNAPSHOT="$1" ;;
  esac
  shift
done

_dk() {
  if docker info >/dev/null 2>&1; then docker "$@";
  elif sudo -n docker info >/dev/null 2>&1; then sudo docker "$@";
  else sudo docker "$@"; fi
}

# This script must run as root (root-owned repo/password, container volume swap).
# Running as root means restic sees the exported RESTIC_* env directly, so we
# call `restic` plainly — never via sudo (which would drop the env without -E).
require_root() {
  if [[ "$(id -u)" -ne 0 && "$DRY_RUN" != "1" ]]; then
    log_die "Run as root: sudo ./scripts/restore.sh"
  fi
}

setup_repo_env() {
  [[ -n "${RESTIC_REPOSITORY:-}" ]] || export RESTIC_REPOSITORY="$FORGE_BACKUP_REPO"
  if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    [[ -f "$FORGE_RESTIC_PASSWORD_FILE" ]] || log_die "No Restic password file at $FORGE_RESTIC_PASSWORD_FILE and none in env. Cannot decrypt."
    export RESTIC_PASSWORD_FILE="$FORGE_RESTIC_PASSWORD_FILE"
  fi
  command -v restic >/dev/null 2>&1 || log_die "restic not installed."
  log_info "Restic repo: $RESTIC_REPOSITORY"
}

list_snapshots() { run_cmd restic snapshots --tag forge; }

# Restore the snapshot's staging tree into a scratch dir on the host.
restore_to_scratch() {
  log_info "Restoring snapshot '$SNAPSHOT' to scratch: $RESTORE_SCRATCH"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would: restic restore $SNAPSHOT --target $RESTORE_SCRATCH"
    return 0
  fi
  run_cmd_sudo rm -rf "$RESTORE_SCRATCH"
  run_cmd_sudo mkdir -p "$RESTORE_SCRATCH"
  run_cmd restic restore "$SNAPSHOT" --target "$RESTORE_SCRATCH" \
    || log_die "restic restore failed."
}

# Find the staging root inside the scratch tree (restic recreates the absolute
# path that was backed up, e.g. <scratch>/var/lib/forge/staging/<ts>).
find_staging_root() {
  # The deepest dir containing a 'volumes' subdir is our staging root.
  local hit
  hit="$(sudo find "$RESTORE_SCRATCH" -type d -name volumes 2>/dev/null | head -1 || true)"
  [[ -n "$hit" ]] && dirname "$hit"
}

# Replace one volume's contents from a restored tarball.
restore_volume() {
  local vol="$1" tar="$2"
  log_info "Restoring volume $vol from $(basename "$tar")…"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would wipe + extract $tar into volume $vol"
    return 0
  fi
  # Ensure the volume exists, then wipe and extract via an alpine helper.
  _dk volume create "$vol" >/dev/null
  _dk run --rm \
    -v "$vol":/dst \
    -v "$(dirname "$tar")":/src:ro \
    "$HELPER_IMAGE" \
    sh -c "rm -rf /dst/* /dst/..?* /dst/.[!.]* 2>/dev/null; tar xf /src/$(basename "$tar") -C /dst" \
    || log_warn "Restoring $vol failed; continuing."
}

main() {
  log_step "homelab-forge restore (Restic)"
  require_root
  setup_repo_env

  if [[ "$LIST_ONLY" == "1" ]]; then
    list_snapshots
    exit 0
  fi

  log_alert \
    "DESTRUCTIVE RESTORE." \
    "This stops data-layer services and OVERWRITES their volumes with the" \
    "contents of snapshot: $SNAPSHOT" \
    "Current data in those volumes will be lost." \
    "Make sure you have a fresh backup first if the current state matters."
  if [[ "$DRY_RUN" != "1" ]]; then
    confirm_typed "Type RESTORE to proceed" "RESTORE" || { log_info "Restore cancelled."; exit 1; }
  fi

  restore_to_scratch

  local staging; staging="$(find_staging_root || true)"
  if [[ "$DRY_RUN" != "1" && -z "$staging" ]]; then
    log_die "Could not locate staging data in the restored snapshot. Nothing changed to volumes."
  fi
  [[ "$DRY_RUN" == "1" ]] && staging="<scratch>/…/staging/<ts>"

  # Stop data-layer services so files aren't in use while we swap volumes.
  local services="postgres redis minio qdrant"
  log_info "Stopping data-layer containers before volume swap…"
  local s
  for s in $services; do
    if _dk inspect "forge_$s" >/dev/null 2>&1; then
      run_cmd _dk stop "forge_$s" >/dev/null 2>&1 || true
    fi
  done

  # Restore each volume tarball present in the snapshot.
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would restore each forge_*_data.tar from $staging/volumes/ into its volume."
  else
    local tar vol
    for tar in "$staging"/volumes/*.tar; do
      [[ -e "$tar" ]] || { log_warn "No volume tarballs found in snapshot."; break; }
      vol="$(basename "$tar" .tar)"
      restore_volume "$vol" "$tar"
    done
  fi

  # Restart services.
  log_info "Restarting data-layer containers…"
  for s in $services; do
    if _dk inspect "forge_$s" >/dev/null 2>&1; then
      run_cmd _dk start "forge_$s" >/dev/null 2>&1 || true
    fi
  done

  # Postgres: re-import the logical dump on top of the running container — this
  # is the authoritative Postgres restore (more reliable than the raw volume).
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would re-import $staging/postgres/all.sql into forge_postgres via psql."
  elif [[ -f "$staging/postgres/all.sql" ]] && _dk inspect forge_postgres >/dev/null 2>&1; then
    log_info "Re-importing Postgres logical dump…"
    # Wait briefly for postgres to accept connections after restart.
    local i
    for i in $(seq 1 30); do _dk exec forge_postgres pg_isready -q 2>/dev/null && break; sleep 2; done
    sudo cat "$staging/postgres/all.sql" | _dk exec -i forge_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
      || log_warn "Postgres dump re-import reported issues; check logs."
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    run_cmd_sudo rm -rf "$RESTORE_SCRATCH"
    log_ok "Restore complete. Verify each service with its healthcheck.sh."
  else
    log_ok "[dry-run] restore preview complete; nothing was changed."
  fi
}

main "$@"
