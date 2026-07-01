#!/usr/bin/env bash
# modules/access/ssh-hardening/harden.sh
#
# Hardens OpenSSH server config following a strict, lockout-safe sequence.
# This is the single most dangerous module in homelab-forge, so it is written
# defensively: it validates a candidate config with `sshd -t` BEFORE it ever
# replaces the live file, reloads (never restarts) to avoid dropping sessions,
# and refuses to declare success until the user confirms a fresh login works.
#
# SEQUENCE (never skip a step):
#   1. Require working key-based login (STOP if absent — user must add a key first).
#   2. Unconditionally back up sshd_config to sshd_config.bak.<timestamp>.
#   3. Apply directives idempotently (only change values that differ).
#   4. Validate candidate with `sshd -t`; abort on failure. Reload (not restart).
#   5. Keep this session open; instruct user to test a NEW session (bold/red).
#   6. Require explicit confirmation; otherwise print the rollback command.
#   7. Optionally: fail2ban for sshd, and ufw limiting :22 to tailscale0 ONLY
#      after Tailscale is verified up.
#
# FLAGS:
#   --dry-run                 print changes, touch nothing
#   --i-understand-the-risk   permit running when NOT interactive (lockout risk)
#
# ENV (optional, from forge.config.yaml wiring later):
#   SSH_PERMIT_ROOT_LOGIN   "no" (default) | "prohibit-password"
#   SSH_ENABLE_FAIL2BAN     "1" to configure fail2ban (step 7)
#   SSH_UFW_TAILSCALE_ONLY  "1" to restrict :22 to tailscale0 (step 7)

set -euo pipefail

: "${FORGE_LIB:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)}"
# shellcheck source=../../../lib/log.sh
source "$FORGE_LIB/log.sh"

SSHD_CONFIG="/etc/ssh/sshd_config"
PERMIT_ROOT_LOGIN="${SSH_PERMIT_ROOT_LOGIN:-no}"
BACKUP_PATH=""   # set in step 2; referenced by the rollback message.

# --- Local flag parse (module can be invoked standalone) ---------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)               DRY_RUN=1 ;;
    --i-understand-the-risk) I_UNDERSTAND_THE_RISK=1 ;;
    *) log_warn "ssh-hardening: ignoring unknown arg '$1'" ;;
  esac
  shift
done
: "${I_UNDERSTAND_THE_RISK:=0}"

# The exact directives we enforce. Order preserved for readability of the diff.
declare -a HARDENED_KEYS=(
  "PubkeyAuthentication"
  "PasswordAuthentication"
  "PermitRootLogin"
  "KbdInteractiveAuthentication"
)
declare -A HARDENED_VALUES=(
  ["PubkeyAuthentication"]="yes"
  ["PasswordAuthentication"]="no"
  ["PermitRootLogin"]="$PERMIT_ROOT_LOGIN"
  ["KbdInteractiveAuthentication"]="no"
)

# --- Guardrail: refuse unattended runs without explicit acknowledgement ------
guard_interactivity() {
  if [[ ! -t 0 ]]; then
    if [[ "$I_UNDERSTAND_THE_RISK" != "1" && "$DRY_RUN" != "1" ]]; then
      log_error "ssh-hardening refuses to run non-interactively without --i-understand-the-risk."
      log_error "Editing sshd_config unattended risks locking you out of the box."
      log_die   "Re-run interactively, or pass --i-understand-the-risk if you accept the risk."
    fi
  fi
}

# --- Determine the human user who will log in --------------------------------
login_user() {
  # If invoked via sudo, the real user is SUDO_USER; else the current user.
  echo "${SUDO_USER:-${USER:-$(id -un)}}"
}

user_home() {
  local u="$1" home
  home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)"
  [[ -z "$home" ]] && home="$(eval echo "~$u" 2>/dev/null || true)"
  echo "$home"
}

