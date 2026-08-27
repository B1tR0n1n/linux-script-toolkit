#!/usr/bin/env python3
"""
level-api-pull.py — pull SSD report rows out of Level automation runs and
build the fleet master CSV in one command.

Uses only the Python standard library.

    export LEVEL_API_KEY=xxxxx
    ./level-api-pull.py --automation-id <id> -o fleet-ssd-master.csv

What it does:
  1. lists automation runs (optionally filtered to one automation)
  2. fetches each run with include_steps=true
  3. pulls the report row out of each step's `output` text
  4. writes the fleet CSV, newest row per drive, worst drive first

The row is located by shape - an ISO-8601 timestamp and the right column
count - so the surrounding install chatter and table output are ignored, and
the same file works whether the output came from here, a run log, or a
report file copied off an endpoint.
"""
import argparse, json, os, re, ssl, sys, urllib.error, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

NCOL = 25
HEADER = ("timestamp,asset_id,hostname,device,protocol,model,serial,firmware,capacity_gb,"
          "media_type,smart_status,life_remaining_pct,life_used_pct,life_source,"
          "available_spare_pct,power_on_hours,temperature_c,data_written_tb,error_count,"
          "wear_pct_per_year,est_days_remaining,est_eol_date,est_method,status,life_confidence")
ROW_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z,")

class ApiError(Exception):
    pass

class Level:
    def __init__(self, key, base, verbose=False, insecure=False):
        self.key, self.base, self.verbose = key, base.rstrip("/"), verbose
        # The docs show an "Authorization" header but not its value format, so
        # try the raw key first and fall back to Bearer on a 401 rather than
        # guessing one and failing with an unhelpful error.
        self.scheme = None
        self.ctx = ssl._create_unverified_context() if insecure else None

    def _open(self, url, scheme):
        auth = self.key if scheme == "raw" else f"Bearer {self.key}"
        req = urllib.request.Request(url, headers={
            "Authorization": auth, "Accept": "application/json",
            "User-Agent": "ssd-life-expectancy/level-api-pull",
        })
        return urllib.request.urlopen(req, timeout=60, context=self.ctx)

    def get(self, path, params=None):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        schemes = [self.scheme] if self.scheme else ["raw", "bearer"]
        last = None
        for sc in schemes:
            try:
                with self._open(url, sc) as r:
                    body = r.read().decode("utf-8", "replace")
                self.scheme = sc          # remember what worked
                if self.verbose:
                    print(f"  GET {url} -> 200", file=sys.stderr)
                return json.loads(body)
            except urllib.error.HTTPError as e:
                last = e
                if e.code == 401 and sc == "raw" and len(schemes) > 1:
                    continue              # try Bearer
                detail = e.read().decode("utf-8", "replace")[:300]
                raise ApiError(f"HTTP {e.code} for {url}\n    {detail}") from None
            except urllib.error.URLError as e:
                raise ApiError(f"cannot reach {url}: {e.reason}") from None
        raise ApiError(f"authentication failed for {url}: {last}")

def walk_runs(api, list_path, automation_id, page_size, max_pages, verbose):
    """Yield run summaries. Pagination style is discovered, not assumed."""
    seen, page = [], 1
    params = {}
    if automation_id:
        params["automation_id"] = automation_id
        if verbose:
            print(f"  filtering on automation_id={automation_id}", file=sys.stderr)
    while page <= max_pages:
        p = dict(params)
        p["page"], p["per_page"] = page, page_size
        data = api.get(list_path, p)
        # Accept the common envelope shapes rather than requiring one.
        if isinstance(data, list):
            items = data
        elif isinstance(data, dict):
            items = next((data[k] for k in ("data", "items", "results", "automation_runs", "runs")
                          if isinstance(data.get(k), list)), None)
            if items is None:
                raise ApiError("could not find a list of runs in the response. "
                               f"Top-level keys were: {sorted(data.keys())}\n"
                               "    Re-run with --list-path if the endpoint differs.")
        else:
            raise ApiError(f"unexpected response type: {type(data).__name__}")
        if not items:
            break
        seen.extend(items)
        if verbose:
            print(f"  page {page}: {len(items)} run(s)", file=sys.stderr)
        if len(items) < page_size:
            break
        page += 1
    return seen

