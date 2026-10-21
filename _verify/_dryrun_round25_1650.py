"""Dry-run the snippet-names verifier against a tree whose NAMES are broken.

WHAT THIS PROVES
=================
`_verify/_verify_snippet_names_1650.py` checks that the names the README uses
are the package's names: that a snippet passes only real constructor
arguments, that every `LearnerDispatch::X` the README names is a public
FUNCTION rather than an enum variant, and that the example-binaries figure
and its own decomposition close.

Round 25 found three such defects by reading -- a snippet passing `alpha` to
a constructor that has none, two enum variants named where the package's
functions belong, and a decomposition summing to 19 under a headline of 21.
None of them is a wrong claim about behaviour, so no claim verifier could see
them: a well-formed claim about a call that does not compile is still a
well-formed claim.

EACH MECHANISM IS PROVEN ON ITS OWN
====================================
Round 24's dry-run had SIX mechanisms and one of them contributed ZERO
failures -- it patched the wrong slot, so the total was > 0 and the dead
mechanism hid inside a passing run.  So this one applies the mechanisms ONE
AT A TIME and runs the verifier after each, and requires the failure count to
GROW at every step.  A mechanism that contributes nothing is visible as a
flat step, and the driver fails.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the rebuilt README, the fixed
source docstring, the new verifier -- are copied in from the WORKING TREE, and
the names are broken on top of that.

Run: python _verify/_dryrun_round25_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r25_mut")
VERIFIER = "_verify/_verify_snippet_names_1650.py"

COPY_IN = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "moonbit_doubleML/lplr.mbt",
    VERIFIER,
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


def verify(work):
    """Run the verifier in `work`; return (exit code, output, failure count)."""
    rc, out = run([sys.executable, os.path.join(work, VERIFIER)],
                  cwd=work, timeout=3600)
    exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
    return rc, out, exact


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

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
LPLR = os.path.join(WORK, "moonbit_doubleML", "lplr.mbt")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0 = verify(WORK)
print("  exit=%d  failures=%d" % (rc0, n0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# ------------------------------------------------------------ the mechanisms
MECHANISMS = [
    ("the README's LPLR snippet passes `alpha` again", lambda: patch(
        README,
        "   let model = DoubleMLLPLR::new(data).fit()",
        "   let model = DoubleMLLPLR::new(data, alpha=1.5).fit()")),
    ("the source docstring passes `alpha` again", lambda: patch(
        LPLR,
        "/// let model = DoubleMLLPLR::new(data).fit()",
        "/// let model = DoubleMLLPLR::new(data, alpha=1.5).fit()")),
    ("the nonlinear options are named by their enum variants again", lambda: patch(
        README,
        "`LearnerDispatch::random_forest_classifier(RFClassifier::new(...))` and\n"
        "`LearnerDispatch::gradient_boosting_classifier(GBClassifier::new(...))` are\n"
        "the nonlinear options.",
        "`LearnerDispatch::RandomForestClassifier` and\n"
        "`LearnerDispatch::GradientBoostingClassifier` are the nonlinear options.")),
    ("the example-binaries decomposition loses its two fixtures again", lambda: patch(
        README,
        "- ✅ **21 runnable example binaries** -- 16 CLI demos, plus\n"
        "  `examples/api_server/` (the HTTP service), `examples/consumer_demo/`,\n"
        "  `examples/fuzz/`, and the two fixtures `examples/bitexact/` and\n"
        "  `examples/parity/`.",
        "- ✅ **21 runnable example binaries** -- 16 CLI demos, an HTTP service, a\n"
        "  consumer demo and a property-based fuzz harness.")),
]

print()
print("=== breaking the names, one mechanism at a time ===")
counts = [n0]
transcript = []
for i, (label, apply) in enumerate(MECHANISMS, start=1):
    apply()
    print("  %d. %s" % (i, label))
    rc, out, n = verify(WORK)
    print("     exit=%d  failures=%d  (was %d)" % (rc, n, counts[-1]))
    if n <= counts[-1]:
        print("     !! this mechanism contributed NO failure -- it is a dead control")
    counts.append(n)
    transcript.append((label, rc, out))

# the shipped copy must stay byte-identical, so it gets the same damage
shutil.copy2(README, SHIPPED)

print()
print("=== the fully broken tree ===")
rc, out, final = verify(WORK)
print(out)
print("=== verifier exit code: %d ===" % rc)
print()

exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
print("EXACT failure count (check lines carrying the marker): %d" % exact)

m = re.search(r"(\d+) checks, (\d+) failed", out)
if m:
    print("verifier summary: checks=%s failed=%s" % (m.group(1), m.group(2)))
    agree = int(m.group(2)) == exact
    print("the counter agrees with the summary: %s" % agree)
else:
    print("verifier summary: NOT FOUND (the verifier probably crashed)")
    agree = False

# every mechanism must have contributed
grew = all(counts[i + 1] > counts[i] for i in range(len(counts) - 1))
print()
print("failure count after each mechanism: %s" % counts)
print("every mechanism contributed a failure: %s" % grew)

print()
if rc == 0:
    print("VERDICT: *** the dry-run did NOT bite -- the verifier PASSED against "
          "a tree whose names were broken ***")
    sys.exit(1)
if not grew:
    print("VERDICT: *** a mechanism contributed no failure -- a dead control ***")
    sys.exit(1)
if not agree:
    print("VERDICT: *** the counter disagrees with the verifier's own summary ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures, every mechanism visible)"
      % exact)

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r25_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
    fh.write("failure count after each mechanism: %s\n" % counts)
print("wrote %s" % LOG)
sys.exit(0)
