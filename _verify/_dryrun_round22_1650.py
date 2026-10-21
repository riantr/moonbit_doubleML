"""Dry-run the test-verification verifier against a tree where the claims are FALSE.

NO HISTORICAL WITNESS EXISTS, AND THAT IS A FACT ABOUT THE REPOSITORY
======================================================================
The obvious dry-run for this verifier is a commit whose README stated a
census, a script count, a battery size or a seed the tree did not have.
Three scans over all 372 commits say there is none:

  * the .mbt census (total / production / blackbox / whitebox): 0 commits
    where the README disagreed with the tree;
  * the "N / N Python reference scripts PASS" count: 0;
  * the "kills three mutants on one kernel" battery size: 0;
  * the fuzz harness's fixed seed: 0.

So these claims have ALWAYS tracked the tree.  That is a good result for the
README and a problem for a dry-run, and the answer is the same one the
round-21 coverage dry-run used: a DELIBERATE violation.

THE VIOLATION BREAKS ALL FOUR KINDS OF CLAIM
============================================
  1. a .mbt file is added to the package   -> the census claims are stale
  2. a fourth mutant is added to MUTS      -> "three mutants on one kernel"
  3. the fuzz harness's `fn main` grows a parameter -> "its seed argument
     is ignored -- `fn main` takes no parameters"
  4. a workflow gains a line that RUNS the fuzz check -> "no CI workflow
     runs it either"

Each of those is a different KIND of derivation -- a tree walk, an AST
count, a source signature, a workflow scan -- and the dry-run proves each
one bites.  The counter is checked against the verifier's own summary,
because a count that can drift from the output proves nothing.

Run: python _verify/_dryrun_round22_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r22_mut")

COPY_IN = [
    "_verify/_verify_test_verification_1650.py",
]


def run(cmd, cwd=REPO, timeout=1800):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def patch(path, old, new, count=1):
    """Replace `old` with `new`, keeping the file's own line endings.

    The workflows and the QA registry are CRLF; a pattern written with a
    bare "\\n" will not match them, and a patch that silently does nothing
    is worse than one that fails.
    """
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
print("=== breaking all four kinds of claim ===")

# 1. a .mbt file appears in the package
probe = os.path.join(WORK, "moonbit_doubleML", "r22_probe_tmp.mbt")
with io.open(probe, "w", encoding="utf-8", newline="") as fh:
    fh.write("//| a temporary file, here only to make the census claim false\n")
print("  1. added moonbit_doubleML/r22_probe_tmp.mbt")

# 2. the mutation battery grows a fourth mutant
patch(os.path.join(WORK, ".github", "scripts", "qa_loop", "checks.py"),
      '        ("flip comparison", lambda s: s.replace(">=", ">", 1)),\n',
      '        ("flip comparison", lambda s: s.replace(">=", ">", 1)),\n'
      '        ("a fourth mutant", lambda s: s.replace(">=", ">=", 1)),\n')
print("  2. added a fourth mutant to the QA registry's MUTS")

# 3. the fuzz harness's `fn main` grows a parameter
patch(os.path.join(WORK, "examples", "fuzz", "main.mbt"),
      "fn main {", "fn main(seed : Int) {")
print("  3. gave the fuzz harness's `fn main` a parameter")

# 4. a workflow gains a line that RUNS the fuzz check
patch(os.path.join(WORK, ".github", "workflows", "check.yml"),
      "      - name: QA loop (fast scope)\n",
      "      - name: QA loop (fast scope)\n"
      "        run: python3 .github/scripts/qa_loop/run.py --only fuzz\n")
print("  4. added a workflow step that RUNS the fuzz check")

print()
print("=== running the test-verification verifier ===")
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_test_verification_1650.py")],
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
          "a tree whose verification claims were false ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures)" % exact)

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r22_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
