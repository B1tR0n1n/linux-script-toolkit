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
import argparse, json, os, re, ssl, sys, time, urllib.error, urllib.parse, urllib.request
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

    def post(self, path, body=None):
        url = self.base + path
        data = json.dumps(body or {}).encode("utf-8")
        schemes = [self.scheme] if self.scheme else ["raw", "bearer"]
        for sc in schemes:
            auth = self.key if sc == "raw" else f"Bearer {self.key}"
            req = urllib.request.Request(url, data=data, method="POST", headers={
                "Authorization": auth, "Accept": "application/json",
                "Content-Type": "application/json",
                "User-Agent": "ssd-life-expectancy/level-api-pull",
            })
            try:
                with urllib.request.urlopen(req, timeout=120, context=self.ctx) as r:
                    out = json.loads(r.read().decode("utf-8", "replace"))
                self.scheme = sc
                if self.verbose:
                    print(f"  POST {url} -> 200", file=sys.stderr)
                return out
            except urllib.error.HTTPError as e:
                if e.code == 401 and sc == "raw" and len(schemes) > 1:
                    continue
                detail = e.read().decode("utf-8", "replace")[:400]
                raise ApiError(f"HTTP {e.code} for POST {url}\n    {detail}") from None
            except urllib.error.URLError as e:
                raise ApiError(f"cannot reach {url}: {e.reason}") from None
        raise ApiError(f"authentication failed for POST {url}")

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

TERMINAL = {"success", "warning", "error", "canceled"}

def all_pages(api, path, page_size=100, max_pages=200, verbose=False):
    """Walk a {data, has_more} collection."""
    items, page = [], 1
    while page <= max_pages:
        d = api.get(path, {"page": page, "per_page": page_size})
        batch = d.get("data") if isinstance(d, dict) else d
        if not batch:
            break
        items.extend(batch)
        if verbose:
            print(f"  {path} page {page}: {len(batch)}", file=sys.stderr)
        if isinstance(d, dict) and not d.get("has_more"):
            break
        if len(batch) < page_size:
            break
        page += 1
    return items

