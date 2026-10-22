"""Dry-run the measurements verifier against a tree whose measurements rot.

WHAT THIS PROVES
=================
`_verify/_verify_measurements_1650.py` holds the README's quoted
MEASUREMENTS to four rules: every ratio the prose states must be derivable
from the numbers its own passage prints, every number in a table cell must be
the correctly-rounded rendering of a value in the record that measured it, a
table's measurements must be written in code spans, and every small-n figure
must be the correctly-rounded rendering of a value in the record the README
cites.

Round 33 found that the second rule was narrower than its own wording: the
cell numbers were collected from the CODE SPANS, so a table that wrote its
measurements in bold and plain -- the propensity table -- was never looked at.
Its four measurements (`-225.86`, `0.043`, `1.44`, `0.842`) had never been
checked, and they were checkable all along: the v0.131.9 record holds all
four.  The fourth rule is the fix -- the convention becomes a check, so the
next table that breaks it fails here instead of going unchecked for another
twenty releases.

THE MECHANISMS
==============
Each mechanism breaks ONE promise, and the failure count must GROW at every
step:

  1. a table cell loses its witness;
  2. a ratio stops being derivable;
  3. a small-n figure loses its witness;
  4. the published check count is wrong;
  5. the published check count is gone;
  6. a measurement appears outside a code span -- I4 alone catches it, and the
     cell set does not move;
  7. the SET SIZE moves -- a measurement loses its code span -- so it runs
     LAST, because it changes the size several of the checks above are
     stated against.

Mechanisms 4 and 5 share the CHANGELOG's witness -- there is only one place
that publishes this verifier's check count -- so they cannot have sites of
their own.  They are still independent: mechanism 4 rewrites the count and
mechanism 5 DELETES the block that carries it, each by its own pattern, and
neither pattern mentions the other's output.  The two land on different
verdicts, which is the point: a count that is WRONG and a count that is
ABSENT are different failures.

Mechanism 6 is the one round 33 added: it breaks the CONVENTION without
touching the cell set, so I4's verdict is visible on its own rather than
riding along with the set-size check that mechanism 7 triggers.

NOTHING HERE CARRIES A VERSION LITERAL
======================================
The version is READ from the tree under test, and the published check count
is READ from the CHANGELOG under test.  A literal here would be a tracked
file naming a current version, and the round-9 check requires every such
file to be a site the bump script covers.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the patched README, the builder,
the new verifier and the CHANGELOG that publishes the count -- are copied in
from the WORKING TREE, and the claims are broken on top of that.

Run: python _verify/_dryrun_round33_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r33_mut")
VERIFIER = "_verify/_verify_measurements_1650.py"

ALWAYS_COPY = [VERIFIER]

# the CHANGELOG's witness: the one place that publishes this verifier's count
WITNESS = re.compile(r"\(`_verify/_verify_measurements_1650\.py` \(\*\*(\d+)\*\* checks\)\)")
WITNESS_BLOCK = re.compile(
    r"- \(`_verify/_verify_measurements_1650\.py` \(\*\*\d+\*\* checks\)\)[^\n]*\r?\n"
    r"(?:  [^\n]*\r?\n)*")

# the published FAILURE count -- scoped to the entry that names THIS driver, so
# a later round's entry cannot be read in its place.
FAILCOUNT = re.compile(r"requires the failure count to GROW at every step:\s*"
                       r"\*\*(\d+)\*\*\s+failures at the")


def entry_naming(text, filename):
    """The CHANGELOG entry that names `filename` -- the newest one."""
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                         text, re.M | re.S):
        if filename in m.group(2):
            return m.group(2)
    return None


def run(cmd, cwd=REPO, timeout=3600):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def read(path):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def patch(path, old, new, count=1):
    """Replace `old` with `new`, keeping the file's own line endings."""
    text = read(path)
    crlf = "\r\n" in text
    old = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
    new = new.replace("\n", "\r\n") if crlf and "\r\n" not in new else new
    n = text.count(old)
    if n != count:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, old[:70], n, count))
    write(path, text.replace(old, new))


def set_witness_count(path, n):
    """Rewrite the CHANGELOG's published check count for this verifier.

    Only the NEWEST occurrence is rewritten: the CHANGELOG keeps one entry
    per release, and the verifier reads the newest one -- that is the entry
    describing the tree under test.  An older entry's count is history and is
    left alone.
    """
    text = read(path)
    hits = list(WITNESS.finditer(text))
    if not hits:
        raise SystemExit("!! the witness is absent")
    m = hits[0]
    write(path, text[:m.start()]
          + m.group(0).replace("(**%s** checks)" % m.group(1), "(**%d** checks)" % n)
          + text[m.end():])


