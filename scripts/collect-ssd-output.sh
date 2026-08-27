#!/usr/bin/env bash
#
# collect-ssd-output.sh — build a fleet master CSV from emitted report output.
#
# Feed it whatever you have: text copied out of Level.io run history, a
# directory of saved run logs, per-machine *_ssd-health.csv files, or a pipe.
# It finds the report rows inside the noise, keeps the newest row per drive,
# and writes one master CSV sorted worst-drive-first.
#
# Usage:
#   ./collect-ssd-output.sh runs.txt                    # a pasted run log
#   ./collect-ssd-output.sh ./logs -o fleet.csv         # a directory
#   ./collect-ssd-output.sh ./logs ./more runs.txt      # any mix
#   pbpaste | ./collect-ssd-output.sh -                 # from the clipboard
#   ./collect-ssd-output.sh runs.txt --by-asset         # sort by name instead
#
set -uo pipefail

OUT="fleet-ssd-master.csv"
SORT_MODE="life"          # life | asset | date
QUIET=false
INPUTS=()

HEADER="timestamp,asset_id,hostname,device,protocol,model,serial,firmware,capacity_gb,media_type,smart_status,life_remaining_pct,life_used_pct,life_source,available_spare_pct,power_on_hours,temperature_c,data_written_tb,error_count,wear_pct_per_year,est_days_remaining,est_eol_date,est_method,status,life_confidence"
NCOL=25

usage() { sed -n '2,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)  OUT="${2:-}"; shift 2 ;;
    --by-asset)   SORT_MODE="asset"; shift ;;
    --by-date)    SORT_MODE="date"; shift ;;
    --by-life)    SORT_MODE="life"; shift ;;
    -q|--quiet)   QUIET=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    -)            INPUTS+=("-"); shift ;;
    -*)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)            INPUTS+=("$1"); shift ;;
  esac
done

say() { [ "$QUIET" = "true" ] || printf '%s\n' "$*"; }

# No arguments and stdin is a pipe -> read stdin.
if [ "${#INPUTS[@]}" -eq 0 ]; then
  if [ ! -t 0 ]; then INPUTS+=("-"); else
    echo "ERROR: nothing to read. Pass a file or directory, or pipe text in." >&2
    usage >&2; exit 2
  fi
fi

RAW="$(mktemp)"; ROWS="$(mktemp)"
trap 'rm -f "$RAW" "$ROWS"' EXIT

# ---- gather every input into one stream -----------------------------------
nfiles=0
for src in "${INPUTS[@]}"; do
  if [ "$src" = "-" ]; then
    cat >> "$RAW"; nfiles=$((nfiles+1))
  elif [ -d "$src" ]; then
    while IFS= read -r f; do
      cat "$f" >> "$RAW"; printf '\n' >> "$RAW"; nfiles=$((nfiles+1))
    done < <(find "$src" -type f \( -name '*.csv' -o -name '*.txt' -o -name '*.log' -o -name '*.out' \) \
                  ! -name "$(basename "$OUT")" 2>/dev/null)
  elif [ -f "$src" ]; then
    cat "$src" >> "$RAW"; printf '\n' >> "$RAW"; nfiles=$((nfiles+1))
  else
    echo "WARN: not found, skipping: $src" >&2
  fi
done

[ "$nfiles" -gt 0 ] || { echo "ERROR: no readable inputs." >&2; exit 2; }

# ---- pull report rows out of arbitrary surrounding text -------------------
# Level.io wraps each output line in markdown fences, and run logs interleave
# progress lines, so rows are identified by shape rather than by position:
# an ISO-8601 timestamp in field 1 and the expected column count. Header
# lines, fences, and log chatter are ignored.
sed -e 's/\r$//' -e 's/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$//' "$RAW" \
  | awk -F, -v n="$NCOL" '
      $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ && NF==n { print }
    ' > "$ROWS"

found=$(grep -c . "$ROWS" 2>/dev/null); found=$(printf '%s' "${found:-0}" | head -1)
if [ "$found" -eq 0 ]; then
  echo "ERROR: found no report rows in the input." >&2
  echo "       Rows look like: 2026-08-27T18:44:41Z,md4060H,...  ($NCOL comma-separated fields)" >&2
  echo "       Run the reporter with SSD_EMIT_CSV=true so it prints them." >&2
  exit 2
fi

# ---- newest row per physical drive (asset_id + serial) --------------------
# Same key the reporter uses for the master file, so a drive that moved
# between device nodes stays one drive. Falls back to the node when the
# serial is unreadable.
DEDUPED="$(sort -t, -k1,1r "$ROWS" \
  | awk -F, '{k=($7=="" || $7 ~ /^[Uu]nknown/) ? $2","$4 : $2","$7} !seen[k]++')"

# ---- order and write ------------------------------------------------------
{
  printf '%s\n' "$HEADER"
  case "$SORT_MODE" in
    life)  # worst first; drives with no reading sort last, not as 0%
      printf '%s\n' "$DEDUPED" \
        | awk -F, '{k=($12=="")?9999:$12+0; printf "%05d\t%s\n", k, $0}' | sort -n | cut -f2- ;;
    asset) printf '%s\n' "$DEDUPED" | sort -t, -k2,2 ;;
    date)  printf '%s\n' "$DEDUPED" | sort -t, -k1,1r ;;
  esac
} > "$OUT"

# ---- report ---------------------------------------------------------------
count() { grep -c . 2>/dev/null | head -1; }
rows=$(tail -n +2 "$OUT" | count)
assets=$(tail -n +2 "$OUT" | cut -d, -f2 | sort -u | count)
crit=$(tail -n +2 "$OUT" | awk -F, '$24=="CRITICAL"' | count)
warn=$(tail -n +2 "$OUT" | awk -F, '$24=="WARN"' | count)
unk=$(tail -n +2 "$OUT"  | awk -F, '$24=="UNKNOWN"' | count)
dropped=$(( ${found:-0} - ${rows:-0} ))

say "Read $nfiles input(s), found $found row(s) -> $OUT"
say "  $rows drive(s) across $assets machine(s)"
[ "$dropped" -gt 0 ] && say "  $dropped duplicate/superseded row(s) collapsed"
[ "$crit" -gt 0 ] && say "  CRITICAL: $crit"
[ "$warn" -gt 0 ] && say "  WARN:     $warn"
[ "$unk"  -gt 0 ] && say "  UNKNOWN:  $unk  (could not read wear data)"

if [ "$QUIET" != "true" ] && [ "$((crit + warn))" -gt 0 ]; then
  say ""
  say "Replacement queue (worst first):"
  say "$(printf '  %-12s %-10s %-22s %5s %8s  %s' ASSET DEVICE SERIAL LIFE EST_LEFT STATUS)"
  tail -n +2 "$OUT" | awk -F, '$24=="CRITICAL" || $24=="WARN"' | head -25 \
    | awk -F, '{printf "  %-12s %-10s %-22s %4s%% %7sd  %s\n", $2, $4, $7, ($12==""?"n/a":$12), ($21==""?"n/a":$21), $24}'
fi

# 2 if anything is CRITICAL, 1 if only WARN, 0 otherwise.
[ "$crit" -gt 0 ] && exit 2
[ "$warn" -gt 0 ] && exit 1
exit 0
