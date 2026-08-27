# linux-script-toolkit

Operational Linux scripts for fleet management via [Level.io](https://level.io) (or Ansible, cron, or plain SSH).

| Script | Purpose |
| --- | --- |
| [`scripts/install-ssd-monitor.sh`](scripts/install-ssd-monitor.sh) | **Start here.** One paste: installs deps, installs the reporter, schedules it weekly, runs it now. |
| [`scripts/ssd-life-expectancy.sh`](scripts/ssd-life-expectancy.sh) | The reporter itself. Run it directly if you don't want anything installed. |
| [`scripts/collect-ssd-output.sh`](scripts/collect-ssd-output.sh) | Build a fleet master CSV from report output you already have (paste Level.io run history in). No SSH. |
| [`scripts/level-api-pull.py`](scripts/level-api-pull.py) | Pull report rows from Level's API and build the fleet CSV in one command. |
| [`scripts/setup-push-key.sh`](scripts/setup-push-key.sh) | RMM script: install the push key on each endpoint and verify it can reach the collector. |
| [`scripts/pull-ssd-reports.sh`](scripts/pull-ssd-reports.sh) | SSH *out* to each machine and fetch its report. Needs an ssh client where you run it. |
| [`scripts/merge-ssd-reports.sh`](scripts/merge-ssd-reports.sh) | Roll individual per-machine CSV files into one master file. |

## Quick start — the whole thing in one paste

Paste [`scripts/install-ssd-monitor.sh`](scripts/install-ssd-monitor.sh) into a Level.io script
(Shell / run as root / target Linux) and run it. It installs `smartmontools` if missing, drops
the reporter at `/usr/local/sbin`, schedules a weekly run, and reports immediately.

For one fleet-wide file, set **one** variable — a path every machine can write to:

```
SSD_MASTER_PATH=/mnt/reports/ssd-life-master.csv
```

Output mode switches to `both` automatically when that is set, so you get the shared master
*and* a local copy on each machine. Running it on 50 machines at once is safe (see
**Fleet master file** below).

Nothing else is required. Everything below is for tuning.

---

## ssd-life-expectancy.sh

Reads SMART data from every non-removable SSD/NVMe, derives **percent life remaining**,
projects **how long the drive has left**, and reports it as a table, CSV, and/or JSON.

### What it measures

| Drive type | Source of "life remaining" | Confidence |
| --- | --- | --- |
| NVMe | `Percentage Used` (100 − used), plus `Available Spare` vs threshold | `high` — defined by the NVMe spec |
| SATA/SAS | `231 SSD_Life_Left`, `233 Media_Wearout_Indicator`, `202 Percent_Lifetime_Remain`, `169 Remaining_Life` | `high` — defined as percent-of-life-remaining |
| SATA/SAS | `177 Wear_Leveling_Count`, `173 Ave_Block-Erase_Count`, `232 Endurance_Remaining`, `209` | `heuristic` — see below |

### Read `life_confidence` before acting on `est_eol_date`

SMART vendor attributes are exactly that — vendor-specific. High-confidence IDs are *defined* as
percent-of-life-remaining and are always tried first. The heuristic tier holds erase-count health
indicators whose normalized value usually tracks remaining life on the families that use them, but
no vendor guarantees it: a value between 0 and 100 is suggestive, not a literal percentage.

A drive read from the heuristic tier is marked `~` in the console table, called out in a note below
it, and carries `life_confidence=heuristic` in the CSV and JSON. **Treat its `est_eol_date` as
indicative, not as a replacement signal** — a believable-but-wrong date is worse than `UNKNOWN`.
The `life_source` column always names the exact attribute used, so any reading can be audited.

### How the projection works

Two methods, best-first:

1. **`calendar`** — the accurate one. The script keeps a small state file
   (`/var/lib/ssd-life-expectancy/state.csv`) recording wear at first run. On later runs it
   measures *actual wear per calendar day* for that machine's real workload and extrapolates.
   Needs two runs at least 7 days apart, so **schedule it weekly and it self-calibrates**.
2. **`power_on_hours`** — the day-one fallback. Extrapolates from lifetime power-on hours.
   Conservative: it assumes the machine runs 24/7, so for a workstation that's off nights and
   weekends the real calendar life is longer than reported.

Projections are capped at 7300 days (20 years) — a "142 year" estimate helps nobody.

### Status and exit codes

Level.io can alert on the exit code:

| Exit | Status | Trigger |
| --- | --- | --- |
| `0` | OK | healthy |
| `1` | WARN | ≤ 20% life left, ≤ 180 days projected, or a drive whose wear data could not be read |
| `2` | CRITICAL | ≤ 10% life left, ≤ 60 days projected, available spare below threshold, or SMART self-assessment `FAILED` |
| `3` | ERROR | not root, `smartctl` missing, or no drives found |

All thresholds are tunable (`--warn-pct`, `--crit-pct`, `--warn-days`, `--crit-days`).

### If your RMM marks the action FAILED

Level.io (and most RMMs) treat any non-zero exit as a failed action, and with **On failure: Fail
pipeline** a worn drive will stop the pipeline. That is the script reporting correctly being read
as an error. Set:

```
SSD_ALWAYS_EXIT_OK=true
```

The script then always exits 0. Drive status still appears in the output and the CSV — alert on
the `RESULT:` line instead of the exit code. Leave it `false` if you *want* to alert on exit codes
and your action is set to tolerate failure.

### Requirements

- **root** (Level.io runs scripts as root by default)
- **`smartmontools`** — the only hard dependency, and the script **installs it for you** if
  missing. It detects the host package manager (`apt-get`, `dnf`, `yum`, `zypper`, `pacman`,
  `apk`, `emerge`), installs, then verifies the binary actually landed. If the install fails it
  prints the package manager's own error output instead of dying silently. Disable with
  `--no-auto-install`.
- Everything else is optional and has a built-in fallback: no `lsblk` → falls back to
  `smartctl --scan`; no `flock` → falls back to atomic `mkdir` locking. The `nvme` kernel module
  is loaded automatically if NVMe devices are present.

---

## Level.io setup

### 1. Create the script

**Scripts → New Script → Shell (bash), Run as: root, Target: Linux.**
Paste the contents of `scripts/ssd-life-expectancy.sh`.

### 2. Pick your output mode

Level.io script variables arrive as environment variables, so you can configure everything
without editing the script.

#### Option A — individual file on each computer (default, no infrastructure needed)

| Variable | Value |
| --- | --- |
| `SSD_OUTPUT_MODE` | `local` |
| `SSD_LOCAL_DIR` | `/var/log/ssd-health` |
| `SSD_FORMAT` | `both` |

Produces `/var/log/ssd-health/md-4004_ssd-health.csv` (and `.json`) on each endpoint.

#### Option B — one master file for the whole fleet

Requires a path every endpoint can write to (NFS/CIFS mount, or a synced directory):

| Variable | Value |
| --- | --- |
| `SSD_OUTPUT_MODE` | `both` |
| `SSD_MASTER_PATH` | `/mnt/reports/ssd-life-master.csv` |

### Fleet master file — concurrent writes

Running on many machines at once is the normal case, and it is safe:

- **Locking adapts to the filesystem.** `flock` on local disks; on NFS/CIFS/SMB — where `flock`
  semantics depend on the server and can silently fail to exclude — it switches to `mkdir`,
  which is atomic by protocol. Force either with `SSD_LOCK_STRATEGY=flock|mkdir`.
- **A broken `flock` never costs you a row.** If `flock` is missing or the filesystem refuses
  the lock, it falls back to `mkdir` instead of skipping the write.
- **Stale locks self-heal.** A run killed mid-write would otherwise block the whole fleet
  forever; a lock older than `SSD_STALE_LOCK_SECS` (default 300) is broken automatically.
- **One row per drive per machine.** Each machine replaces its own previous row rather than
  appending, so the file does not grow with every run.

Verified with 30 machines running the installer simultaneously against one master file: 60 rows,
30 machines, 1 header, zero malformed rows, zero duplicates — on both locking strategies, and
with `flock` deliberately broken.

#### Option C — no shared mount? Let Level.io collect it

Set `SSD_OUTPUT_MODE=local` and `SSD_EMIT_CSV=true`. The script prints raw CSV rows to stdout,
which Level.io captures as the script's output — copy them out of the run history, or collect
the local files later and merge them:

```bash
# From Level.io run history: select the output, save it, and feed it in.
./scripts/collect-ssd-output.sh runs.txt -o fleet-ssd-master.csv

# Or from collected per-machine files
./scripts/merge-ssd-reports.sh -i ./collected -o fleet-ssd-master.csv --sort-by-life
```

### Four ways to get one fleet CSV — pick by what you have

| You have | Use | Needs | Scales to |
| --- | --- | --- | --- |
| A shared mount every machine can write to | `SSD_MASTER_PATH` | NFS/CIFS mount | any size |
| **One Linux box the machines can SSH to** | **`SSD_PUSH_TARGET`** | **an ssh key per endpoint** | **any size** |
| SSH access *out* to the machines | `pull-ssd-reports.sh` | ssh + scp, a host list | hundreds |
| **A Level API key** | **`level-api-pull.py`** | **an API key** | **any size** |
| Only the RMM's run output | `collect-ssd-output.sh` | nothing | tens |

### Level API — one command, nothing to install on the endpoints

Level's API exposes each automation run's step output, which is where the emitted CSV row
lands. `level-api-pull.py` (stdlib Python 3 only) lists the runs, fetches each with
`include_steps=true`, extracts the row from the output text, and writes the fleet CSV.

```bash
export LEVEL_API_KEY=xxxxx                       # Settings -> API keys
./scripts/level-api-pull.py --automation-id <id> -o fleet-ssd-master.csv
```

```
Listed 900 automation run(s)
  ... 450/900 runs fetched
898 drive(s) across 898 machine(s) -> fleet-ssd-master.csv
  CRITICAL: 41
  WARN:     117
  2 run(s) produced no row — see fleet-ssd-master-missing.txt
```

Requires `SSD_EMIT_CSV=true`, since the row has to be in the run's output to reach the API.

The `Authorization` header value format is not documented, so the script sends the raw key
first and retries as `Bearer <key>` on a 401, then remembers which worked. If the run-list
endpoint differs from `/v2/automation-runs`, pass `--list-path`; if listing is unavailable
entirely, `--run-ids-file` takes a list of run ids instead. `--save-raw` dumps every step's
output for troubleshooting.

Runs that produced no row are written to `<output>-missing.txt` rather than being counted as
absent — a machine quietly missing from the fleet file is how a dying drive hides.

### No shared mount? Push to a collection host

Each machine scp's its own report to one server after every run. There is no share to
maintain, and no central box fanning SSH out to every endpoint — the traffic is one small
file per machine, outbound, on the machine's own schedule. This is the option that scales
when a mount is not available.

In the installer:

```bash
: "${SSD_PUSH_TARGET:=ssdcollect@mddb:/srv/ssd-reports/}"
```

Report filenames are keyed on asset id, so they land side by side without collisions.
Build the master on the collection host, from the same directory:

```bash
./collect-ssd-output.sh /srv/ssd-reports -o fleet-ssd-master.csv
```

Everything below runs as RMM scripts — you never need an SSH client on your own
workstation, and you never SSH to an endpoint by hand.

**1. On the collection host** (once, by hand):

```bash
sudo useradd -m -d /srv/ssd-collect -s /bin/bash ssdcollect
sudo mkdir -p /srv/ssd-reports && sudo chown ssdcollect /srv/ssd-reports
sudo -u ssdcollect ssh-keygen -t ed25519 -N '' -f /tmp/ssdpush   # one key for the fleet
sudo -u ssdcollect mkdir -p /srv/ssd-collect/.ssh
# Restrict the key so it can only move files — no shell, no forwarding:
printf 'command="internal-sftp",restrict %s\n' "$(cat /tmp/ssdpush.pub)" \
  | sudo -u ssdcollect tee -a /srv/ssd-collect/.ssh/authorized_keys
sudo -u ssdcollect chmod 700 /srv/ssd-collect/.ssh
sudo -u ssdcollect chmod 600 /srv/ssd-collect/.ssh/authorized_keys
cat /tmp/ssdpush     # the private key — paste into an RMM secret variable, then delete it
```

One shared key across the fleet is the practical choice at hundreds of machines. The
`command="internal-sftp",restrict` prefix is what makes that acceptable: the key can move
files and nothing else, even if an endpoint is compromised.

**2. Deploy it to the fleet** with [`scripts/setup-push-key.sh`](scripts/setup-push-key.sh)
as an RMM script, with these variables:

| Variable | Value |
| --- | --- |
| `SSD_PUSH_KEY` | the private key text — use a **secret** variable |
| `SSD_PUSH_HOST` | `mddb` |
| `SSD_PUSH_USER` | `ssdcollect` |

It installs the key at `/root/.ssh/id_ssdpush` with `0600`, records the host key, **verifies
the machine can actually reach the collector**, and writes `SSD_PUSH_TARGET` into
`/etc/ssd-life-expectancy.conf` so scheduled runs push too. It exits 1 if the push does not
work, so a machine that silently would never report shows as a failed action instead.

**3. Build the master** on the collection host whenever you want it:

```bash
./collect-ssd-output.sh /srv/ssd-reports -o fleet-ssd-master.csv
```

<details><summary>Manual collector setup, the long way</summary>

```bash
# on the collector
sudo useradd -m -d /srv/ssd-collect -s /bin/bash ssdcollect
sudo mkdir -p /srv/ssd-reports && sudo chown ssdcollect /srv/ssd-reports

# on each endpoint — deploy the key via your RMM
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519    # if it has no key
# then add each endpoint's public key to /srv/ssd-collect/.ssh/authorized_keys
```

Give that account nothing beyond write access to the report directory. It is reachable
from every endpoint in the fleet, so it should not be able to do anything else.
</details>

A failed push is reported as a warning on the endpoint and in the RMM output — a machine
silently missing from the fleet view is how a dying drive stays hidden. `SSD_PUSH_RETRIES`
(default 2) controls retries with backoff.

### collect-ssd-output.sh

Takes emitted report rows out of whatever surrounds them — including an RMM's
**export of run results**, where each device's whole output sits inside one quoted CSV
cell. Rows are found wherever they appear on a line, so the export's own columns in
front of them (`md4065,Linux Devices,Success,5,<row>`) do not matter. Level.io wraps every
output line in markdown fences and interleaves install chatter, so rows are found by
shape — an ISO-8601 timestamp in field 1 and the right column count — rather than by
position. Everything else is ignored.

```bash
./scripts/collect-ssd-output.sh runs.txt                 # a saved run log
./scripts/collect-ssd-output.sh ./logs -o fleet.csv      # a directory of logs
./scripts/collect-ssd-output.sh ./logs runs.txt          # any mix
pbpaste | ./scripts/collect-ssd-output.sh                # straight off the clipboard
./scripts/collect-ssd-output.sh results-export.csv       # an RMM run-results export
```

It keeps the newest row per physical drive (asset_id + serial, same key the reporter
uses), sorts worst-drive-first by default — `--by-asset` or `--by-date` to change —
and prints a replacement queue. Drives with no reading sort last rather than as 0%.
Exits 2 if anything is CRITICAL, 1 for WARN, 0 otherwise.

### pull-ssd-reports.sh

Goes and gets the files instead of waiting for you to paste them. SSHes to each host,
copies `/var/log/ssd-health/*_ssd-health.csv`, then hands everything to
`collect-ssd-output.sh` for the same dedupe and sort.

```bash
./scripts/pull-ssd-reports.sh -H hosts.txt -o fleet-ssd-master.csv
./scripts/pull-ssd-reports.sh md4004 md4006 md4065        # hosts inline
./scripts/pull-ssd-reports.sh -H hosts.txt -u svcacct     # a specific ssh user
./scripts/pull-ssd-reports.sh -H hosts.txt --run          # re-run the reporter first, then pull
```

The host file is one name per line; blanks and `#` comments are ignored. Transfers run
8 at a time (`-j`), and hosts that cannot be reached or have no report are listed with
the reason rather than silently dropped — a machine missing from the master file is
the kind of gap that hides a dying drive.

### 3. Create the automation

**Automations → New → Trigger: Schedule (weekly is ideal — it lets the calendar projection
self-calibrate) → Action: Run Script → target your device group.**

To alert on failing drives, add a condition on the script's **exit code ≥ 1** (WARN) or
**= 2** (CRITICAL).

### 4. Naming conventions (`md-4004`)

The script extracts an **asset ID** from the hostname and uses it as the report key and
filename, so `md-4004.corp.local` becomes asset `md-4004` and file `md-4004_ssd-health.csv`.

Default pattern is `[A-Za-z]{2,6}-?[0-9]{2,6}` — the hyphen is optional, so it matches both
`md-4004` and `md4065`, plus `wks-12`, `srv100234`.
Override with `SSD_HOST_REGEX` if your convention differs. If nothing matches, the full
hostname is used, so it never fails closed.

---

## Output

### Console (what you see in the Level.io run output)

```
SSD Life Expectancy — md-4004 (md-4004.corp.local) — 2026-08-27T16:04:51Z
DEVICE       TYPE   MODEL                    SERIAL               LIFE  EST_LEFT  EOL_DATE   STATUS
------------------------------------------------------------------------------------------------
nvme0n1      NVMe   Samsung SSD 980 PRO 1TB  S5GXNX0T123456A       93%     7300d  2046-08-22 OK
sda          SSD    Crucial_CT500MX500SSD1   1902E1F2A3B4          14%      261d  2027-05-15 WARN (14% life left)

RESULT: WARN — at least one drive is wearing out (2 scanned)
```

### CSV columns

`timestamp, asset_id, hostname, device, protocol, model, serial, firmware, capacity_gb,
media_type, smart_status, life_remaining_pct, life_used_pct, life_source, available_spare_pct,
power_on_hours, temperature_c, data_written_tb, error_count, wear_pct_per_year,
est_days_remaining, est_eol_date, est_method, status, life_confidence`

Rows in the master file are keyed on **asset_id + serial**, not the device node, so a disk that
Linux enumerates as `/dev/sda` today and `/dev/sdb` after a reboot stays one row instead of
becoming a phantom second drive. The node is the key only when the serial is unreadable.

Drops straight into Excel or Google Sheets — sort by `life_remaining_pct` ascending to get your
replacement queue.

---

## Options

Every option is a flag **or** an environment variable (use env vars in Level.io).

| Flag | Env var | Default | Description |
| --- | --- | --- | --- |
| `--output-mode` | `SSD_OUTPUT_MODE` | `local` | `local` \| `master` \| `both` \| `none` |
| `--local-dir` | `SSD_LOCAL_DIR` | `/var/log/ssd-health` | per-machine report directory |
| `--local-name` | `SSD_LOCAL_NAME` | `<asset_id>_ssd-health` | per-machine filename |
| `--master-path` | `SSD_MASTER_PATH` | — | shared master CSV |
| `--format` | `SSD_FORMAT` | `csv` | `csv` \| `json` \| `both` |
| `--append-history` | `SSD_APPEND_HISTORY` | `false` | append to local file to build a trend log |
| `--emit-csv` | `SSD_EMIT_CSV` | `false` | print CSV rows to stdout |
| `--quiet` | `SSD_QUIET` | `false` | suppress the summary table |
| `--always-exit-ok` | `SSD_ALWAYS_EXIT_OK` | `false` | always exit 0, for RMMs that fail an action on non-zero exit |
| `--push-target` | `SSD_PUSH_TARGET` | — | scp the report to `user@host:/path/` after writing it |
| `--include-hdd` | `SSD_INCLUDE_HDD` | `false` | also report spinning disks |
| `--devices` | `SSD_DEVICES` | autodetect | explicit device list |
| `--hostname` | `SSD_HOSTNAME` | detected | override hostname |
| `--host-regex` | `SSD_HOST_REGEX` | `[A-Za-z]{2,6}-?[0-9]{2,6}` | asset-id extraction |
| `--debug` | `SSD_DEBUG` | `false` | dump raw smartctl output per drive |
| `--unknown-ok` | `SSD_UNKNOWN_IS_WARN` | `true` | treat unreadable drives as OK instead of WARN |
| `--no-enable-smart` | `SSD_ENABLE_SMART` | `true` | don't run `smartctl -s on` when a drive has SMART disabled |
| `--warn-pct` | `SSD_WARN_PCT` | `20` | WARN at/below this % life left |
| `--crit-pct` | `SSD_CRIT_PCT` | `10` | CRITICAL at/below this % |
| `--warn-days` | `SSD_WARN_DAYS` | `180` | WARN at/below projected days |
| `--crit-days` | `SSD_CRIT_DAYS` | `60` | CRITICAL at/below projected days |
| `--no-auto-install` | `SSD_AUTO_INSTALL` | `true` | don't install smartmontools |
| `--state-file` | `SSD_STATE_FILE` | `/var/lib/ssd-life-expectancy/state.csv` | wear-rate history |

---

## Examples

```bash
# Default: local CSV + JSON per machine
sudo ./scripts/ssd-life-expectancy.sh --format both

# Fleet master on a shared mount, plus a local copy
sudo ./scripts/ssd-life-expectancy.sh --output-mode both \
     --master-path /mnt/reports/ssd-life-master.csv

# Aggressive thresholds for a critical server group
sudo ./scripts/ssd-life-expectancy.sh --warn-pct 30 --crit-pct 15 --warn-days 365

# Include HDDs, and build a local trend log over time
sudo ./scripts/ssd-life-expectancy.sh --include-hdd --append-history

# Just print CSV, write nothing to disk
sudo ./scripts/ssd-life-expectancy.sh --output-mode none --emit-csv --quiet
```

---

## Caveats

- **Virtual disks report nothing.** VMs (virtio/vmdk) have no SMART data; the script lists them
  under "Skipped" with the reason rather than failing silently.
- **USB enclosures** often need an explicit device type. The script already retries with
  `-d sat`, `-d nvme`, `-d scsi`, and `-d auto` before giving up.
- **Partitions are fine to pass.** `/dev/sda1` resolves to its parent disk `/dev/sda`
  automatically (SMART lives on the disk, not the partition), and multiple partitions of the
  same disk are only reported once.
- **Hardware RAID** hides member drives. Point at them explicitly, e.g.
  `--devices "/dev/bus/0"` with a controller-aware smartctl type.
- **Scheduled runs get the full config.** The installer persists every reporter variable to
  `/etc/ssd-life-expectancy.conf`, single-quoted and escaped, so a Level.io variable set at install
  time still applies when the timer fires next Sunday. Paths containing spaces, `#`, `$`, or quotes
  round-trip correctly, in both the config file and the generated cron line.
- **Drives that expose no wear attribute** are reported as `UNKNOWN` and count as **WARN**, never
  as healthy — a drive you cannot read is not a drive you know is fine. Pass `--unknown-ok` if you
  would rather they stay silent. Check the `life_source` column to see which attribute was used.
- **Old smartctl versions** (confirmed on smartctl 6.6 / Ubuntu 20.04 with Crucial MX500) can
  answer `smartctl -a` with the identity and health blocks but **silently omit the attribute
  table**, even though `smartctl -A` returns it fine. `-a` is documented as a superset of `-A`,
  so this is easy to get wrong. The script therefore never trusts `-a` alone: if the attribute
  table is missing it re-asks with an explicit `-A` before giving up.
- **Attribute names may read `Unknown_Attribute`** on an smartctl older than the drive. That is
  cosmetic — the lookup matches on attribute **ID**, not name, so wear is still read correctly.

## Troubleshooting a drive that reports UNKNOWN

An `UNKNOWN` drive now **states its own reason** in the normal output — no debug run needed:

| Reason shown | Meaning |
| --- | --- |
| `SMART is disabled on the drive` | SMART is off in firmware. The script runs `smartctl -s on` and re-reads automatically (disable with `--no-enable-smart`). |
| `no known wear attribute among IDs: 9 194 250` | The attribute table was read, but none of the listed IDs is a recognized wear counter. Send that ID list and it can be added. |
| `no attribute table returned (best probe: ...)` | No device type produced an attribute table. Names the probe that got furthest. |
| `drive/controller does not support SMART` | Pass-through is blocked, typically by a RAID controller. |

For the full dump:

```bash
sudo ./scripts/ssd-life-expectancy.sh --debug --output-mode none
```

This prints the winning `smartctl` invocation, the full raw output, and the parsed attribute
table for each drive. If the attribute table is empty, the drive or controller is not exposing
one; if it has rows but no wear attribute was matched, send the dump so the attribute can be
added to the lookup list.
