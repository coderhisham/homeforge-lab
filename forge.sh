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
# shellcheck source=lib/deps.sh
source "$FORGE_LIB/deps.sh"
# shellcheck source=lib/tui.sh
source "$FORGE_LIB/tui.sh"

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

# resolve_selection: populate FORGE_SELECTION (dependency-resolved, install-
# ordered) from exactly one source — explicit --with, a --config file, or the
# interactive OpenClaw-style menu. Returns 1 to abort.
resolve_selection() {
  if [[ -n "$WITH_SERVICES" ]]; then
    # Non-interactive: validate names, resolve deps, order. Mirrors --non-interactive.
    local raw name bad=""
    raw="$(with_list | tr '\n' ' ')"
    for name in $raw; do
      forge_is_service "$name" || bad="$bad $name"
    done
    if [[ -n "${bad// }" ]]; then
      log_error "Unknown service(s):$bad"
      log_info  "Valid services: $(forge_all_services | tr '\n' ' ')"
      return 1
    fi
    local added
    # shellcheck disable=SC2086
    added="$(forge_added_deps $raw)"
    [[ -n "${added// }" ]] && log_info "Auto-adding dependencies:$added"
    # shellcheck disable=SC2086
    FORGE_SELECTION="$(forge_install_order $raw)"
    log_info "Selected: $FORGE_SELECTION"
    return 0
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    log_warn "--config YAML parsing lands with lib/env.sh later in Phase 1."
    log_info "For now use --with, e.g.: ./forge.sh install --with caddy,portainer"
    return 1
  fi

  # No flags: interactive selection (QuickStart/Advanced fork).
  tui_select_services || return 1
  return 0
}

cmd_install() {
  require_linux
  log_step "homelab-forge install"

  resolve_selection || { log_info "Nothing installed."; return 0; }

  # Access layer runs FIRST (before any service stack), in registry order so
  # Tailscale precedes SSH hardening (ufw-to-tailscale0 depends on it).
  local svc
  for svc in $FORGE_SELECTION; do
    case "$svc" in
      tailscale)
        log_step "Access layer: Tailscale"
        bash "$FORGE_MODULES/access/tailscale/install.sh"
        ;;
      ssh-hardening)
        log_step "Access layer: SSH hardening"
        local ssh_args=()
        [[ "$DRY_RUN" == "1" ]] && ssh_args+=(--dry-run)
        [[ "$I_UNDERSTAND_THE_RISK" == "1" ]] && ssh_args+=(--i-understand-the-risk)
        bash "$FORGE_MODULES/access/ssh-hardening/harden.sh" "${ssh_args[@]}"
        ;;
    esac
  done

  # Non-access services: modules are implemented phase by phase. Report which
  # selected services already have a module vs. which are still pending.
  local pending=""
  for svc in $FORGE_SELECTION; do
    case "$svc" in
      tailscale|ssh-hardening) continue ;;
    esac
    if [[ -f "$FORGE_MODULES/$svc/docker-compose.yml" ]]; then
      log_warn "Module '$svc' is present but its installer wiring is not active yet."
    else
      pending="$pending $svc"
    fi
  done
  if [[ -n "${pending// }" ]]; then
    log_warn "Selected, but their modules arrive in a later phase:${pending}"
    log_info "Access layer is complete. Service-stack modules (Caddy, Portainer, …) are next."
  fi

  log_ok "install run finished."
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
