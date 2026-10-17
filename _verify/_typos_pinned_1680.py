"""Run the EXACT typos version the publish workflow pins.

CI pins TYPOS_VERSION=v1.19.0 and runs bare `typos`. The local build is
1.50.3, a much newer dictionary, so "local typos is clean" is not evidence
about what CI saw -- and this release's `Check typos` failed on exactly the
files that landed after the last successful publish. Downloading the pinned
build is the only way to reproduce the gate instead of guessing at it.

Downloads into a temp dir; never overwrites the installed typos.
"""

import io
import os
import subprocess
import sys
import zipfile
import tempfile
import urllib.request

VER = "v1.19.0"
# The workflow downloads the x86_64-unknown-linux-musl tarball. That is a Linux
# ELF and will not execute on Windows (WinError 216). Same version, same
# dictionary, Windows build -- and the dictionary is the only thing that
# decides what this gate reports.
URL = ("https://github.com/crate-ci/typos/releases/download/%s/"
       "typos-%s-x86_64-pc-windows-msvc.zip" % (VER, VER))
REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"


def main():
    tmp = tempfile.mkdtemp(prefix="typos_pinned_")
    print("downloading", URL)
    try:
        with urllib.request.urlopen(URL, timeout=180) as r:
            data = r.read()
    except Exception as e:  # noqa: BLE001
        print("DOWNLOAD FAILED:", e)
        print("Cannot reproduce the gate locally; treat CI's result as final.")
        return 3
    print("bytes:", len(data))
    zippath = os.path.join(tmp, "t.zip")
    with open(zippath, "wb") as f:
        f.write(data)
    exe = None
    with zipfile.ZipFile(zippath) as zf:
        for n in zf.namelist():
            if n.lower().endswith("typos.exe"):
                zf.extract(n, tmp)
                exe = os.path.join(tmp, n)
                break
    if exe is None:
        print("no typos.exe in archive:", zf.namelist()[:10])
        return 3
    print("extracted ->", exe)

    v = subprocess.run([exe, "--version"], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    print("version:", (v.stdout or "").strip() or (v.stderr or "").strip())

    r = subprocess.run([exe], cwd=REPO, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")

    # Persist the full output before analysing it: a truncated tail hides
    # files, which is how "typos is clean" gets believed on a dirty tree.
    log = os.path.join(REPO, "_verify", "_typos_pinned_out_1680.txt")
    with io.open(log, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)

    import re
    where = re.findall(r"^error:[^\n]*\n\s*-->\s*([^\n]+)", out, re.M)
    files = sorted({w.strip().split(":")[0].replace("\\", "/").lstrip("./")
                    for w in where})
    tr = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True,
                        text=True, encoding="utf-8")
    tracked = {t.strip().replace("\\", "/") for t in tr.stdout.splitlines() if t.strip()}

    print("bare `typos` exit:", r.returncode)
    print("full output ->", log)
    print()
    print("files with findings (TRACKED = what CI sees in a clean checkout):")
    for f_ in files:
        print("   %-8s %s" % ("TRACKED" if f_ in tracked else "untracked", f_))
    flag = [f_ for f_ in files if f_ in tracked]
    print()
    print("tracked files flagged: %d %s" % (len(flag), flag))
    return 0


if __name__ == "__main__":
    sys.exit(main())
