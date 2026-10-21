"""Dry-run the count-referents verifier against a tree whose COUNTS are broken.

WHAT THIS PROVES
=================
`_verify/_verify_count_referents_1650.py` checks that every count in the README
that stands for a set is the right size AND names the set.  Round 24 found two
sentences that used a bare count as a referent -- "the largest margin of the
four" and "all four earlier outcomes" -- and a CHANGELOG entry that called
SSM "the fifth" while naming four.  None of those is a wrong NUMBER: every one
of them was a correct number attached to a set the reader could not resolve.

A verifier that only checked numbers would have passed all three.  So the
check has to be proven against a tree where the counts are broken.

Six defects, six different mechanisms:

  1. the SSM sentence drops the named set        -> the referent checks
  2. the classifier sentence drops the named set  -> the referent checks
  3. the CHANGELOG's ordinal goes back to "fifth" -> the ordinal checks
  4. a source default moves                       -> the source-derived sets
  5. the QA message goes back to "29/29 resolve"  -> the gherkin-evidence checks
  6. the README grows an UNREGISTERED count       -> the inventory check

The counter is checked against the verifier's own summary, because a count
that can drift from the output proves nothing.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the rebuilt README, the spliced
CHANGELOG, the patched QA registry, the new verifier -- are copied in from the
WORKING TREE, and the counts are broken on top of that.

Run: python _verify/_dryrun_round24_1650.py
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r24_mut")

COPY_IN = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
    ".github/scripts/qa_loop/checks.py",
    "_verify/_verify_count_referents_1650.py",
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
print("=== breaking the counts in six places ===")

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
CHANGELOG = os.path.join(WORK, "CHANGELOG.md")
CHECKS = os.path.join(WORK, ".github", "scripts", "qa_loop", "checks.py")

# 1. the SSM sentence drops the named set -- the count stays, the set goes
patch(README,
      "`DoubleMLSSM` has the largest margin of the four migrations of\n"
      "v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and\n"
      "`DoubleMLSSM` -- because",
      "`DoubleMLSSM` has the largest margin of the four, because")
print("  1. the SSM sentence drops the named set")

# 2. the classifier sentence drops the named set
patch(README,
      "was used to prioritise the probes, and it reproduces the four hazardous\n"
      "verdicts of v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`,\n"
      "`DoubleMLAPOS` and `DoubleMLSSM` -- but",
      "was used to prioritise the probes, and it reproduces all four earlier outcomes\n"
      "-- but")
print("  2. the classifier sentence drops the named set")

# 3. the CHANGELOG's ordinal goes back to "fifth"
patch(CHANGELOG,
      "This is the fourth and last estimator to be migrated:",
      "This is the fifth and last estimator to be migrated:")
print("  3. the CHANGELOG's ordinal goes back to 'fifth'")

# 4. a source default moves: DoubleMLIIVM stops defaulting `ml_m` to OLS.
# The `ml_m` SLOT, specifically: IIVM's `ml_g` default is also OLS, and
# patching the first occurrence would move `ml_g` instead -- a change no
# check here can see.  A control that cannot fail is not a control.
PATCH_FILE = os.path.join(WORK, "moonbit_doubleML", "iivm.mbt")
patch(PATCH_FILE,
      "  ml_m~ : LearnerDispatch = LearnerDispatch::linear_regression(),",
      "  ml_m~ : LearnerDispatch = LearnerDispatch::logistic_regression(LogisticRegression::new()),")
print("  4. a source default moves (DoubleMLIIVM's `ml_m` off the OLS propensity)")

# 5. the QA message goes back to "29/29 mapped test names resolve"
patch(CHECKS,
      'f"{len(mapped)} mapped names: {len(real) - len(unresolved)} resolve to a "\n'
      '             f"real declaration, {len(prose)} prose-exempt"',
      'f"{len(mapped)-len(unresolved)}/{len(mapped)} mapped test names resolve"')
print("  5. the QA message goes back to '29/29 mapped test names resolve'")

# 6. the README grows a count claim nobody registered
tail = io.open(README, encoding="utf-8", newline="").read().rstrip("\n")
with io.open(README, "w", encoding="utf-8", errors="replace", newline="") as fh:
    fh.write(tail + "\n\nSeven estimators carry a classifier propensity by default.\n")
print("  6. the README grows an UNREGISTERED count claim")

# the shipped copy must stay byte-identical, so it gets the same damage
shutil.copy2(README, SHIPPED)
print("  (the shipped copy was given the same damage, so the byte-identity "
      "check still holds and does not mask the other five)")

print()
print("=== running the count-referents verifier ===")
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_count_referents_1650.py")],
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
          "a tree whose counts were broken ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures)" % exact)

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r24_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
