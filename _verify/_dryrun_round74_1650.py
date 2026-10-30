#!/usr/bin/env python3
"""Round 74 dry-run: the census must CATCH a verifier that goes back to a
raw read.

WHAT THIS IS A WITNESS FOR
==========================
Round 74 added `_verify/_verify_layout_anchors_1680.py`, a census of the
tracked contract's prose anchors.  Its own control arm proves the census can
classify a SYNTHETIC verifier four ways.  That is not the same thing as
proving it sees the REAL contract.

So this driver takes a verifier this round FIXED and puts the raw read back:

    `_verify/_verify_count_referents_1650.py`
        "**Four backends**" in readme_flat   ->   "**Four backends**" in readme

and asks the census what it thinks.  The answer must be FRAGILE for that
file, because the raw read is exactly the shape the house rule forbids: a
literal with spaces matched against a document whose wrap the builder owns.

Then the file is put back, and the census must be GREEN again.

A census that cannot report the regression protects nothing -- and the
assertion that the file is restored is what keeps this driver honest: a
driver that leaves the tree mutated has not proved anything, it has broken
something.

Run: python _verify/_dryrun_round74_1650.py
"""
import io
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

TARGET = os.path.join("_verify", "_verify_count_referents_1650.py")
CENSUS = os.path.join("_verify", "_verify_layout_anchors_1680.py")
CAPTURE = os.path.join("_verify", "_dryrun1650", "r74_dryrun.out")

FIXED = ('check("the README says four backends", "**Four backends**" in readme_flat)')
BROKEN = ('check("the README says four backends", "**Four backends**" in readme)')


def census():
    p = subprocess.run([sys.executable, CENSUS], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def report(label, ok, detail=""):
    print("  %-64s %s" % (label[:64], "OK" if ok else "*** FAIL ***"))
    if not ok:
        print("        %s" % detail)


src = io.open(TARGET, encoding="utf-8", newline="").read()
print("=" * 78)
print("round 74 dry-run: a verifier that goes back to a raw read")
print("=" * 78)
print()
print("the target: %s" % TARGET)
print("the census: %s" % CENSUS)
print()

rc0, out0 = census()
print("the census on the tree as it stands: exit %d" % rc0)
if rc0 != 0:
    print(out0)
    print("!! the census is RED on the tree as it stands -- fix that first")
    sys.exit(1)

lines = []
fragile = []
try:
    if src.count(FIXED) != 1:
        print("!! the fixed anchor was found %d times (expected 1)" % src.count(FIXED))
        sys.exit(1)
    mutated = src.replace(FIXED, BROKEN, 1)
    with io.open(TARGET, "wb") as fh:
        fh.write(mutated.encode("utf-8"))
    print("the raw read is put back: %s" % BROKEN[:60])
    print()

    rc1, out1 = census()
    fragile = [l for l in out1.splitlines()
               if "FRAGILE" in l and "_verify_count_referents_1650.py" in l]
    print("the census on the mutated tree: exit %d" % rc1)
    for l in fragile:
        print("   %s" % l.strip())
    print()

    report("the census goes RED on the mutated tree", rc1 == 1)
    report("the census names the verifier it caught", len(fragile) == 1,
           "found %d FRAGILE lines for the target" % len(fragile))
    report("the census FAILS its own FRAGILE check",
           any("no tracked check is FRAGILE" in l and "*** FAIL ***" in l
               for l in out1.splitlines()))
    lines.append("the raw read put back -> the census reports FRAGILE")
finally:
    with io.open(TARGET, "wb") as fh:
        fh.write(src.encode("utf-8"))
    print()
    print("the target is restored")

restored = io.open(TARGET, encoding="utf-8", newline="").read()
rc2, out2 = census()
print("the census on the restored tree: exit %d" % rc2)
report("the target file is byte-identical to what it was", restored == src)
report("the census is GREEN again", rc2 == 0)

ok = (rc1 == 1 and len(fragile) == 1 and restored == src and rc2 == 0)
print()
print("=" * 78)
print("VERDICT %s" % ("PASS" if ok else "FAIL"))
print("=" * 78)

os.makedirs(os.path.dirname(CAPTURE), exist_ok=True)
with io.open(CAPTURE, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 74 dry-run: the anchor census against the real contract\n")
    fh.write("the census on the tree as it stands : exit %d\n" % rc0)
    fh.write("the census on the mutated tree     : exit %d\n" % rc1)
    for l in fragile:
        fh.write("  %s\n" % l.strip())
    fh.write("the census on the restored tree    : exit %d\n" % rc2)
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
print("wrote %s" % CAPTURE)
sys.exit(0 if ok else 1)
