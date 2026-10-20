"""Are the upstream source copies in _verify/ the REAL upstream sources?

The record `UPSTREAM_PROVENANCE.md` promises "Files kept in this directory" and
quotes code from them.  Before tracking any of them, each must be compared
against the INSTALLED upstream package -- otherwise the repo would ship a
copy of upstream that does not match the package the claims cite.
"""
import hashlib
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
VD = os.path.join(REPO, "_verify")
PKG = r"C:\Users\31379\AppData\Local\Programs\Python\Python313\Lib\site-packages\doubleml"

# local copy name -> where it lives in the installed package
PAIRS = [
    ("did_cs.py", os.path.join(PKG, "did", "did_cs.py")),
    ("_utils_did_cs_manual.py", os.path.join(PKG, "did", "tests", "_utils_did_cs_manual.py")),
    ("_utils_did_manual.py", os.path.join(PKG, "did", "tests", "_utils_did_manual.py")),
    ("double_ml_linear_score.py", os.path.join(PKG, "double_ml_linear_score.py")),
    ("double_ml_score_mixins.py", os.path.join(PKG, "double_ml_score_mixins.py")),
]


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]


print("=== local copy vs the installed upstream package ===")
for name, upstream_path in PAIRS:
    local = os.path.join(VD, name)
    lok = os.path.isfile(local)
    upk = os.path.isfile(upstream_path)
    if not lok:
        print("  %-30s LOCAL MISSING" % name)
        continue
    if not upk:
        print("  %-30s local=%s  upstream file NOT in the installed package" % (name, sha(local)))
        continue
    same = sha(local) == sha(upstream_path)
    print("  %-30s local=%s upstream=%s  %s"
          % (name, sha(local), sha(upstream_path), "IDENTICAL" if same else "DIFFERS"))
    if not same:
        a = open(local, encoding="utf-8", errors="replace").read().splitlines()
        b = open(upstream_path, encoding="utf-8", errors="replace").read().splitlines()
        print("        local %d lines, upstream %d lines" % (len(a), len(b)))
        shown = 0
        for i in range(max(len(a), len(b))):
            x = a[i] if i < len(a) else "<eof>"
            y = b[i] if i < len(b) else "<eof>"
            if x != y:
                print("        line %d:" % (i + 1))
                print("          local   : %s" % x[:110])
                print("          upstream: %s" % y[:110])
                shown += 1
                if shown >= 4:
                    break
print()

print("=== the tarball: is the installed package really 0.11.3, and the sdist 0.11.4? ===")
try:
    from importlib.metadata import version
    print("  installed doubleml version:", version("doubleml"))
except Exception as e:
    print("  could not read the installed version:", e)

import tarfile
tb = os.path.join(VD, "doubleml-0.11.4.tar.gz")
if os.path.isfile(tb):
    with tarfile.open(tb, "r:gz") as tf:
        names = [m.name for m in tf.getmembers() if m.name.endswith("PKG-INFO")]
        if names:
            txt = tf.extractfile(names[0]).read().decode("utf-8", "replace")
            for line in txt.splitlines()[:6]:
                if line.startswith("Version") or line.startswith("Name"):
                    print("  sdist:", line)
