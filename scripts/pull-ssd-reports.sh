#!/usr/bin/env bash
#
# pull-ssd-reports.sh — fetch each machine's SSD report over SSH and build the
# fleet master CSV.
#
# Complements the two other collection routes:
#   collect-ssd-output.sh  parses report output you already have (Level.io run
#                          history, saved logs) - no SSH needed.
#   this script            reaches out to the machines and pulls their files.
#
# Usage:
#   ./pull-ssd-reports.sh -H hosts.txt                      # one hostname per line
#   ./pull-ssd-reports.sh md4004 md4006 md4065              # hosts on the command line
#   ./pull-ssd-reports.sh -H hosts.txt -u svcacct -o out.csv
#   ./pull-ssd-reports.sh -H hosts.txt --run                # run the reporter first, then pull
#
set -uo pipefail

OUT="fleet-ssd-master.csv"
USER_AT=""
REMOTE_DIR="/var/log/ssd-health"
WORKDIR=""
JOBS=8
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
RUN_FIRST=false
KEEP=false
HOSTS=()

usage() { sed -n '2,18p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -H|--hosts-file)
      [ -f "${2:-}" ] || { echo "ERROR: host file not found: ${2:-}" >&2; exit 2; }
      # One host per line; ignore blanks and # comments.
      while IFS= read -r line; do
        line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -n "$line" ] && HOSTS+=("$line")
      done < "$2"; shift 2 ;;
    -u|--user)        USER_AT="${2:-}@"; shift 2 ;;
    -o|--output)      OUT="${2:-}"; shift 2 ;;
    -d|--remote-dir)  REMOTE_DIR="${2:-}"; shift 2 ;;
    -j|--jobs)        JOBS="${2:-8}"; shift 2 ;;
    -w|--workdir)     WORKDIR="${2:-}"; shift 2 ;;
    --run)            RUN_FIRST=true; shift ;;
    --keep)           KEEP=true; shift ;;
    --ssh-opts)       SSH_OPTS="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)                HOSTS+=("$1"); shift ;;
  esac
done

[ "${#HOSTS[@]}" -gt 0 ] || { echo "ERROR: no hosts given. Use -H hosts.txt or list them." >&2; usage >&2; exit 2; }
command -v ssh  >/dev/null 2>&1 || { echo "ERROR: ssh not found." >&2; exit 2; }
command -v scp  >/dev/null 2>&1 || { echo "ERROR: scp not found." >&2; exit 2; }

if [ -z "$WORKDIR" ]; then
  WORKDIR="$(mktemp -d)"
  [ "$KEEP" = "true" ] || trap 'rm -rf "$WORKDIR"' EXIT
fi
mkdir -p "$WORKDIR"

echo "Pulling from ${#HOSTS[@]} host(s), $JOBS at a time -> $WORKDIR"

OKF="$WORKDIR/.ok"; FAILF="$WORKDIR/.fail"
: > "$OKF"; : > "$FAILF"

fetch_one() {
  local host="$1" target="${USER_AT}$1" err
  if [ "$RUN_FIRST" = "true" ]; then
    # shellcheck disable=SC2086
    if ! err="$(ssh $SSH_OPTS "$target" 'sudo -n /usr/local/sbin/ssd-life-expectancy.sh --quiet >/dev/null 2>&1; exit 0' 2>&1)"; then
      printf '%s\treporter run failed: %s\n' "$host" "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-120)" >> "$FAILF"
      return 1
    fi
  fi
  # Copy every report file this host has into a per-host directory.
  mkdir -p "$WORKDIR/$host"
  # shellcheck disable=SC2086
  if err="$(scp $SSH_OPTS -q "$target:$REMOTE_DIR/*_ssd-health.csv" "$WORKDIR/$host/" 2>&1)"; then
    printf '%s\n' "$host" >> "$OKF"
  else
    printf '%s\tno report file: %s\n' "$host" "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-120)" >> "$FAILF"
    rmdir "$WORKDIR/$host" 2>/dev/null
    return 1
  fi
}

# Bounded parallelism: keep at most $JOBS transfers in flight.
running=0
for h in "${HOSTS[@]}"; do
  fetch_one "$h" &
  running=$((running+1))
  if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running-1)); fi
done
wait

nok=$(grep -c . "$OKF" 2>/dev/null | head -1); nok=${nok:-0}
nfail=$(grep -c . "$FAILF" 2>/dev/null | head -1); nfail=${nfail:-0}
echo "  pulled from $nok host(s); $nfail could not be reached or had no report"

if [ "$nfail" -gt 0 ]; then
  echo ""
  echo "Not collected:"
  while IFS=$'\t' read -r h reason; do printf '  %-14s %s\n' "$h" "$reason"; done < "$FAILF"
fi

[ "$nok" -gt 0 ] || { echo "ERROR: nothing was pulled; no master file written." >&2; exit 2; }

# Hand off to the collector, which already dedupes by asset+serial and sorts.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECTOR="$SELF_DIR/collect-ssd-output.sh"
if [ -x "$COLLECTOR" ]; then
  echo ""
  "$COLLECTOR" "$WORKDIR" -o "$OUT"
  rc=$?
else
  echo "WARN: collect-ssd-output.sh not found next to this script; concatenating instead." >&2
  { head -1 "$(find "$WORKDIR" -name '*_ssd-health.csv' | head -1)"
    find "$WORKDIR" -name '*_ssd-health.csv' -exec tail -n +2 {} \; ; } > "$OUT"
  rc=0
fi

[ "$KEEP" = "true" ] && echo "" && echo "Pulled files kept in $WORKDIR"
exit "$rc"