def extract_rows(text):
    """Pull report rows out of arbitrary output text."""
    out = []
    for line in text.splitlines():
        line = line.replace('""', '"').strip().strip('"').strip()
        m = ROW_RE.search(line)
        if not m:
            continue
        cand = line[m.start():]
        f = cand.split(",")
        if len(f) == NCOL:
            out.append(cand)
        elif len(f) > NCOL:
            out.append(",".join(f[:NCOL]))   # drop trailing text on the line
    return out

def id_variants(raw):
    """Return the plausible forms of an id.

    Ids copied from the web UI are base64 of a GraphQL global id, e.g.
    Z2lk... decodes to "gid://level/Automation/180096". The API may want that
    base64 form, the decoded gid, or the bare numeric id at the end, and the
    docs do not say which - so try all three rather than assume.
    """
    if not raw:
        return []
    out = [raw]
    try:
        import base64
        padded = raw + "=" * (-len(raw) % 4)
        dec = base64.b64decode(padded).decode("utf-8")
        if dec.startswith("gid://"):
            out.append(dec)
            tail = dec.rstrip("/").rsplit("/", 1)[-1]
            if tail.isdigit():
                out.append(tail)
    except Exception:
        pass
    return out

def discover(api, automation_id):
    """Probe candidate endpoints and report what the account can actually see.

    The docs published a "Show automation run" endpoint but not a way to list
    runs, and /v2/automation-runs returns 404. Rather than guess one path at a
    time across round-trips, try the plausible ones and report the results.
    """
    variants = id_variants(automation_id)
    if len(variants) > 1:
        print("Automation id forms to try (web-UI ids are base64 of a gid):")
        for v in variants:
            print(f"  {v}")
        print()
    candidates = [
        "/v2/devices",                                   # known-good, proves auth
        "/v2/automations",
        "/v2/automation-runs",
        "/v2/automation_runs",
        "/v2/runs",
        "/v1/automation-runs",
        "/v2/scripts",
        "/v2/script-runs",
    ]
    for v in variants:
        candidates += [
            f"/v2/automations/{v}",
            f"/v2/automations/{v}/runs",
            f"/v2/automations/{v}/automation-runs",
            f"/v2/automations/{v}/history",
        ]
    print("Probing endpoints (200 = exists, 404 = no such path, 401 = auth problem)\n")
    found = []
    for path in candidates:
        if "{automation_id}" in path:
            print(f"  {'skip':<5}  {path}   (pass --automation-id to test this one)")
            continue
        try:
            data = api.get(path, {"page": 1, "per_page": 1})
            keys = sorted(data.keys()) if isinstance(data, dict) else f"list[{len(data)}]"
            print(f"  {'200':<5}  {path}   -> {keys}")
            found.append(path)
        except ApiError as e:
            first = str(e).splitlines()[0]
            code = first.split()[1] if first.startswith("HTTP") else "err"
            print(f"  {code:<5}  {path}")
    print()
    if found:
        print("Endpoints that responded:")
        for f in found:
            print(f"  {f}")
        print("\nIf one of these lists automation runs, re-run with:")
        print(f"  --list-path {found[-1]}")
    else:
        print("Nothing responded. Check the API key and the base URL.")
    print("\nIf none of these is right, look in the API docs sidebar under")
    print("Automations for whatever sits next to 'Show automation run'.")