def drop_witness_block(path):
    """Delete the CHANGELOG blocks that publish this verifier's check count.

    ALL of them, not just the newest: the point of this mechanism is that the
    count becomes ABSENT, which is a different failure from a count that is
    WRONG.  Dropping only the newest would leave an older entry's count
    behind, and the verdict would not move.
    """
    text = read(path)
    hits = list(WITNESS_BLOCK.finditer(text))
    if not hits:
        raise SystemExit("!! the witness block is absent")
    for m in reversed(hits):
        text = text[:m.start()] + text[m.end():]
    write(path, text)


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

CHANGELOG = os.path.join(WORK, "CHANGELOG.md")
README = os.path.join(WORK, "README.mbt.md")

PUBLISHED = WITNESS.findall(read(CHANGELOG))
if not PUBLISHED:
    raise SystemExit("!! the CHANGELOG does not publish this verifier's count")
PUBLISHED = int(PUBLISHED[0])          # the NEWEST entry -- the one under test
print("  the CHANGELOG publishes %d checks" % PUBLISHED)

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


def break_smalln_figure():
    """Make the small-n figure unwitnessed, in BOTH places that carry it.

    The figure set is a SET of distinct values, so replacing one occurrence
    would leave the other and GROW the set -- and a mechanism that moves a
    set size belongs last.
    """
    patch(README, "`theta0 = 6.842`", "`theta0 = 6.843`")
    patch(README, "`6.842` sits at the **90th percentile**",
          "`6.843` sits at the **90th percentile**")


# ------------------------------------------------------------ the mechanisms
MECHANISMS = [
    # -- 1. a table cell loses its witness -----------------------------------
    ("a hazard-table cell names a value nobody measured",
     lambda: patch(
         README,
         "| `DoubleMLAPOS` | hazardous | per-level bias to `436.11` |",
         "| `DoubleMLAPOS` | hazardous | per-level bias to `436.19` |")),

    # -- 2. a ratio stops being derivable ------------------------------------
    ("the 344 is attached to the wrong pair again",
     lambda: patch(
         README,
         "the `-0.0277` it\nwas at upstream's start value `theta0 = 1.003`",
         "the `-0.00277` it\nwas at upstream's start value `theta0 = 1.003`")),

    # -- 3. a small-n figure loses its witness -------------------------------
    ("a small-n figure is not in the cited record",
     break_smalln_figure),

    # -- 4. the published check count is wrong -------------------------------
    ("the CHANGELOG publishes a wrong check count",
     lambda: set_witness_count(CHANGELOG, PUBLISHED - 1)),

    # -- 5. the published check count is gone --------------------------------
    ("the CHANGELOG stops publishing the check count",
     lambda: drop_witness_block(CHANGELOG)),

    # -- 6. a measurement sits outside a code span ---------------------------
    # I4 alone catches this one: the cell set does not move, because the
    # offending number was never a cell -- it is a measurement written in
    # plain text where the document writes every other one in a code span.
    ("a measurement is written outside a code span",
     lambda: patch(
         README,
         "differs by exactly 1 ULP:",
         "differs by exactly 1.0 ULP:")),

    # -- 7. the SET SIZE moves: LAST on purpose ------------------------------
    # A measurement loses its code span, so it stops being a cell AND it stops
    # being code-spanned: the declared cell count no longer holds and I4
    # fails.  It runs last because it changes the set SIZE, which the checks
    # above are stated against.
    ("a measurement loses its code span",
     lambda: patch(
         README,
         "| `linear_regression` | **`-225.86`** | `0.043` |",
         "| `linear_regression` | **`-225.86`** | 0.043 |")),
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
    print("  %d. %-62s failures %d -> %d  %s%s"
          % (i, desc[:62], prev, n, "GROW" if grew else "*** FLAT ***", moved))
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
# dry-run ASSERTS its own published number.
#
# The count is TREE-DEPENDENT on purpose -- the verifier reports one failure
# per broken claim, and the tree under test here is deliberately broken.
#
# The lookup is SCOPED to the entry that names THIS driver, so a later round's
# entry cannot be read in its place.
_entry = entry_naming(read(CHANGELOG), "_dryrun_round33_1650.py")
if _entry is None:
    print()
    print("=== the published failure count, witnessed ===")
    print("  no CHANGELOG entry names this driver -- ABORT")
    sys.exit(1)
_found = FAILCOUNT.findall(_entry)
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
