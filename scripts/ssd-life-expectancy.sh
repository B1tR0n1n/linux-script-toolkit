#!/usr/bin/env bash
#
# ssd-life-expectancy.sh — SSD/NVMe wear + life-expectancy reporter
#
# Built for fleet automation (Level.io, Ansible, cron). Reads SMART data from
# every non-removable disk, derives percent-life-remaining, projects an
# end-of-life date, and writes a per-machine report and/or appends to a shared
# master CSV.
#
# Exit codes (Level.io can alert on these):
#   0 = all drives OK
#   1 = at least one drive in WARN
#   2 = at least one drive CRITICAL (or SMART self-assessment FAILED)
#   3 = script error / no usable data
#
# Every option is settable by flag OR environment variable, because Level.io
# script variables are injected as env vars.
#
set -uo pipefail

VERSION="1.1.0"
SCRIPT_NAME="ssd-life-expectancy"

# ---------------------------------------------------------------------------
# Defaults (env var  <-  flag)
# ---------------------------------------------------------------------------
OUTPUT_MODE="${SSD_OUTPUT_MODE:-local}"          # local | master | both | none
LOCAL_DIR="${SSD_LOCAL_DIR:-/var/log/ssd-health}"
LOCAL_NAME="${SSD_LOCAL_NAME:-}"                 # default: <asset_id>_ssd-health.csv
MASTER_PATH="${SSD_MASTER_PATH:-}"               # e.g. /mnt/reports/ssd-life-master.csv
FORMAT="${SSD_FORMAT:-csv}"                      # csv | json | both
APPEND_HISTORY="${SSD_APPEND_HISTORY:-false}"    # local file: append rows vs overwrite
INCLUDE_HDD="${SSD_INCLUDE_HDD:-false}"          # also report spinning rust
AUTO_INSTALL="${SSD_AUTO_INSTALL:-true}"         # install smartmontools if missing
STATE_FILE="${SSD_STATE_FILE:-/var/lib/ssd-life-expectancy/state.csv}"
# NOTE: assigned in two steps on purpose — ${VAR:-default} truncates a default
# containing "}" (bash ends the expansion at the first one), which silently
# mangled this regex and broke asset-id extraction.
HOST_REGEX_DEFAULT='[A-Za-z]{2,6}-[0-9]{2,6}'                   # matches md-4004
HOST_REGEX="${SSD_HOST_REGEX:-}"
[ -n "$HOST_REGEX" ] || HOST_REGEX="$HOST_REGEX_DEFAULT"
HOSTNAME_OVERRIDE="${SSD_HOSTNAME:-}"
DEVICES_OVERRIDE="${SSD_DEVICES:-}"              # space-separated, skip autodetect
EMIT_CSV="${SSD_EMIT_CSV:-false}"                # dump raw CSV rows to stdout
QUIET="${SSD_QUIET:-false}"
LOCK_TIMEOUT="${SSD_LOCK_TIMEOUT:-30}"

WARN_PCT="${SSD_WARN_PCT:-20}"     # life remaining % -> WARN at or below
CRIT_PCT="${SSD_CRIT_PCT:-10}"     # life remaining % -> CRITICAL at or below
WARN_DAYS="${SSD_WARN_DAYS:-180}"  # projected days left -> WARN at or below
CRIT_DAYS="${SSD_CRIT_DAYS:-60}"   # projected days left -> CRITICAL at or below

CSV_HEADER="timestamp,asset_id,hostname,device,protocol,model,serial,firmware,capacity_gb,media_type,smart_status,life_remaining_pct,life_used_pct,life_source,available_spare_pct,power_on_hours,temperature_c,data_written_tb,error_count,wear_pct_per_year,est_days_remaining,est_eol_date,est_method,status"

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION — SSD/NVMe life-expectancy reporter

Usage: $0 [options]

Output
  --output-mode MODE     local | master | both | none      (env SSD_OUTPUT_MODE) [$OUTPUT_MODE]
  --local-dir DIR        per-machine report directory      (env SSD_LOCAL_DIR)  [$LOCAL_DIR]
  --local-name NAME      per-machine filename              (env SSD_LOCAL_NAME) [<asset_id>_ssd-health.csv]
  --master-path FILE     shared master CSV to append to    (env SSD_MASTER_PATH)
  --format FMT           csv | json | both                 (env SSD_FORMAT)     [$FORMAT]
  --append-history       append to local file instead of overwriting
  --emit-csv             print raw CSV rows to stdout (handy for Level.io output capture)
  --quiet                suppress the human-readable summary

