#!/usr/bin/env bash
# lib/tui.sh — interactive service selection, modeled on OpenClaw's
# `openclaw onboard` wizard (QuickStart vs Advanced fork), rendered with
# whiptail (preinstalled on Ubuntu LTS).
#
# Contract:
#   tui_select_services        -> populates the global TUNINFORGE_SELECTION (space-
#                                 separated, dependency-resolved, install-ordered)
#                                 and returns 0 to proceed, 1 to abort.
#
# All whiptail widgets draw to the terminal; this file never prints the
# selection to stdout mid-flow, so callers read TUNINFORGE_SELECTION directly.
#
# Depends on: lib/log.sh, lib/deps.sh (source those first).

[[ -n "${_TUNINFORGE_TUI_SH:-}" ]] && return 0
_TUNINFORGE_TUI_SH=1

TUNINFORGE_SELECTION=""   # result, set by tui_select_services

# --- whiptail availability / sizing ------------------------------------------
tui_has_whiptail() { command -v whiptail >/dev/null 2>&1; }

# --- Go TUI (beautiful path) -------------------------------------------------
# A committed, statically-linked Bubble Tea binary renders the selection UI.
# It is a pure VIEW over the registry: tuninforge.sh pipes tuninforge_registry_json to it
# on stdin, it draws to stderr, and prints the raw picks (space-separated) to
# stdout. Bash remains authoritative — we re-resolve dependencies on the picks.
#
# tui_go_binary -> echoes the path to the right binary for this arch, or empty.
tui_go_binary() {
  local bindir="${TUNINFORGE_ROOT:-.}/bin" arch bin
  case "$(uname -m)" in
    x86_64|amd64)      arch="amd64" ;;
    aarch64|arm64)     arch="arm64" ;;
    *)                 return 0 ;;   # unsupported arch -> no binary
  esac
  bin="$bindir/tuninforge-tui-linux-$arch"
  # Only usable on Linux (these are ELF binaries) and if present + executable.
  [[ "$(uname -s)" == "Linux" && -f "$bin" ]] || return 0
  [[ -x "$bin" ]] || chmod +x "$bin" 2>/dev/null || true
  echo "$bin"
}

# tui_select_via_go -> run the Go TUI; on success set TUNINFORGE_SELECTION (resolved
# + ordered by Bash) and return 0. Return 2 if the binary is unavailable/failed
# (caller falls back to whiptail), or 1 if the user cancelled in the UI.
tui_select_via_go() {
  local bin; bin="$(tui_go_binary)"
  [[ -n "$bin" ]] || return 2

  # Write the registry JSON to a temp file and pass its PATH as an argument.
  # We must NOT pipe it on stdin: the Go TUI needs stdin attached to the
  # terminal for Bubble Tea to read keystrokes.
  local regfile; regfile="$(mktemp -t tuninforge-registry.XXXXXX.json)"
  # shellcheck disable=SC2064
  trap "rm -f '$regfile'" RETURN
  tuninforge_registry_json >"$regfile"

  local picks rc
  # UI draws to stderr (inherited TTY); picks come back on stdout.
  picks="$("$bin" "$regfile")"; rc=$?

  if [[ $rc -eq 1 ]]; then
    log_info "Setup cancelled."
    return 1
  elif [[ $rc -ne 0 ]]; then
    log_warn "Go selection UI unavailable (exit $rc); falling back to whiptail."
    return 2
  fi

  picks="$(tr -s ' \n' ' ' <<<"$picks" | sed 's/^ *//;s/ *$//')"
  if [[ -z "$picks" ]]; then
    log_info "No services selected."
    return 1
  fi

  # Bash is authoritative: re-resolve deps + order, independent of the UI.
  local added
  # shellcheck disable=SC2086
  added="$(tuninforge_added_deps $picks)"
  [[ -n "${added// }" ]] && log_info "Auto-adding dependencies:$added"
  # shellcheck disable=SC2086
  TUNINFORGE_SELECTION="$(tuninforge_install_order $picks)"
  log_info "Selected: $TUNINFORGE_SELECTION"
  return 0
}

# Backtitle shown on every screen (OpenClaw-style consistent framing).
_TUI_BACKTITLE="tuninforge — modular self-hosted stack installer"

# Reasonable box dimensions that work over SSH on an 80x24 terminal.
_tui_rows()  { echo "${LINES:-24}"; }
_tui_cols()  { echo "${COLUMNS:-80}"; }

