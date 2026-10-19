"""Download typos v1.19.0 (the version publish.yml pins) and run it on a clean export.

Why this exists
===============
Section 26 of `_verify/LPLR_GATE_BLINDNESS_1680.md` asserted that the PINNED
typos v1.19.0 accepts the misspellings that local typos 1.50.3 reports, and the
whole release was built on that inference without ever running the pinned binary
on the current tree. v0.163.4's publish run falsified it: `Check typos` FAILED
with the pinned binary reporting `datas` and `Ba` at
`_verify/LPLR_GATE_BLINDNESS_1680.md:2245,2246,2259,2266` -- the exact lines §26
introduced and then excused.

So: no more inference. This fetches the pinned binary and runs it over a
`git archive` export, which is what CI checks out. Downloads for this asset have
been failing intermittently (WinError 10060/10054), so a failure here reports
"NOT VERIFIED" rather than quietly falling back to the local binary -- a local
1.50.3 pass is not evidence about a pinned 1.19.0 gate, and conflating the two is
what produced the original mistake.

Run: python _verify/_typos_pinned_check_1680.py
"""

import io
import json
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
VERSION = "v1.19.0"
DEST = os.path.join(REPO, "_verify", "_typos_pinned_1680")
URL = ("https://github.com/crate-ci/typos/releases/download/%s/"
       "typos-%s-x86_64-pc-windows-msvc.zip" % (VERSION, VERSION))


def fetch():
    os.makedirs(DEST, exist_ok=True)
    exe = os.path.join(DEST, "typos.exe")
    if os.path.isfile(exe):
        return exe, "already downloaded"
    print("downloading %s" % URL)
    req = urllib.request.Request(URL, headers={"User-Agent": "moonbit_doubleML-release-check"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        blob = resp.read()
    print("  got %d bytes" % len(blob))
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        names = z.namelist()
        print("  archive: %s" % names)
        member = [n for n in names if n.endswith("typos.exe")][0]
        with z.open(member) as src, io.open(exe, "wb") as dst:
            dst.write(src.read())
    return exe, "downloaded"


def export(ref):
    """A pristine tree, the way CI checks it out -- not the working dir."""
    d = os.path.join(REPO, "_verify", "_typos_export_1680")
    if os.path.isdir(d):
        # shutil, not the `rm` shim: the shim is a scoop wrapper that is not on
        # PATH for a bare subprocess, and FileNotFoundError here would read as
        # "the scan failed" rather than "the cleanup failed".
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    zf = os.path.join(REPO, "_verify", "_typos_export_1680.zip")
    r = subprocess.run(["git", "archive", "--format=zip", "-o", zf, ref],
                       cwd=REPO, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return None, "git archive failed: %s" % (r.stderr or "")[:200]
    r = subprocess.run(["powershell", "-NoProfile", "-Command",
                        "Expand-Archive -LiteralPath '%s' -DestinationPath '%s' -Force"
                        % (zf, d)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return None, "Expand-Archive failed: %s" % (r.stderr or "")[:200]
    return d, "exported %s" % ref


def main():
    try:
        exe, how = fetch()
    except Exception as exc:  # noqa: BLE001
        print("")
        print("PINNED BINARY UNAVAILABLE: %s: %s" % (type(exc).__name__, exc))
        print("RESULT: NOT VERIFIED. The local typos 1.50.3 is NOT a substitute;")
        print("        do not claim the pinned gate passes without this binary.")
        return 3
    print("typos at %s (%s)" % (exe, how))
    ver = subprocess.run([exe, "--version"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    print("version: %s" % (ver.stdout or ver.stderr).strip())

    ref = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    tree, note = export(ref)
    if not tree:
        print("could not export: %s" % note)
        return 4
    print("scanning a pristine `git archive %s` export" % ref)

    r = subprocess.run([exe], cwd=tree, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    nfiles = sum(len(fs) for _, _, fs in os.walk(tree))
    print("")
    print("exit code : %d" % r.returncode)
    print("files     : %d" % nfiles)
    print("VERDICT   : %s" % ("PASS -- the pinned gate is green" if r.returncode == 0
                              else "FAIL -- the pinned gate rejects this tree"))
    if r.returncode != 0:
        print("")
        print(out[:4000])
    return 0 if r.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
