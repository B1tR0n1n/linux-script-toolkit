#!/usr/bin/env bash
#
# install-ssd-monitor.sh — one-paste SSD life-expectancy monitoring.
#
#   GENERATED FILE — do not edit. Edit scripts/ssd-life-expectancy.sh and run
#   tools/build-installer.sh to regenerate.
#
# Paste this whole file into a Level.io script (or a root shell) and it will:
#   1. install smartmontools if missing
#   2. install the reporter to /usr/local/sbin
#   3. schedule it weekly (systemd timer, or cron as a fallback)
#   4. run it once now and print the results
#
# Everything is configurable by editing the CONFIG block below, or by setting
# the same names as environment variables (Level.io script variables work).
#
set -uo pipefail

# ===========================================================================
# CONFIG — edit these, or set them as Level.io script variables
# ===========================================================================
# --- FLEET MASTER FILE ---------------------------------------------------
# Set SSD_MASTER_PATH to a path every machine can write to (an NFS/CIFS mount,
# or any shared directory) and every machine appends to that one file. Writes
# are locked, so running this on 50 machines at once is safe: each machine
# REPLACES its own row rather than appending duplicates, so the file stays one
# row per drive per machine no matter how often it runs.
# Leave it empty for per-machine files only.
: "${SSD_MASTER_PATH:=}"               # e.g. /mnt/reports/ssd-life-master.csv

# Output mode is inferred: "both" when a master path is set, else "local".
# Override explicitly if you want master-only (no local copy).
if [ -n "${SSD_MASTER_PATH:-}" ]; then
  : "${SSD_OUTPUT_MODE:=both}"
else
  : "${SSD_OUTPUT_MODE:=local}"
fi
: "${SSD_LOCAL_DIR:=/var/log/ssd-health}"
: "${SSD_FORMAT:=both}"                # csv | json | both
: "${SSD_SCHEDULE:=weekly}"            # weekly | daily | none
: "${SSD_SCHEDULE_TIME:=03:17}"        # HH:MM, local time
: "${SSD_RUN_NOW:=true}"               # run once immediately after install
# Set true if your RMM marks the action FAILED on any non-zero exit code.
# The drive status still appears in the output and CSV; it just is not
# signalled through the exit code.
: "${SSD_ALWAYS_EXIT_OK:=false}"
: "${SSD_INSTALL_PATH:=/usr/local/sbin/ssd-life-expectancy.sh}"
: "${SSD_CONF_PATH:=/etc/ssd-life-expectancy.conf}"
# Thresholds (see the reporter's --help for the full list)
: "${SSD_WARN_PCT:=20}"
: "${SSD_CRIT_PCT:=10}"
: "${SSD_WARN_DAYS:=180}"
: "${SSD_CRIT_DAYS:=60}"
# ===========================================================================

say() { printf '%s\n' "$*"; }
# Shell-quote a value for safe interpolation into a command line.
shq() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 3; }

[ "$(id -u)" -eq 0 ] || die "must run as root (Level.io runs scripts as root by default)"

# --- 1. install the reporter ------------------------------------------------
say "==> install-ssd-monitor build 1.5.0"
say "==> Installing reporter to $SSD_INSTALL_PATH"
mkdir -p "$(dirname "$SSD_INSTALL_PATH")" || die "cannot create $(dirname "$SSD_INSTALL_PATH")"

cat > "$SSD_INSTALL_PATH" <<'SSD_REPORTER_PAYLOAD_EOF'
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

VERSION="1.5.0"
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
HOST_REGEX_DEFAULT='[A-Za-z]{2,6}-?[0-9]{2,6}'                  # matches md-4004 AND md4065
HOST_REGEX="${SSD_HOST_REGEX:-}"
[ -n "$HOST_REGEX" ] || HOST_REGEX="$HOST_REGEX_DEFAULT"
HOSTNAME_OVERRIDE="${SSD_HOSTNAME:-}"
DEVICES_OVERRIDE="${SSD_DEVICES:-}"              # space-separated, skip autodetect
EMIT_CSV="${SSD_EMIT_CSV:-false}"                # dump raw CSV rows to stdout
QUIET="${SSD_QUIET:-false}"
# Always exit 0, whatever the drives say. For RMMs (Level.io included) that
# treat any non-zero exit as a failed action and halt the pipeline: the drive
# status still appears in the output and the CSV, it just stops being signalled
# through the exit code. Alert on the RESULT line instead.
ALWAYS_EXIT_OK="${SSD_ALWAYS_EXIT_OK:-false}"
DEBUG="${SSD_DEBUG:-false}"                      # dump raw smartctl output
ENABLE_SMART="${SSD_ENABLE_SMART:-true}"         # turn SMART on if the drive has it disabled
UNKNOWN_IS_WARN="${SSD_UNKNOWN_IS_WARN:-true}"   # unreadable drive => WARN, not "healthy"
LOCK_TIMEOUT="${SSD_LOCK_TIMEOUT:-30}"
STALE_LOCK_SECS="${SSD_STALE_LOCK_SECS:-300}"    # break a lock left by a killed run
LOCK_STRATEGY="${SSD_LOCK_STRATEGY:-auto}"       # auto | flock | mkdir

WARN_PCT="${SSD_WARN_PCT:-20}"     # life remaining % -> WARN at or below
CRIT_PCT="${SSD_CRIT_PCT:-10}"     # life remaining % -> CRITICAL at or below
WARN_DAYS="${SSD_WARN_DAYS:-180}"  # projected days left -> WARN at or below
CRIT_DAYS="${SSD_CRIT_DAYS:-60}"   # projected days left -> CRITICAL at or below