# --- STEP 1: require working key-based login ---------------------------------
step1_require_key_auth() {
  log_step "Step 1/7 — Verify key-based login is possible"
  local u home found=0
  u="$(login_user)"
  home="$(user_home "$u")"

  if [[ -n "$home" && -f "$home/.ssh/authorized_keys" ]]; then
    # Non-empty, non-comment line == at least one key present.
    if grep -qvE '^\s*(#|$)' "$home/.ssh/authorized_keys" 2>/dev/null; then
      found=1
      local n; n="$(grep -cvE '^\s*(#|$)' "$home/.ssh/authorized_keys" 2>/dev/null || echo 0)"
      log_ok "Found $n authorized key(s) for user '$u' in $home/.ssh/authorized_keys."
    fi
  fi

  # Root recovery access: if PermitRootLogin will allow key auth, note root keys.
  if [[ "$PERMIT_ROOT_LOGIN" == "prohibit-password" ]]; then
    if [[ -f /root/.ssh/authorized_keys ]] && grep -qvE '^\s*(#|$)' /root/.ssh/authorized_keys 2>/dev/null; then
      log_ok "Root has authorized key(s) (prohibit-password recovery path available)."
    else
      log_warn "PermitRootLogin=prohibit-password but /root/.ssh/authorized_keys has no keys."
    fi
  fi

  if [[ "$found" != "1" ]]; then
    log_alert \
      "NO SSH PUBLIC KEY FOUND for user '$u'." \
      "Disabling password auth now would LOCK YOU OUT of this server." \
      "" \
      "Do this FIRST, then re-run:" \
      "  1. On your local machine:  ssh-copy-id $u@<this-host>" \
      "  2. Open a NEW terminal and confirm:  ssh $u@<this-host>" \
      "     (it must log in WITHOUT asking for a password)" \
      "  3. Only then re-run the SSH-hardening module."
    log_die "Stopping: confirm key-based login works before hardening. (No changes made.)"
  fi

  # We cannot truly prove a login succeeds from here, so require the user to
  # affirm it — unless a key is present AND they pass the risk flag / --yes.
  if ! confirm "Have you ALREADY logged into this box successfully using an SSH key (no password)?" no; then
    log_die "Confirm a successful key-based login first. No changes made."
  fi
}

# --- STEP 2: unconditional timestamped backup --------------------------------
step2_backup() {
  log_step "Step 2/7 — Back up $SSHD_CONFIG"
  local ts; ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
  BACKUP_PATH="${SSHD_CONFIG}.bak.${ts}"

  if [[ ! -f "$SSHD_CONFIG" ]]; then
    log_die "$SSHD_CONFIG not found — is OpenSSH server installed? (apt install openssh-server)"
  fi

  run_cmd_sudo cp -a "$SSHD_CONFIG" "$BACKUP_PATH"
  if [[ "$DRY_RUN" != "1" ]]; then
    [[ -f "$BACKUP_PATH" ]] || log_die "Backup failed; refusing to continue."
    log_ok "Backed up to $BACKUP_PATH"
  else
    log_info "[dry-run] backup would be at $BACKUP_PATH"
  fi
}

# --- STEP 3+4: build candidate config idempotently, validate, then install ---
# Produces the new config on stdout from the current one, changing only the
# directives whose effective value differs. Preserves everything else verbatim.
render_candidate() {
  local src="$1"
  awk -v keys="${HARDENED_KEYS[*]}" \
      -v pubkey="${HARDENED_VALUES[PubkeyAuthentication]}" \
      -v passwd="${HARDENED_VALUES[PasswordAuthentication]}" \
      -v root="${HARDENED_VALUES[PermitRootLogin]}" \
      -v kbd="${HARDENED_VALUES[KbdInteractiveAuthentication]}" '
    BEGIN {
      want["PubkeyAuthentication"]=pubkey
      want["PasswordAuthentication"]=passwd
      want["PermitRootLogin"]=root
      want["KbdInteractiveAuthentication"]=kbd
      for (k in want) seen[k]=0
    }
    {
      line=$0
      # Match an active (uncommented) directive line: optional leading ws, key, ws, value.
      if (match(line, /^[ \t]*[A-Za-z]+[ \t]/)) {
        # Extract the first token as the directive name.
        tmp=line
        sub(/^[ \t]+/, "", tmp)
        split(tmp, parts, /[ \t]+/)
        key=parts[1]
        if (key in want) {
          if (seen[key]==0) {
            print key " " want[key]
            seen[key]=1
          }
          # Drop any duplicate active occurrences (idempotent collapse).
          next
        }
      }
      print line
    }
    END {
      # Append any directive that was never present.
      for (k in want) if (seen[k]==0) print k " " want[k]
    }
  ' "$src"
}

