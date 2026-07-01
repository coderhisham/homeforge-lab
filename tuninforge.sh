#!/usr/bin/env bash
# tuninforge.sh — tuninforge entrypoint.
#
#   ./tuninforge.sh install [--with a,b,c] [--config FILE] [--dry-run] [--yes]
#   ./tuninforge.sh add <service>...
#   ./tuninforge.sh remove <service>... [--dry-run] [--purge-volumes]
#   ./tuninforge.sh status
#   ./tuninforge.sh help
#
# Phase 0 implements the ACCESS LAYER (tailscale, ssh-hardening) end to end.
# The service-stack selection menu + data/AI/observability modules arrive in
# later phases; tuninforge.sh dispatches to them but they are stubbed for now.

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
TUNINFORGE_ROOT="$(_resolve_root)"
export TUNINFORGE_ROOT
export TUNINFORGE_LIB="$TUNINFORGE_ROOT/lib"
export TUNINFORGE_MODULES="$TUNINFORGE_ROOT/modules"

# shellcheck source=lib/log.sh
source "$TUNINFORGE_LIB/log.sh"
# shellcheck source=lib/deps.sh
source "$TUNINFORGE_LIB/deps.sh"
# shellcheck source=lib/secrets.sh
source "$TUNINFORGE_LIB/secrets.sh"
# shellcheck source=lib/env.sh
source "$TUNINFORGE_LIB/env.sh"
# shellcheck source=lib/network.sh
source "$TUNINFORGE_LIB/network.sh"
# shellcheck source=lib/health.sh
source "$TUNINFORGE_LIB/health.sh"
# shellcheck source=lib/compose.sh
source "$TUNINFORGE_LIB/compose.sh"
# shellcheck source=lib/tui.sh
source "$TUNINFORGE_LIB/tui.sh"

# --- Global flag state (exported so modules inherit) -------------------------
export DRY_RUN="${DRY_RUN:-0}"
export TUNINFORGE_ASSUME_YES="${TUNINFORGE_ASSUME_YES:-0}"
export TUNINFORGE_DEBUG="${TUNINFORGE_DEBUG:-0}"
I_UNDERSTAND_THE_RISK=0
CONFIG_FILE=""
WITH_SERVICES=""          # comma-separated, from --with
PURGE_VOLUMES=0

usage() {
  cat >&2 <<'EOF'
tuninforge — modular self-hosted stack installer

USAGE:
  ./tuninforge.sh <command> [options]

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
  ./tuninforge.sh install
  ./tuninforge.sh install --with tailscale,ssh-hardening
  ./tuninforge.sh install --with caddy,portainer --yes
  ./tuninforge.sh add qdrant
  ./tuninforge.sh remove qdrant --dry-run
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
    -y|--yes)            TUNINFORGE_ASSUME_YES=1; export TUNINFORGE_ASSUME_YES; shift ;;
    --i-understand-the-risk) I_UNDERSTAND_THE_RISK=1; shift ;;
    --purge-volumes)     PURGE_VOLUMES=1; shift ;;
    --debug)             TUNINFORGE_DEBUG=1; export TUNINFORGE_DEBUG; shift ;;
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
    log_warn "tuninforge targets Ubuntu LTS. Detected $(uname -s)."
    log_warn "You can still --dry-run to preview, but real installs need Linux."
    [[ "$DRY_RUN" == "1" ]] || confirm "Continue anyway?" no || exit 1
  fi
}

# =============================================================================
# Subcommand: install
# =============================================================================