Selection
  --include-hdd          include spinning disks (default: SSD/NVMe only)
  --devices "a b"        explicit device list, skips autodetection (env SSD_DEVICES)
  --hostname NAME        override detected hostname        (env SSD_HOSTNAME)
  --host-regex RE        asset-id extraction regex         (env SSD_HOST_REGEX) [$HOST_REGEX]

Thresholds
  --warn-pct N           WARN at/below N% life remaining   [$WARN_PCT]
  --crit-pct N           CRITICAL at/below N% life left    [$CRIT_PCT]
  --warn-days N          WARN at/below N projected days    [$WARN_DAYS]
  --crit-days N          CRITICAL at/below N days          [$CRIT_DAYS]

Misc
  --no-auto-install      do not attempt to install smartmontools
  --state-file FILE      wear-rate history file            [$STATE_FILE]
  --version, --help

Exit codes: 0 OK | 1 WARN | 2 CRITICAL | 3 error
USAGE
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --output-mode)     OUTPUT_MODE="${2:-}"; shift 2 ;;
    --local-dir)       LOCAL_DIR="${2:-}"; shift 2 ;;
    --local-name)      LOCAL_NAME="${2:-}"; shift 2 ;;
    --master-path)     MASTER_PATH="${2:-}"; shift 2 ;;
    --format)          FORMAT="${2:-}"; shift 2 ;;
    --append-history)  APPEND_HISTORY=true; shift ;;
    --emit-csv)        EMIT_CSV=true; shift ;;
    --quiet)           QUIET=true; shift ;;
    --include-hdd)     INCLUDE_HDD=true; shift ;;
    --devices)         DEVICES_OVERRIDE="${2:-}"; shift 2 ;;
    --hostname)        HOSTNAME_OVERRIDE="${2:-}"; shift 2 ;;
    --host-regex)      HOST_REGEX="${2:-}"; shift 2 ;;
    --warn-pct)        WARN_PCT="${2:-}"; shift 2 ;;
    --crit-pct)        CRIT_PCT="${2:-}"; shift 2 ;;
    --warn-days)       WARN_DAYS="${2:-}"; shift 2 ;;
    --crit-days)       CRIT_DAYS="${2:-}"; shift 2 ;;
    --no-auto-install) AUTO_INSTALL=false; shift ;;
    --state-file)      STATE_FILE="${2:-}"; shift 2 ;;
    --version)         echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
  esac
done

say()  { [ "$QUIET" = "true" ] || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  warn "ERROR: must run as root (SMART access requires it). Level.io runs scripts as root by default."
  exit 3
fi

# Detect the host's package manager so we can name it in errors.
detect_pkg_mgr() {
  for m in apt-get dnf yum zypper pacman apk emerge; do
    command -v "$m" >/dev/null 2>&1 && { echo "$m"; return 0; }
  done
  echo "none"
}

# Install smartmontools. Captures output so a failure is reportable, not silent.
install_smartmontools() {
  local mgr log rc=1
  mgr="$(detect_pkg_mgr)"
  log="$(mktemp 2>/dev/null || echo /tmp/ssd-dep-install.$$)"

  say "Dependency 'smartctl' missing — installing smartmontools via ${mgr}..."
  case "$mgr" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >"$log" 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq smartmontools >>"$log" 2>&1; rc=$? ;;
    dnf)    dnf install -y -q smartmontools >"$log" 2>&1; rc=$? ;;
    yum)    yum install -y -q smartmontools >"$log" 2>&1; rc=$? ;;
    zypper) zypper --non-interactive --quiet install smartmontools >"$log" 2>&1; rc=$? ;;
    pacman) pacman -Sy --noconfirm smartmontools >"$log" 2>&1; rc=$? ;;
    apk)    apk add --quiet smartmontools >"$log" 2>&1; rc=$? ;;
    emerge) emerge --quiet sys-apps/smartmontools >"$log" 2>&1; rc=$? ;;
    none)
      warn "ERROR: no supported package manager found (tried apt-get, dnf, yum, zypper, pacman, apk, emerge)."
      rm -f "$log"; return 1 ;;
  esac

  # Some managers exit 0 while still failing to place the binary, so verify.
  if command -v smartctl >/dev/null 2>&1; then
    say "Installed smartmontools ($(smartctl --version 2>/dev/null | head -1))"
    rm -f "$log"; return 0
  fi

  warn "ERROR: '$mgr' failed to install smartmontools (exit $rc). Last output:"
  [ -f "$log" ] && tail -10 "$log" | while IFS= read -r l; do warn "  | $l"; done
  rm -f "$log"
  return 1
}

