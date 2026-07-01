#!/usr/bin/env bash
# lib/deps.sh — the single source of truth for the service catalog.
#
# The TUI, summary screen, footprint totals, dependency auto-check, `status`,
# and `add`/`remove` all read from the registry defined here. Nothing else in
# homelab-forge should hard-code a service list.
#
# PORTABILITY: this file intentionally avoids `declare -A` (bash 4+) and uses
# pipe-delimited records + pure functions instead, so the dependency and
# footprint logic runs identically on bash 3.2 (macOS, for local unit tests)
# and bash 5.x (Ubuntu LTS, the real target). The logic here is pure — it never
# touches the system — which is what makes it testable without a VM.

[[ -n "${_FORGE_DEPS_SH:-}" ]] && return 0
_FORGE_DEPS_SH=1

# --- Registry ----------------------------------------------------------------
# One record per service, fields separated by '|':
#   1 name
#   2 layer         access|core|data|ai|automation|observability|backup
#   3 deps          space-separated service names, or '-' for none
#   4 ram_mb        soft RAM estimate (mem_reservation ballpark), MB
#   5 disk_mb       rough on-disk footprint, MB (excludes user data growth)
#   6 watchtower    yes|no  (yes = opt-in to Watchtower auto-updates)
#   7 networks      public|internal|both|none
#   8 desc          one-line description (may note "grows" / "big disk")
#
# RAM/disk are deliberate ESTIMATES for the summary screen, not hard limits
# (limits are soft by design — see the plan). Values err toward the base image
# footprint; stateful services grow with your data.
forge_registry() {
  cat <<'REGISTRY'
tailscale|access|-|30|50|no|none|Mesh VPN; installed first so the box is safely reachable
ssh-hardening|access|-|0|0|no|none|Lockout-safe OpenSSH hardening (config only, no container)
caddy|core|-|64|50|yes|public|Reverse proxy + automatic TLS (Tailscale MagicDNS certs)
portainer|core|-|128|100|yes|public|Docker management web UI
watchtower|core|-|32|50|no|none|Opt-in auto-updater (never touches stateful services)
postgres|data|-|256|500|no|internal|PostgreSQL, multi-database (stateful; grows)
redis|data|-|64|100|no|internal|In-memory cache/queue (stateful)
minio|data|-|512|1024|no|both|S3-compatible object storage (stateful; big disk, grows)
qdrant|data|-|256|500|no|both|Vector database (stateful; grows)
ollama|ai|-|2048|5120|yes|both|Local LLM runtime (models are 4-40GB each; BIG disk)
litellm|ai|-|256|100|yes|both|Gateway to Ollama + OpenAI/Gemini-compatible APIs
n8n|automation|postgres redis|512|300|yes|both|Workflow automation (needs Postgres + Redis)
prometheus|observability|-|512|1024|yes|both|Metrics collection + TSDB (grows)
loki|observability|-|256|1024|yes|internal|Log aggregation (stateful; grows)
alloy|observability|loki|128|100|yes|internal|Ships all container logs to Loki (Grafana Alloy; Promtail successor)
grafana|observability|prometheus loki|256|200|yes|both|Dashboards (needs Prometheus + Loki datasources)
restic|backup|-|64|100|no|none|Encrypted scheduled backups (local + remote repos)
REGISTRY
}

# --- Basic accessors ---------------------------------------------------------
# forge_all_services -> newline list of every service name, in registry order.
forge_all_services() { forge_registry | awk -F'|' 'NF{print $1}'; }

# forge_is_service <name> -> 0 if known, 1 otherwise.
forge_is_service() {
  local n="$1"
  forge_registry | awk -F'|' -v n="$n" 'BEGIN{f=1} $1==n{f=0} END{exit f}'
}

# forge_field <name> <field-index 1..8> -> the field value (empty if unknown).
forge_field() {
  local n="$1" idx="$2"
  forge_registry | awk -F'|' -v n="$n" -v i="$idx" '$1==n{print $i; exit}'
}

