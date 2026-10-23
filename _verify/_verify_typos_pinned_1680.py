"""Re-run the PINNED typos gate, reusing an already-downloaded v1.19.0.

The fix script re-downloads the 3 MB binary each run and the last attempt
timed out mid-download AFTER the renames were already written. This is
verification only: find a cached binary, or fetch it, then report which
TRACKED files still carry findings.
"""

import glob
import io
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VER = "v1.19.0"
URL = ("https://github.com/crate-ci/typos/releases/download/%s/"
       "typos-%s-x86_64-pc-windows-msvc.zip" % (VER, VER))


def find_cached():
    pats = os.path.join(tempfile.gettempdir(), "typos_pinned_*", "**", "typos.exe")
    for p in glob.glob(pats, recursive=True):
        try:
            r = subprocess.run([p, "--version"], capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            out = ((r.stdout or "") + (r.stderr or "")).strip()
            if VER.lstrip("v") in out:
                return p, out
        except Exception:  # noqa: BLE001
            continue
    return None, None


def download():
    tmp = tempfile.mkdtemp(prefix="typos_pinned_")
    zp = os.path.join(tmp, "t.zip")
    with urllib.request.urlopen(URL, timeout=300) as r:
        data = r.read()
    with open(zp, "wb") as f:
        f.write(data)
    with zipfile.ZipFile(zp) as zf:
        for n in zf.namelist():
            if n.lower().endswith("typos.exe"):
                zf.extract(n, tmp)
                return os.path.join(tmp, n)
    raise SystemExit("no typos.exe in archive")


def main():
    exe, ver = find_cached()
    if exe is None:
        print("no cached binary; downloading", VER)
        exe = download()
        ver = "downloaded"
    print("binary:", exe, "|", ver)

    r = subprocess.run([exe], cwd=REPO, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    log = os.path.join(REPO, "_verify", "_typos_pinned_out_1680.txt")
    with io.open(log, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)

    where = re.findall(r"^error:[^\n]*\n\s*-->\s*([^\n]+)", out, re.M)
    files = sorted({w.strip().split(":")[0].replace("\\", "/").lstrip("./")
                    for w in where})
    tr = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True,
                        text=True, encoding="utf-8")
    tracked = {t.strip().replace("\\", "/") for t in tr.stdout.splitlines() if t.strip()}
    flag = [f_ for f_ in files if f_ in tracked]
    print("pinned typos exit:", r.returncode)
    print("all flagged files  :", len(files))
    print("TRACKED flagged    :", flag)
    print("VERDICT:", "clean -- a new tag can be cut"
          if not flag else "still red -- do NOT cut a tag")
    return 0 if not flag else 1


if __name__ == "__main__":
    sys.exit(main())