CSV_HEADER="timestamp,asset_id,hostname,device,protocol,model,serial,firmware,capacity_gb,media_type,smart_status,life_remaining_pct,life_used_pct,life_source,available_spare_pct,power_on_hours,temperature_c,data_written_tb,error_count,wear_pct_per_year,est_days_remaining,est_eol_date,est_method,status,life_confidence"

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
  --always-exit-ok       always exit 0 (for RMMs that fail an action on non-zero exit)
  --debug                dump raw smartctl output for each drive (for troubleshooting)
  --unknown-ok           treat unreadable drives as OK instead of WARN
  --no-enable-smart      do not run 'smartctl -s on' when a drive has SMART disabled

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
    --always-exit-ok)  ALWAYS_EXIT_OK=true; shift ;;
    --debug)           DEBUG=true; shift ;;
    --unknown-ok)      UNKNOWN_IS_WARN=false; shift ;;
    --no-enable-smart) ENABLE_SMART=false; shift ;;
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
  local out
  # Preferred: everything between the header row and the next blank line.
  out="$(printf '%s\n' "$SMART" | awk '
    /^[[:space:]]*ID#[[:space:]]+ATTRIBUTE_NAME/ { f=1; next }
    f && /^[[:space:]]*$/                        { f=0 }
    f                                            { print }')"
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi

  # Fallback: recognize attribute rows by their shape, with no header at all.
  # An ATA attribute row is:  <id> <name> <0xflag> <val> <worst> <thresh> ...
  # This survives header wording/spacing differences across smartctl versions.
  printf '%s\n' "$SMART" | awk '
    $1 ~ /^[0-9]+$/ && $1+0 >= 1 && $1+0 <= 255 &&
    $3 ~ /^0x[0-9a-fA-F]+$/ &&
    $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ { print }'
}

# Normalized VALUE column (col 4) for an ATA attribute id.
# Normalized VALUE (col 4) for an attribute id.
# NF>=4, not NF>=8: the ID list shown for an UNKNOWN drive is built from column
# 1 of every row, so a row with fewer columns than expected was reported as
# "found" and then silently skipped here - the attribute appeared in the output
# yet produced no reading. Only the first four columns are actually needed, and
# $4 must be numeric so a malformed row cannot become a bogus 0%.
attr_norm() {
  printf '%s\n' "$ATTRS" | awk -v id="$1" '
    $1==id && NF>=4 && $4 ~ /^[0-9]+$/ { print $4+0; exit }'
}
# RAW_VALUE for an ATA attribute id. RAW_VALUE is column 10; do NOT use $NF,
# because smartctl appends notes to some rows, e.g.
#   194 Temperature_Celsius ... 38 (Min/Max 0/71)
# where $NF is "0/71)" rather than the value.
# RAW_VALUE is column 10. Require the full 10 columns: on a short row $NF is
# THRESH or WHEN_FAILED, not the raw value, and returning that produced
# confident nonsense (a 99% life reading off a threshold column). Every caller
# tolerates a missing raw value; none tolerates a wrong one.
attr_raw()  { printf '%s\n' "$ATTRS" | awk -v id="$1" '$1==id && NF>=10 {print $10; exit}'; }

# Fetch SMART data, trying every device type and keeping the RICHEST response.
#
# Older smartctl (e.g. 6.6) on some controllers answers a bare "-a" with the
# identity block but NO attribute table — which looks like a success but
# carries no wear data. So we score each candidate and keep the best one
# instead of accepting the first that merely has a serial number.
smart_score() {
  local o="$1" sc=0
  printf '%s\n' "$o" | grep -qE '^ID#[[:space:]]+ATTRIBUTE_NAME' && sc=$((sc+4))   # ATA attribute table
  printf '%s\n' "$o" | grep -qiE 'Percentage Used|SMART/Health Information' && sc=$((sc+4))  # NVMe health log
  printf '%s\n' "$o" | grep -qiE 'SMART overall-health|SMART Health Status' && sc=$((sc+2))
  printf '%s\n' "$o" | grep -qiE 'Serial Number|Device Model|Model Number' && sc=$((sc+1))
  echo "$sc"
}

