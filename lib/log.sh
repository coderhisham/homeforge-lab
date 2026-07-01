#!/usr/bin/env bash
# lib/log.sh — shared logging, warnings, dry-run, and confirmation helpers.
#
# Source this from tuninforge.sh and every module:
#   source "${TUNINFORGE_LIB:-lib}/log.sh"
#
# Design notes:
# - This file only DEFINES functions and a few globals. It never calls `set -e`
#   or exits on its own, so sourcing it can't change the caller's shell options.
# - Colors auto-disable when stdout is not a terminal, when NO_COLOR is set
#   (https://no-color.org), or when TERM=dumb — so piping to a file stays clean.
# - Diagnostics (info/ok/warn/error/step) go to STDERR, so a command's real
#   output on STDOUT stays uncontaminated and pipeable.

# Guard against double-sourcing.
[[ -n "${_TUNINFORGE_LOG_SH:-}" ]] && return 0
_TUNINFORGE_LOG_SH=1

# --- Global toggles ----------------------------------------------------------
# DRY_RUN=1        -> run_cmd prints commands instead of executing them.
# TUNINFORGE_ASSUME_YES=1 -> confirm() returns success without prompting (for
#                       --yes / non-interactive installs). Never auto-assume yes
#                       for the SSH-hardening lockout confirmation; that path
#                       gates on interactivity separately.
: "${DRY_RUN:=0}"
: "${TUNINFORGE_ASSUME_YES:=0}"

# --- Color setup -------------------------------------------------------------
_tuninforge_init_colors() {
  if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]] || [[ ! -t 2 ]]; then
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
    return
  fi
  # Prefer tput when available (respects terminfo); fall back to raw ANSI.
  if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"
    C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
    C_BLUE="$(tput setaf 4)"; C_CYAN="$(tput setaf 6)"
  else
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
  fi
}
_tuninforge_init_colors

# --- Core log levels (all to stderr) -----------------------------------------
log_info()  { printf '%s\n' "${C_BLUE}•${C_RESET} $*" >&2; }
log_ok()    { printf '%s\n' "${C_GREEN}✓${C_RESET} $*" >&2; }
log_warn()  { printf '%s\n' "${C_YELLOW}!${C_RESET} ${C_YELLOW}$*${C_RESET}" >&2; }
log_error() { printf '%s\n' "${C_RED}✗${C_RESET} ${C_RED}$*${C_RESET}" >&2; }
log_debug() { [[ "${TUNINFORGE_DEBUG:-0}" == "1" ]] && printf '%s\n' "${C_DIM}  $*${C_RESET}" >&2; return 0; }

# log_step: a titled section header, e.g. before each module or hardening step.
log_step() { printf '\n%s\n' "${C_BOLD}${C_CYAN}==> $*${C_RESET}" >&2; }

# log_die: error + exit non-zero. Use for unrecoverable failures.
log_die() { log_error "$*"; exit 1; }

# log_alert: a bold/red boxed banner for safety-critical warnings the user MUST
# read (e.g. the SSH-hardening "open a second terminal" instruction). Every line
# passed as a separate argument becomes its own line inside the box.
log_alert() {
  local line width=0
  for line in "$@"; do (( ${#line} > width )) && width=${#line}; done
  (( width < 60 )) && width=60
  local bar; bar="$(printf '━%.0s' $(seq 1 $((width + 2))))"
  {
    printf '%s\n' "${C_BOLD}${C_RED}┏${bar}┓${C_RESET}"
    for line in "$@"; do
      printf '%s\n' "${C_BOLD}${C_RED}┃ ${C_RESET}${C_BOLD}$(printf '%-*s' "$width" "$line")${C_BOLD}${C_RED} ┃${C_RESET}"
    done
    printf '%s\n' "${C_BOLD}${C_RED}┗${bar}┛${C_RESET}"
  } >&2
}

# --- Dry-run command wrapper -------------------------------------------------
# run_cmd: execute a command, or (when DRY_RUN=1) print what WOULD run.
# Usage: run_cmd systemctl reload ssh
# Quotes each argument so the printed form is copy-pasteable.
run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    printf '%s\n' "${C_DIM}[dry-run]${C_RESET}${C_YELLOW} would run:${C_RESET}${q}" >&2
    return 0
  fi
  "$@"
}

# run_cmd_sudo: same as run_cmd but prefixes sudo when not already root.
run_cmd_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    run_cmd "$@"
  else
    run_cmd sudo "$@"
  fi
}

# --- Confirmation prompt -----------------------------------------------------
# confirm "Question?"            -> default No
# confirm "Question?" yes        -> default Yes
# Returns 0 for yes, 1 for no. Honors TUNINFORGE_ASSUME_YES=1 (returns 0 without
# prompting). If stdin is not a TTY and TUNINFORGE_ASSUME_YES is unset, returns 1
# (safe default) rather than hanging.
confirm() {
  local prompt="$1" default="${2:-no}" reply hint

  if [[ "$TUNINFORGE_ASSUME_YES" == "1" ]]; then
    log_debug "auto-confirming (--yes): $prompt"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    log_warn "Not interactive; declining by default: $prompt"
    return 1
  fi

  if [[ "$default" == "yes" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while true; do
    printf '%s ' "${C_BOLD}${prompt}${C_RESET} ${hint}" >&2
    read -r reply || return 1
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) log_warn "Please answer yes or no." ;;
    esac
  done
}

# confirm_typed: require the user to type an exact phrase (stronger than y/n),
# for genuinely dangerous actions. Never auto-confirmed by TUNINFORGE_ASSUME_YES.
# Usage: confirm_typed "Type the service name to confirm deletion" "qdrant"
confirm_typed() {
  local prompt="$1" expected="$2" reply
  if [[ ! -t 0 ]]; then
    log_warn "Not interactive; cannot confirm typed phrase for: $prompt"
    return 1
  fi
  printf '%s ' "${C_BOLD}${prompt}${C_RESET} (type '${C_CYAN}${expected}${C_RESET}'):" >&2
  read -r reply || return 1
  [[ "$reply" == "$expected" ]]
}
