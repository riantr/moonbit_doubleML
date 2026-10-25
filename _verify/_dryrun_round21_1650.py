"""Dry-run the hazard-margin verifier against a tree whose README is WRONG.

A verifier that has stopped biting looks exactly like a verifier that passes.
So the round-21 checks are run against `147cc71` (v0.164.13) -- the release
whose README says "default recovers within `0.198`", "an OLS propensity
misses by at least `72.8`", "a 366x separation" and "a 300x separation".
The invariant this verifier asserts was FALSE there, and it is false in
exactly the way round 21 found it false.

THE WITNESS
===========
`147cc71` is the release that shipped the wrong figures.  It is the most
recent commit whose README carries them, so the failures are the ones a
reader would have hit, not a synthetic mutation.

The commit is cloned locally with `--local --shared --no-checkout` (so no
network) and checked out detached.  The verifier AND the measurement record
are copied in, because the witness commit predates both.  The record is then
staged inside the clone, so the "is the record tracked" check passes there and
the ONLY failures are the number failures -- a dry-run that fails for a
reason unrelated to the defect proves less than it looks like it proves.

Run: python _verify/_dryrun_round21_1650.py [commit]
"""
import io
import os
import re
import shutil
import stat
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = sys.argv[1] if len(sys.argv) > 1 else "147cc71"
WORK = os.path.join(REPO, "_verify", "_dryrun1650",
                    "r21_%s" % COMMIT[:9])

COPY_IN = [
    "_verify/_verify_hazard_margins_1650.py",
    "_verify/_hazard_margins_1650.json",
]


def run(cmd, cwd=REPO, timeout=1800, env=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout, env=env)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def force_rmtree(path):
    """Remove `path`, including the read-only files a git clone leaves behind.

    Windows refuses to delete a read-only file, and a clone's `.git` holds
    some.  So the mode is cleared first and the removal is retried; without
    this the driver dies with a PermissionError on its SECOND run, before it
    has done any work at all.
    """
    def _onerror(func, p, _exc):
        try:
            os.chmod(p, stat.S_IWRITE)
        except OSError:
            pass
        try:
            func(p)
        except OSError:
            pass

    shutil.rmtree(path, onerror=_onerror)


if os.path.isdir(WORK):
    force_rmtree(WORK)
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

# the record is a NEW file at this commit, so it has to be staged inside the
# clone for the "is it tracked" check to pass there
rc, out = run(["git", "add", "_verify/_hazard_margins_1650.json"], cwd=WORK)
print("  staged the record inside the clone (rc=%d)" % rc)

print()
print("=== running the hazard-margin verifier against %s ===" % COMMIT)
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_hazard_margins_1650.py")],
              cwd=WORK, timeout=3600)
print(out)
print("=== verifier exit code: %d ===" % rc)
print()

fail_lines = [l for l in out.splitlines() if "*** FAIL ***" in l]
print("FAIL lines: %d" % len(fail_lines))
for l in fail_lines:
    print("   " + l.strip()[:150])

# The exact counter: a failing CHECK line starts with two spaces and carries
# the marker.  The summary block prints the marker once on a line of its own,
# and that line is not a check, so it is excluded -- a counter that counted it
# would be one too high and would agree with nothing.
exact = len([l for l in out.splitlines()
             if l.startswith("  *** FAIL ***")])
print()
print("EXACT failure count (check lines carrying the marker): %d" % exact)

# and the summary the verifier itself prints
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
          "a tree whose README quoted the wrong margins ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures against %s)"
      % (exact, COMMIT))

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r21_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
