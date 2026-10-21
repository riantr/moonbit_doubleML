"""Dry-run the CLI-demo CI verifier against a tree where the figure is FALSE.

WHAT THIS PROVES
=================
`_verify/_verify_cli_demo_ci_1650.py` re-derives how many of the 16 CLI
demos print a 95 % CI, and checks that the README quotes the number it
measured.  The number it measured is 11, not the 12 the README used to
carry.

A dry-run has to show the verifier FAILS when the claim is false.  This one
breaks the claim in three different places at once, so three different
mechanisms are exercised:

  1. the README quotes the withdrawn figure again   -> the README-vs-
     measurement check fires;
  2. the README carries the withdrawn figure at all -> the
     withdrawn-figure-absence check fires;
  3. the tracked record claims 12                    -> the
     record-vs-fresh-measurement check fires.

Mechanism 3 is the important one: it shows the record is not a rubber stamp.
A record that the verifier never compares against a fresh measurement would
pass no matter what it said.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the new README and the new
verifier -- are copied in from the WORKING TREE, and then the claim is
broken on top of that.  So the dry-run judges the tree as it is now, with
one deliberate lie in it.

The counter is checked against the verifier's own summary, because a count
that can drift from the output proves nothing.

Run: python _verify/_dryrun_round22_ci_1650.py
"""
import io
import json
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r22ci_mut")

# copied from the working tree: the built README (both copies), the new
# verifier and the measurement record it reads
COPY_IN = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "_verify/_verify_cli_demo_ci_1650.py",
    "_verify/_cli_demo_ci_1650.json",
]


def run(cmd, cwd=REPO, timeout=3600):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def patch(path, old, new, count=1):
    """Replace `old` with `new`, keeping the file's own line endings."""
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    crlf = "\r\n" in text
    old = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
    new = new.replace("\n", "\r\n") if crlf and "\r\n" not in new else new
    n = text.count(old)
    if n != count:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, old[:60], n, count))
    text = text.replace(old, new)
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


if os.path.isdir(WORK):
    shutil.rmtree(WORK)
os.makedirs(WORK, exist_ok=True)

print("=== cloning locally and checking out %s ===" % COMMIT)
rc, out = run(["git", "clone", "--local", "--shared", "--no-checkout", ".", WORK])
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "checkout", "--detach", COMMIT], cwd=WORK)
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "rev-parse", "HEAD"], cwd=WORK)
print("  %s -> %s" % (COMMIT, out.strip()))

for rel in COPY_IN:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    print("  copied in %s" % rel)

print()
print("=== breaking the claim in three places ===")

# 1 + 2. the README quotes the withdrawn figure again
for rel in ("README.mbt.md", "moonbit_doubleML/README.mbt.md"):
    patch(os.path.join(WORK, rel.replace("/", os.sep)),
          "**11** of the 16 print a 95 % CI",
          "**12** of the 16 print a 95 % CI")
    print("  1+2. %s now quotes the withdrawn figure of 12" % rel)

# 3. the tracked record claims 12 as well
rec_path = os.path.join(WORK, "_verify", "_cli_demo_ci_1650.json")
with io.open(rec_path, encoding="utf-8", newline="") as fh:
    rec = json.load(fh)
rec["print_ci"] = 12
with io.open(rec_path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(rec, fh, indent=2, sort_keys=True)
    fh.write("\n")
print("  3. the measurement record now claims 12")

print()
print("=== running the CLI-demo CI verifier ===")
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_cli_demo_ci_1650.py")],
              cwd=WORK, timeout=3600)
print(out)
print("=== verifier exit code: %d ===" % rc)
print()

fail_lines = [l for l in out.splitlines() if "*** FAIL ***" in l]
print("FAIL lines: %d" % len(fail_lines))
for l in fail_lines:
    print("   " + l.strip()[:170])

exact = len([l for l in out.splitlines()
             if l.startswith("  *** FAIL ***")])
print()
print("EXACT failure count (check lines carrying the marker): %d" % exact)

m = re.search(r"(\d+) checks, (\d+) failed", out)
if m:
    print("verifier summary: checks=%s failed=%s" % (m.group(1), m.group(2)))
    agree = int(m.group(2)) == exact
    print("the counter agrees with the summary: %s" % agree)
else:
    print("verifier summary: NOT FOUND (the verifier probably crashed)")
    agree = False

print()
if rc == 0:
    print("VERDICT: *** the dry-run did NOT bite -- the verifier PASSED against "
          "a tree whose CI count was false ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures)" % exact)

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r22ci_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
