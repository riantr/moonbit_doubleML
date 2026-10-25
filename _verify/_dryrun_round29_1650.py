"""Dry-run the docstring-count verifier against a tree whose claims are broken.

WHAT THIS PROVES
=================
`_verify/_verify_docstring_counts_1650.py` derives the `bias_corrected*` family
from the SOURCE -- its members, each one's self-declared "vX.Y.Z+:" version,
and the count of members in any stated range -- and then asks five docstrings
whether they agree.

Round 29 found three false counts in the public API docstrings, and each of
them is a sentence that READS FINE: a count of a family that was right when it
was written and was never revisited as the family grew.  "Identical in
reasoning to the twelve `bias_corrected_coef` methods added in v0.86.0 -
v0.92.0" is not a typo; it is a stale number in a sentence a user reads in an
IDE.  No spelling check and no README check sees any of them.

EACH MECHANISM IS PROVEN ON ITS OWN
====================================
The mechanisms are applied ONE AT A TIME and the verifier is run after each,
and the failure count must GROW at every step.  A mechanism that contributes
nothing is visible as a flat step, and the driver fails.  (Round 24's dry-run
had exactly that defect: one mechanism contributed ZERO failures, the total
was still > 0, and the dead mechanism hid inside a passing run.)

THE LAST MECHANISMS PROVE THE DERIVATION IS LIVE
=================================================
Mechanism 5 moves a member's self-declared version, so the derived counts
change and the publisher whose own range it falls out of is caught.  Nothing in
the verifier is hard-coded to "the family has fifteen members": the count is
re-derived from the source, so the publishers that still state the old number
fail.

Mechanism 15 removes a member from the SOURCE, so the family shrinks and the
publishers, the canonical `bias_corrected_theta` docstring and the "exactly
five sites publish a count" check all notice.  It runs LAST on purpose: it
changes the derived plain-family SIZE, which several of the section-3 checks
are stated against, so running it earlier would break those checks and mask
the mechanisms above it.

A MECHANISM MUST NOT REPAIR AN EARLIER ONE
==========================================
An early draft of this driver failed at mechanism 4 with a FLAT step, and the
reason was worth keeping.  Mechanism 4 moved the PQ publisher's range, which
changed the derived count in that range from 14 to 13 -- and 13 was exactly
what mechanism 2 had already broken the stated count to.  The two mechanisms
were talking to each other: the later one UNDID the earlier one's failure,
so the failure count did not grow even though the tree was still broken.

The fix is to give every mechanism a site of its own, and to order them so
that no later mechanism can move a derived count onto a value an earlier
mechanism has already broken.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the three corrected docstrings, the
new verifier and the CHANGELOG that publishes the two counts -- are copied in
from the WORKING TREE, and the claims are broken on top of that.

The CHANGELOG has to be copied in: it is the file that PUBLISHES the counts,
and at dry-run time the new entry is not in HEAD yet.  (Round 28's driver did
not copy it, and got away with it only because the numbers it published had
already been committed by the time it ran.)

Run: python _verify/_dryrun_round29_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r29_mut")
VERIFIER = "_verify/_verify_docstring_counts_1650.py"

COPY_IN = [
    "CHANGELOG.md",
    "moonbit_doubleML/lpq.mbt",
    "moonbit_doubleML/quantile.mbt",
    "moonbit_doubleML/sandwich.mbt",
    VERIFIER,
]

# the vendored upstream tree is NOT tracked, so it has to be copied in
# explicitly -- without it the verifier reports no vendored 0.11.4 and the
# baseline is not green.
COPY_DIRS = ["_verify/_upstream_0114"]


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

for rel in COPY_DIRS:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copytree(src, dst)
    print("  copied in %s (directory)" % rel)

LPQ = os.path.join(WORK, "moonbit_doubleML", "lpq.mbt")
QUANT = os.path.join(WORK, "moonbit_doubleML", "quantile.mbt")
SAND = os.path.join(WORK, "moonbit_doubleML", "sandwich.mbt")
LPLR = os.path.join(WORK, "moonbit_doubleML", "lplr.mbt")
RDD = os.path.join(WORK, "moonbit_doubleML", "rdd.mbt")
SENS = os.path.join(WORK, "moonbit_doubleML", "sensitivity.mbt")
BLP = os.path.join(WORK, "moonbit_doubleML", "blp_policy.mbt")
FIT = os.path.join(WORK, "moonbit_doubleML", "fit_cache.mbt")
LOG = os.path.join(WORK, "moonbit_doubleML", "logistic.mbt")
DIDBIN = os.path.join(WORK, "moonbit_doubleML", "did_binary.mbt")
PS = os.path.join(WORK, "moonbit_doubleML", "ps_processor.mbt")

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
    # -- the three claims this round fixed ------------------------------------
    ("lpq.mbt's count goes back to 'twelve'",
     lambda: patch(
         LPQ,
         "/// bias correction. Identical in reasoning to the thirteen\n"
         "/// `bias_corrected_coef` methods added in v0.86.0 - v0.92.0; see",
         "/// bias correction. Identical in reasoning to the twelve\n"
         "/// `bias_corrected_coef` methods added in v0.86.0 - v0.92.0; see")),

    ("quantile.mbt's PQ count goes back to 'thirteen'",
     lambda: patch(
         QUANT,
         "/// bias correction. Identical in reasoning to the fourteen\n"
         "/// `bias_corrected_coef` methods added in v0.86.0 - v0.93.0; see",
         "/// bias correction. Identical in reasoning to the thirteen\n"
         "/// `bias_corrected_coef` methods added in v0.86.0 - v0.93.0; see")),

    ("sandwich.mbt's canonical 'All twelve' comes back",
     lambda: patch(
         SAND,
         "///      number. All fifteen `bias_corrected_coef` methods are",
         "///      number. All twelve `bias_corrected_coef` methods are")),

    # -- a version RANGE moves, so the derived count in it moves ---------------
    ("quantile.mbt's QTE range loses its upper bound",
     lambda: patch(
         QUANT,
         "/// `bias_corrected_coef` methods added in v0.86.0 - v0.94.0; see",
         "/// `bias_corrected_coef` methods added in v0.86.0 - v0.93.0; see")),

    # -- the DERIVATION is live: a member's version moves ---------------------
    # LPLR moves DOWN to v0.91.0, so the count in every range is unchanged and
    # no earlier mechanism's break is repaired -- only the publisher whose own
    # range it falls out of is caught.
    ("lplr.mbt's member is re-versioned, so the derived counts move",
     lambda: patch(
         LPLR,
         "/// v0.92.0+: returns `coef` UNCHANGED --",
         "/// v0.91.0+: returns `coef` UNCHANGED --")),

    # -- a publisher stops publishing a count ----------------------------------
    ("lplr.mbt stops publishing a count at all",
     lambda: patch(
         LPLR,
         "/// a bias correction. Identical in reasoning to the twelve\n"
         "/// `bias_corrected_coef` methods added in v0.86.0 - v0.91.0;",
         "/// a bias correction. Identical in reasoning to the\n"
         "/// same argument as its siblings;")),

    # -- the other package-wide counts ----------------------------------------
    ("rdd.mbt says 14 other estimators have the bias correction",
     lambda: patch(
         RDD,
         "`bias_corrected_coef` already exists on 15 other estimators in this",
         "`bias_corrected_coef` already exists on 14 other estimators in this")),

    ("sensitivity.mbt says eight upstream estimators set the flag",
     lambda: patch(
         SENS,
         "the seven estimators whose upstream sets",
         "the eight estimators whose upstream sets")),

    ("blp_policy.mbt says the tree node has 4 slots",
     lambda: patch(
         BLP,
         "/// Layout: 5 slots per node, emitted in pre-order. Each node",
         "/// Layout: 4 slots per node, emitted in pre-order. Each node")),

    ("fit_cache.mbt says the hash samples 5 rows from each end",
     lambda: patch(
         FIT,
         "/// 10 + last 10 rows, first column), and the full content of",
         "/// 5 + last 5 rows, first column), and the full content of")),

    ("logistic.mbt says max_iter = 50",
     lambda: patch(
         LOG,
         "/// The default `max_iter = 25` comfortably covers both well-separated",
         "/// The default `max_iter = 50` comfortably covers both well-separated")),

    ("sensitivity.mbt says GainStatsResult has three fields",
     lambda: patch(
         SENS,
         "/// Returned by `gain_statistics`. The four fields are",
         "/// Returned by `gain_statistics`. The three fields are")),

    ("did_binary.mbt says four methods are delegated",
     lambda: patch(
         DIDBIN,
         "the three methods are delegated\n/// rather than recomputed",
         "the four methods are delegated\n/// rather than recomputed")),

    ("ps_processor.mbt says thirteen upstream estimators call it",
     lambda: patch(
         PS,
         "the function twelve\n/// upstream estimators call",
         "the function thirteen\n/// upstream estimators call")),

    # -- the DERIVATION is live, and it is LAST on purpose --------------------
    # Removing a member changes the derived plain-family SIZE, which several
    # of the section-3 checks are stated against -- so if this ran earlier it
    # would break those checks and mask the mechanisms above.  It runs last,
    # and it still does not REPAIR any of them: the counts it moves land on
    # values none of the broken publishers happen to state.
    ("the source loses a `bias_corrected_coef` member",
     lambda: patch(
         QUANT,
         "pub fn DoubleMLPQ::bias_corrected_coef(self : DoubleMLPQ) -> Double {",
         "pub fn DoubleMLPQ::bias_corrected_coef_removed(self : DoubleMLPQ) -> Double {")),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    grew = n > prev
    print("  %d. %-70s failures %d -> %d  %s"
          % (i, desc[:70], prev, n, "GROW" if grew else "*** FLAT ***"))
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n

# the counter must agree with the verifier's own summary
rc, out, n = verify(WORK)
m = re.search(r"(\d+) checks, (\d+) failed", out)
print()
print("=== the counter and the verifier's own summary ===")
print("  the driver counted %d failures" % n)
print("  the verifier says  %s checks, %s failed" % (m.group(1), m.group(2)))
if not m or int(m.group(2)) != n:
    print("!! the counter and the summary disagree -- ABORT")
    sys.exit(1)
if rc == 0:
    print("!! the broken tree still exits 0 -- ABORT")
    sys.exit(1)

# the check COUNT must not have moved -- the whole point of the fixed-count
# design is that the published number cannot drift when the tree does.
if int(m.group(1)) != int(re.search(r"(\d+) checks", out).group(1)):
    print("!! the check count moved -- ABORT")
    sys.exit(1)

def published_count(text, driver):
    """The failure count the CHANGELOG publishes FOR THIS DRIVER.

    The lookup is SCOPED twice: to the ENTRY that names the driver, and
    within that entry to the BULLET that names it.  The CHANGELOG is in
    descending order, so the newest entry wins -- and a newest entry that
    publishes two drivers' counts must not bind one driver's number to the
    other's.  An entry that NAMES a driver without publishing a count for it
    is not a publication, so the search falls through to the older one.
    """
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                         text, re.M | re.S):
        body = m.group(2)
        if driver not in body:
            continue
        lines = body.split("\n")
        start = None
        for i, l in enumerate(lines):
            if driver in l:
                start = i
                break
        if start is None:
            continue
        head = start
        while head > 0 and not lines[head].startswith("- "):
            head -= 1
        tail = start + 1
        while tail < len(lines) and not lines[tail].startswith("- "):
            tail += 1
        # The sentence that carries the number is hard-WRAPPED, so the
        # phrase is matched against a whitespace-COLLAPSED bullet.  A
        # pattern with literal spaces matches only the entries that
        # happen to keep the phrase on ONE line -- and the driver then
        # reads an OLDER entry's number and calls it its own.
        flat = re.sub(r"\s+", " ", "\n".join(lines[head:tail]))
        found = re.findall(r"requires the failure count to GROW at every step: "
                           r"\*\*(\d+)\*\* failures at the", flat)
        if found:
            return int(found[0])
    return None

# --- the published failure count, witnessed -----------------------------------
# The CHANGELOG publishes the number of failures this dry-run ends at.  A
# published exact number with nothing asserting it goes stale silently, so the
# dry-run ASSERTS its own published number: it measures the final failure
# count and compares that with the number the CHANGELOG states.
#
# The count is TREE-DEPENDENT on purpose -- the verifier reports one failure
# per broken claim, and the tree under test here is deliberately broken.  That
# is why the number this dry-run ends at is NOT the number the verifier makes
# on the tree as it stands.
CHANGELOG = os.path.join(WORK, "CHANGELOG.md")
# The CHANGELOG is in DESCENDING order -- the newest entry is at the TOP -- so
# the CURRENT published number is the FIRST occurrence.  (Taking the last one
# binds the witness to an entry that has already shipped.)
published = published_count(io.open(CHANGELOG, encoding="utf-8", errors="replace").read(), "_dryrun_round29_1650.py")
print()
print("=== the published failure count, witnessed ===")
if published is None:
    print("  the CHANGELOG publishes no failure count for this dry-run -- ABORT")
    print("  (this run measured %d -- put that number in the CHANGELOG)" % n)
    sys.exit(1)
print("  the CHANGELOG publishes %d; this run measured %d" % (published, n))
if published != n:
    print("!! the published failure count and the measured one disagree -- ABORT")
    sys.exit(1)
print("  OK -- the published number is the number this run measured")

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