# --- The QuickStart vs Advanced fork (mirrors `openclaw onboard`) ------------
# Returns via stdout: "quickstart" or "advanced". Aborts (rc 1) on cancel.
#
# Uses --menu, NOT --radiolist: for a pick-exactly-one choice, a menu returns
# the highlighted row on ENTER directly. A radiolist requires SPACE to move the
# radio button first — arrow+ENTER leaves it on the default, so selecting the
# second option appears to do nothing. --menu removes that footgun entirely.
tui_choose_mode() {
  local choice
  choice="$(whiptail --backtitle "$_TUI_BACKTITLE" \
    --title "Setup mode" \
    --menu \
    "How do you want to set up tuninforge?\n\nUse ↑/↓ to move, ENTER to confirm." \
    15 74 2 \
    "quickstart" "Recommended defaults (Caddy + Portainer)" \
    "advanced"   "Choose every service, grouped by layer" \
    3>&1 1>&2 2>&3)" || return 1
  echo "$choice"
}

# --- Advanced: layer-grouped checklist ---------------------------------------
# Builds one flat whiptail checklist with layer headers as disabled-looking
# separator rows. whiptail has no native grouping, so we prefix each service
# tag with its layer via ordering and insert "──" section labels as items the
# user can toggle but that map to nothing (filtered out of results).
#
# Populates TUNINFORGE_SELECTION with the raw user picks (pre-dependency-resolution).
# Returns 1 on cancel.
tui_advanced_checklist() {
  local args=() layer svc title desc state def_checked
  def_checked=" $(tuninforge_default_checked | tr '\n' ' ') "

  while IFS= read -r layer; do
    title="$(tuninforge_layer_title "$layer")"
    # Section separator row: tag is "#<layer>", always shown OFF; filtered later.
    args+=( "#$layer" "── ${title} ──────────────────" OFF )
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      desc="$(tuninforge_desc "$svc")"
      case "$def_checked" in *" $svc "*) state=ON ;; *) state=OFF ;; esac
      # Tag = service name; item text = short description.
      args+=( "$svc" "$desc" "$state" )
    done < <(tuninforge_services_in_layer "$layer")
  done < <(tuninforge_layers)

  local raw
  raw="$(whiptail --backtitle "$_TUI_BACKTITLE" \
    --title "Select services" \
    --checklist \
    "SPACE toggles, ENTER confirms. Core is pre-selected.\nSeparator rows (── ──) are ignored if toggled." \
    22 78 12 \
    "${args[@]}" \
    3>&1 1>&2 2>&3)" || return 1

  # whiptail returns selected tags space-separated and quoted, e.g. "caddy" "redis".
  # Strip quotes and drop any "#layer" separator rows.
  local picked="" tag
  for tag in $raw; do
    tag="${tag%\"}"; tag="${tag#\"}"
    [[ "$tag" == \#* ]] && continue
    picked="$picked $tag"
  done
  # shellcheck disable=SC2086
  TUNINFORGE_SELECTION="$(echo $picked)"
  return 0
}

# --- Dependency handling (auto-add with note, warn on unchecking) ------------
# Given TUNINFORGE_SELECTION (raw picks), resolve dependencies. If any dependency is
# missing from the picks, tell the user which and why, and offer to add them
# (default yes). If they decline, warn about what will break but honor it.
tui_apply_dependencies() {
  local picks="$TUNINFORGE_SELECTION" missing note svc d
  missing="$(tuninforge_added_deps $picks)"

  if [[ -z "${missing// }" ]]; then
    # Still normalize to resolved + ordered even when nothing was added.
    TUNINFORGE_SELECTION="$(tuninforge_install_order $picks)"
    return 0
  fi

  # Build the "X is required by Y" explanation for the missing deps.
  note="These dependencies are required by your selection:\n"
  for d in $missing; do
    local needed_by=""
    for svc in $picks; do
      case " $(tuninforge_deps "$svc") " in *" $d "*) needed_by="$needed_by $svc" ;; esac
    done
    note="$note\n  • ${d}  ←  needed by:${needed_by}"
  done
  note="$note\n\nAdd them automatically? (Recommended)"

  if whiptail --backtitle "$_TUI_BACKTITLE" \
       --title "Dependencies" \
       --yesno "$note" 16 74 \
       3>&1 1>&2 2>&3; then
    TUNINFORGE_SELECTION="$(tuninforge_install_order $picks $missing)"
    log_info "Auto-added dependencies:$missing"
  else
    # User declined. Warn about what will break, but honor their choice.
    local breakage=""
    for svc in $picks; do
      for d in $(tuninforge_deps "$svc"); do
        case " $picks " in *" $d "*) ;; *) breakage="$breakage\n  • ${svc} may not start (missing ${d})" ;; esac
      done
    done
    whiptail --backtitle "$_TUI_BACKTITLE" \
      --title "⚠ Broken dependencies" \
      --msgbox "You chose not to add required dependencies. Expect:$breakage\n\nYou can add them later with:  ./tuninforge.sh add <service>" \
      15 74 3>&1 1>&2 2>&3 || true
    TUNINFORGE_SELECTION="$(tuninforge_install_order $picks)"
  fi
  return 0
}

