#!/usr/bin/env bash
# scripts/uninstall.sh — tear down the whole tuninforge stack.
#
# Removes every installed stack module's containers, then (optionally) the
# shared Docker networks. It does NOT touch the access layer — Tailscale and SSH
# hardening are safety-critical and ripping them out unattended could lock you
# off the box, so those are left in place with instructions printed at the end.
#
# Flags:
#   --dry-run          print what would happen, change nothing
#   --purge-volumes    also delete named volumes — DESTRUCTIVE, IRREVERSIBLE
#
# Requires a typed confirmation. Reuses tuninforge_teardown_module from lib/compose.sh.

set -euo pipefail

TUNINFORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TUNINFORGE_ROOT TUNINFORGE_LIB="$TUNINFORGE_ROOT/lib" TUNINFORGE_MODULES="$TUNINFORGE_ROOT/modules"
# shellcheck source=../lib/log.sh
source "$TUNINFORGE_LIB/log.sh"
# shellcheck source=../lib/deps.sh
source "$TUNINFORGE_LIB/deps.sh"
# shellcheck source=../lib/network.sh
source "$TUNINFORGE_LIB/network.sh"
# shellcheck source=../lib/health.sh
source "$TUNINFORGE_LIB/health.sh"
# shellcheck source=../lib/secrets.sh
source "$TUNINFORGE_LIB/secrets.sh"
# shellcheck source=../lib/env.sh
source "$TUNINFORGE_LIB/env.sh"
# shellcheck source=../lib/compose.sh
source "$TUNINFORGE_LIB/compose.sh"

: "${DRY_RUN:=0}"
PURGE_VOLUMES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --purge-volumes) PURGE_VOLUMES=1 ;;
    *) log_warn "uninstall: ignoring unknown arg '$1'" ;;
  esac
  shift
done
export DRY_RUN

# Which stack services actually have containers present (installed)?
installed_stack() {
  local svc
  while IFS= read -r svc; do
    case "$svc" in tailscale|ssh-hardening) continue ;; esac
    tuninforge_docker_q inspect "tuninforge_$svc" >/dev/null 2>&1 && echo "$svc"
  done < <(tuninforge_all_services)
}

main() {
  log_step "tuninforge uninstall (full stack teardown)"

  local present; present="$(installed_stack | tr '\n' ' ')"
  if [[ -z "${present// }" ]]; then
    log_info "No stack services appear to be installed. Nothing to tear down."
  else
    log_info "Installed stack services:$present"
  fi

  log_alert \
    "This removes ALL tuninforge stack containers." \
    "${present:-<none detected>}" \
    "" \
    "$([[ "$PURGE_VOLUMES" == "1" ]] && echo "--purge-volumes: NAMED VOLUMES WILL BE DELETED (data lost, irreversible)." || echo "Volumes are PRESERVED (re-installing keeps your data). Use --purge-volumes to delete them.")" \
    "" \
    "The access layer (Tailscale, SSH hardening) is NOT touched."

  if [[ "$DRY_RUN" != "1" ]]; then
    confirm_typed "Type UNINSTALL to proceed" "UNINSTALL" || { log_info "Uninstall cancelled."; exit 1; }
  fi

  # Tear down in REVERSE registry order so dependents go before dependencies
  # (e.g. n8n before postgres/redis). Registry order is a valid topo order, so
  # reversing it is a valid teardown order.
  local purge_flag=""; [[ "$PURGE_VOLUMES" == "1" ]] && purge_flag="--purge-volumes"
  local svc
  for svc in $(installed_stack | tail -r 2>/dev/null || installed_stack | tac); do
    tuninforge_teardown_module "$svc" "$purge_flag" || log_warn "Teardown of '$svc' reported an issue; continuing."
  done

  # Offer to remove the shared networks (only meaningful once containers are gone).
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would remove shared networks $TUNINFORGE_NET_PUBLIC + $TUNINFORGE_NET_INTERNAL if unused."
  else
    for net in "$TUNINFORGE_NET_PUBLIC" "$TUNINFORGE_NET_INTERNAL"; do
      if tuninforge_docker_q network inspect "$net" >/dev/null 2>&1; then
        tuninforge_docker network rm "$net" >/dev/null 2>&1 \
          && log_ok "Removed network $net." \
          || log_info "Network $net still in use (other containers attached); left in place."
      fi
    done
  fi

  log_ok "Stack teardown complete."
  log_info "Access layer left intact. To reverse it manually:"
  log_info "  • SSH hardening: sudo rm -f /etc/ssh/sshd_config.d/00-tuninforge-hardening.conf && sudo systemctl reload ssh"
  log_info "  • Tailscale:     sudo tailscale down   (and remove the node in the admin console)"
  [[ "$PURGE_VOLUMES" != "1" && "$DRY_RUN" != "1" ]] && \
    log_info "  • Volumes kept. To delete them too: re-run with --purge-volumes, or 'docker volume rm tuninforge_<svc>_data'."
}

main "$@"
