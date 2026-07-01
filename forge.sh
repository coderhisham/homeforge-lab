#!/usr/bin/env bash
# forge.sh — homelab-forge entrypoint.
#
#   ./forge.sh install [--with a,b,c] [--config FILE] [--dry-run] [--yes]
#   ./forge.sh add <service>...
#   ./forge.sh remove <service>... [--dry-run] [--purge-volumes]
#   ./forge.sh status
#   ./forge.sh help
#
# Phase 0 implements the ACCESS LAYER (tailscale, ssh-hardening) end to end.
# The service-stack selection menu + data/AI/observability modules arrive in
# later phases; forge.sh dispatches to them but they are stubbed for now.

set -euo pipefail

# --- Resolve our own location (handles symlinks) -----------------------------
_resolve_root() {
  local src="${BASH_SOURCE[0]}" dir
  while [[ -h "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
FORGE_ROOT="$(_resolve_root)"
export FORGE_ROOT
export FORGE_LIB="$FORGE_ROOT/lib"
export FORGE_MODULES="$FORGE_ROOT/modules"

# shellcheck source=lib/log.sh
source "$FORGE_LIB/log.sh"

# --- Global flag state (exported so modules inherit) -------------------------
export DRY_RUN="${DRY_RUN:-0}"
export FORGE_ASSUME_YES="${FORGE_ASSUME_YES:-0}"
export FORGE_DEBUG="${FORGE_DEBUG:-0}"
I_UNDERSTAND_THE_RISK=0
CONFIG_FILE=""
WITH_SERVICES=""          # comma-separated, from --with
PURGE_VOLUMES=0

usage() {
  cat >&2 <<'EOF'
homelab-forge — modular self-hosted stack installer

USAGE:
  ./forge.sh <command> [options]

COMMANDS:
  install              Select and install services (interactive menu by default)
  add <service>...     Add service(s) to an already-running stack
  remove <service>...  Stop and remove service(s) (confirm + dry-run)
  status               Show installed vs available services and their health
  help                 Show this help

GLOBAL OPTIONS:
  --with a,b,c         Non-interactive selection (skip the menu)
  --config FILE        Read selection + settings from a YAML config file
  --dry-run            Print what would change without touching the system
  --yes, -y            Assume "yes" to ordinary confirmations (non-interactive).
                       Does NOT bypass the SSH-hardening lockout confirmation.
  --i-understand-the-risk
                       Required to run SSH hardening unattended/non-interactively.
  --purge-volumes      (remove only) also delete named volumes — DESTRUCTIVE.
  --debug              Verbose diagnostics.
  -h, --help           Show this help.

EXAMPLES:
  ./forge.sh install
  ./forge.sh install --with tailscale,ssh-hardening
  ./forge.sh install --with caddy,portainer --yes
  ./forge.sh add qdrant
  ./forge.sh remove qdrant --dry-run
EOF
}

# --- Argument parsing --------------------------------------------------------
# First positional token is the subcommand; the rest are options + operands.
[[ $# -eq 0 ]] && { usage; exit 1; }

COMMAND="$1"; shift
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)              WITH_SERVICES="${2:-}"; shift 2 ;;
    --with=*)            WITH_SERVICES="${1#*=}"; shift ;;
    --config)            CONFIG_FILE="${2:-}"; shift 2 ;;
    --config=*)          CONFIG_FILE="${1#*=}"; shift ;;
    --dry-run)           DRY_RUN=1; export DRY_RUN; shift ;;
    -y|--yes)            FORGE_ASSUME_YES=1; export FORGE_ASSUME_YES; shift ;;
    --i-understand-the-risk) I_UNDERSTAND_THE_RISK=1; shift ;;
    --purge-volumes)     PURGE_VOLUMES=1; shift ;;
    --debug)             FORGE_DEBUG=1; export FORGE_DEBUG; shift ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    -*)                  log_error "Unknown option: $1"; usage; exit 1 ;;
    *)                   POSITIONAL+=("$1"); shift ;;
  esac
done
export I_UNDERSTAND_THE_RISK

