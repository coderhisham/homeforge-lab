#!/usr/bin/env bash
# modules/access/tailscale/install.sh
#
# Installs Tailscale via the official script (shown before it runs, never
# silently piped), brings the interface up with an auth key OR interactive
# browser/headless auth, asks the user to choose an SSH access model explicitly,
# and verifies connectivity before returning.
#
# Honors: DRY_RUN, FORGE_ASSUME_YES. Reads optional env:
#   TS_AUTHKEY        pre-supplied auth key (else prompt / browser)
#   TS_SSH_MODE       "tailscale-ssh" | "sshd" (else ask)
#   TS_HOSTNAME       override the machine name registered on the tailnet
#
# Idempotent: if tailscale is already installed and up, it verifies and exits.

set -euo pipefail

: "${FORGE_LIB:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)}"
# shellcheck source=../../../lib/log.sh
source "$FORGE_LIB/log.sh"

TS_INSTALL_URL="https://tailscale.com/install.sh"

# --- Step 1: install the tailscale binary ------------------------------------
install_binary() {
  if command -v tailscale >/dev/null 2>&1; then
    log_ok "Tailscale already installed ($(tailscale version 2>/dev/null | head -1))."
    return 0
  fi

  log_step "Installing Tailscale"
  log_info "The official installer will be downloaded from:"
  log_info "    $TS_INSTALL_URL"
  log_info "Per security best practice, homelab-forge downloads it to a file and"
  log_info "shows it to you BEFORE running — it never pipes curl straight to sh."

  local tmp; tmp="$(mktemp -t tailscale-install.XXXXXX.sh)"
  # shellcheck disable=SC2064  # expand tmp now, on trap-setup, intentionally.
  trap "rm -f '$tmp'" RETURN

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would download and display $TS_INSTALL_URL, then run it with sh."
    return 0
  fi

  if ! curl -fsSL "$TS_INSTALL_URL" -o "$tmp"; then
    log_die "Failed to download the Tailscale installer. Check network/DNS."
  fi

  local lines; lines="$(wc -l <"$tmp" | tr -d ' ')"
  log_info "Downloaded installer ($lines lines, sha256 below). Review it now:"
  if command -v sha256sum >/dev/null 2>&1; then
    log_info "    sha256: $(sha256sum "$tmp" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    log_info "    sha256: $(shasum -a 256 "$tmp" | awk '{print $1}')"
  fi

  # Show the script (paged if the user has a pager and a TTY).
  if [[ -t 0 && -t 1 ]] && confirm "View the installer script before running it?" yes; then
    "${PAGER:-less}" "$tmp" || true
  fi
  if ! confirm "Run the official Tailscale installer now?" yes; then
    log_die "Aborted by user before installing Tailscale."
  fi

  run_cmd_sudo sh "$tmp"
  command -v tailscale >/dev/null 2>&1 || log_die "Tailscale install did not produce a 'tailscale' binary."
  log_ok "Tailscale binary installed."
}

# --- Step 2: choose SSH access model (explicit, never silent) ----------------
choose_ssh_mode() {
  local mode="${TS_SSH_MODE:-}"
  if [[ -z "$mode" ]]; then
    if [[ ! -t 0 ]]; then
      # Non-interactive and unspecified: default to traditional sshd (the
      # conservative choice) and warn. We never silently enable Tailscale SSH.
      log_warn "TS_SSH_MODE not set and not interactive; defaulting to 'sshd' (traditional key auth)."
      mode="sshd"
    else
      log_step "Choose your SSH access model"
      cat >&2 <<'EOF'
  How do you want to reach this box over SSH?

    1) Tailscale SSH   — Tailscale manages SSH auth via tailnet ACLs. No SSH
                         keys to distribute; access is governed by your tailnet
                         policy. `tailscale up --ssh` enables it.
    2) Traditional sshd — Classic OpenSSH with public-key auth. Pair this with
                         the SSH-hardening module. You manage keys yourself.

  These are different trust models. homelab-forge will NOT silently enable both.
  If you pick Tailscale SSH, you can still keep sshd for a break-glass path, but
  that's your explicit choice to make afterward.