read_smart() {
  local dev="$1" out="" best="" best_score=0 sc
  for dtype in "" "-d sat" "-d ata" "-d nvme" "-d scsi" "-d auto" "-d sat,12"; do
    # shellcheck disable=SC2086
    out="$(smartctl -a $dtype "$dev" 2>/dev/null)"
    [ -n "$out" ] || continue
    sc="$(smart_score "$out")"
    if [ "$sc" -gt "$best_score" ]; then
      best_score="$sc"; best="$out"; BEST_DTYPE="$dtype"
    fi
    # Score >=5 means we have both identity and real health data; stop looking.
    [ "$best_score" -ge 5 ] && break
  done
  [ "$best_score" -gt 0 ] || return 1
  # Command substitution runs this in a subshell, so a variable assignment
  # cannot reach the caller — pass the winning type back as a marker line.
  printf '#SSD_DTYPE:%s\n%s' "${BEST_DTYPE:-default}" "$best"
  return 0
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

# SMART lives on the physical disk, not a partition. If someone passes
# /dev/sda1 or /dev/nvme0n1p2, walk up to the parent disk.
resolve_parent_disk() {
  local dev="$1" base parent
  base="$(basename "$dev")"
  if [ -e "/sys/class/block/$base/partition" ]; then
    if command -v lsblk >/dev/null 2>&1; then
      parent="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1 | tr -d ' ')"
      [ -n "$parent" ] && { echo "/dev/$parent"; return; }
    fi
    # sysfs fallback: /sys/class/block/sda1 -> .../block/sda/sda1
    parent="$(basename "$(dirname "$(readlink -f "/sys/class/block/$base")")")"
    [ -n "$parent" ] && [ "$parent" != "block" ] && { echo "/dev/$parent"; return; }
  fi
  # Name-pattern fallback, for when the node isn't in sysfs (explicit --devices).
  case "$dev" in
    /dev/nvme[0-9]*n[0-9]*p[0-9]*) echo "${dev%p*}"; return ;;
    /dev/mmcblk[0-9]*p[0-9]*)      echo "${dev%p*}"; return ;;
    /dev/[shv]d[a-z][0-9]*)        echo "$dev" | sed -E 's/[0-9]+$//'; return ;;
  esac
  echo "$dev"
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
    # -s not -f: an existing but empty file still needs the header row.
    [ -s "$MASTER_PATH" ] || printf '%s\n' "$CSV_HEADER" > "$MASTER_PATH"
    # Replace this drive's previous row. The key is asset_id + SERIAL, not the
    # device node: Linux can enumerate the same disk as /dev/sda today and
    # /dev/sdb after a reboot or a controller change, and keying on the node
    # would leave the old row behind as a phantom second drive. Fall back to
    # the node only when the serial is unknown and cannot identify the drive.
    local tmp="${MASTER_PATH}.tmp.$$"
    case "$serial" in
      ''|unknown*|Unknown*|UNKNOWN*)
        awk -F, -v h="$ASSET_ID" -v d="$dev" \
            'NR==1 || !($2==h && $4==d)' "$MASTER_PATH" > "$tmp" 2>/dev/null ;;
      *)
        awk -F, -v h="$ASSET_ID" -v s="$serial" \
            'NR==1 || !($2==h && $7==s)' "$MASTER_PATH" > "$tmp" 2>/dev/null ;;
    esac
    mv -f "$tmp" "$MASTER_PATH" 2>/dev/null || rm -f "$tmp"
    printf '%s\n' "$row" >> "$MASTER_PATH"
  }

  # Pick a locking strategy. flock is the right tool on a local filesystem, but
  # its semantics over NFS/CIFS depend on the server and mount options and can
  # silently fail to exclude — which is exactly the case a shared master file
  # hits. On network filesystems use mkdir, which is atomic by protocol.
  local fstype="" strategy="$LOCK_STRATEGY"
  if [ "$strategy" = "auto" ]; then
    strategy="flock"
    fstype="$(stat -f -c %T "$dir" 2>/dev/null || echo unknown)"
    case "$fstype" in
      nfs*|smb*|cifs*|fuseblk|9p) strategy="mkdir" ;;
    esac
    command -v flock >/dev/null 2>&1 || strategy="mkdir"
  fi

  if [ "$strategy" = "flock" ]; then
    local frc=0
    if exec 9>"$lock" 2>/dev/null; then
      flock -w "$LOCK_TIMEOUT" 9; frc=$?
      if [ "$frc" -eq 0 ]; then
        _do_write; flock -u 9; exec 9>&-; return 0
      fi
      exec 9>&-
    else
      frc=126
    fi
    # rc 1 is a genuine timeout (someone else holds it). Anything else means
    # flock is unusable here - a missing binary, a filesystem that refuses the
    # lock - so fall through to mkdir rather than silently dropping the row.
    if [ "$frc" -eq 1 ]; then
      warn "WARN: timed out waiting for master file lock"; return 1
    fi
    warn "NOTE: flock unusable on $dir (rc=$frc); using mkdir locking."
    strategy="mkdir"
  fi

  if [ "$strategy" = "mkdir" ]; then
    local lockd="${lock}.d" waited=0 age
    while ! mkdir "$lockd" 2>/dev/null; do
      # Break a lock left behind by a run that was killed mid-write, otherwise
      # one crashed machine blocks the whole fleet forever.
      age="$(( $(date -u +%s) - $(stat -c %Y "$lockd" 2>/dev/null || date -u +%s) ))"
      if [ "$age" -gt "$STALE_LOCK_SECS" ]; then
        warn "WARN: breaking stale master lock (${age}s old)"
        rmdir "$lockd" 2>/dev/null || rm -rf "$lockd" 2>/dev/null
        continue
      fi
      waited=$((waited+1))
      [ "$waited" -ge "$LOCK_TIMEOUT" ] && { warn "WARN: timed out waiting for master file lock"; return 1; }
      sleep 1
    done
    _do_write
    rmdir "$lockd" 2>/dev/null
    return 0
  fi
}

# ---------------------------------------------------------------------------
# Main scan
# ---------------------------------------------------------------------------
BEST_DTYPE=""
SEEN_DEVS=""
UNKNOWN_REASONS=()
UNKNOWN_DUMPS=()
HEURISTIC_NOTES=()
OVERWORN_NOTES=()
ROWS=()
JSON_ITEMS=()
SUMMARY_LINES=()
SKIPPED=()
WORST=0          # 0 ok, 1 warn, 2 critical
FOUND=0
UNKNOWN_COUNT=0

