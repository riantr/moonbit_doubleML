"""Dry-run the test-count verifier against a tree where the README is WRONG.

A verifier that has stopped biting looks exactly like a verifier that passes.
So the round-19 checks are run against a commit whose README stated a test
count the tree did not have -- the invariant the verifier asserts was FALSE
there -- and the failures are counted EXACTLY (the counter matches the
literal "FAIL" line the verifier prints), because a count that can drift
from the output proves nothing.

THE WITNESS
===========
`0fbe5d3c6` ("docs(lplr): the a_hat double-cross-fit is measured, and it is
not the cause") is the most recent commit whose README said 1116 while the
package carried 1117 tests.  A scan of 234 commits that touched the package
or the README found 84 in which the README's count and the tree's count
disagreed, so this is a recurring failure and not a one-off.

The commit is cloned locally with `--local --shared --no-checkout` (so no
network) and checked out detached.  The verifier is copied in, because the
witness commit predates it.

Run: python _verify/_dryrun_round19_1650.py [commit]
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = sys.argv[1] if len(sys.argv) > 1 else "0fbe5d3c6"
WORK = os.path.join(REPO, "_verify", "_dryrun1650",
                    "r19_%s" % COMMIT[:9])

COPY_IN = [
    "_verify/_verify_testcounts_1610.py",
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
print("=== running the test-count verifier against %s ===" % COMMIT)
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_testcounts_1610.py")],
              cwd=WORK, timeout=3600)
print(out)
print("=== verifier exit code: %d ===" % rc)
print()

fail_lines = [l for l in out.splitlines() if "*** FAIL ***" in l]
print("FAIL lines: %d" % len(fail_lines))
for l in fail_lines:
    print("   " + l.strip()[:150])

# the exact counter: a check line is two spaces, the label, then the verdict.
# The summary block prints "FAILED:", which does not carry the marker, so the
# counter cannot double-count it.
exact = len(fail_lines)
print()
print("EXACT failure count (check lines carrying '*** FAIL ***'): %d" % exact)

# and the summary the verifier itself prints
m = re.search(r"checks:\s*(\d+)\s+failures:\s*(\d+)", out)
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
          "a tree whose README was wrong ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures against %s)"
      % (exact, COMMIT))

# the log the CHANGELOG splicer reads the failure count from
LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r19_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