# Named field helpers for readability.
forge_layer()      { forge_field "$1" 2; }
forge_deps()       { local d; d="$(forge_field "$1" 3)"; [[ "$d" == "-" ]] && d=""; echo "$d"; }
forge_ram()        { forge_field "$1" 4; }
forge_disk()       { forge_field "$1" 5; }
forge_watchtower() { forge_field "$1" 6; }
forge_networks()   { forge_field "$1" 7; }
forge_desc()       { forge_field "$1" 8; }

# --- Layers ------------------------------------------------------------------
# Ordered so the UI presents Access first (installed first) through Backup last.
forge_layers() { printf '%s\n' access core data ai automation observability backup; }

# Human-friendly layer titles for the checklist headers.
forge_layer_title() {
  case "$1" in
    access)        echo "Access" ;;
    core)          echo "Core" ;;
    data)          echo "Data layer" ;;
    ai)            echo "AI layer" ;;
    automation)    echo "Automation" ;;
    observability) echo "Observability" ;;
    backup)        echo "Backup" ;;
    *)             echo "$1" ;;
  esac
}

# forge_services_in_layer <layer> -> newline list, registry order.
forge_services_in_layer() {
  local layer="$1"
  forge_registry | awk -F'|' -v L="$layer" '$2==L{print $1}'
}

# --- QuickStart defaults -----------------------------------------------------
# Mirrors OpenClaw's QuickStart: sensible core, minimal questions. Core services
# only (Caddy + Portainer). Access + everything else is opt-in.
# forge_quickstart_defaults() { printf '%s\n' caddy portainer; }
forge_quickstart_defaults() { printf '%s\n' caddy portainer; }

# --- JSON serialization for the Go TUI ---------------------------------------
# forge_registry_json -> emit the full catalog as a JSON object the external
# selection TUI consumes on stdin. This keeps lib/deps.sh the SINGLE source of
# truth: the Go TUI is a pure view over this data and never hard-codes services.
#
# Shape:
#   {
#     "layers":   [ {"key":"access","title":"Access"}, ... ],
#     "services": [ {"name","layer","deps":[...],"ram_mb","disk_mb",
#                    "watchtower":bool,"networks","desc","default":bool}, ... ]
#   }
#
# Registry fields contain no double-quotes or backslashes, so escaping reduces
# to a no-op here; awk still routes text through a json-string helper in case
# the catalog gains punctuation later.
forge_registry_json() {
  local defaults; defaults=" $(forge_quickstart_defaults | tr '\n' ' ') "
  {
    # layers array (key + human title), preserving forge_layers order.
    printf '{"layers":['
    local first=1 layer
    while IFS= read -r layer; do
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '{"key":"%s","title":"%s"}' "$layer" "$(forge_layer_title "$layer")"
    done < <(forge_layers)
    printf '],"services":['

    # services array, in registry order.
    forge_registry | awk -F'|' -v defaults="$defaults" '
      function jstr(s,   r) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return "\"" s "\"" }
      NF {
        if (NR>1 && printed) printf ",";
        printed=1
        # deps array
        deps=$3; depsjson="["
        if (deps != "-" && deps != "") {
          n=split(deps, d, /[ \t]+/)
          for (i=1;i<=n;i++) { if(i>1) depsjson=depsjson","; depsjson=depsjson jstr(d[i]) }
        }
        depsjson=depsjson"]"
        wt = ($6=="yes") ? "true" : "false"
        # default-checked if the name is in the quickstart defaults list
        def = (index(defaults, " " $1 " ") > 0) ? "true" : "false"
        printf "{\"name\":%s,\"layer\":%s,\"deps\":%s,\"ram_mb\":%s,\"disk_mb\":%s,\"watchtower\":%s,\"networks\":%s,\"desc\":%s,\"default\":%s}",
          jstr($1), jstr($2), depsjson, ($4+0), ($5+0), wt, jstr($7), jstr($8), def
      }
    '
    printf ']}'
  }
}

