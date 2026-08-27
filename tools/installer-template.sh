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
say "==> Installing reporter to $SSD_INSTALL_PATH"
mkdir -p "$(dirname "$SSD_INSTALL_PATH")" || die "cannot create $(dirname "$SSD_INSTALL_PATH")"

cat > "$SSD_INSTALL_PATH" <<'SSD_REPORTER_PAYLOAD_EOF'
@@REPORTER_PAYLOAD@@
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
exit "$RC"
