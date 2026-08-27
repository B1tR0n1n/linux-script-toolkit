#!/usr/bin/env bash
#
# merge-ssd-reports.sh — roll individual per-machine CSVs into one master file.
#
# Use this when your endpoints cannot write to a shared mount, so each machine
# keeps a local report that you collect later (rsync/scp/Level.io file pull).
#
# Usage:
#   ./merge-ssd-reports.sh -i ./collected -o fleet-ssd-master.csv [--sort-by-life]
#
set -uo pipefail

IN_DIR="."
OUT="fleet-ssd-master.csv"
SORT_BY_LIFE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)   IN_DIR="${2:-}"; shift 2 ;;
    -o|--output)  OUT="${2:-}"; shift 2 ;;
    --sort-by-life) SORT_BY_LIFE=true; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -d "$IN_DIR" ] || { echo "ERROR: input dir not found: $IN_DIR" >&2; exit 2; }

HEADER="timestamp,asset_id,hostname,device,protocol,model,serial,firmware,capacity_gb,media_type,smart_status,life_remaining_pct,life_used_pct,life_source,available_spare_pct,power_on_hours,temperature_c,data_written_tb,error_count,wear_pct_per_year,est_days_remaining,est_eol_date,est_method,status,life_confidence"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

count=0
while IFS= read -r f; do
  # Skip each file's header row, keep the data.
  tail -n +2 "$f" | grep -v '^[[:space:]]*$' >> "$TMP"
  count=$((count+1))
done < <(find "$IN_DIR" -type f -name '*.csv' ! -name "$(basename "$OUT")" 2>/dev/null)

[ "$count" -gt 0 ] || { echo "ERROR: no CSV files found under $IN_DIR" >&2; exit 2; }

# Keep only the newest row per asset+serial+device (col 2,7,4), then order output.
# Key on asset_id + serial so a drive that moved from sda to sdb is one drive,
# falling back to the device node only when the serial is unknown.
DEDUPED="$(sort -t, -k1,1r "$TMP" | awk -F, '{k=($7=="" || $7 ~ /^[Uu]nknown/) ? $2","$4 : $2","$7} !seen[k]++')"

{
  printf '%s\n' "$HEADER"
  if [ "$SORT_BY_LIFE" = "true" ]; then
    # Worst drives first; blank life values sort last.
    printf '%s\n' "$DEDUPED" | awk -F, '{k=($12=="")?9999:$12; print k"\t"$0}' | sort -n | cut -f2-
  else
    printf '%s\n' "$DEDUPED" | sort -t, -k2,2
  fi
} > "$OUT"

rows=$(( $(wc -l < "$OUT") - 1 ))
assets=$(tail -n +2 "$OUT" | cut -d, -f2 | sort -u | wc -l)
echo "Merged $count file(s) -> $OUT"
echo "  $rows drive row(s) across $assets machine(s)"

crit=$(tail -n +2 "$OUT" | awk -F, '$24=="CRITICAL"' | wc -l)
warn=$(tail -n +2 "$OUT" | awk -F, '$24=="WARN"' | wc -l)
[ "$crit" -gt 0 ] && echo "  CRITICAL: $crit"
[ "$warn" -gt 0 ] && echo "  WARN:     $warn"
exit 0
