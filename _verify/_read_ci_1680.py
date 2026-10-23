import io
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "_verify", "_ci_sim_1631_1680.txt")
# PowerShell's Tee-Object writes UTF-16LE, so a naive utf-8 decode turns every
# other byte into U+FFFD and every status line silently stops matching. That
# is the same trap as a truncated pipe: the file looks plausible and the
# greps return nothing. Detect the encoding instead of assuming it.
raw = io.open(PATH, "rb").read()
enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
print("decoded as:", enc)
s = raw.decode(enc, errors="replace").split("\n")

print("total lines:", len(s))
print("=== job headers ===")
for i, l in enumerate(s):
    if l.strip().endswith("running") or "===" in l and "[" in l:
        print("%3d| %s" % (i, l.strip()[:120]))
print("=== README / tests / FAIL lines ===")
for i, l in enumerate(s):
    t = l.strip()
    if t.startswith("FAIL") or "README" in t or "Total tests" in t:
        print("%3d| %s" % (i, l.rstrip()[:150]))
print("=== counts ===")
for st in ("PASS", "FAIL", "BLOCKED", "SKIP"):
    print("%-8s %d" % (st, sum(1 for l in s if l.strip().startswith(st))))
