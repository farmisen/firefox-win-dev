#!/usr/bin/env python3
"""firefox-win-dev / scripts/fetch-iso.py

Get an official Windows 11 ISO download URL from Microsoft, stdlib only.

This is a port of the request sequence Fido (pbatard/Fido, the script Rufus
uses) performs; Fido itself refuses to run outside Windows, so we speak the API
directly. Fido.ps1 is still fetched, but only as DATA: it is the maintained
source for the per-release product edition ids Microsoft rotates.

  fetch-iso.py --arch x64|arm64 [--lang English] [--url-only] [--out PATH]

URLs are valid for ~24 h. Microsoft rate-limits by IP; a "715-123130" style
error means back off (or change IP) and retry later.
"""
import argparse, json, os, re, subprocess, sys, time, uuid, urllib.request, urllib.error

ORG_ID = "y6jn8c31"
PROFILE_ID = "606624d44113"
INSTANCE_ID = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
LOCALE = "en-US"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
FALLBACK_EDITION_IDS = {"x64": 3321, "arm64": 3324}   # Windows 11 Home/Pro/Edu, 25H2
DOWNLOAD_TYPE = {1: "x64", 2: "arm64"}                # Microsoft's DownloadType codes
FIDO_URL = "https://raw.githubusercontent.com/pbatard/Fido/{ref}/Fido.ps1"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def get(url, headers=None, timeout=30):
    h = {"User-Agent": UA, "Accept": "*/*"}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def get_json(url, headers=None, attempts=3):
    last = None
    for i in range(attempts):
        if i:
            time.sleep(2)
        try:
            body = get(url, headers)
            data = json.loads(body) if body.strip() else None
        except (urllib.error.URLError, json.JSONDecodeError) as e:
            last = e
            continue
        if data is None:
            last = RuntimeError("empty reply")
            continue
        if data.get("Errors"):
            err = data["Errors"][0]
            last = RuntimeError(f"Microsoft API error {err.get('Type')}: {err.get('Value')}")
            if err.get("Type") == 9:      # blocked / rate limited: retrying won't help
                break
            continue
        return data
    raise SystemExit(f"{url.split('?')[0]}: {last}")


def edition_ids(tools_dir, ref):
    """Read the 'Windows 11 Home/Pro/Edu' edition ids for the newest release from Fido.ps1."""
    path = os.path.join(tools_dir, f"Fido-{ref}.ps1")
    try:
        if not os.path.exists(path):
            os.makedirs(tools_dir, exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(get(FIDO_URL.format(ref=ref)))
        src = open(path, encoding="utf-8").read()
        m = re.search(r'"Windows 11 Home/Pro/Edu",\s*@\((\d+),\s*(\d+)\)', src)
        if m:
            return {"x64": int(m.group(1)), "arm64": int(m.group(2))}, f"Fido.ps1 @{ref}"
        log("warning: could not find edition ids in Fido.ps1; using built-in fallback")
    except Exception as e:  # network down, GitHub unreachable, etc.
        log(f"warning: could not fetch Fido.ps1 for edition ids ({e}); using built-in fallback")
    return FALLBACK_EDITION_IDS, "built-in fallback"


def whitelist_session(session_id):
    # 1) session whitelisting
    get(f"https://vlscppe.microsoft.com/tags?org_id={ORG_ID}&session_id={session_id}")
    # 2) ov-df challenge: fetch mdt.js, extract w + rticks, echo them back with a timestamp
    js = get(f"https://ov-df.microsoft.com/mdt.js?instanceId={INSTANCE_ID}&PageId=si&session_id={session_id}")
    w = re.search(r"[?&]w=([A-F0-9]+)", js)
    rt = re.search(r'rticks\=\"\+?(\d+)', js)
    if not (w and rt):
        raise SystemExit("ov-df: could not extract w/rticks (Microsoft changed the handshake?)")
    get(f"https://ov-df.microsoft.com/?session_id={session_id}&CustomerId={INSTANCE_ID}&PageId=si"
        f"&w={w.group(1)}&mdt={int(time.time()*1000)}&rticks={rt.group(1)}")


def download_url(arch, lang, tools_dir, fido_ref):
    ids, source = edition_ids(tools_dir, fido_ref)
    edition_id = ids[arch]
    log(f"edition id {edition_id} for {arch} (from {source})")

    session_id = str(uuid.uuid4())
    whitelist_session(session_id)

    api = "https://www.microsoft.com/software-download-connector/api"
    common = f"profile={PROFILE_ID}&friendlyFileName=undefined&Locale={LOCALE}&sessionID={session_id}"
    skus = get_json(f"{api}/getskuinformationbyproductedition?{common}&productEditionId={edition_id}&SKU=undefined")
    wanted = [s for s in skus.get("Skus", []) if re.search(lang, s.get("Language", ""), re.I)]
    if not wanted:
        names = sorted({s.get("Language") for s in skus.get("Skus", [])})
        raise SystemExit(f"no SKU matches --lang {lang!r}; available: {', '.join(names)}")
    sku = wanted[0]
    log(f"SKU {sku['Id']}: {sku.get('Language')} ({sku.get('LocalizedLanguage')})")

    links = get_json(f"{api}/GetProductDownloadLinksBySku?{common}&productEditionId=undefined&SKU={sku['Id']}",
                     headers={"Referer": "https://www.microsoft.com/software-download/windows11"})
    for opt in links.get("ProductDownloadOptions", []):
        if DOWNLOAD_TYPE.get(opt.get("DownloadType")) == arch:
            return opt["Uri"]
    have = [DOWNLOAD_TYPE.get(o.get("DownloadType"), o.get("DownloadType")) for o in links.get("ProductDownloadOptions", [])]
    raise SystemExit(f"no {arch} link in reply (got: {have})")


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arch", choices=["x64", "arm64"], default="x64")
    ap.add_argument("--lang", default="^English$", help="regex on Microsoft's language name (default ^English$; 'English International' = en-GB)")
    ap.add_argument("--url-only", action="store_true", help="print the URL and exit")
    ap.add_argument("--out", help="download destination (default build/win11-<arch>.iso)")
    ap.add_argument("--fido-ref", default=os.environ.get("FIDO_REF", "master"), help="pbatard/Fido git ref to read edition ids from")
    a = ap.parse_args()

    url = download_url(a.arch, a.lang, os.path.join(here, ".tools"), a.fido_ref)
    if a.url_only:
        print(url)
        return
    out = a.out or os.path.join(here, "build", f"win11-{a.arch}.iso")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    name = url.split("?")[0].rsplit("/", 1)[-1]
    log(f"downloading {name} -> {out}  (curl -C - resumes if interrupted)")
    rc = subprocess.call(["curl", "-fL", "-C", "-", "--retry", "5", "--progress-bar", "-A", UA, "-o", out, url])
    if rc:
        raise SystemExit(f"curl failed ({rc}); re-run to resume")
    sha = subprocess.run(["sha256sum", out], capture_output=True, text=True).stdout.split()[0]
    print(f"sha256: {sha}")
    print("Compare once against the hash list at https://www.microsoft.com/software-download/windows11")


if __name__ == "__main__":
    main()
