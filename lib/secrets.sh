#!/usr/bin/env bash
# lib/secrets.sh — strong secret generation for service .env files.
#
# Contract:
#   - Secrets are generated with `openssl rand` (falls back to /dev/urandom).
#   - They are written to git-ignored per-module .env files by lib/env.sh.
#   - A secret is PRINTED TO THE USER EXACTLY ONCE, at first generation, behind
#     a bold "save these now" warning — never re-printed on subsequent runs.
#   - Idempotent: if a value already exists in a .env, it is NOT regenerated
#     (so re-running the installer never rotates live credentials).
#
# Depends on: lib/log.sh.

[[ -n "${_TUNINFORGE_SECRETS_SH:-}" ]] && return 0
_TUNINFORGE_SECRETS_SH=1

# Accumulates "SERVICE|KEY|VALUE" for secrets generated during THIS run, so we
# can print them together once at the end via secrets_flush_notice.
_TUNINFORGE_NEW_SECRETS=()

# --- Generators --------------------------------------------------------------
# gen_hex <bytes>   -> hex string (2*bytes chars). Safe everywhere.
# gen_b64url <bytes>-> URL-safe base64 (no +/= to break URLs/env).
# gen_alnum <len>   -> alphanumeric of exactly <len> (safe in connection strings).
#
# All prefer openssl; fall back to /dev/urandom so a minimal box still works.
gen_hex() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

gen_b64url() {
  local bytes="${1:-32}" out
  if command -v openssl >/dev/null 2>&1; then
    out="$(openssl rand -base64 "$bytes")"
  else
    out="$(head -c "$bytes" /dev/urandom | base64)"
  fi
  # Make URL/env-safe: +/ -> -_ and strip padding/newlines.
  printf '%s' "$out" | tr '+/' '-_' | tr -d '=\n'
}

gen_alnum() {
  local len="${1:-32}" out=""
  # Draw extra random bytes, keep only [A-Za-z0-9], trim to length. Loop until
  # we have enough (rejection of non-alnum can shrink the pool).
  while [ "${#out}" -lt "$len" ]; do
    if command -v openssl >/dev/null 2>&1; then
      out="$out$(openssl rand -base64 $((len * 2)) | LC_ALL=C tr -dc 'A-Za-z0-9')"
    else
      out="$out$(head -c $((len * 3)) /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    fi
  done
  printf '%s' "${out:0:$len}"
}

# --- Registration + one-time notice ------------------------------------------
# secrets_register <service> <key> <value>: record a freshly generated secret so
# it is shown once. Called by lib/env.sh when it fills a placeholder.
secrets_register() {
  _TUNINFORGE_NEW_SECRETS+=("$1|$2|$3")
}

# secrets_any_new -> 0 if secrets were generated this run.
secrets_any_new() { [ "${#_TUNINFORGE_NEW_SECRETS[@]}" -gt 0 ]; }

# secrets_flush_notice: print all secrets generated this run, ONCE, with a
# prominent save-now warning, then clear the buffer. In DRY_RUN we don't have
# real values (nothing was written), so we just note that.
secrets_flush_notice() {
  secrets_any_new || return 0

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] would generate ${#_TUNINFORGE_NEW_SECRETS[@]} secret(s) and show them once here."
    _TUNINFORGE_NEW_SECRETS=()
    return 0
  fi

  log_alert \
    "GENERATED SECRETS — SAVE THESE NOW." \
    "They are stored in git-ignored .env files and will NOT be shown again." \
    "Store them in your password manager before continuing."

  local entry svc key val last_svc=""
  for entry in "${_TUNINFORGE_NEW_SECRETS[@]}"; do
    svc="${entry%%|*}"; entry="${entry#*|}"
    key="${entry%%|*}"; val="${entry#*|}"
    if [[ "$svc" != "$last_svc" ]]; then
      printf '\n  %s%s%s\n' "${C_BOLD}${C_CYAN}" "$svc" "${C_RESET}" >&2
      last_svc="$svc"
    fi
    printf '    %s = %s%s%s\n' "$key" "${C_BOLD}" "$val" "${C_RESET}" >&2
  done
  printf '\n' >&2
  log_warn "The above will not be printed again. Saved? Continuing."
  _TUNINFORGE_NEW_SECRETS=()
}
