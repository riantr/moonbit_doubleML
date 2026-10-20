"""Dry-run the number-coverage verifier against a tree where the invariant is FALSE.

WHAT THIS PROVES
================
The coverage verifier asserts: every number in the README is recorded
somewhere in this repository -- guarded by a verifier, derived from the
tree, or witnessed in a tracked file.

NO HISTORICAL WITNESS EXISTS FOR IT, and that is a fact about the repository
rather than a gap in the check.  The CHANGELOG records every figure the
README has ever quoted, so at every commit this verifier would have passed:
at `147cc71` (v0.164.13) the README says "recovers within `0.198`" and
"a 366x separation", and the CHANGELOG of that day says `0.198` and
`366x` -- so the figures were WITNESSED, and the witness was itself the
thing that was wrong.  The coverage map cannot see a wrong number; it can
only see an unsourced one.  The hazard verifier is what sees the wrong one.

So the dry-run here is a DELIBERATE VIOLATION rather than a historical
witness: one unsourced figure is written into the README of a clean clone,
and the verifier must fail -- with a count that matches its own summary.

The mutation is written to BOTH README copies, so the byte-identical check
still passes and the ONLY failure is the one the mutation is about.

The clone is local (`--local --shared --no-checkout`), so no network.

Run: python _verify/_dryrun_round21_coverage_1650.py [commit]
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r21cov_mut")

# A figure that exists nowhere in the repository.
UNSOURCED = "0.999123456"
MUTATION = ("\nThe re-measurement lands at `%s`.\n" % UNSOURCED,)

COPY_IN = [
    "_verify/_verify_number_coverage_1650.py",
]


def run(cmd, cwd=REPO, timeout=1800, env=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout, env=env)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


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
print("=== mutating the README so the invariant is FALSE ===")
# Both copies, so the byte-identical check still passes and the ONLY failure
# is the one the mutation is about.
for rel in ("README.mbt.md", os.path.join("moonbit_doubleML", "README.mbt.md")):
    path = os.path.join(WORK, rel)
    with io.open(path, "a", encoding="utf-8", newline="") as fh:
        fh.write(MUTATION[0])
    print("  appended the unsourced figure %s to %s" % (UNSOURCED, rel))

print()
print("=== running the number-coverage verifier against %s ===" % COMMIT)
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_number_coverage_1650.py")],
              cwd=WORK, timeout=3600)
print(out)
print("=== verifier exit code: %d ===" % rc)
print()

fail_lines = [l for l in out.splitlines() if "*** FAIL ***" in l]
print("FAIL lines: %d" % len(fail_lines))
for l in fail_lines:
    print("   " + l.strip()[:400])

# The exact counter: a failing CHECK line starts with two spaces and carries
# the marker; the summary block prints the marker once on a line of its own,
# and that line is not a check.
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
          "a tree whose README carried unwitnessed figures ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures against %s)"
      % (exact, COMMIT))

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r21cov_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