for RAW_DEV in $(discover_devices); do
  DEV="$(resolve_parent_disk "$RAW_DEV")"
  [ "$DEV" = "$RAW_DEV" ] || say "NOTE: $RAW_DEV is a partition — reading SMART from its disk $DEV."
  # Skip if we already covered this disk via another partition.
  case " ${SEEN_DEVS:-} " in *" $DEV "*) continue ;; esac
  SEEN_DEVS="${SEEN_DEVS:-} $DEV"
  # Autodetected devices must be real nodes; an explicit --devices list is
  # trusted as-is so odd paths (controller pass-through, /dev/bsg/...) work.
  if [ -z "$DEVICES_OVERRIDE" ] && [ ! -b "$DEV" ] && [ ! -c "$DEV" ]; then
    continue
  fi

  if ! SMART="$(read_smart "$DEV")" || [ -z "$SMART" ]; then
    SKIPPED+=("$DEV: SMART unavailable (virtual disk, or a controller needing an explicit -d type)")
    continue
  fi

  # Split the marker line back off the payload.
  BEST_DTYPE="$(printf '%s\n' "$SMART" | sed -n '1s/^#SSD_DTYPE://p')"
  SMART="$(printf '%s\n' "$SMART" | tail -n +2)"
  [ -n "$BEST_DTYPE" ] || BEST_DTYPE="default"

  SUPPLEMENTED=""
  SUPP_RAW=""
  ATTRS="$(attr_table)"

  # "-a" is documented as a superset of "-A", but on some smartctl/drive
  # combinations (confirmed on smartctl 6.6 + Crucial MX500) it returns
  # identity and health while silently omitting the attribute table. Ask for
  # the attributes explicitly whenever they are missing instead of trusting -a.
  if [ -z "$ATTRS" ]; then
    if [ "$BEST_DTYPE" = "default" ] || [ -z "$BEST_DTYPE" ]; then
      SUPP="$(smartctl -A "$DEV" 2>/dev/null)"
    else
      # shellcheck disable=SC2086
      SUPP="$(smartctl -A $BEST_DTYPE "$DEV" 2>/dev/null)"
    fi
    if [ -n "$SUPP" ]; then
      SMART_TRY="$SMART"
      SMART="$(printf '%s\n%s\n' "$SMART" "$SUPP")"
      if [ -n "$(attr_table)" ]; then
        ATTRS="$(attr_table)"
        SUPPLEMENTED="smartctl -A"
      else
        SMART="$SMART_TRY"
        # Keep what -A said so an UNKNOWN drive can explain itself below.
        SUPP_RAW="$SUPP"
      fi
    fi
  fi

  # The NVMe health log can go missing from "-a" for the same reason.
  # NOTE: detect NVMe inline here. PROTOCOL is not assigned until further down,
  # so testing it at this point silently disabled this whole recovery path.
  is_nvme_dev() {
    case "$1" in */nvme*) return 0 ;; esac
    printf '%s\n' "$SMART" | grep -qiE 'NVMe Version|Number of Namespaces|NVMe Log'
  }
  if is_nvme_dev "$DEV" && ! printf '%s\n' "$SMART" | grep -qi 'Percentage Used'; then
    SUPP="$(smartctl -A "$DEV" 2>/dev/null)"
    if printf '%s\n' "$SUPP" | grep -qi 'Percentage Used'; then
      SMART="$(printf '%s\n%s\n' "$SMART" "$SUPP")"
      SUPPLEMENTED="smartctl -A"
    fi
  fi



  if [ "$DEBUG" = "true" ]; then
    echo "=================== DEBUG: $DEV ==================="
    [ -n "${SUPPLEMENTED:-}" ] && echo "--- attribute table recovered via: ${SUPPLEMENTED} $DEV"
    echo "--- winning invocation: smartctl -a $([ "$BEST_DTYPE" = "default" ] || echo "$BEST_DTYPE") $DEV"
    echo "--- raw smartctl output ---"
    printf '%s\n' "$SMART"
    echo "--- parsed attribute table (${DEV}) ---"
    if [ -n "$ATTRS" ]; then printf '%s\n' "$ATTRS"; else echo "(EMPTY — no attribute table found)"; fi
    echo "=================== END DEBUG: $DEV ==================="
  fi

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

  # A drive with SMART turned off answers with identity but no attributes.
  # Enabling it is a standard, persistent monitoring setting - not a data change.
  if [ -z "$ATTRS" ] && [ "$PROTOCOL" != "nvme" ] \
     && printf '%s\n' "$SMART" | grep -qi 'SMART support is:[[:space:]]*Disabled'; then
    if [ "$ENABLE_SMART" = "true" ]; then
      say "NOTE: SMART is disabled on $DEV — enabling it (smartctl -s on)."
      # shellcheck disable=SC2086
      if [ "$BEST_DTYPE" = "default" ] || [ -z "$BEST_DTYPE" ]; then
        smartctl -s on "$DEV" >/dev/null 2>&1
      else
        # shellcheck disable=SC2086
        smartctl -s on $BEST_DTYPE "$DEV" >/dev/null 2>&1
      fi
      if SMART_RETRY="$(read_smart "$DEV")" && [ -n "$SMART_RETRY" ]; then
        SMART="$(printf '%s\n' "$SMART_RETRY" | tail -n +2)"
        ATTRS="$(attr_table)"
      fi
    else
      say "NOTE: SMART is disabled on $DEV. Enable it with: smartctl -s on $DEV"
    fi
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
  LIFE_CONFIDENCE=""

  if [ "$PROTOCOL" = "nvme" ]; then
    PU="$(num "$(sm_field 'Percentage Used')")"
    if is_num "${PU:-}"; then
      LIFE_USED="$PU"
      LIFE_REMAIN="$(awk -v u="$PU" 'BEGIN{r=100-u; if(r<0)r=0; printf "%.0f", r}')"
      LIFE_SOURCE="nvme:percentage_used"
      LIFE_CONFIDENCE="high"   # defined by the NVMe spec, not vendor-specific
    fi
    SPARE="$(num "$(sm_field 'Available Spare')")"
    SPARE_THRESH="$(num "$(sm_field 'Available Spare Threshold')")"
  else
    # ATA/SATA SSDs: vendors disagree about what these attributes mean, so they
    # are split into two tiers and the tier is reported in life_confidence.
    #
    #   high      - the attribute is DEFINED as percent-of-life-remaining.
    #   heuristic - the normalized value usually tracks remaining life on the
    #               families that use it, but the vendor does not guarantee it.
    #               Wear_Leveling_Count and Ave_Block-Erase_Count are erase-count
    #               health indicators; a 0-100 normalized value is suggestive,
    #               not a literal percentage. Treated as a signal, not a promise.
    #
    # High-confidence IDs are tried first, so a heuristic is only ever used when
    # the drive exposes nothing authoritative.
    for pair in "231:SSD_Life_Left:high" "233:Media_Wearout_Indicator:high" \
                "202:Percent_Lifetime_Remain:high" "169:Remaining_Life:high" \
                "177:Wear_Leveling_Count:heuristic" "173:Ave_Block-Erase_Count:heuristic" \
                "232:Endurance_Remaining:heuristic" "209:Remaining_Life:heuristic"; do
      aid="${pair%%:*}"; rest="${pair#*:}"; aname="${rest%%:*}"; atier="${rest##*:}"
      v="$(attr_norm "$aid")"

      # A normalized life value above 100 is an unsigned-byte underflow, not a
      # percentage: firmware computes 100 - percent_used, and once the drive
      # passes its rated endurance that goes negative and wraps. Observed on a
      # Crucial MX500 reporting VALUE=232 with RAW=124, i.e. 100-124 = -24,
      # and -24 as an unsigned byte is 232. Such a drive has NO life left, so
      # rejecting the value as out-of-range hid the most worn drive in the
      # fleet behind UNKNOWN. Prefer the RAW percent-used, which stays correct
      # past 100%, and fall back to zero when RAW is unusable.
      if is_num "${v:-}" && [ "${v:-0}" -gt 100 ] 2>/dev/null; then
        rawused="$(num "$(attr_raw "$aid")")"
        if is_num "${rawused:-}" && [ "${rawused:-0}" -ge 100 ] 2>/dev/null \
           && [ "${rawused:-999}" -le 255 ] 2>/dev/null; then
          LIFE_USED="$rawused"; LIFE_REMAIN=0
          LIFE_SOURCE="ata:${aid}_${aname}_raw_used"
          LIFE_CONFIDENCE="$atier"
          OVERWORN_NOTES+=("$DEV: attribute $aid reports ${rawused}% of rated endurance consumed (normalized ${v} is a wrapped negative) — the drive is past its rated life")
          break
        fi
        # Normalized wrapped but RAW is not a usable percentage: still zero.
        LIFE_USED=100; LIFE_REMAIN=0
        LIFE_SOURCE="ata:${aid}_${aname}_wrapped"
        LIFE_CONFIDENCE="$atier"
        OVERWORN_NOTES+=("$DEV: attribute $aid normalized value ${v} is a wrapped negative — the drive is at or past its rated life")
        break
      fi
      # -ge 0, NOT -gt 0. A normalized value of 0 means ZERO life remaining -
      # a fully worn drive - not a missing attribute. is_num already rejects
      # the empty string returned when the attribute is absent, so treating 0
      # as "not found" only ever hid the drives that most needed replacing.
      if is_num "${v:-}" && [ "${v:-x}" -ge 0 ] 2>/dev/null && [ "${v:-x}" -le 100 ] 2>/dev/null; then
        LIFE_REMAIN="$v"
        LIFE_USED="$((100 - v))"
        LIFE_SOURCE="ata:${aid}_${aname}"
        LIFE_CONFIDENCE="$atier"
        break
      fi
    done
    # Last resort: match on attribute NAME, for drives whose vendor used an
    # unexpected ID for wear (or a smartctl too old to know the drive).
    if [ -z "$LIFE_REMAIN" ] && [ -n "$ATTRS" ]; then
      read -r n_id n_name n_val <<EOF_ATTR
