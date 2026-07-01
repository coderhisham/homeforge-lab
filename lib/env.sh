#!/usr/bin/env bash
# lib/env.sh — materialize a module's .env from its .env.example.
#
# Convention (in .env.example):
#   PLAIN_KEY=some-fixed-default          # copied verbatim
#   SECRET_KEY=__GEN:alnum:32__           # replaced with a fresh secret
#   OTHER=__GEN:hex:16__ / __GEN:b64url:48__
#   # comments and blank lines are preserved
#
# Behavior:
#   - Creates <module>/.env if absent, from .env.example.
#   - For each __GEN:type:len__ placeholder, generates a secret, substitutes it,
#     and registers it for the one-time "save these" notice (secrets.sh).
#   - IDEMPOTENT: a key already present in .env is left untouched — re-running
#     never rotates a live credential. Keys newly added to .env.example (an
#     upgrade) are appended with generated values; existing ones are preserved.
#   - .env files are git-ignored (see root .gitignore: **/.env).
#
# Depends on: lib/log.sh, lib/secrets.sh.

[[ -n "${_FORGE_ENV_SH:-}" ]] && return 0
_FORGE_ENV_SH=1

# _env_expand_placeholder <service> <key> <raw-value> -> resolved value.
# Resolves a __GEN:type:len__ token to a fresh secret and registers it so it is
# shown once. Non-placeholder values are returned unchanged.
_env_expand_placeholder() {
  local svc="$1" key="$2" raw="$3"
  case "$raw" in
    __GEN:*__)
      local spec type len val
      spec="${raw#__GEN:}"; spec="${spec%__}"   # e.g. "alnum:32"
      type="${spec%%:*}"; len="${spec#*:}"
      [[ "$len" =~ ^[0-9]+$ ]] || len=32
      case "$type" in
        alnum)  val="$(gen_alnum "$len")" ;;
        hex)    val="$(gen_hex "$len")" ;;
        b64url) val="$(gen_b64url "$len")" ;;
        *)      log_warn "env: unknown generator '$type' for $key; using alnum:32"
                val="$(gen_alnum 32)" ;;
      esac
      secrets_register "$svc" "$key" "$val"
      printf '%s' "$val"
      ;;
    *)
      printf '%s' "$raw"
      ;;
  esac
}

# env_key_present <env-file> <key> -> 0 if an active KEY= line exists.
env_key_present() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  grep -qE "^[[:space:]]*${key}=" "$file"
}

# env_materialize <module-dir> [service-name]
#   Ensures <module-dir>/.env exists and contains a value for every key in
#   <module-dir>/.env.example. service-name defaults to the dir's basename and
#   is used only to label secrets in the one-time notice.
env_materialize() {
  local dir="$1" svc="${2:-$(basename "$1")}"
  local example="$dir/.env.example" envfile="$dir/.env"

  if [[ ! -f "$example" ]]; then
    log_debug "env: no .env.example in $dir; skipping."
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    # Report what would happen without writing or generating real values.
    if [[ -f "$envfile" ]]; then
      log_info "[dry-run] $svc/.env exists; would fill only missing keys."
    else
      log_info "[dry-run] would create $svc/.env from .env.example and generate its secrets."
    fi
    # Still register placeholders so the notice count is representative.
    local k v
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      k="${line%%=*}"; v="${line#*=}"
      case "$v" in __GEN:*__) secrets_register "$svc" "$k" "<generated>" ;; esac
    done < "$example"
    return 0
  fi

  # First run: create .env from example, expanding placeholders.
  if [[ ! -f "$envfile" ]]; then
    local tmp; tmp="$(mktemp -t forge-env.XXXXXX)"
    local line key val resolved
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        ''|\#*)
          printf '%s\n' "$line" >>"$tmp" ;;
        *=*)
          key="${line%%=*}"; val="${line#*=}"
          resolved="$(_env_expand_placeholder "$svc" "$key" "$val")"
          printf '%s=%s\n' "$key" "$resolved" >>"$tmp" ;;
        *)
          printf '%s\n' "$line" >>"$tmp" ;;
      esac
    done < "$example"
    # 0600: .env holds secrets — restrict to owner.
    install -m 0600 "$tmp" "$envfile"
    rm -f "$tmp"
    log_ok "Generated $svc/.env (secrets included)."
    return 0
  fi

  # Existing .env: append only keys that are missing (idempotent upgrade path).
  local line key val resolved added=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    if ! env_key_present "$envfile" "$key"; then
      resolved="$(_env_expand_placeholder "$svc" "$key" "$val")"
      printf '%s=%s\n' "$key" "$resolved" >>"$envfile"
      added=$((added + 1))
    fi
  done < "$example"
  if [[ "$added" -gt 0 ]]; then
    log_ok "Updated $svc/.env (+$added new key(s); existing values preserved)."
  else
    log_debug "env: $svc/.env already complete; no changes."
  fi
}