# --- dependency check ------------------------------------------------------
# Hard requirement: smartctl. Everything else has a built-in fallback.
if ! command -v smartctl >/dev/null 2>&1; then
  if [ "$AUTO_INSTALL" != "true" ]; then
    warn "ERROR: smartctl is not installed and auto-install is disabled (--no-auto-install)."
    warn "       Install it with: $(detect_pkg_mgr) install smartmontools"
    exit 3
  fi
  if ! install_smartmontools; then
    warn "       Install smartmontools manually, then re-run."
    exit 3
  fi
fi

# Soft dependencies — note them, but keep going (fallbacks exist).
command -v lsblk >/dev/null 2>&1 || warn "NOTE: lsblk missing; falling back to 'smartctl --scan' for device discovery."
command -v flock >/dev/null 2>&1 || warn "NOTE: flock missing; using mkdir-based locking for master-file writes."

# NVMe drives need the nvme module loaded to answer SMART queries.
if ls /dev/nvme* >/dev/null 2>&1 || [ -d /sys/class/nvme ]; then
  lsmod 2>/dev/null | grep -q '^nvme' || modprobe nvme >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
HOST="${HOSTNAME_OVERRIDE:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)}"
HOST="${HOST:-unknown-host}"

# Pull the asset tag out of the hostname (md-4004 from md-4004.corp.local etc).
ASSET_ID="$(printf '%s' "$HOST" | grep -oE "$HOST_REGEX" | head -1)"
[ -n "$ASSET_ID" ] || ASSET_ID="$HOST"

NOW_EPOCH="$(date -u +%s)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Strip characters that would break a plain CSV; collapse whitespace.
clean() {
  printf '%s' "${1:-}" | tr -d '",\r\n' | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//'
}

json_escape() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# First numeric token of a string, commas stripped: "1,234 h" -> 1234
num() {
  printf '%s' "${1:-}" | tr -d ',' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
}

is_num() { case "${1:-}" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }

# Value of a "Key: value" line in smartctl output.
sm_field() {
  printf '%s\n' "$SMART" | grep -m1 -iE "^[[:space:]]*$1:" | sed -E 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# Just the ATA attribute table rows.
attr_table() {
  printf '%s\n' "$SMART" | awk '
    /^ID#[[:space:]]+ATTRIBUTE_NAME/ { f=1; next }
    f && /^[[:space:]]*$/            { f=0 }
    f                                 { print }'
}

# Normalized VALUE column (col 4) for an ATA attribute id.
attr_norm() { printf '%s\n' "$ATTRS" | awk -v id="$1" '$1==id && NF>=8 {print $4+0; exit}'; }
# RAW_VALUE column (last field) for an ATA attribute id.
attr_raw()  { printf '%s\n' "$ATTRS" | awk -v id="$1" '$1==id && NF>=8 {print $NF; exit}'; }

# Fetch SMART data, trying device-type fallbacks for USB bridges / controllers.
read_smart() {
  local dev="$1" out=""
  for dtype in "" "-d sat" "-d nvme" "-d scsi" "-d auto"; do
    # shellcheck disable=SC2086
    out="$(smartctl -a $dtype "$dev" 2>/dev/null)"
    if printf '%s' "$out" | grep -qiE 'Serial Number|Device Model|Model Number|SMART overall-health|SMART Health Status|Percentage Used'; then
      printf '%s' "$out"
      return 0
    fi
  done
  # Nothing usable — return empty so the caller records a clean "unsupported".
  return 1
}

# ---------------------------------------------------------------------------
# Device discovery
# ---------------------------------------------------------------------------
discover_devices() {
  if [ -n "$DEVICES_OVERRIDE" ]; then
    printf '%s\n' $DEVICES_OVERRIDE
    return
  fi
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -dpno NAME,TYPE,RM 2>/dev/null | awk '$2=="disk" && $3=="0" {print $1}' \
      | grep -vE '/dev/(loop|ram|zram|sr|fd|dm-|md)' 
  else
    smartctl --scan 2>/dev/null | awk '{print $1}'
  fi
}

is_rotational() {
  local dev="$1" base
  base="$(basename "$dev")"
  if [ -r "/sys/block/$base/queue/rotational" ]; then
    cat "/sys/block/$base/queue/rotational"
  else
    echo "unknown"
  fi
}

# ---------------------------------------------------------------------------
# Wear-rate state (gives a calendar-accurate projection after the 2nd run)
# state.csv: serial,baseline_epoch,baseline_used_pct,last_epoch,last_used_pct
# ---------------------------------------------------------------------------
state_get() { [ -f "$STATE_FILE" ] && awk -F, -v s="$1" '$1==s {print; exit}' "$STATE_FILE"; }

state_put() {
  local serial="$1" b_epoch="$2" b_used="$3" l_epoch="$4" l_used="$5" tmp
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  tmp="${STATE_FILE}.$$"
  { [ -f "$STATE_FILE" ] && awk -F, -v s="$serial" '$1!=s' "$STATE_FILE"; \
    printf '%s,%s,%s,%s,%s\n' "$serial" "$b_epoch" "$b_used" "$l_epoch" "$l_used"; } > "$tmp" 2>/dev/null
  mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Locked write to the shared master file (safe with N machines at once)
# ---------------------------------------------------------------------------
master_write() {
  local row="$1" serial="$2" dev="$3" dir lock
  dir="$(dirname "$MASTER_PATH")"
  mkdir -p "$dir" 2>/dev/null || { warn "WARN: cannot create master dir $dir"; return 1; }
  lock="${MASTER_PATH}.lock"

  _do_write() {
    [ -f "$MASTER_PATH" ] || printf '%s\n' "$CSV_HEADER" > "$MASTER_PATH"
    # Replace this machine+drive's previous row so the master stays one-row-per-drive.
    local tmp="${MASTER_PATH}.tmp.$$"
    awk -F, -v h="$ASSET_ID" -v s="$serial" -v d="$dev" \
        'NR==1 || !($2==h && $7==s && $4==d)' "$MASTER_PATH" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$MASTER_PATH" 2>/dev/null || rm -f "$tmp"
    printf '%s\n' "$row" >> "$MASTER_PATH"
  }

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock" 2>/dev/null || { warn "WARN: cannot open lock $lock"; return 1; }
    if flock -w "$LOCK_TIMEOUT" 9; then _do_write; flock -u 9; exec 9>&-; return 0
    else warn "WARN: timed out waiting for master file lock"; exec 9>&-; return 1; fi
  else
    # flock-less fallback (some minimal images / NFS): mkdir is atomic.
    local waited=0
    while ! mkdir "${lock}.d" 2>/dev/null; do
      waited=$((waited+1)); [ "$waited" -ge "$LOCK_TIMEOUT" ] && { warn "WARN: lock timeout"; return 1; }
      sleep 1
    done
    _do_write
    rmdir "${lock}.d" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Main scan
# ---------------------------------------------------------------------------
ROWS=()
JSON_ITEMS=()
SUMMARY_LINES=()
SKIPPED=()
WORST=0          # 0 ok, 1 warn, 2 critical
FOUND=0

for DEV in $(discover_devices); do
  # Autodetected devices must be real nodes; an explicit --devices list is
  # trusted as-is so odd paths (controller pass-through, /dev/bsg/...) work.
  if [ -z "$DEVICES_OVERRIDE" ] && [ ! -b "$DEV" ] && [ ! -c "$DEV" ]; then
    continue
  fi

  if ! SMART="$(read_smart "$DEV")" || [ -z "$SMART" ]; then
    SKIPPED+=("$DEV: SMART unavailable (virtual disk, or a controller needing an explicit -d type)")
    continue
  fi

  ATTRS="$(attr_table)"

  # --- protocol / media type -------------------------------------------------
  PROTOCOL="ata"
  case "$DEV" in */nvme*) PROTOCOL="nvme" ;; esac
  printf '%s' "$SMART" | grep -qi 'NVMe Version\|Number of Namespaces' && PROTOCOL="nvme"

  ROT="$(is_rotational "$DEV")"
  MEDIA="SSD"
  if [ "$PROTOCOL" = "nvme" ]; then
    MEDIA="NVMe"
  elif printf '%s' "$SMART" | grep -qi 'Rotation Rate:.*Solid State'; then
    MEDIA="SSD"
  elif printf '%s' "$SMART" | grep -qiE 'Rotation Rate:[[:space:]]*[0-9]+ rpm'; then
    MEDIA="HDD"
  elif [ "$ROT" = "1" ]; then
    MEDIA="HDD"
  fi
  if [ "$MEDIA" = "HDD" ] && [ "$INCLUDE_HDD" != "true" ]; then
    SKIPPED+=("$DEV: rotational disk (use --include-hdd to report it)")
    continue
  fi

  FOUND=$((FOUND+1))

  # --- identity --------------------------------------------------------------
  MODEL="$(sm_field 'Device Model')";      [ -n "$MODEL" ] || MODEL="$(sm_field 'Model Number')"
  [ -n "$MODEL" ] || MODEL="$(sm_field 'Product')"
  [ -n "$MODEL" ] || MODEL="$(sm_field 'Model Family')"
  SERIAL="$(sm_field 'Serial Number')";    [ -n "$SERIAL" ] || SERIAL="unknown-$(basename "$DEV")"
  FIRMWARE="$(sm_field 'Firmware Version')"
  [ -n "$FIRMWARE" ] || FIRMWARE="$(sm_field 'Revision')"

  CAP_RAW="$(sm_field 'User Capacity')"
  [ -n "$CAP_RAW" ] || CAP_RAW="$(sm_field 'Total NVM Capacity')"
  [ -n "$CAP_RAW" ] || CAP_RAW="$(sm_field 'Namespace 1 Size/Capacity')"
  CAP_BYTES="$(printf '%s' "$CAP_RAW" | tr -d ',' | grep -oE '[0-9]{6,}' | head -1)"
  if is_num "${CAP_BYTES:-}"; then
    CAPACITY_GB="$(awk -v b="$CAP_BYTES" 'BEGIN{printf "%.1f", b/1000000000}')"
  else
    CAPACITY_GB=""
  fi

  # --- SMART overall health --------------------------------------------------
  SMART_STATUS="$(printf '%s\n' "$SMART" | grep -m1 -iE 'SMART overall-health self-assessment test result|SMART Health Status' | sed -E 's/^.*:[[:space:]]*//')"
  SMART_STATUS="$(clean "$SMART_STATUS")"
  [ -n "$SMART_STATUS" ] || SMART_STATUS="UNKNOWN"

  # --- life remaining --------------------------------------------------------
  LIFE_REMAIN=""; LIFE_USED=""; LIFE_SOURCE=""; SPARE=""; SPARE_THRESH=""

  if [ "$PROTOCOL" = "nvme" ]; then
    PU="$(num "$(sm_field 'Percentage Used')")"
    if is_num "${PU:-}"; then
      LIFE_USED="$PU"
      LIFE_REMAIN="$(awk -v u="$PU" 'BEGIN{r=100-u; if(r<0)r=0; printf "%.0f", r}')"
      LIFE_SOURCE="nvme:percentage_used"
    fi
    SPARE="$(num "$(sm_field 'Available Spare')")"
    SPARE_THRESH="$(num "$(sm_field 'Available Spare Threshold')")"
  else
    # ATA/SATA SSDs: vendors disagree, so try the known life attributes in order.
    # For these IDs the NORMALIZED value is percent-of-life-remaining.
    for pair in "231:SSD_Life_Left" "233:Media_Wearout_Indicator" "202:Percent_Lifetime_Remain" \
                "177:Wear_Leveling_Count" "173:Ave_Block_Erase_Count" "169:Remaining_Life"; do
      aid="${pair%%:*}"; aname="${pair##*:}"
      v="$(attr_norm "$aid")"
      if is_num "${v:-}" && [ "${v:-0}" -gt 0 ] 2>/dev/null && [ "${v:-0}" -le 100 ] 2>/dev/null; then
        LIFE_REMAIN="$v"
        LIFE_USED="$((100 - v))"
        LIFE_SOURCE="ata:${aid}_${aname}"
        break
      fi
    done
    # Crucial/Micron style: 202 raw holds percent USED, not remaining.
    if [ -z "$LIFE_REMAIN" ]; then
      v="$(num "$(attr_raw 202)")"
      if is_num "${v:-}" && [ "${v:-101}" -le 100 ] 2>/dev/null; then
        LIFE_USED="$v"; LIFE_REMAIN="$((100 - v))"; LIFE_SOURCE="ata:202_raw_used"
      fi
    fi
  fi

  # --- wear/usage counters ---------------------------------------------------
  if [ "$PROTOCOL" = "nvme" ]; then
    POH="$(num "$(sm_field 'Power On Hours')")"
    TEMP="$(num "$(sm_field 'Temperature')")"
    DUW="$(printf '%s\n' "$SMART" | grep -m1 -i 'Data Units Written' | sed -E 's/.*\[([^]]*)\].*/\1/')"
    if printf '%s' "$DUW" | grep -qi 'TB'; then
      WRITTEN_TB="$(num "$DUW")"
    elif printf '%s' "$DUW" | grep -qi 'GB'; then
      WRITTEN_TB="$(awk -v g="$(num "$DUW")" 'BEGIN{printf "%.2f", g/1000}')"
    else
      DU="$(num "$(sm_field 'Data Units Written')")"
      if is_num "${DU:-}"; then WRITTEN_TB="$(awk -v d="$DU" 'BEGIN{printf "%.2f", d*512000/1000000000000}')"; else WRITTEN_TB=""; fi
    fi
    ERRORS="$(num "$(sm_field 'Media and Data Integrity Errors')")"
  else
    POH="$(num "$(attr_raw 9)")"
    [ -n "${POH:-}" ] || POH="$(num "$(sm_field 'Accumulated power on time, hours:minutes')")"
    TEMP="$(num "$(attr_raw 194)")"
    [ -n "${TEMP:-}" ] || TEMP="$(num "$(sm_field 'Current Drive Temperature')")"
    LBAW="$(num "$(attr_raw 241)")"
    [ -n "${LBAW:-}" ] || LBAW="$(num "$(attr_raw 246)")"
    if is_num "${LBAW:-}"; then
      WRITTEN_TB="$(awk -v l="$LBAW" 'BEGIN{printf "%.2f", l*512/1000000000000}')"
    else WRITTEN_TB=""; fi
    e5="$(num "$(attr_raw 5)")";   e187="$(num "$(attr_raw 187)")"; e197="$(num "$(attr_raw 197)")"
    ERRORS="$(( ${e5:-0} + ${e187:-0} + ${e197:-0} ))"
  fi

  # --- projection ------------------------------------------------------------
  EST_DAYS=""; EST_METHOD="none"; WEAR_YR=""
  if is_num "${LIFE_USED:-}" && is_num "${LIFE_REMAIN:-}"; then
    # 1) Preferred: measured calendar wear rate from our own history file.
    ST="$(state_get "$SERIAL")"
    B_EPOCH=""; B_USED=""
    if [ -n "$ST" ]; then
      B_EPOCH="$(printf '%s' "$ST" | cut -d, -f2)"
      B_USED="$(printf '%s' "$ST" | cut -d, -f3)"
    fi
    if is_num "${B_EPOCH:-}" && is_num "${B_USED:-}" \
       && [ "$(awk -v a="$LIFE_USED" -v b="$B_USED" 'BEGIN{print (a>b)?1:0}')" = "1" ] \
       && [ "$((NOW_EPOCH - B_EPOCH))" -ge 604800 ]; then
      read -r WEAR_YR EST_DAYS <<EOF2
$(awk -v used="$LIFE_USED" -v bused="$B_USED" -v now="$NOW_EPOCH" -v bep="$B_EPOCH" -v rem="$LIFE_REMAIN" \
  'BEGIN{ days=(now-bep)/86400; rate=(used-bused)/days; printf "%.2f %.0f", rate*365, (rate>0 ? rem/rate : 0) }')
EOF2
      EST_METHOD="calendar"
    fi
    # 2) Fallback: extrapolate from power-on hours (conservative — assumes 24/7).
    if [ -z "${EST_DAYS:-}" ] || [ "${EST_DAYS:-0}" = "0" ]; then
      if is_num "${POH:-}" && [ "${POH:-0}" -gt 0 ] 2>/dev/null \
         && [ "$(awk -v u="$LIFE_USED" 'BEGIN{print (u>0)?1:0}')" = "1" ]; then
        read -r WEAR_YR EST_DAYS <<EOF3
$(awk -v poh="$POH" -v used="$LIFE_USED" -v rem="$LIFE_REMAIN" \
  'BEGIN{ hpp=poh/used; rh=hpp*rem; printf "%.2f %.0f", used/(poh/8760), rh/24 }')
EOF3
        EST_METHOD="power_on_hours"
      elif [ "${LIFE_USED:-0}" = "0" ]; then
        EST_DAYS="7300"; EST_METHOD="no_measurable_wear"; WEAR_YR="0.00"
      fi
    fi
    # Track wear for the next run.
    if [ -n "$ST" ] && is_num "${B_EPOCH:-}" && is_num "${B_USED:-}" \
       && [ "$(awk -v a="$LIFE_USED" -v b="$B_USED" 'BEGIN{print (a>=b)?1:0}')" = "1" ]; then
      state_put "$SERIAL" "$B_EPOCH" "$B_USED" "$NOW_EPOCH" "$LIFE_USED"
    else
      state_put "$SERIAL" "$NOW_EPOCH" "$LIFE_USED" "$NOW_EPOCH" "$LIFE_USED"
    fi
  fi

  # Clamp silly projections (a 300-year estimate helps nobody).
  if is_num "${EST_DAYS:-}"; then
    [ "$EST_DAYS" -gt 7300 ] 2>/dev/null && EST_DAYS=7300
    EST_EOL="$(date -u -d "+${EST_DAYS} days" +%Y-%m-%d 2>/dev/null || echo "")"
  else
    EST_DAYS=""; EST_EOL=""
  fi

  # --- status ----------------------------------------------------------------
  STATUS="OK"; REASON=""
  if [ -z "${LIFE_REMAIN:-}" ]; then
    STATUS="UNKNOWN"; REASON="no life attribute exposed"
  fi
  if is_num "${LIFE_REMAIN:-}"; then
    if [ "$LIFE_REMAIN" -le "$WARN_PCT" ]; then STATUS="WARN"; REASON="${LIFE_REMAIN}% life left"; fi
    if [ "$LIFE_REMAIN" -le "$CRIT_PCT" ]; then STATUS="CRITICAL"; REASON="${LIFE_REMAIN}% life left"; fi
  fi
  if is_num "${EST_DAYS:-}"; then
    if [ "$EST_DAYS" -le "$WARN_DAYS" ] && [ "$STATUS" = "OK" ]; then STATUS="WARN"; REASON="~${EST_DAYS}d projected"; fi
    if [ "$EST_DAYS" -le "$CRIT_DAYS" ]; then STATUS="CRITICAL"; REASON="~${EST_DAYS}d projected"; fi
  fi
  if is_num "${SPARE:-}" && is_num "${SPARE_THRESH:-}" && [ "$SPARE" -le "$SPARE_THRESH" ]; then
    STATUS="CRITICAL"; REASON="spare ${SPARE}% <= threshold ${SPARE_THRESH}%"
  fi
  case "$SMART_STATUS" in
    *FAILED*|*failed*) STATUS="CRITICAL"; REASON="SMART self-assessment FAILED" ;;
  esac

  case "$STATUS" in
    CRITICAL) [ "$WORST" -lt 2 ] && WORST=2 ;;
    WARN)     [ "$WORST" -lt 1 ] && WORST=1 ;;
  esac

  # --- emit ------------------------------------------------------------------
  ROW="$NOW_ISO,$(clean "$ASSET_ID"),$(clean "$HOST"),$(clean "$DEV"),$PROTOCOL,$(clean "$MODEL"),$(clean "$SERIAL"),$(clean "$FIRMWARE"),${CAPACITY_GB},$MEDIA,$(clean "$SMART_STATUS"),${LIFE_REMAIN},${LIFE_USED},${LIFE_SOURCE},${SPARE},${POH},${TEMP},${WRITTEN_TB},${ERRORS},${WEAR_YR},${EST_DAYS},${EST_EOL},${EST_METHOD},$STATUS"
  ROWS+=("$ROW")

  JSON_ITEMS+=("$(cat <<JSON
    {
      "device": "$(json_escape "$DEV")",
      "protocol": "$PROTOCOL",
      "media_type": "$MEDIA",
      "model": "$(json_escape "$MODEL")",
      "serial": "$(json_escape "$SERIAL")",
      "firmware": "$(json_escape "$FIRMWARE")",
      "capacity_gb": ${CAPACITY_GB:-null},
      "smart_status": "$(json_escape "$SMART_STATUS")",
      "life_remaining_pct": ${LIFE_REMAIN:-null},
      "life_used_pct": ${LIFE_USED:-null},
      "life_source": "$(json_escape "$LIFE_SOURCE")",
      "available_spare_pct": ${SPARE:-null},
      "power_on_hours": ${POH:-null},
      "temperature_c": ${TEMP:-null},
      "data_written_tb": ${WRITTEN_TB:-null},
      "error_count": ${ERRORS:-null},
      "wear_pct_per_year": ${WEAR_YR:-null},
      "est_days_remaining": ${EST_DAYS:-null},
      "est_eol_date": "$(json_escape "$EST_EOL")",
      "est_method": "$EST_METHOD",
      "status": "$STATUS"
    }
JSON
)")

  SUMMARY_LINES+=("$(printf '%-12s %-6s %-24.24s %-18.18s %5s%%  %8s  %-10s %s' \
    "$(basename "$DEV")" "$MEDIA" "${MODEL:-unknown}" "${SERIAL:-unknown}" \
    "${LIFE_REMAIN:-n/a}" "${EST_DAYS:-n/a}d" "${EST_EOL:-n/a}" "$STATUS${REASON:+ ($REASON)}")")