$(printf '%s\n' "$ATTRS" | awk 'tolower($2) ~ /life|wear|lifetime|endurance|remain/ && NF>=4 && $4 ~ /^[0-9]+$/ {print $1" "$2" "$4+0; exit}')
EOF_ATTR
      if is_num "${n_val:-}" && [ "${n_val:-x}" -ge 0 ] 2>/dev/null && [ "${n_val:-x}" -le 100 ] 2>/dev/null; then
        LIFE_REMAIN="$n_val"; LIFE_USED="$((100 - n_val))"; LIFE_SOURCE="ata:${n_id}_${n_name}"
        LIFE_CONFIDENCE="heuristic"
      fi
    fi
    # Crucial/Micron style: 202 raw holds percent USED, not remaining.
    if [ -z "$LIFE_REMAIN" ]; then
      v="$(num "$(attr_raw 202)")"
      if is_num "${v:-}" && [ "${v:-x}" -ge 0 ] 2>/dev/null && [ "${v:-x}" -le 100 ] 2>/dev/null; then
        LIFE_USED="$v"; LIFE_REMAIN="$((100 - v))"; LIFE_SOURCE="ata:202_raw_used"
        LIFE_CONFIDENCE="heuristic"
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
    STATUS="UNKNOWN"
    # Say exactly what was missing, so this is diagnosable from one run.
    if [ -z "$ATTRS" ]; then
      if printf '%s\n' "$SMART" | grep -qi 'SMART support is:[[:space:]]*Disabled'; then
        REASON="SMART is disabled on the drive"
      elif printf '%s\n' "$SMART" | grep -qi 'SMART support is:[[:space:]]*Unavailable\|does not support SMART'; then
        REASON="drive/controller does not support SMART"
      else
        REASON="no attribute table returned (best probe: smartctl -a ${BEST_DTYPE})"
        # Show what smartctl actually said, so this is diagnosable from the
        # normal Level.io output instead of needing a second --debug run.
        UNKNOWN_DUMPS+=("--- $DEV: 'smartctl -A' returned ---")
        if [ -n "${SUPP_RAW:-}" ]; then
          while IFS= read -r dl; do UNKNOWN_DUMPS+=("    $dl"); done \
            <<< "$(printf '%s\n' "$SUPP_RAW" | grep -v '^[[:space:]]*$' | head -20)"
        else
          UNKNOWN_DUMPS+=("    (no output at all)")
        fi
        UNKNOWN_DUMPS+=("--- $DEV: 'smartctl -a' returned ---")
        while IFS= read -r dl; do UNKNOWN_DUMPS+=("    $dl"); done \
          <<< "$(printf '%s\n' "$SMART" | grep -v '^[[:space:]]*$' | head -20)"
      fi
    else
      ATTR_IDS="$(printf '%s\n' "$ATTRS" | awk '{printf "%s ", $1}')"
      REASON="no known wear attribute among IDs: ${ATTR_IDS}"
      # Print the candidate rows exactly as parsed, with their column count.
      # "the ID is listed but no value came out" is a column-layout problem,
      # and this shows the layout instead of leaving it to be guessed.
      UNKNOWN_DUMPS+=("--- $DEV: rows for known wear-attribute IDs, as parsed ---")
      CAND="$(printf '%s\n' "$ATTRS" | awk '
        $1==169||$1==177||$1==173||$1==201||$1==202||$1==203||$1==209||$1==231||$1==232||$1==233 {
          printf "    [NF=%d] %s\n", NF, $0 }')"
      if [ -n "$CAND" ]; then
        while IFS= read -r cl; do UNKNOWN_DUMPS+=("$cl"); done <<< "$CAND"
      else
        UNKNOWN_DUMPS+=("    (none of the known wear IDs are present)")
        UNKNOWN_DUMPS+=("--- $DEV: full attribute table, as parsed ---")
        while IFS= read -r cl; do UNKNOWN_DUMPS+=("    $cl"); done \
          <<< "$(printf '%s\n' "$ATTRS" | head -30)"
      fi
    fi
    UNKNOWN_REASONS+=("$DEV: $REASON")
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
    UNKNOWN)
      UNKNOWN_COUNT=$((UNKNOWN_COUNT+1))
      # A drive we cannot read is NOT a healthy drive. Surfacing it as OK is
      # how a dying disk hides from monitoring.
      [ "$UNKNOWN_IS_WARN" = "true" ] && [ "$WORST" -lt 1 ] && WORST=1
      ;;
  esac

  # --- emit ------------------------------------------------------------------
  ROW="$NOW_ISO,$(clean "$ASSET_ID"),$(clean "$HOST"),$(clean "$DEV"),$PROTOCOL,$(clean "$MODEL"),$(clean "$SERIAL"),$(clean "$FIRMWARE"),${CAPACITY_GB},$MEDIA,$(clean "$SMART_STATUS"),${LIFE_REMAIN},${LIFE_USED},${LIFE_SOURCE},${SPARE},${POH},${TEMP},${WRITTEN_TB},${ERRORS},${WEAR_YR},${EST_DAYS},${EST_EOL},${EST_METHOD},$STATUS,${LIFE_CONFIDENCE}"
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
      "status": "$STATUS",
      "life_confidence": "$(json_escape "$LIFE_CONFIDENCE")"
    }