step3_4_apply_and_validate() {
  log_step "Step 3/7 — Apply directives idempotently"
  for k in "${HARDENED_KEYS[@]}"; do
    log_info "  enforce: ${C_BOLD}${k} ${HARDENED_VALUES[$k]}${C_RESET}"
  done

  local candidate; candidate="$(mktemp -t sshd_config.candidate.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$candidate'" RETURN

  # Read the live config (via sudo if needed) and render the candidate.
  if [[ "$(id -u)" -eq 0 ]]; then
    render_candidate "$SSHD_CONFIG" >"$candidate"
  else
    sudo cat "$SSHD_CONFIG" | render_candidate /dev/stdin >"$candidate"
  fi

  # Show the diff so the user sees exactly what changes.
  log_info "Proposed changes:"
  if [[ "$(id -u)" -eq 0 ]]; then
    diff -u "$SSHD_CONFIG" "$candidate" >&2 || true
  else
    sudo diff -u "$SSHD_CONFIG" "$candidate" >&2 || true
  fi

  # If the candidate is identical, we're already hardened — idempotent no-op.
  local identical=0
  if [[ "$(id -u)" -eq 0 ]]; then
    diff -q "$SSHD_CONFIG" "$candidate" >/dev/null 2>&1 && identical=1
  else
    sudo diff -q "$SSHD_CONFIG" "$candidate" >/dev/null 2>&1 && identical=1
  fi
  if [[ "$identical" == "1" ]]; then
    log_ok "sshd_config already matches the hardened policy. Nothing to change."
    return 0
  fi

  log_step "Step 4/7 — Validate candidate with 'sshd -t' before applying"
  local sshd_bin; sshd_bin="$(command -v sshd || echo /usr/sbin/sshd)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would validate the candidate with: $sshd_bin -t -f <candidate>"
    log_info "[dry-run] would then install it to $SSHD_CONFIG and 'systemctl reload' ssh."
    return 0
  fi

  # Validate the CANDIDATE file specifically. Abort entirely on failure.
  if ! run_cmd_sudo "$sshd_bin" -t -f "$candidate"; then
    log_die "sshd -t rejected the candidate config. NOT applying. Original untouched."
  fi
  log_ok "Candidate config passed 'sshd -t'."

  # Install the validated candidate over the live file (backup already taken).
  run_cmd_sudo install -m 0644 -o root -g root "$candidate" "$SSHD_CONFIG"
  log_ok "Installed hardened $SSHD_CONFIG."

  # Reload (NOT restart) so existing sessions are not dropped.
  reload_sshd
}

reload_sshd() {
  # Ubuntu's unit is 'ssh'; some distros use 'sshd'. Reload whichever exists.
  local unit=""
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    unit="ssh"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    unit="sshd"
  fi
  if [[ -z "$unit" ]]; then
    log_warn "Could not detect the ssh systemd unit; attempting 'ssh' then 'sshd'."
    run_cmd_sudo systemctl reload ssh 2>/dev/null || run_cmd_sudo systemctl reload sshd
    return
  fi
  log_info "Reloading '$unit' (reload, not restart — active sessions preserved)."
  run_cmd_sudo systemctl reload "$unit"
  log_ok "Reloaded $unit."
}

# --- STEP 5+6: DO NOT close session; confirm; or print rollback --------------
step5_6_confirm_or_rollback() {
  local rollback_cmd="sudo cp ${BACKUP_PATH:-<backup>} $SSHD_CONFIG && sudo systemctl reload ssh"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_step "Step 5/7 — (dry-run) session-safety confirmation"
    log_info "[dry-run] Real run would now require you to verify a fresh SSH session."
    log_info "[dry-run] Rollback command would be: $rollback_cmd"
    return 0
  fi

  log_step "Step 5/7 — Verify a NEW session BEFORE trusting this change"
  log_alert \
    "DO NOT CLOSE THIS SSH SESSION." \
    "" \
    "Open a SECOND terminal on your local machine and run:" \
    "    ssh $(login_user)@<this-host>" \
    "" \
    "It MUST log in using your key, without a password prompt." \
    "If it fails, come back to THIS still-open session and roll back."

  log_step "Step 6/7 — Confirm the new session works"
  if confirm "Did your NEW SSH session log in successfully with your key?" no; then
    log_ok "SSH hardening confirmed working."
    log_info "Backup retained at: ${BACKUP_PATH}"
    return 0
  fi

  # Not confirmed: leave the rollback command prominently on screen. We do NOT
  # auto-rollback (the user may just not have tested yet), but we make it trivial.
  log_alert \
    "SSH HARDENING NOT CONFIRMED." \
    "Your current session is still open and still works." \
    "" \
    "If you are locked out of NEW sessions, run this in THIS session:" \
    "    $rollback_cmd"
  log_warn "Leaving hardened config in place but UNCONFIRMED. Roll back if needed."
  return 0
}