done

# ---------------------------------------------------------------------------
# No drives?
# ---------------------------------------------------------------------------
if [ "$FOUND" -eq 0 ]; then
  warn "ERROR: no SSD/NVMe devices reported on $ASSET_ID ($HOST)."
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    warn "Devices examined and skipped:"
    for s in "${SKIPPED[@]}"; do warn "  - $s"; done
  else
    warn "No block devices were detected at all."
  fi
  warn "Hint: --include-hdd widens the scan; --devices \"/dev/sda\" forces a specific disk."
  exit 3
fi

# ---------------------------------------------------------------------------
# Human-readable summary (this is what shows up in the Level.io run output)
# ---------------------------------------------------------------------------
say "SSD Life Expectancy — $ASSET_ID ($HOST) — $NOW_ISO"
say "$(printf '%-12s %-6s %-24s %-18s %6s  %8s  %-10s %s' DEVICE TYPE MODEL SERIAL LIFE EST_LEFT EOL_DATE STATUS)"
say "------------------------------------------------------------------------------------------------------------"
for l in "${SUMMARY_LINES[@]}"; do say "$l"; done
if [ "${#SKIPPED[@]}" -gt 0 ] && [ "$QUIET" != "true" ]; then
  say ""
  say "Skipped:"
  for s in "${SKIPPED[@]}"; do say "  - $s"; done