EOF
      local pick
      while true; do
        printf '%s ' "${C_BOLD}Select 1 or 2:${C_RESET}" >&2
        read -r pick || pick=""
        case "$pick" in
          1) mode="tailscale-ssh"; break ;;
          2) mode="sshd"; break ;;
          *) log_warn "Enter 1 or 2." ;;
        esac
      done
    fi
  fi
  TS_SSH_MODE="$mode"
  log_ok "SSH access model: $TS_SSH_MODE"
}

# --- Step 3: bring the interface up ------------------------------------------
detect_headless() {
  # Headless == no graphical session we could open a browser in.
  [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]
}

bring_up() {
  # Already up? Idempotent early return.
  if tailscale status >/dev/null 2>&1; then
    log_ok "Tailscale is already up."
    return 0
  fi

  local up_args=(up)
  [[ "$TS_SSH_MODE" == "tailscale-ssh" ]] && up_args+=(--ssh)
  [[ -n "${TS_HOSTNAME:-}" ]] && up_args+=(--hostname "$TS_HOSTNAME")

  local authkey="${TS_AUTHKEY:-}"
  if [[ -z "$authkey" && -t 0 && "$FORGE_ASSUME_YES" != "1" ]]; then
    log_info "You can paste a Tailscale auth key now, or leave blank to authenticate in a browser."
    printf '%s ' "${C_BOLD}Tailscale auth key (input hidden, blank = browser):${C_RESET}" >&2
    read -rs authkey || authkey=""
    printf '\n' >&2
  fi

  if [[ -n "$authkey" ]]; then
    up_args+=(--authkey "$authkey")
    log_info "Bringing Tailscale up with the provided auth key."
    # Note: we pass the key as an argument to `tailscale up`; it is not echoed.
    run_cmd_sudo tailscale "${up_args[@]}" || log_die "tailscale up failed with the provided auth key."
  else
    if detect_headless; then
      log_step "Headless authentication"
      log_info "No display detected. Tailscale will print an authentication URL."
      log_info "Open it on another device (phone/laptop) to authorize this machine."
    fi
    log_info "Running: tailscale ${up_args[*]}"
    # Interactive/browser auth: let tailscale print its URL to the user's terminal.
    run_cmd_sudo tailscale "${up_args[@]}" || log_die "tailscale up failed during interactive auth."
  fi
}

# --- Step 4: verify ----------------------------------------------------------
verify() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would verify with 'tailscale status' and 'ip addr show tailscale0'."
    return 0
  fi

  log_step "Verifying Tailscale connectivity"
  if ! tailscale status >/dev/null 2>&1; then
    log_die "tailscale status reports the interface is not up. Re-run to retry auth."
  fi

  # Assigned Tailscale IPv4 and MagicDNS name.
  local ts_ip ts_name
  ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  ts_name="$(tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//;s/\.$//' || true)"

  if command -v ip >/dev/null 2>&1; then
    if ip addr show tailscale0 >/dev/null 2>&1; then
      log_ok "Interface tailscale0 is present."
    else
      log_warn "tailscale0 interface not found via 'ip addr' — status was OK, but check networking."
    fi
  fi

  log_ok "Tailscale is up."
  [[ -n "$ts_ip" ]]   && log_info "  Tailscale IP:   ${C_BOLD}${ts_ip}${C_RESET}"
  [[ -n "$ts_name" ]] && log_info "  MagicDNS name:  ${C_BOLD}${ts_name}${C_RESET}"
  log_info "Downstream services (e.g. Caddy TLS) will use this MagicDNS name."
}

main() {
  install_binary
  choose_ssh_mode
  bring_up
  verify
  log_ok "Tailscale module complete."
  if [[ "$TS_SSH_MODE" == "sshd" ]]; then
    log_info "You chose traditional sshd — run the SSH-hardening module next:"
    log_info "    ./forge.sh install --with ssh-hardening"
  fi
}

main "$@"
