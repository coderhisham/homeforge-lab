#!/usr/bin/env bash
# modules/docker/install.sh
#
# Installs Docker Engine + the Compose plugin on a fresh Ubuntu box, so every
# downstream service module has a working container runtime. Runs before any
# stack deploy.
#
# Security posture (matches the Tailscale module): the official convenience
# script from https://get.docker.com is downloaded to a FILE and shown to the
# user BEFORE running — never piped straight into sh. The user confirms first.
#
# Idempotent: if Docker + Compose already work, it verifies and exits without
# reinstalling. Honors DRY_RUN and TUNINFORGE_ASSUME_YES.
#
# After install it adds the invoking (sudo) user to the 'docker' group so they
# can run docker without sudo — this requires a re-login to take effect, which
# is clearly flagged.

set -euo pipefail

: "${TUNINFORGE_LIB:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)}"
# shellcheck source=../../lib/log.sh
source "$TUNINFORGE_LIB/log.sh"

DOCKER_INSTALL_URL="https://get.docker.com"

# The real user (when run via sudo), for the docker group membership.
target_user() { echo "${SUDO_USER:-${USER:-$(id -un)}}"; }

# --- Detection ---------------------------------------------------------------
have_docker()         { command -v docker >/dev/null 2>&1; }
have_compose_plugin() { docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1; }
docker_daemon_ok()    { docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; }

# --- Install -----------------------------------------------------------------
install_engine() {
  if have_docker && have_compose_plugin; then
    log_ok "Docker + Compose plugin already installed ($(docker --version 2>/dev/null | head -1))."
    return 0
  fi

  log_step "Installing Docker Engine + Compose plugin"
  log_info "The official installer will be downloaded from:"
  log_info "    $DOCKER_INSTALL_URL"
  log_info "It is downloaded to a file and shown to you BEFORE running — never"
  log_info "piped straight into sh."

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would download, display, and (on confirmation) run the Docker install script."
    log_info "[dry-run] would enable the docker service and add '$(target_user)' to the docker group."
    return 0
  fi

  local tmp; tmp="$(mktemp -t docker-install.XXXXXX.sh)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  if ! curl -fsSL "$DOCKER_INSTALL_URL" -o "$tmp"; then
    log_die "Failed to download the Docker installer. Check network/DNS."
  fi

  local lines; lines="$(wc -l <"$tmp" | tr -d ' ')"
  log_info "Downloaded installer ($lines lines). SHA-256:"
  if command -v sha256sum >/dev/null 2>&1; then
    log_info "    $(sha256sum "$tmp" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    log_info "    $(shasum -a 256 "$tmp" | awk '{print $1}')"
  fi

  if [[ -t 0 && -t 1 ]] && confirm "View the Docker install script before running it?" yes; then
    "${PAGER:-less}" "$tmp" || true
  fi
  if ! confirm "Run the official Docker installer now?" yes; then
    log_die "Aborted by user before installing Docker."
  fi

  run_cmd_sudo sh "$tmp"
  have_docker || log_die "Docker install did not produce a 'docker' binary."
  log_ok "Docker Engine installed."
}

# --- Post-install: service + group -------------------------------------------
enable_service() {
  [[ "$DRY_RUN" == "1" ]] && { log_info "[dry-run] would enable+start the docker systemd service."; return 0; }
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd_sudo systemctl enable --now docker || log_warn "Could not enable the docker service; is systemd present?"
  fi
}

add_user_to_group() {
  local u; u="$(target_user)"
  # root doesn't need the group.
  [[ "$u" == "root" ]] && return 0

  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log_debug "User '$u' already in the docker group."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would add '$u' to the docker group."
    return 0
  fi

  run_cmd_sudo usermod -aG docker "$u"
  log_alert \
    "ADDED '$u' TO THE 'docker' GROUP." \
    "This takes effect on your NEXT login only." \
    "Log out and back in (or run: newgrp docker) before running docker" \
    "without sudo. tuninforge will use sudo automatically until then."
}

# --- Verify ------------------------------------------------------------------
verify() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would verify with 'docker run --rm hello-world' and 'docker compose version'."
    return 0
  fi
  log_step "Verifying Docker"
  docker_daemon_ok || log_die "Docker daemon is not reachable after install. Try: sudo systemctl start docker"
  have_compose_plugin || log_warn "Compose plugin not detected; some modules need 'docker compose'."

  # A lightweight functional check. Use sudo if the group change isn't active yet.
  if docker info >/dev/null 2>&1; then
    run_cmd docker run --rm hello-world >/dev/null 2>&1 && log_ok "Docker runs containers (hello-world OK)." \
      || log_warn "hello-world test could not run; check 'docker info'."
  else
    sudo docker run --rm hello-world >/dev/null 2>&1 && log_ok "Docker runs containers via sudo (group re-login pending)." \
      || log_warn "hello-world test via sudo could not run; check 'sudo docker info'."
  fi
}

main() {
  install_engine
  enable_service
  add_user_to_group
  verify
  log_ok "Docker module complete."
}

main "$@"