JSON
)")

  LIFE_MARK=""
  [ "$LIFE_CONFIDENCE" = "heuristic" ] && LIFE_MARK="~"
  SUMMARY_LINES+=("$(printf '%-12s %-6s %-24.24s %-18.18s %4s%s%%  %8s  %-10s %s' \
    "$(basename "$DEV")" "$MEDIA" "${MODEL:-unknown}" "${SERIAL:-unknown}" \
    "${LIFE_REMAIN:-n/a}" "$LIFE_MARK" "${EST_DAYS:-n/a}d" "${EST_EOL:-n/a}" "$STATUS${REASON:+ ($REASON)}")")
  [ "$LIFE_CONFIDENCE" = "heuristic" ] && HEURISTIC_NOTES+=("$DEV: read from ${LIFE_SOURCE#ata:} — a vendor-specific attribute, so treat the date as indicative, not a guarantee")
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
# Version in the header so a pasted run identifies its own build - otherwise
# an old copy still deployed is indistinguishable from a bug in the new one.
say "SSD Life Expectancy v$VERSION — $ASSET_ID ($HOST) — $NOW_ISO"
say "smartctl: $(smartctl --version 2>/dev/null | head -1 | sed 's/^smartctl //')"
say "$(printf '%-12s %-6s %-24s %-18s %6s  %8s  %-10s %s' DEVICE TYPE MODEL SERIAL LIFE EST_LEFT EOL_DATE STATUS)"
say "------------------------------------------------------------------------------------------------------------"
for l in "${SUMMARY_LINES[@]}"; do say "$l"; done
if [ "${#OVERWORN_NOTES[@]}" -gt 0 ] && [ "$QUIET" != "true" ]; then
  say ""
  say "Past rated endurance:"
  for o in "${OVERWORN_NOTES[@]}"; do say "  - $o"; done