# resolve_selection: populate TUNINFORGE_SELECTION (dependency-resolved, install-
# ordered) from exactly one source — explicit --with, a --config file, or the
# interactive OpenClaw-style menu. Returns 1 to abort.
resolve_selection() {
  if [[ -n "$WITH_SERVICES" ]]; then
    # Non-interactive: validate names, resolve deps, order. Mirrors --non-interactive.
    local raw name bad=""
    raw="$(with_list | tr '\n' ' ')"
    for name in $raw; do
      tuninforge_is_service "$name" || bad="$bad $name"
    done
    if [[ -n "${bad// }" ]]; then
      log_error "Unknown service(s):$bad"
      log_info  "Valid services: $(tuninforge_all_services | tr '\n' ' ')"
      return 1
    fi
    local added
    # shellcheck disable=SC2086
    added="$(tuninforge_added_deps $raw)"
    [[ -n "${added// }" ]] && log_info "Auto-adding dependencies:$added"
    # shellcheck disable=SC2086
    TUNINFORGE_SELECTION="$(tuninforge_install_order $raw)"
    log_info "Selected: $TUNINFORGE_SELECTION"
    return 0
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    log_warn "--config YAML parsing lands with lib/env.sh later in Phase 1."
    log_info "For now use --with, e.g.: ./tuninforge.sh install --with caddy,portainer"
    return 1
  fi

  # No flags: interactive selection (QuickStart/Advanced fork).
  tui_select_services || return 1
  return 0
}

cmd_install() {
  require_linux
  log_step "tuninforge install"

  resolve_selection || { log_info "Nothing installed."; return 0; }

  # Access layer runs FIRST (before any service stack), in registry order so
  # Tailscale precedes SSH hardening (ufw-to-tailscale0 depends on it).
  local svc
  for svc in $TUNINFORGE_SELECTION; do
    case "$svc" in
      tailscale)
        log_step "Access layer: Tailscale"
        bash "$TUNINFORGE_MODULES/access/tailscale/install.sh"
        ;;
      ssh-hardening)
        log_step "Access layer: SSH hardening"
        local ssh_args=()
        [[ "$DRY_RUN" == "1" ]] && ssh_args+=(--dry-run)
        [[ "$I_UNDERSTAND_THE_RISK" == "1" ]] && ssh_args+=(--i-understand-the-risk)
        bash "$TUNINFORGE_MODULES/access/ssh-hardening/harden.sh" "${ssh_args[@]}"
        ;;
    esac
  done

  # Non-access services: deploy each module that exists via compose. Modules
  # not yet implemented are reported as pending (arriving in a later phase).
  local -a to_deploy=()
  local pending="" deploy_rc=0
  for svc in $TUNINFORGE_SELECTION; do
    case "$svc" in
      tailscale|ssh-hardening) continue ;;
    esac
    if [[ -f "$TUNINFORGE_MODULES/$svc/docker-compose.yml" ]]; then
      to_deploy+=("$svc")
    else
      pending="$pending $svc"
    fi
  done

  if [[ "${#to_deploy[@]}" -gt 0 ]]; then
    # Docker is a hard prerequisite for every stack module. Ensure it's present
    # (idempotent; a no-op if already installed) before any network/deploy work.
    if ! command -v docker >/dev/null 2>&1 || { [[ "$DRY_RUN" != "1" ]] && ! { docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; }; }; then
      log_step "Prerequisite: Docker"
      local dk_args=()
      [[ "$DRY_RUN" == "1" ]] && dk_args+=(--dry-run)
      bash "$TUNINFORGE_MODULES/docker/install.sh" "${dk_args[@]}" \
        || log_die "Docker is required for the selected services but could not be installed."
    fi

    # Detect the box's MagicDNS name once so Caddy can request its *.ts.net cert.
    if [[ -z "${TUNINFORGE_TS_HOSTNAME:-}" ]] && command -v tailscale >/dev/null 2>&1; then
      TUNINFORGE_TS_HOSTNAME="$(tailscale status --json 2>/dev/null \
        | grep -o '"DNSName":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//;s/\.$//' || true)"
      export TUNINFORGE_TS_HOSTNAME
      [[ -n "$TUNINFORGE_TS_HOSTNAME" ]] && log_info "Caddy will use MagicDNS name: $TUNINFORGE_TS_HOSTNAME"
    fi

    for svc in "${to_deploy[@]}"; do
      tuninforge_deploy_module "$svc" || { deploy_rc=1; log_error "Deployment of '$svc' did not reach healthy."; }
    done

    # Show any secrets generated across all modules exactly once.
    secrets_flush_notice
  fi

  if [[ -n "${pending// }" ]]; then
    log_warn "Selected, but their modules arrive in a later phase:${pending}"
  fi

  if [[ "$deploy_rc" -ne 0 ]]; then
    log_error "One or more services did not become healthy. Check logs with: docker logs <container>"
    return 1
  fi
  log_ok "install run finished."
}