def main():
    ap = argparse.ArgumentParser(description="Build the SSD fleet CSV from Level automation runs.")
    ap.add_argument("-o", "--output", default="fleet-ssd-master.csv")
    ap.add_argument("--automation-id", help="only pull runs for this automation")
    ap.add_argument("--run-ids-file", help="skip listing; read run ids from this file, one per line")
    ap.add_argument("--base", default=os.environ.get("LEVEL_API_BASE", "https://api.level.io"))
    ap.add_argument("--list-path", default="/v2/automation-runs")
    ap.add_argument("--show-path", default="/v2/automation-runs/{id}")
    ap.add_argument("--page-size", type=int, default=100)
    ap.add_argument("--max-pages", type=int, default=200)
    ap.add_argument("-j", "--jobs", type=int, default=16)
    ap.add_argument("--save-raw", help="also write every step output here, for troubleshooting")
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--discover", action="store_true",
                    help="probe likely endpoints and report which ones exist, then stop")
    args = ap.parse_args()

    key = os.environ.get("LEVEL_API_KEY", "")
    if not key:
        sys.exit("ERROR: set LEVEL_API_KEY (Settings -> API keys in Level).")

    api = Level(key, args.base, args.verbose, args.insecure)

    if args.discover:
        discover(api, args.automation_id)
        return

    # --- which runs -------------------------------------------------------
    try:
        if args.run_ids_file:
            with open(args.run_ids_file) as fh:
                ids = [l.split("#")[0].strip() for l in fh]
            ids = [i for i in ids if i]
            print(f"Reading {len(ids)} run id(s) from {args.run_ids_file}")
        else:
            runs = walk_runs(api, args.list_path, args.automation_id,
                             args.page_size, args.max_pages, args.verbose)
            ids = [r.get("id") for r in runs if isinstance(r, dict) and r.get("id")]
            print(f"Listed {len(ids)} automation run(s)")
    except ApiError as e:
        sys.exit(f"ERROR: {e}")

    if not ids:
        sys.exit("ERROR: no automation runs found. Check --automation-id, or pass --run-ids-file.")

    # --- fetch each run's steps ------------------------------------------
    rows, failed, raw_chunks = [], [], []
    def fetch(run_id):
        path = args.show_path.replace("{id}", urllib.parse.quote(str(run_id)))
        return run_id, api.get(path, {"include_steps": "true"})

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for i, res in enumerate(pool.map(lambda r: _safe(fetch, r), ids), 1):
            run_id, data, err = res
            if err:
                failed.append((run_id, err)); continue
            host = data.get("device_hostname") or data.get("device_id") or run_id
            text = "\n".join(s.get("output") or "" for s in (data.get("steps") or [])
                             if isinstance(s, dict))
            if args.save_raw:
                raw_chunks.append(f"===== {host} ({run_id}) =====\n{text}\n")
            got = extract_rows(text)
            if got:
                rows.extend(got)
            else:
                failed.append((host, "no report row in output"))
            if i % 50 == 0:
                print(f"  ... {i}/{len(ids)} runs fetched", file=sys.stderr)

    if args.save_raw:
        with open(args.save_raw, "w") as fh:
            fh.write("\n".join(raw_chunks))
        print(f"Raw step output written to {args.save_raw}")

    if not rows:
        print("ERROR: fetched runs but found no report rows.", file=sys.stderr)
        print("       The reporter must run with SSD_EMIT_CSV=true for its rows to reach the API.",
              file=sys.stderr)
        if failed[:3]:
            print("       First few problems: " + "; ".join(f"{h}: {e}" for h, e in failed[:3]),
                  file=sys.stderr)
        sys.exit(2)

    # --- newest row per drive, worst first --------------------------------
    rows.sort(key=lambda r: r.split(",")[0], reverse=True)
    best, seen = [], set()
    for r in rows:
        f = r.split(",")
        serial = f[6]
        key_ = (f[1], f[3]) if (not serial or serial.lower().startswith("unknown")) else (f[1], serial)
        if key_ in seen:
            continue
        seen.add(key_); best.append(r)

    def life(r):
        v = r.split(",")[11]
        return 9999 if v == "" else int(float(v))    # unreadable drives sort last
    best.sort(key=life)

    with open(args.output, "w") as fh:
        fh.write(HEADER + "\n")
        fh.write("\n".join(best) + "\n")

    crit = sum(1 for r in best if r.split(",")[23] == "CRITICAL")
    warn = sum(1 for r in best if r.split(",")[23] == "WARN")
    unk  = sum(1 for r in best if r.split(",")[23] == "UNKNOWN")
    print(f"\n{len(best)} drive(s) across {len({r.split(',')[1] for r in best})} machine(s) -> {args.output}")
    if crit: print(f"  CRITICAL: {crit}")
    if warn: print(f"  WARN:     {warn}")
    if unk:  print(f"  UNKNOWN:  {unk}  (could not read wear data)")
    if failed:
        # A machine absent from the fleet file is how a dying drive hides, so
        # name what did not make it rather than reporting only successes.
        miss = args.output.rsplit(".", 1)[0] + "-missing.txt"
        with open(miss, "w") as fh:
            fh.write("\n".join(f"{h}\t{e}" for h, e in failed) + "\n")
        print(f"  {len(failed)} run(s) produced no row — see {miss}")

    if crit: sys.exit(2)
    if warn: sys.exit(1)
    sys.exit(0)

def _safe(fn, arg):
    try:
        rid, data = fn(arg)
        return rid, data, None
    except Exception as e:
        return arg, None, str(e)

if __name__ == "__main__":
    main()
