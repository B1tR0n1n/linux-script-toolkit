# linux-script-toolkit

Operational Linux scripts for fleet management via [Level.io](https://level.io) (or Ansible, cron, or plain SSH).

| Script | Purpose |
| --- | --- |
| [`scripts/install-ssd-monitor.sh`](scripts/install-ssd-monitor.sh) | **Start here.** One paste: installs deps, installs the reporter, schedules it weekly, runs it now. |
| [`scripts/ssd-life-expectancy.sh`](scripts/ssd-life-expectancy.sh) | The reporter itself. Run it directly if you don't want anything installed. |
| [`scripts/merge-ssd-reports.sh`](scripts/merge-ssd-reports.sh) | Roll individual per-machine CSVs into one master file. |

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

| Drive type | Source of "life remaining" |
| --- | --- |
| NVMe | `Percentage Used` (100 − used), plus `Available Spare` vs its threshold |
| SATA/SAS SSD | First available vendor attribute: `231 SSD_Life_Left`, `233 Media_Wearout_Indicator`, `202 Percent_Lifetime_Remain`, `177 Wear_Leveling_Count`, `173 Ave_Block_Erase_Count`, `169 Remaining_Life` |

Vendors disagree wildly on which attribute means what, so the CSV records a `life_source`
column telling you exactly which attribute produced the number.

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
./scripts/merge-ssd-reports.sh -i ./collected -o fleet-ssd-master.csv --sort-by-life
```

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
est_days_remaining, est_eol_date, est_method, status`

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
