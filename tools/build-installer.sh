#!/usr/bin/env bash
#
# build-installer.sh — regenerate scripts/install-ssd-monitor.sh
#
# The installer embeds the reporter verbatim so it is a single paste with no
# network access needed. This generator is the only supported way to update it:
# edit scripts/ssd-life-expectancy.sh, then re-run this. Never hand-edit the
# generated file, or the two copies will drift.
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPORTER="scripts/ssd-life-expectancy.sh"
TEMPLATE="tools/installer-template.sh"
OUT="scripts/install-ssd-monitor.sh"
DELIM="SSD_REPORTER_PAYLOAD_EOF"

[ -f "$REPORTER" ] || { echo "missing $REPORTER" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }

# A line equal to the delimiter inside the payload would end the heredoc early.
if grep -qxF "$DELIM" "$REPORTER"; then
  echo "ERROR: reporter contains a line matching the heredoc delimiter $DELIM" >&2
  exit 1
fi

awk -v delim="$DELIM" -v reporter="$REPORTER" '
  /^@@REPORTER_PAYLOAD@@$/ {
    while ((getline line < reporter) > 0) print line
    next
  }
  { print }
' "$TEMPLATE" > "$OUT"

chmod +x "$OUT"
bash -n "$OUT" || { echo "generated installer has a syntax error" >&2; exit 1; }
echo "Generated $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes)"