# =============================================================================
# Subcommand: add
# =============================================================================
# Add service(s) to an already-running stack without disturbing what's installed.
# Resolves dependencies (auto-adding any missing), then deploys each in order.
cmd_add() {
  [[ ${#POSITIONAL[@]} -gt 0 ]] || log_die "add: name at least one service, e.g. ./tuninforge.sh add qdrant"
  require_linux

  # Validate names.
  local name bad=""
  for name in "${POSITIONAL[@]}"; do
    case "$name" in tailscale|ssh-hardening)
      log_warn "'$name' is an access-layer module; add it via: ./tuninforge.sh install --with $name"
      continue ;;
    esac
    tuninforge_is_service "$name" || bad="$bad $name"
  done
  [[ -n "${bad// }" ]] && { log_error "Unknown service(s):$bad"; log_info "Valid: $(tuninforge_all_services | tr '\n' ' ')"; return 1; }

  # Resolve deps + order (Bash authoritative), then note any auto-added.
  local requested; requested="$(printf '%s ' "${POSITIONAL[@]}")"
  local added
  # shellcheck disable=SC2086
  added="$(tuninforge_added_deps $requested)"
  [[ -n "${added// }" ]] && log_info "Auto-adding dependencies:$added"
  # shellcheck disable=SC2086
  local order; order="$(tuninforge_install_order $requested)"
  # Only deploy the non-access services.
  order="$(tr ' ' '\n' <<<"$order" | grep -vxE 'tailscale|ssh-hardening' || true)"
  log_step "Adding: $(tr '\n' ' ' <<<"$order")"

  local svc rc=0
  for svc in $order; do
    [[ -f "$TUNINFORGE_MODULES/$svc/docker-compose.yml" ]] || { log_warn "No module for '$svc' yet; skipping."; continue; }
    tuninforge_deploy_module "$svc" || { rc=1; log_error "'$svc' did not become healthy."; }
  done
  secrets_flush_notice
  [[ "$rc" -eq 0 ]] && log_ok "add complete." || return 1
}

# =============================================================================
# Subcommand: remove
# =============================================================================
# Stop and remove service(s). Confirms first; supports --dry-run and
# --purge-volumes. Warns when removing something other installed services depend
# on, and warns loudly before deleting stateful data.
cmd_remove() {
  [[ ${#POSITIONAL[@]} -gt 0 ]] || log_die "remove: name at least one service, e.g. ./tuninforge.sh remove qdrant"

  local name bad=""
  for name in "${POSITIONAL[@]}"; do tuninforge_is_service "$name" || bad="$bad $name"; done
  [[ -n "${bad// }" ]] && { log_error "Unknown service(s):$bad"; return 1; }

  # Warn if a named service is a dependency of another INSTALLED service.
  local svc dependents installed_all
  installed_all="$(_installed_services)"
  for svc in "${POSITIONAL[@]}"; do
    # shellcheck disable=SC2086
    dependents="$(tuninforge_dependents_of "$svc" $installed_all)"
    # Filter dependents down to ones NOT also being removed.
    local d filtered=""
    for d in $dependents; do
      case " ${POSITIONAL[*]} " in *" $d "*) ;; *) filtered="$filtered $d" ;; esac
    done
    [[ -n "${filtered// }" ]] && log_warn "Removing '$svc' may break installed dependents:$filtered"
  done

  # Loud warning for stateful services (data loss if volumes purged).
  if [[ "$PURGE_VOLUMES" == "1" ]]; then
    local stateful=""
    for svc in "${POSITIONAL[@]}"; do
      grep -q 'com.centurylinklabs.watchtower.enable' "$TUNINFORGE_MODULES/$svc/docker-compose.yml" 2>/dev/null || stateful="$stateful $svc"
    done
    log_alert \
      "--purge-volumes will DELETE NAMED VOLUMES for:${POSITIONAL[*]}" \
      "This is IRREVERSIBLE. Stateful data (databases, objects, vectors) is lost." \
      "${stateful:+Stateful services affected:$stateful}"
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    confirm "Remove: ${POSITIONAL[*]} (purge-volumes=$PURGE_VOLUMES)?" no || { log_info "Cancelled."; return 0; }
  fi

  local purge_flag=""; [[ "$PURGE_VOLUMES" == "1" ]] && purge_flag="--purge-volumes"
  for svc in "${POSITIONAL[@]}"; do
    tuninforge_teardown_module "$svc" "$purge_flag"
  done
  log_ok "remove complete."
}

# =============================================================================
# Subcommand: status
# =============================================================================
# _installed_services -> newline list of stack services whose main container exists.
_installed_services() {
  local svc
  while IFS= read -r svc; do
    case "$svc" in tailscale|ssh-hardening) continue ;; esac
    if tuninforge_docker_q inspect "tuninforge_$svc" >/dev/null 2>&1; then echo "$svc"; fi
  done < <(tuninforge_all_services)
}

cmd_status() {
  log_step "tuninforge status"

  # Access layer (no containers — detect by artifact).
  printf '\n%s\n' "${C_BOLD}Access${C_RESET}" >&2
  if command -v tailscale >/dev/null 2>&1; then
    printf '  %s tailscale       installed\n' "${C_GREEN}●${C_RESET}" >&2
  else
    printf '  %s tailscale       not installed\n' "${C_DIM}○${C_RESET}" >&2
  fi
  if [[ -f /etc/ssh/sshd_config.d/00-tuninforge-hardening.conf ]]; then
    printf '  %s ssh-hardening   applied (drop-in present)\n' "${C_GREEN}●${C_RESET}" >&2
  else
    printf '  %s ssh-hardening   not applied\n' "${C_DIM}○${C_RESET}" >&2
  fi

  # Stack services by layer: installed? running? health?
  local layer svc cname state health mark note
  while IFS= read -r layer; do
    [[ "$layer" == "access" ]] && continue
    local any=0
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      [[ $any -eq 0 ]] && { printf '\n%s\n' "${C_BOLD}$(tuninforge_layer_title "$layer")${C_RESET}" >&2; any=1; }
      cname="tuninforge_$svc"
      if ! tuninforge_docker_q inspect "$cname" >/dev/null 2>&1; then
        printf '  %s %-14s available (not installed)\n' "${C_DIM}○${C_RESET}" "$svc" >&2
        continue
      fi
      state="$(tuninforge_docker_q inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo '?')"
      health="$(tuninforge_docker_q inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cname" 2>/dev/null || echo '-')"
      if [[ "$state" == "running" ]]; then mark="${C_GREEN}●${C_RESET}"; else mark="${C_RED}●${C_RESET}"; fi
      note="$state"; [[ "$health" != "-" ]] && note="$state, health=$health"
      printf '  %s %-14s %s\n' "$mark" "$svc" "$note" >&2
    done < <(tuninforge_services_in_layer "$layer")
  done < <(tuninforge_layers)

  printf '\n' >&2
  log_info "Per-service deep check: ./modules/<service>/healthcheck.sh"
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