fi
say ""
case "$WORST" in
  0) say "RESULT: OK — all drives healthy ($FOUND scanned)" ;;
  1) say "RESULT: WARN — at least one drive is wearing out ($FOUND scanned)" ;;
  2) say "RESULT: CRITICAL — replace drive(s) ($FOUND scanned)" ;;
esac

# ---------------------------------------------------------------------------
# Build JSON document
# ---------------------------------------------------------------------------
build_json() {
  local items="" i
  for i in "${JSON_ITEMS[@]}"; do
    [ -n "$items" ] && items="${items},"$'\n'
    items="${items}${i}"
  done
  cat <<JSONDOC
{
  "schema": "$SCRIPT_NAME/$VERSION",
  "timestamp": "$NOW_ISO",
  "asset_id": "$(json_escape "$ASSET_ID")",
  "hostname": "$(json_escape "$HOST")",
  "overall_status": "$(case $WORST in 0) echo OK;; 1) echo WARN;; 2) echo CRITICAL;; esac)",
  "drives_scanned": $FOUND,
  "drives": [
$items
  ]
}
JSONDOC
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
write_local() {
  mkdir -p "$LOCAL_DIR" 2>/dev/null || { warn "WARN: cannot create $LOCAL_DIR"; return 1; }
  local base="${LOCAL_NAME:-${ASSET_ID}_ssd-health}"
  base="${base%.csv}"; base="${base%.json}"

  if [ "$FORMAT" = "csv" ] || [ "$FORMAT" = "both" ]; then
    local f="$LOCAL_DIR/${base}.csv"
    if [ "$APPEND_HISTORY" = "true" ]; then
      [ -f "$f" ] || printf '%s\n' "$CSV_HEADER" > "$f"
    else
      printf '%s\n' "$CSV_HEADER" > "$f"
    fi
    printf '%s\n' "${ROWS[@]}" >> "$f"
    say "Wrote $f"
  fi
  if [ "$FORMAT" = "json" ] || [ "$FORMAT" = "both" ]; then
    local j="$LOCAL_DIR/${base}.json"
    build_json > "$j"
    say "Wrote $j"
  fi
}

write_master() {
  if [ -z "$MASTER_PATH" ]; then
    warn "WARN: output mode includes 'master' but --master-path/SSD_MASTER_PATH is unset. Skipping."
    return 1
  fi
  local ok=0
  for r in "${ROWS[@]}"; do
    local ser dev
    ser="$(printf '%s' "$r" | cut -d, -f7)"
    dev="$(printf '%s' "$r" | cut -d, -f4)"
    master_write "$r" "$ser" "$dev" && ok=$((ok+1))
  done
  [ "$ok" -gt 0 ] && say "Appended $ok row(s) to $MASTER_PATH"
}

case "$OUTPUT_MODE" in
  local)  write_local ;;
  master) write_master ;;
  both)   write_local; write_master ;;
  none)   : ;;
  *)      warn "WARN: unknown --output-mode '$OUTPUT_MODE'; defaulting to local"; write_local ;;
esac

if [ "$EMIT_CSV" = "true" ]; then
  printf '%s\n' "$CSV_HEADER"
  printf '%s\n' "${ROWS[@]}"
fi

exit "$WORST"