# Normalize --with into a newline list helper for later phases.
with_list() { [[ -n "$WITH_SERVICES" ]] && tr ',' '\n' <<<"$WITH_SERVICES" | sed '/^$/d'; }

# --- Preconditions -----------------------------------------------------------
require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    log_warn "homelab-forge targets Ubuntu LTS. Detected $(uname -s)."
    log_warn "You can still --dry-run to preview, but real installs need Linux."
    [[ "$DRY_RUN" == "1" ]] || confirm "Continue anyway?" no || exit 1
  fi
}

# =============================================================================
# Subcommand: install
# =============================================================================
cmd_install() {
  require_linux
  log_step "homelab-forge install"

  # --- Access layer runs FIRST, before any service stack. ---
  # Selection source: --with list (Phase 0), config file (later), or the
  # interactive menu (Phase 1). For Phase 0 we key off --with; if the user asks
  # for access modules we run them, and the rest of the stack is deferred.
  local want_tailscale=0 want_ssh=0 sel
  while IFS= read -r sel; do
    case "$sel" in
      tailscale)     want_tailscale=1 ;;
      ssh-hardening) want_ssh=1 ;;
    esac
  done < <(with_list)

  # With no explicit selection yet, guide the user (full menu lands in Phase 1).
  if [[ -z "$WITH_SERVICES" && -z "$CONFIG_FILE" ]]; then
    log_info "Interactive service menu arrives in Phase 1."
    log_info "For now, select the access layer explicitly, e.g.:"
    log_info "    ./forge.sh install --with tailscale,ssh-hardening"
    return 0
  fi

  if [[ "$want_tailscale" == "1" ]]; then
    log_step "Access layer: Tailscale"
    bash "$FORGE_MODULES/access/tailscale/install.sh"
  fi
  if [[ "$want_ssh" == "1" ]]; then
    log_step "Access layer: SSH hardening"
    local ssh_args=()
    [[ "$DRY_RUN" == "1" ]] && ssh_args+=(--dry-run)
    [[ "$I_UNDERSTAND_THE_RISK" == "1" ]] && ssh_args+=(--i-understand-the-risk)
    bash "$FORGE_MODULES/access/ssh-hardening/harden.sh" "${ssh_args[@]}"
  fi

  # Non-access services: deferred to later phases.
  local deferred
  deferred="$(with_list | grep -vxE 'tailscale|ssh-hardening' || true)"
  if [[ -n "$deferred" ]]; then
    log_warn "These services are not available until later phases:"
    sed 's/^/    /' <<<"$deferred" >&2
  fi

  log_ok "install complete for the selected access-layer modules."
}

# =============================================================================
# Subcommand: add / remove / status (skeletons — full logic in later phases)
# =============================================================================
cmd_add() {
  [[ ${#POSITIONAL[@]} -gt 0 ]] || log_die "add: name at least one service, e.g. ./forge.sh add qdrant"
  log_warn "'add' wiring lands in Phase 1 with the service registry."
  log_info "Requested: ${POSITIONAL[*]}"
}

cmd_remove() {
  [[ ${#POSITIONAL[@]} -gt 0 ]] || log_die "remove: name at least one service, e.g. ./forge.sh remove qdrant"
  log_warn "'remove' wiring lands in Phase 1 with the service registry."
  log_info "Requested: ${POSITIONAL[*]} (purge-volumes=$PURGE_VOLUMES, dry-run=$DRY_RUN)"
}

cmd_status() {
  log_step "homelab-forge status"
  log_info "Full status table (installed vs available + health) lands in Phase 1."
  # Phase 0: report access-layer state we can cheaply detect.
  if command -v tailscale >/dev/null 2>&1; then
    log_ok  "tailscale: installed"
  else
    log_info "tailscale: not installed"
  fi
}

# --- Dispatch ----------------------------------------------------------------
case "$COMMAND" in
  install)       cmd_install ;;
  add)           cmd_add ;;
  remove)        cmd_remove ;;
  status)        cmd_status ;;
  help|-h|--help) usage ;;
  *)             log_error "Unknown command: $COMMAND"; usage; exit 1 ;;
esac
