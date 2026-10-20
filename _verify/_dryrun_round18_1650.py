"""Dry-run the round-18 verifier against the PREVIOUS release.

A verifier that has stopped biting looks exactly like a verifier that passes.
So the round-18 checks are run against v0.164.11 -- the release whose README
was 2290 lines of investigation narrative, with no `ENGINEERING.md` and none of
the reference page's shape -- and the failures are counted EXACTLY (the
counter matches the literal "  *** FAIL ***" line the verifier prints),
because a count that can drift from the output proves nothing.

The previous release is cloned locally with `--local --shared --no-checkout`
(so no network) and checked out detached.  The round-18 verifier and builder
are copied in, because v0.164.11 has neither.

Run: python _verify/_dryrun_round18_1650.py v0.164.11
"""
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
TAG = sys.argv[1] if len(sys.argv) > 1 else "v0.164.11"
WORK = os.path.join(REPO, "_verify", "_dryrun1650",
                    "r18_%s" % TAG.replace("v", "").replace(".", ""))

COPY_IN = [
    "_verify/_verify_round18_readme_1650.py",
    "_verify/_r18_build_readme_1650.py",
]


def run(cmd, cwd=REPO, timeout=1800, env=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout, env=env)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


if os.path.isdir(WORK):
    shutil.rmtree(WORK)
os.makedirs(WORK, exist_ok=True)

print("=== cloning %s locally ===" % TAG)
rc, out = run(["git", "clone", "--local", "--shared", "--no-checkout", ".", WORK])
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "checkout", "--detach", TAG], cwd=WORK)
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "rev-parse", "HEAD"], cwd=WORK)
print("  %s -> %s" % (TAG, out.strip()))

for rel in COPY_IN:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    print("  copied in %s" % rel)

print()
print("=== running the round-18 verifier against %s ===" % TAG)
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_round18_readme_1650.py")],
              cwd=WORK, timeout=3600)
print(out)
print("=== verifier exit code: %d ===" % rc)

fail_lines = [l for l in out.splitlines() if "*** FAIL ***" in l]
print()
print("FAIL lines: %d" % len(fail_lines))
for l in fail_lines:
    print("   " + l.strip()[:150])

# the exact counter: a check line is two spaces, the label, then the verdict
exact = sum(1 for l in out.splitlines()
            if l.startswith("  ") and "*** FAIL ***" in l)
print()
print("EXACT failure count (check lines carrying '*** FAIL ***'): %d" % exact)

# and the summary the verifier itself prints
m = re.search(r"checks:\s*(\d+)\s+failed:\s*(\d+)", out)
if m:
    print("verifier summary: checks=%s failed=%s" % (m.group(1), m.group(2)))
    agree = int(m.group(2)) == exact
    print("the counter agrees with the summary: %s" % agree)
else:
    print("verifier summary: NOT FOUND (the verifier probably crashed)")
    agree = False

if exact == 0:
    print()
    print("VERDICT: *** the dry-run did NOT bite -- 0 failures against %s ***" % TAG)
    sys.exit(1)
print()
print("VERDICT: PASS -- the dry-run bites (%d failures against %s)" % (exact, TAG))

# the log the CHANGELOG splicer reads the failure count from
LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r18_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