fi
if [ "${#HEURISTIC_NOTES[@]}" -gt 0 ] && [ "$QUIET" != "true" ]; then
  say ""
  say "Readings marked ~ come from a vendor-specific attribute (life_confidence=heuristic):"
  for h in "${HEURISTIC_NOTES[@]}"; do say "  - $h"; done
fi
if [ "${#SKIPPED[@]}" -gt 0 ] && [ "$QUIET" != "true" ]; then
  say ""
  say "Skipped:"
  for s in "${SKIPPED[@]}"; do say "  - $s"; done
fi
say ""
HEALTHY=$((FOUND - UNKNOWN_COUNT))
if [ "$UNKNOWN_COUNT" -gt 0 ]; then
  say "NOTE: $UNKNOWN_COUNT of $FOUND drive(s) exposed no wear attribute — health is UNKNOWN, not OK."
  for r in "${UNKNOWN_REASONS[@]}"; do say "      $r"; done
  if [ "${#UNKNOWN_DUMPS[@]}" -gt 0 ]; then
    say ""
    say "What smartctl actually returned (send this if the drive should be readable):"
    for d in "${UNKNOWN_DUMPS[@]}"; do say "$d"; done
  fi
fi
case "$WORST" in
  0) if [ "$UNKNOWN_COUNT" -gt 0 ]; then
       say "RESULT: OK — $HEALTHY drive(s) healthy, $UNKNOWN_COUNT unreadable ($FOUND scanned)"
     else
       say "RESULT: OK — all drives healthy ($FOUND scanned)"
     fi ;;
  1) if [ "$UNKNOWN_COUNT" -gt 0 ] && [ "$HEALTHY" -eq 0 ]; then
       say "RESULT: WARN — could not read wear data from any drive ($FOUND scanned)"
     else
       say "RESULT: WARN — at least one drive needs attention ($FOUND scanned)"
     fi ;;
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

if [ "$ALWAYS_EXIT_OK" = "true" ]; then
  exit 0
fi
exit "$WORST"
SSD_REPORTER_PAYLOAD_EOF

chmod 0755 "$SSD_INSTALL_PATH" || die "cannot chmod $SSD_INSTALL_PATH"
bash -n "$SSD_INSTALL_PATH" || die "installed reporter failed its syntax check"
say "    installed $(wc -l < "$SSD_INSTALL_PATH") lines"

# --- 2. write the config the scheduled runs will read -----------------------
say "==> Writing config to $SSD_CONF_PATH"

# Emit NAME='value' with embedded single quotes escaped. Values reach this file
# from Level.io variables, so they cannot be assumed free of spaces, #, $, or
# quotes; an unquoted value would be re-split or expanded when the scheduled
# run sources this file. Both `set -a; . file` and systemd EnvironmentFile
# accept single-quoted values.
conf_line() {
  local name="$1" val="${2:-}"
  printf "%s='%s'\n" "$name" "$(printf '%s' "$val" | sed "s/'/'\\\\''/g")"
}

{
  echo "# Written by install-ssd-monitor.sh. Read by the scheduled run."
  echo "# Values are single-quoted; edit with care."
  # Everything the reporter honors, so a scheduled run behaves exactly like the
  # install-time run. Persisting only a subset meant a Level.io variable applied
  # now and silently vanished on the next timer firing.
  conf_line SSD_OUTPUT_MODE      "$SSD_OUTPUT_MODE"
  conf_line SSD_LOCAL_DIR        "$SSD_LOCAL_DIR"
  conf_line SSD_LOCAL_NAME       "${SSD_LOCAL_NAME:-}"
  conf_line SSD_MASTER_PATH      "$SSD_MASTER_PATH"
  conf_line SSD_FORMAT           "$SSD_FORMAT"
  conf_line SSD_APPEND_HISTORY   "${SSD_APPEND_HISTORY:-false}"
  conf_line SSD_INCLUDE_HDD      "${SSD_INCLUDE_HDD:-false}"
  conf_line SSD_DEVICES          "${SSD_DEVICES:-}"
  conf_line SSD_HOSTNAME         "${SSD_HOSTNAME:-}"
  conf_line SSD_HOST_REGEX       "${SSD_HOST_REGEX:-}"
  conf_line SSD_WARN_PCT         "$SSD_WARN_PCT"
  conf_line SSD_CRIT_PCT         "$SSD_CRIT_PCT"
  conf_line SSD_WARN_DAYS        "$SSD_WARN_DAYS"
  conf_line SSD_CRIT_DAYS        "$SSD_CRIT_DAYS"
  conf_line SSD_AUTO_INSTALL     "${SSD_AUTO_INSTALL:-true}"
  conf_line SSD_ENABLE_SMART     "${SSD_ENABLE_SMART:-true}"
  conf_line SSD_UNKNOWN_IS_WARN  "${SSD_UNKNOWN_IS_WARN:-true}"
  conf_line SSD_STATE_FILE       "${SSD_STATE_FILE:-/var/lib/ssd-life-expectancy/state.csv}"
  conf_line SSD_LOCK_TIMEOUT     "${SSD_LOCK_TIMEOUT:-30}"
  conf_line SSD_LOCK_STRATEGY    "${SSD_LOCK_STRATEGY:-auto}"
  conf_line SSD_STALE_LOCK_SECS  "${SSD_STALE_LOCK_SECS:-300}"
  conf_line SSD_QUIET            "${SSD_QUIET:-false}"
  conf_line SSD_ALWAYS_EXIT_OK   "${SSD_ALWAYS_EXIT_OK:-false}"
} > "$SSD_CONF_PATH"
chmod 0644 "$SSD_CONF_PATH"