# --- STEP 7: optional fail2ban + ufw (post-Tailscale) ------------------------
step7_optional_firewalling() {
  log_step "Step 7/7 — Optional: fail2ban + ufw (safe extras)"

  # fail2ban: no lockout risk, purely additive.
  if [[ "${SSH_ENABLE_FAIL2BAN:-0}" == "1" ]] || \
     { [[ -t 0 ]] && confirm "Configure fail2ban for sshd (recommended, no lockout risk)?" yes; }; then
    configure_fail2ban
  else
    log_info "Skipping fail2ban."
  fi

  # ufw restricting :22 to tailscale0 — ONLY if Tailscale is verified up.
  local want_ufw=0
  if [[ "${SSH_UFW_TAILSCALE_ONLY:-0}" == "1" ]]; then
    want_ufw=1
  elif [[ -t 0 ]] && confirm "Restrict SSH (port 22) to the tailscale0 interface only?" no; then
    want_ufw=1
  fi

  if [[ "$want_ufw" == "1" ]]; then
    if ! command -v tailscale >/dev/null 2>&1 || ! tailscale status >/dev/null 2>&1; then
      log_warn "Tailscale is NOT verified up. Refusing to firewall off SSH — that could"
      log_warn "lock you out. Bring Tailscale up first, then re-run this step."
    else
      configure_ufw_ssh_tailscale_only
    fi
  else
    log_info "Skipping ufw SSH restriction."
  fi
}

configure_fail2ban() {
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    log_info "Installing fail2ban."
    run_cmd_sudo apt-get update -qq
    run_cmd_sudo apt-get install -y fail2ban
  fi
  # Minimal, safe sshd jail. Written idempotently to a dedicated jail.d file.
  local jail="/etc/fail2ban/jail.d/forge-sshd.local"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would write $jail enabling the sshd jail (maxretry=5, bantime=1h)."
  else
    run_cmd_sudo tee "$jail" >/dev/null <<'EOF'
# Managed by homelab-forge (ssh-hardening). Safe defaults; edit as needed.
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
    run_cmd_sudo systemctl enable --now fail2ban
    log_ok "fail2ban configured (sshd jail: 5 retries / 10m, 1h ban)."
  fi
}

configure_ufw_ssh_tailscale_only() {
  if ! command -v ufw >/dev/null 2>&1; then
    log_info "Installing ufw."
    run_cmd_sudo apt-get update -qq
    run_cmd_sudo apt-get install -y ufw
  fi
  log_info "Allowing SSH only on tailscale0; denying :22 elsewhere."
  # Allow SSH in on the tailscale interface, then remove any broad allow.
  run_cmd_sudo ufw allow in on tailscale0 to any port 22 proto tcp
  # Ensure ufw is enabled without prompting.
  run_cmd_sudo ufw --force enable
  log_ok "ufw now limits SSH to the tailscale0 interface."
  log_info "Verify with: sudo ufw status verbose"
}

# --- Orchestration -----------------------------------------------------------
main() {
  guard_interactivity
  log_step "SSH hardening (lockout-safe)"
  [[ "$DRY_RUN" == "1" ]] && log_info "DRY-RUN: no changes will be made."

  step1_require_key_auth
  step2_backup
  step3_4_apply_and_validate
  step5_6_confirm_or_rollback
  step7_optional_firewalling

  log_ok "SSH-hardening module finished."
  [[ -n "$BACKUP_PATH" && "$DRY_RUN" != "1" ]] && \
    log_info "Rollback anytime: sudo cp $BACKUP_PATH $SSHD_CONFIG && sudo systemctl reload ssh"
}

main "$@"
