#!/usr/bin/env bash
#
# setup-push-key.sh — give each endpoint the SSH key it needs to push reports.
#
# Paste into your RMM and run against the fleet. Nothing here is interactive
# and nothing needs an SSH client on your own workstation: each machine
# installs the key locally, and from then on the reporter scp's its own file to
# the collection host.
#
# The private key is read from the environment, NOT hard-coded, so it can live
# in your RMM's secret store rather than in the script body:
#
#   SSD_PUSH_KEY        the private key, PEM text (use an RMM secret variable)
#   SSD_PUSH_HOST       collection host, e.g. mddb
#   SSD_PUSH_USER       account on that host, e.g. ssdcollect   (default ssdcollect)
#   SSD_PUSH_KEY_PATH   where to install it (default /root/.ssh/id_ssdpush)
#
# One shared key across the fleet is the practical choice at hundreds of
# machines. Restrict it on the collection host so it can do nothing but write
# reports — in that account's authorized_keys, prefix the key with:
#
#   command="internal-sftp",restrict
#
# then the key cannot open a shell, forward ports, or run anything else even
# if an endpoint is compromised.
#
set -uo pipefail

KEY_TEXT="${SSD_PUSH_KEY:-}"
PUSH_HOST="${SSD_PUSH_HOST:-}"
PUSH_USER="${SSD_PUSH_USER:-ssdcollect}"
KEY_PATH="${SSD_PUSH_KEY_PATH:-/root/.ssh/id_ssdpush}"
CONF="${SSD_CONF_PATH:-/etc/ssd-life-expectancy.conf}"
REMOTE_DIR="${SSD_PUSH_DIR:-/srv/ssd-reports/}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -n "$KEY_TEXT" ]   || die "SSD_PUSH_KEY is empty. Put the private key in an RMM secret variable named SSD_PUSH_KEY."
[ -n "$PUSH_HOST" ]  || die "SSD_PUSH_HOST is empty. Set it to your collection host, e.g. mddb."

command -v ssh >/dev/null 2>&1 || die "no ssh client installed on this machine"

# --- install the key -------------------------------------------------------
mkdir -p "$(dirname "$KEY_PATH")" || die "cannot create $(dirname "$KEY_PATH")"
chmod 0700 "$(dirname "$KEY_PATH")"
umask 077
printf '%s\n' "$KEY_TEXT" > "$KEY_PATH" || die "cannot write $KEY_PATH"
# A key file with loose permissions is refused by ssh outright.
chmod 0600 "$KEY_PATH"
say "Installed key at $KEY_PATH"

# --- trust the collection host --------------------------------------------
KNOWN="$(dirname "$KEY_PATH")/known_hosts"
if command -v ssh-keyscan >/dev/null 2>&1; then
  if ssh-keyscan -T 10 -H "$PUSH_HOST" >> "$KNOWN" 2>/dev/null; then
    sort -u "$KNOWN" -o "$KNOWN" 2>/dev/null
    chmod 0600 "$KNOWN"
    say "Recorded host key for $PUSH_HOST"
  else
    say "NOTE: could not reach $PUSH_HOST to record its host key; the first push will accept it instead."
  fi
fi

# --- verify the key actually works ----------------------------------------
# Better to fail here, visibly, than to look fine and then never report.
SSH_OPTS="-i $KEY_PATH -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN"
# shellcheck disable=SC2086
if ssh $SSH_OPTS "${PUSH_USER}@${PUSH_HOST}" true 2>/dev/null; then
  say "Verified: this machine can reach ${PUSH_USER}@${PUSH_HOST}"
  VERIFIED=yes
else
  # A restricted key (command="internal-sftp") refuses a plain ssh command by
  # design, so a failure here is not conclusive. Try an actual file transfer.
  TESTFILE="$(mktemp)"; printf 'ssd-push-test\n' > "$TESTFILE"
  # shellcheck disable=SC2086
  if scp $SSH_OPTS -q "$TESTFILE" "${PUSH_USER}@${PUSH_HOST}:${REMOTE_DIR}.push-test-$(hostname -s 2>/dev/null || echo unknown)" 2>/dev/null; then
    say "Verified: file transfer to ${PUSH_USER}@${PUSH_HOST}:${REMOTE_DIR} works"
    VERIFIED=yes
  else
    say "WARNING: could not reach ${PUSH_USER}@${PUSH_HOST}. The key is installed, but"
    say "         this machine cannot push yet — check that its public key is in that"
    say "         account's authorized_keys and that $REMOTE_DIR is writable."
    VERIFIED=no
  fi
  rm -f "$TESTFILE"
fi

# --- point the reporter at the collection host -----------------------------
TARGET="${PUSH_USER}@${PUSH_HOST}:${REMOTE_DIR}"
if [ -f "$CONF" ]; then
  # Replace any existing setting, then append ours.
  tmp="${CONF}.tmp.$$"
  grep -v '^SSD_PUSH_TARGET=' "$CONF" 2>/dev/null | grep -v '^SSD_PUSH_OPTS=' > "$tmp"
  printf "SSD_PUSH_TARGET='%s'\n" "$TARGET" >> "$tmp"
  printf "SSD_PUSH_OPTS='-i %s -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=%s -o StrictHostKeyChecking=accept-new'\n" "$KEY_PATH" "$KNOWN" >> "$tmp"
  mv -f "$tmp" "$CONF" && chmod 0644 "$CONF"
  say "Updated $CONF -> SSD_PUSH_TARGET=$TARGET"
else
  say "NOTE: $CONF not found — run the SSD installer first, then re-run this."
  say "      Or set SSD_PUSH_TARGET=$TARGET in the installer's config block."
fi

say ""
if [ "${VERIFIED:-no}" = "yes" ]; then
  say "RESULT: OK — this machine is set up to push its SSD reports."
  exit 0
fi
say "RESULT: KEY INSTALLED, PUSH NOT YET WORKING — see the warning above."
exit 1