# --- 3. schedule ------------------------------------------------------------
SCHED_HOUR="${SSD_SCHEDULE_TIME%%:*}"
SCHED_MIN="${SSD_SCHEDULE_TIME##*:}"
# Strip any leading zero so cron/arithmetic don't read them as octal.
SCHED_HOUR="$((10#${SCHED_HOUR:-3}))"
SCHED_MIN="$((10#${SCHED_MIN:-17}))"

remove_schedules() {
  rm -f /etc/cron.d/ssd-life-expectancy
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now ssd-life-expectancy.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/ssd-life-expectancy.timer /etc/systemd/system/ssd-life-expectancy.service
    systemctl daemon-reload >/dev/null 2>&1
  fi
}

install_systemd() {
  [ -d /run/systemd/system ] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  local oncal
  case "$SSD_SCHEDULE" in
    weekly) oncal="Sun *-*-* $(printf '%02d:%02d' "$SCHED_HOUR" "$SCHED_MIN"):00" ;;
    daily)  oncal="*-*-* $(printf '%02d:%02d' "$SCHED_HOUR" "$SCHED_MIN"):00" ;;
    *) return 1 ;;
  esac
  cat > /etc/systemd/system/ssd-life-expectancy.service <<SERVICE
[Unit]
Description=SSD life expectancy report
After=local-fs.target

[Service]
Type=oneshot
EnvironmentFile=-$SSD_CONF_PATH
ExecStart=$(shq "$SSD_INSTALL_PATH")
# The reporter exits 1/2 to signal WARN/CRITICAL; that is data, not a failure.
SuccessExitStatus=0 1 2
SERVICE
  cat > /etc/systemd/system/ssd-life-expectancy.timer <<TIMER
[Unit]
Description=Run the SSD life expectancy report on a schedule

[Timer]
OnCalendar=$oncal
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
TIMER
  systemctl daemon-reload >/dev/null 2>&1 || return 1
  systemctl enable --now ssd-life-expectancy.timer >/dev/null 2>&1 || return 1
  return 0
}

install_cron() {
  command -v crond >/dev/null 2>&1 || command -v cron >/dev/null 2>&1 || [ -d /etc/cron.d ] || return 1
  [ -d /etc/cron.d ] || return 1
  local dow="*"
  [ "$SSD_SCHEDULE" = "weekly" ] && dow="0"
  # set -a exports what the conf file defines, so the reporter inherits it.
  # Single-quote every interpolated path, and escape cron's % (which it would
  # otherwise turn into a newline) so unusual paths cannot break the crontab.
  local q_conf q_bin q_log
  q_conf="$(shq "$SSD_CONF_PATH")"
  q_bin="$(shq "$SSD_INSTALL_PATH")"
  q_log="$(shq "$SSD_LOCAL_DIR/scheduled-run.log")"
  cat > /etc/cron.d/ssd-life-expectancy <<CRON
# SSD life expectancy report — installed by install-ssd-monitor.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$SCHED_MIN $SCHED_HOUR * * $dow root set -a; . $q_conf 2>/dev/null; set +a; $q_bin >> $q_log 2>&1
CRON
  # cron treats an unescaped % as a newline in the command field.
  sed -i 's/%/\\%/g' /etc/cron.d/ssd-life-expectancy
  chmod 0644 /etc/cron.d/ssd-life-expectancy
  mkdir -p "$SSD_LOCAL_DIR"
  return 0
}

if [ "$SSD_SCHEDULE" = "none" ]; then
  say "==> Scheduling skipped (SSD_SCHEDULE=none)"
  remove_schedules
else
  say "==> Scheduling: $SSD_SCHEDULE at $(printf '%02d:%02d' "$SCHED_HOUR" "$SCHED_MIN")"
  remove_schedules
  if install_systemd; then
    say "    systemd timer installed (next: $(systemctl show -p NextElapseUSecRealtime --value ssd-life-expectancy.timer 2>/dev/null || echo 'see systemctl list-timers'))"
  elif install_cron; then
    say "    cron job installed at /etc/cron.d/ssd-life-expectancy"
  else
    say "    WARNING: no systemd or cron found — install succeeded but nothing is scheduled."
  fi
fi

# --- 4. run once now --------------------------------------------------------
RC=0
if [ "$SSD_RUN_NOW" = "true" ]; then
  say "==> Running now"
  say ""
  set -a
  # shellcheck disable=SC1090
  . "$SSD_CONF_PATH" 2>/dev/null
  set +a
  "$SSD_INSTALL_PATH"
  RC=$?
  say ""
fi

say "==> Done. Reporter: $SSD_INSTALL_PATH   Config: $SSD_CONF_PATH"
if [ -n "$SSD_MASTER_PATH" ]; then
  say "    Fleet master file: $SSD_MASTER_PATH"
else
  say "    Per-machine reports: $SSD_LOCAL_DIR   (set SSD_MASTER_PATH for one fleet-wide file)"
fi
case "$RC" in
  0) say "    Drive status: OK" ;;
  1) say "    Drive status: WARN — see the table above" ;;
  2) say "    Drive status: CRITICAL — replace drive(s)" ;;
  3) say "    Drive status: reporter error — see messages above" ;;
esac
if [ "$SSD_ALWAYS_EXIT_OK" = "true" ]; then
  say "    (exiting 0: SSD_ALWAYS_EXIT_OK is set — read the status line above, not the exit code)"
  exit 0
fi
exit "$RC"