# --- Summary + footprint + proceed gate --------------------------------------
# Shows chosen services grouped by layer, per-service + total RAM/disk estimate,
# a disk warning for heavy services, then requires explicit proceed.
tui_summary_and_confirm() {
  local sel="$TUNINFORGE_SELECTION"
  if [[ -z "${sel// }" ]]; then
    whiptail --backtitle "$_TUI_BACKTITLE" --title "Nothing selected" \
      --msgbox "No services were selected. Nothing to do." 8 60 3>&1 1>&2 2>&3 || true
    return 1
  fi

  local body="" svc ram disk heavy_note=""
  body="Services to install (dependencies included):\n"
  # List grouped by layer for readability.
  local layer
  while IFS= read -r layer; do
    local layer_line=""
    for svc in $(tuninforge_services_in_layer "$layer"); do
      case " $sel " in *" $svc "*) layer_line="$layer_line $svc" ;; esac
    done
    [[ -n "${layer_line// }" ]] && body="$body\n  $(tuninforge_layer_title "$layer"):${layer_line}"
  done < <(tuninforge_layers)

  # Footprint estimates.
  # shellcheck disable=SC2086
  ram="$(tuninforge_total_ram $sel)"
  # shellcheck disable=SC2086
  disk="$(tuninforge_total_disk $sel)"

  for svc in $sel; do
    tuninforge_is_heavy_disk "$svc" && heavy_note="$heavy_note\n  • ${svc}: large/growing disk use — grows with your data"
  done

  body="$body\n\nEstimated footprint (soft — not hard limits):"
  body="$body\n  RAM (reservations):  ~$(tuninforge_human_mb "$ram")"
  body="$body\n  Disk (base images):  ~$(tuninforge_human_mb "$disk")"
  [[ -n "$heavy_note" ]] && body="$body\n\n⚠ Disk-heavy services selected:$heavy_note"
  body="$body\n\nProceed with installation?"

  whiptail --backtitle "$_TUI_BACKTITLE" \
    --title "Review & confirm" \
    --yesno "$body" 22 76 \
    --yes-button "Proceed" --no-button "Cancel" \
    3>&1 1>&2 2>&3
}

# --- Orchestration -----------------------------------------------------------
# tui_select_services -> sets TUNINFORGE_SELECTION and returns 0 to proceed / 1 abort.
# Prefers the beautiful Go TUI when a matching binary is present; otherwise uses
# the whiptail flow (fork -> checklist -> summary). Both feed the SAME
# authoritative Bash dependency resolution.
tui_select_services() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    log_error "No TTY for the interactive menu. Use --with or --config instead."
    return 1
  fi

  # 1) Preferred: committed Go (Bubble Tea) selection UI.
  local rc
  tui_select_via_go; rc=$?
  case $rc in
    0) return 0 ;;   # user proceeded; TUNINFORGE_SELECTION populated
    1) return 1 ;;   # user cancelled in the UI
    *) : ;;          # 2 = unavailable/failed -> fall through to whiptail
  esac

  # 2) Fallback: whiptail (preinstalled on Ubuntu; zero bootstrap).
  if ! tui_has_whiptail; then
    log_error "No selection UI available: Go TUI binary missing and whiptail not found."
    log_error "Install whiptail (sudo apt-get install -y whiptail) or use --with a,b,c."
    return 1
  fi

  local mode
  mode="$(tui_choose_mode)" || { log_info "Setup cancelled."; return 1; }

  if [[ "$mode" == "quickstart" ]]; then
    # shellcheck disable=SC2046
    TUNINFORGE_SELECTION="$(tuninforge_install_order $(tuninforge_quickstart_defaults))"
    log_info "QuickStart selected: $TUNINFORGE_SELECTION"
  else
    tui_advanced_checklist || { log_info "Setup cancelled."; return 1; }
    tui_apply_dependencies
  fi

  tui_summary_and_confirm || { log_info "Installation cancelled at review."; return 1; }
  return 0
}