def trigger_runs(api, token, device_ids, verbose):
    """POST the webhook and return the run ids it creates.

    There is no endpoint that lists past runs, so this is how run ids are
    obtained: triggering returns one run per device it started.
    """
    body = {}
    if device_ids:
        body["device_ids"] = device_ids
    data = api.post(f"/v2/automations/webhooks/{urllib.parse.quote(token)}", body)
    runs = data.get("runs") if isinstance(data, dict) else None
    if not isinstance(runs, list):
        raise ApiError("the webhook responded but returned no 'runs' array; "
                       f"got keys {sorted(data.keys()) if isinstance(data, dict) else type(data).__name__}")
    return [(r.get("id"), r.get("device_id")) for r in runs if isinstance(r, dict) and r.get("id")]

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
            # Print one record's fields. The whole problem is that ids in the
            # web UI do not match the API's, and a sample answers that
            # immediately instead of costing another exchange.
            items = data.get("data") if isinstance(data, dict) else data
            if isinstance(items, list) and items and isinstance(items[0], dict):
                rec = items[0]
                print(f"         sample fields: {sorted(rec.keys())}")
                for k in ("id", "name", "hostname", "automation_id", "status"):
                    if k in rec:
                        print(f"           {k} = {rec[k]!r}")
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
    ap.add_argument("--trigger-token", help="webhook token: trigger the automation, then collect its runs")
    ap.add_argument("--device-ids-file", help="restrict the trigger to these device ids, one per line")
    ap.add_argument("--all-devices", action="store_true",
                    help="with --trigger-token, trigger every device the API lists")
    ap.add_argument("--wait", type=int, default=900,
                    help="seconds to wait for triggered runs to finish (default 900)")
    ap.add_argument("--poll-every", type=int, default=10, help="seconds between polls (default 10)")
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
    ap.add_argument("--dump", metavar="PATH",
                    help="GET this path and print the raw JSON, then stop (e.g. /v2/automations)")
    args = ap.parse_args()

    key = os.environ.get("LEVEL_API_KEY", "")
    if not key:
        sys.exit("ERROR: set LEVEL_API_KEY (Settings -> API keys in Level).")

    api = Level(key, args.base, args.verbose, args.insecure)

    if args.dump:
        try:
            data = api.get(args.dump, {"page": 1, "per_page": args.page_size})
        except ApiError as e:
            sys.exit(f"ERROR: {e}")
        print(json.dumps(data, indent=2)[:20000])
        return

    if args.discover:
        discover(api, args.automation_id)
        return

    # --- which runs -------------------------------------------------------
    triggered = False
    try:
        if args.trigger_token:
            device_ids = []
            if args.device_ids_file:
                with open(args.device_ids_file) as fh:
                    device_ids = [l.split("#")[0].strip() for l in fh]
                device_ids = [d for d in device_ids if d]
                print(f"Triggering for {len(device_ids)} device(s) from {args.device_ids_file}")
            elif args.all_devices:
                devs = all_pages(api, "/v2/devices", args.page_size, args.max_pages, args.verbose)
                device_ids = [d.get("id") for d in devs if isinstance(d, dict) and d.get("id")]
                print(f"Triggering for {len(device_ids)} device(s) from /v2/devices")
            else:
                print("Triggering the webhook (its own conditions decide the devices)")
            pairs = trigger_runs(api, args.trigger_token, device_ids, args.verbose)
            ids = [i for i, _ in pairs]
            triggered = True
            print(f"Triggered {len(ids)} run(s)")
        elif args.run_ids_file:
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

    # A run triggered a moment ago is queued, and its output does not exist
    # yet. Poll until every run reaches a terminal state, or the wait budget
    # runs out - reading too early would report the whole fleet as row-less.
    results = {}
    pending = list(ids)
    if triggered:
        deadline = time.time() + args.wait
        while pending:
            with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
                for run_id, data, err in pool.map(lambda r: _safe(fetch, r), pending):
                    if err:
                        results[run_id] = (None, err)
                    else:
                        st = (data or {}).get("status", "")
                        if st in TERMINAL:
                            results[run_id] = (data, None)
                        # else leave it pending
            pending = [i for i in pending if i not in results]
            if not pending:
                break
            if time.time() >= deadline:
                for i in pending:
                    results[i] = (None, f"still running after {args.wait}s")
                break
            print(f"  {len(results)}/{len(ids)} finished, waiting on {len(pending)}...",
                  file=sys.stderr)
            time.sleep(args.poll_every)
    else:
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            for run_id, data, err in pool.map(lambda r: _safe(fetch, r), pending):
                results[run_id] = (data, err)

    for i, run_id in enumerate(ids, 1):
        data, err = results.get(run_id, (None, "not fetched"))
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

    if args.save_raw:
        with open(args.save_raw, "w") as fh:
            fh.write("\n".join(raw_chunks))
        print(f"Raw step output written to {args.save_raw}")

    if not rows:
        # Name the actual cause. "no rows" from runs that simply had not
        # finished is a different problem from runs that finished without
        # emitting anything, and blaming the wrong one sends you the wrong way.
        unfinished = sum(1 for _, e in failed if "still running" in str(e))
        print("ERROR: no report rows found.", file=sys.stderr)
        if unfinished:
            print(f"       {unfinished} of {len(failed)} run(s) had not finished within the wait.",
                  file=sys.stderr)
            print(f"       Raise the budget, e.g. --wait {max(args.wait * 3, 900)}.", file=sys.stderr)
        else:
            print("       The runs finished but their output carried no CSV row.", file=sys.stderr)
            print("       Set SSD_EMIT_CSV=true in the installer - the row has to be in the", file=sys.stderr)
            print("       run's output to reach the API. --save-raw shows what came back.", file=sys.stderr)
        if failed[:3]:
            print("       First few: " + "; ".join(f"{h}: {e}" for h, e in failed[:3]), file=sys.stderr)
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
