"""Dry-run the citation verifier against a tree whose citations are broken.

WHAT THIS PROVES
=================
`_verify/_verify_citations_1650.py` reads every `file:line` citation in the
tracked prose and asks whether the cited line MENTIONS the thing the sentence
names.  It derives the citation set from the prose itself, so a citation
cannot be added or removed without the declared count moving with it.

Round 30 found that **64 of the 102** port-side citations in the tracked
prose at v0.164.23 did not point at a line that mentions the thing the
sentence names -- and every one of them still READS FINE, because a sentence
is never re-read when the code underneath it moves.  The four that had broken
worst (`did_binary.mbt:445`, `lplr.mbt:1630`, `lplr.mbt:758`,
`did_cs.mbt:1263`) were cited for things that had since moved 6, 392 and 23
lines away.

EACH MECHANISM IS PROVEN ON ITS OWN
====================================
The mechanisms are applied ONE AT A TIME and the verifier is run after each,
and the failure count must GROW at every step.  A mechanism that contributes
nothing is visible as a flat step, and the driver fails.  (Round 24's dry-run
had exactly that defect: one mechanism contributed ZERO failures, the total
was still > 0, and the dead mechanism hid inside a passing run.)

THE MECHANISMS COVER BOTH SIDES OF THE CLAIM
=============================================
A citation can rot in two ways, and the verifier has to catch both:

  * the CODE moves away from the prose -- mechanism 1 edits the source, which
    is exactly what this round's repairs had to undo;
  * the PROSE moves away from the code -- mechanisms 2 and 3 edit the prose.

Mechanism 1 is the one that matters most.  It is the rot itself: a source
file grows a line above a cited one and every citation into that file above
the insertion point is now pointing at the wrong line, with nothing in the
prose changing.

THE LAST MECHANISM MOVES THE SET SIZE
=====================================
Mechanism 8 removes a citation from the prose entirely, so the derived set
shrinks and the declared counts, the file count and the published-count check
all notice.  It runs LAST on purpose: it changes the derived set SIZE, which
several of the other checks are stated against, so running it earlier would
break those checks and mask the mechanisms above it.

A MECHANISM MUST NOT REPAIR AN EARLIER ONE
==========================================
An early draft of round 29's driver failed at mechanism 4 with a FLAT step,
and the reason was worth keeping.  Mechanism 4 moved the PQ publisher's
range, which changed the derived count in that range from 14 to 13 -- and 13
was exactly what mechanism 2 had already broken the stated count to.  The two
mechanisms were talking to each other: the later one UNDID the earlier one's
failure, so the failure count did not grow even though the tree was still
broken.

The fix is to give every mechanism a site of its own, and to order them so
that no later mechanism can move a derived count onto a value an earlier one
has already broken.  Here every mechanism below has its own citation, its own
file or its own count, and the set-size mechanism is last.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the repaired prose, the new verifier
and the CHANGELOG that publishes the counts -- are copied in from the WORKING
TREE, and the claims are broken on top of that.

The CHANGELOG has to be copied in: it is the file that PUBLISHES the counts,
and at dry-run time the new entry is not in HEAD yet.

Run: python _verify/_dryrun_round30_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r30_mut")
VERIFIER = "_verify/_verify_citations_1650.py"

# the new verifier is not in HEAD yet, so it is copied in by hand
ALWAYS_COPY = [VERIFIER]


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
                         % (path, old[:70], n, count))
    text = text.replace(old, new)
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def patch_re(path, pattern, new, count=1):
    """Replace every match of `pattern` with `new`.

    A regex is needed for the mechanism that REMOVES the published count: by
    then the mechanism that corrupted it has already changed the number, so a
    literal match on the number would no longer find it.
    """
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    crlf = "\r\n" in text
    new = new.replace("\n", "\r\n") if crlf and "\r\n" not in new else new
    if crlf and "\r\n" not in pattern:
        pattern = pattern.replace("\\n", "\r\n")
    hits = re.findall(pattern, text)
    if len(hits) != count:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, pattern[:70], len(hits), count))
    text = re.sub(pattern, lambda m: new, text)
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def insert(path, anchor, added):
    """Insert `added` immediately before the line that contains `anchor`."""
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    crlf = "\r\n" in text
    if crlf and "\r\n" not in anchor:
        anchor = anchor.replace("\n", "\r\n")
        added = added.replace("\n", "\r\n")
    if text.count(anchor) != 1:
        raise SystemExit("!! %s: the anchor %r matched %d times (expected 1)"
                         % (path, anchor[:70], text.count(anchor)))
    text = text.replace(anchor, added + anchor)
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def truncate(path, keep):
    """Keep only the first `keep` lines, as the verifier counts them.

    The verifier reads a file and splits it on "\\n", so a file that ends with
    a newline has one more element than it has lines.  `keep` therefore counts
    ELEMENTS, not visible lines: keeping 43 leaves the file with 43 elements
    and line 44 out of range.
    """
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    crlf = "\r\n" in text
    lines = text.split("\r\n") if crlf else text.split("\n")
    if len(lines) <= keep:
        raise SystemExit("!! %s: it has only %d lines, cannot truncate to %d"
                         % (path, len(lines), keep))
    tail = "\r\n" if crlf else "\n"
    out = tail.join(lines[:keep - 1]) + tail
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(out)


def append(path, extra):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    crlf = "\r\n" in text
    if crlf and "\r\n" not in extra:
        extra = extra.replace("\n", "\r\n")
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text + extra)


def verify(work):
    """Run the verifier in `work`; return (exit code, output, failure count)."""
    rc, out = run([sys.executable, os.path.join(work, VERIFIER)],
                  cwd=work, timeout=3600)
    exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
    return rc, out, exact


def check_count(out):
    m = re.search(r"(\d+) checks, (\d+) failed", out)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


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

# --- copy the working tree's state in -----------------------------------------
# Everything the working tree has modified since HEAD is copied in, because the
# clone carries the COMMITTED tree and this round's repairs are not committed
# yet.  The list is derived, not hard-coded, so a prose file repaired in this
# round cannot be forgotten.
rc, out = run(["git", "diff", "--name-only", "HEAD"])
CHANGED = [x for x in out.split("\n") if x.strip()]

COPY_IN = []
for rel in CHANGED + ALWAYS_COPY:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    if not os.path.isfile(src):
        raise SystemExit("!! %s does not exist in the working tree" % rel)
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    COPY_IN.append(rel)

print("  copied in %d files from the working tree:" % len(COPY_IN))
for rel in COPY_IN:
    print("    %s" % rel)

LIB = os.path.join(WORK, "moonbit_doubleML")
CHANGELOG = os.path.join(WORK, "CHANGELOG.md")

DGP = os.path.join(LIB, "dgp_did_CS2021.mbt")
KFOLD = os.path.join(LIB, "kfold.mbt")
V066WB = os.path.join(LIB, "v066_wbtest.mbt")
V154B = os.path.join(LIB, "expand_v154b_test.mbt")
TUNE = os.path.join(LIB, "tune.mbt")
PSPROC = os.path.join(LIB, "ps_processor.mbt")
SUITE = os.path.join(WORK, "pyexample_suite.py")
SENS = os.path.join(LIB, "sensitivity.mbt")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0 = verify(WORK)
c0, f0 = check_count(out0)
print("  exit=%d  failures=%d  checks=%s" % (rc0, n0, c0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# ------------------------------------------------------------ the mechanisms
MECHANISMS = [
    # -- 1. the CODE moves away from the prose: the rot itself ----------------
    # `kfold.mbt` carries exactly ONE citation (`kfold.mbt:199`), so one line
    # inserted above it moves that one line and nothing else.
    #
    # The target has to be a SINGLE-line citation: a RANGE such as
    # `dgp_did_CS2021.mbt:50-51` keeps its content inside the window when one
    # line is inserted above it, and the first draft of this driver used one
    # and the mechanism contributed nothing.  The driver caught that -- which
    # is what a dry-run is for.
    ("a source file grows a line above a cited one",
     lambda: insert(
         KFOLD,
         "///|\n/// A single fold is represented by a pair of train and test index\n"
         "/// arrays. Test indices are disjoint and together cover `[0, n_obs)`.\n",
         "// The port's own Fold; upstream's is a dataclass with the same two\n"
         "// arrays.\n")),

    # -- 2. the PROSE stops naming the code: nothing left to anchor on -------
    # The citation is inside backticks, so the plain-text fallback after it is
    # empty -- with the one code token gone there is no anchor at all, and the
    # citation becomes UNCHECKABLE.
    ("the prose drops the code token beside the citation",
     lambda: patch(
         V154B,
         "// `cond_d0_t0` (`did_cs.mbt:1336-1348`) builds the four g-function condition",
         "// The mask (`did_cs.mbt:1336-1348`) builds the four g-function condition")),

    # -- 3. the citation is edited one line off ------------------------------
    ("a citation is edited to the wrong line",
     lambda: patch(
         TUNE,
         "(`rfl.mbt:649`)",
         "(`rfl.mbt:650`)")),

    # -- 4. the cited line is out of range ------------------------------------
    # `v066_wbtest.mbt` is used here rather than `ps_processor.mbt` because it
    # carries NO upstream-side citation: truncating a file that does would
    # move the upstream-side count as a SIDE EFFECT, and then mechanism 5 --
    # which moves that count on purpose -- would REPAIR it.  That is exactly
    # the "a mechanism must not repair an earlier one" trap, and the first
    # draft of this driver walked straight into it: mechanism 4 took the
    # upstream count from 266 to 265 and mechanism 5 put it back to 266, so
    # the failure count went flat on a tree that was still broken.
    ("the cited line falls off the end of its file",
     lambda: truncate(V066WB, 43)),

    # -- 5. an upstream-side citation appears: the declared count moves -------
    ("the prose gains an upstream-side citation",
     lambda: append(
         SUITE,
         "\n# Upstream's own grid search lives in doubleml/utils/_estimation.py:12\n")),

    # -- 6. the published check count is wrong -------------------------------
    ("the CHANGELOG publishes a wrong check count",
     lambda: patch(
         CHANGELOG,
         "(`_verify/_verify_citations_1650.py` (**108** checks))",
         "(`_verify/_verify_citations_1650.py` (**107** checks))")),

    # -- 7. the published check count is gone --------------------------------
    # The number has already been corrupted by mechanism 6, so this one matches
    # the line by PATTERN: the point is that the CHANGELOG no longer publishes
    # a count for this verifier at all.
    ("the CHANGELOG stops publishing the check count",
     lambda: patch_re(
         CHANGELOG,
         r"- \(`_verify/_verify_citations_1650\.py` \(\*\*\d+\*\* checks\)\) "
         r"derives the port-side\n"
         r"  citation set from the tracked prose and asks every one of them "
         r"whether the\n"
         r"  line it names mentions the thing the sentence names\.\n",
         "")),

    # -- 8. the SET SIZE moves: LAST on purpose ------------------------------
    # One prose file stops carrying any citation, so the derived port-side
    # count, the file count and the published-count check all move.  It runs
    # last because it changes the set SIZE, which several checks above are
    # stated against.
    ("a prose file stops carrying citations",
     lambda: patch(
         SENS,
         "`compute_sensitivity_bias` (sensitivity.mbt:565) and reproduced below:",
         "`compute_sensitivity_bias` and reproduced below:")),
]

prev = n0
prev_checks = c0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    c, f = check_count(out)
    grew = n > prev
    moved = "" if c == prev_checks else "  (the check count moved %d -> %d)" % (
        prev_checks, c)
    print("  %d. %-66s failures %d -> %d  %s%s"
          % (i, desc[:66], prev, n, "GROW" if grew else "*** FLAT ***", moved))
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    # every mechanism but the last must leave the CHECK COUNT alone: the
    # count is what the CHANGELOG publishes, and a count that drifts with the
    # tree is the defect round 28 shipped.
    if i < len(MECHANISMS) and c != prev_checks:
        print("!! mechanism %d moved the check count -- ABORT" % i)
        sys.exit(1)
    prev = n
    prev_checks = c

# the counter must agree with the verifier's own summary
rc, out, n = verify(WORK)
c, f = check_count(out)
print()
print("=== the counter and the verifier's own summary ===")
print("  the driver counted %d failures" % n)
print("  the verifier says  %s checks, %s failed" % (c, f))
if not c or f != n:
    print("!! the counter and the summary disagree -- ABORT")
    sys.exit(1)
if rc == 0:
    print("!! the broken tree still exits 0 -- ABORT")
    sys.exit(1)

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
#
# The CHANGELOG is in DESCENDING order -- the newest entry is at the TOP -- so
# the CURRENT published number is the FIRST occurrence.  (Taking the last one
# binds the witness to an entry that has already shipped.)
_found = re.findall(r"requires the failure count to GROW at every step:\s*"
                    r"\*\*(\d+)\*\*\s+failures at the",
                    io.open(CHANGELOG, encoding="utf-8", errors="replace").read())
published = int(_found[0]) if _found else None
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