# Services pre-checked in the Advanced checklist (same core set).
forge_default_checked() { forge_quickstart_defaults; }

# --- Dependency resolution (pure, testable) ----------------------------------
# forge_resolve_deps <name...> -> the transitive closure (inputs + all deps),
# whitespace-normalized on one line. Order is not guaranteed to be topological;
# use forge_install_order for that. Safe on bash 3.2.
forge_resolve_deps() {
  local queue="$*" seen="" name d
  while [ -n "$queue" ]; do
    # shellcheck disable=SC2086  # intentional word-splitting of the worklist.
    set -- $queue; name="$1"; shift; queue="$*"
    case " $seen " in *" $name "*) continue ;; esac
    forge_is_service "$name" || continue
    seen="$seen $name"
    for d in $(forge_deps "$name"); do
      case " $seen $queue " in *" $d "*) ;; *) queue="$queue $d" ;; esac
    done
  done
  # Trim and echo (echo collapses the leading space + normalizes).
  # shellcheck disable=SC2086
  echo $seen
}

# forge_added_deps <selected...> -> only the deps that were pulled in but NOT
# explicitly selected (for the "auto-checked X because Y needs it" note).
forge_added_deps() {
  local selected="$*" resolved d out=""
  resolved="$(forge_resolve_deps $selected)"
  for d in $resolved; do
    case " $selected " in *" $d "*) ;; *) out="$out $d" ;; esac
  done
  # shellcheck disable=SC2086
  echo $out
}

# forge_dependents_of <name> among <candidates...> -> which candidates depend on
# <name> (used to warn when the user unchecks a needed dependency).
forge_dependents_of() {
  local target="$1"; shift
  local candidates="$*" c out=""
  for c in $candidates; do
    case " $(forge_deps "$c") " in *" $target "*) out="$out $c" ;; esac
  done
  # shellcheck disable=SC2086
  echo $out
}

# forge_install_order <name...> -> the resolved dependency closure, emitted in
# REGISTRY order. The registry is authored as a valid topological order (access
# first; every dependency listed before its dependents), so filtering registry
# order by the closure yields a correct install order independent of the order
# the user selected services in. This also makes access-layer ordering
# deterministic (tailscale before ssh-hardening) even though neither declares a
# dependency on the other.
forge_install_order() {
  local resolved out="" svc
  resolved=" $(forge_resolve_deps "$@") "
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    case "$resolved" in *" $svc "*) out="$out $svc" ;; esac
  done < <(forge_all_services)
  # shellcheck disable=SC2086
  echo $out
}

# --- Footprint math (pure, testable) -----------------------------------------
# forge_sum_field <field-index> <name...> -> integer sum of that field.
forge_sum_field() {
  local idx="$1"; shift
  local total=0 n v
  for n in "$@"; do
    v="$(forge_field "$n" "$idx")"
    [[ "$v" =~ ^[0-9]+$ ]] && total=$((total + v))
  done
  echo "$total"
}
forge_total_ram()  { forge_sum_field 4 "$@"; }
forge_total_disk() { forge_sum_field 5 "$@"; }

# forge_human_mb <mb> -> "512 MB" or "5.0 GB" for display.
forge_human_mb() {
  local mb="$1"
  if [ "$mb" -ge 1024 ]; then
    # One decimal place without bc (bash integer math).
    local gb_whole=$((mb / 1024)) gb_frac=$(((mb % 1024) * 10 / 1024))
    echo "${gb_whole}.${gb_frac} GB"
  else
    echo "${mb} MB"
  fi
}

# forge_is_heavy_disk <name> -> 0 if the service is a big/growing disk consumer
# (>= 1GB base), used to surface a disk warning on a constrained SSD.
forge_is_heavy_disk() {
  local d; d="$(forge_disk "$1")"
  [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 1024 ]
}
