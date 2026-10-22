"""Dry-run the measurements verifier against a tree whose measurements rot.

WHAT THIS PROVES
=================
`_verify/_verify_measurements_1650.py` holds the README's quoted
MEASUREMENTS to three rules: every ratio the prose states must be derivable
from the numbers its own passage prints, every number in a table cell must be
the correctly-rounded rendering of a value in the record that measured it, and
every small-n figure must be the correctly-rounded rendering of a value in the
record the README cites.

Round 32 found that two of the README's ratios were not derivable -- the
"factor of **344**" was attached to the wrong pair of numbers (that quotient
is 1387), and the IIVM row's "16x *smaller* SE" printed no standard errors to
be 16 times anything -- and that nothing re-derived the hazard table's cells.

THE MECHANISMS
==============
Each mechanism breaks ONE promise, and the failure count must GROW at every
step:

  1. a ratio stops being derivable;
  2. a table cell loses its witness;
  3. a small-n figure loses its witness;
  4. the published check count is wrong;
  5. the published check count is gone;
  6. the SET SIZE moves -- a new table row -- so it runs LAST, because it
     changes the size several of the checks above are stated against.

Mechanisms 4 and 5 share the CHANGELOG's witness -- there is only one place
that publishes this verifier's check count -- so they cannot have sites of
their own.  They are still independent: mechanism 4 rewrites the count and
mechanism 5 DELETES the block that carries it, each by its own pattern, and
neither pattern mentions the other's output.  The two land on different
verdicts, which is the point: a count that is WRONG and a count that is
ABSENT are different failures.

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

Run: python _verify/_dryrun_round32_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r32_mut")
VERIFIER = "_verify/_verify_measurements_1650.py"

ALWAYS_COPY = [VERIFIER]

# the CHANGELOG's witness: the one place that publishes this verifier's count
WITNESS = re.compile(r"\(`_verify/_verify_measurements_1650\.py` \(\*\*(\d+)\*\* checks\)\)")
WITNESS_BLOCK = re.compile(
    r"- \(`_verify/_verify_measurements_1650\.py` \(\*\*\d+\*\* checks\)\)[^\n]*\r?\n"
    r"(?:  [^\n]*\r?\n)*")


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
    """Rewrite the CHANGELOG's published check count for this verifier."""
    text = read(path)
    hits = WITNESS.findall(text)
    if len(hits) != 1:
        raise SystemExit("!! the witness appears %d times (expected 1)" % len(hits))
    write(path, WITNESS.sub(lambda m: m.group(0).replace(
        "(**%s** checks)" % hits[0], "(**%d** checks)" % n), text))


def drop_witness_block(path):
    """Delete the CHANGELOG block that publishes this verifier's check count."""
    text = read(path)
    hits = WITNESS_BLOCK.findall(text)
    if len(hits) != 1:
        raise SystemExit("!! the witness block appears %d times (expected 1)"
                         % len(hits))
    write(path, WITNESS_BLOCK.sub("", text))


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
if len(PUBLISHED) != 1:
    raise SystemExit("!! the CHANGELOG publishes this verifier's count %d times "
                     "(expected 1)" % len(PUBLISHED))
PUBLISHED = int(PUBLISHED[0])
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
    # -- 1. a ratio stops being derivable ------------------------------------
    ("the 344 is attached to the wrong pair again",
     lambda: patch(
         README,
         "the `-0.0277` it\nwas at upstream's start value `theta0 = 1.003`",
         "the `-0.00277` it\nwas at upstream's start value `theta0 = 1.003`")),

    # -- 2. a table cell loses its witness -----------------------------------
    ("a hazard-table cell names a value nobody measured",
     lambda: patch(
         README,
         "| `DoubleMLAPOS` | hazardous | per-level bias to `436.11` |",
         "| `DoubleMLAPOS` | hazardous | per-level bias to `436.19` |")),

    # -- 3. a small-n figure loses its witness -------------------------------
    ("a small-n figure is not in the cited record",
     break_smalln_figure),

    # -- 4. the published check count is wrong -------------------------------
    ("the CHANGELOG publishes a wrong check count",
     lambda: set_witness_count(CHANGELOG, PUBLISHED - 1)),

    # -- 5. the published check count is gone --------------------------------
    ("the CHANGELOG stops publishing the check count",
     lambda: drop_witness_block(CHANGELOG)),

    # -- 6. the SET SIZE moves: LAST on purpose ------------------------------
    # A new table row appears, so the declared cell count no longer holds.  It
    # runs last because it changes the set SIZE, which the checks above are
    # stated against.
    ("a table row appears",
     lambda: patch(
         README,
         "| `DoubleMLPQ` | **hazardous -- fixed in v0.139.0** | ignored its `quantile` entirely |",
         "| `DoubleMLPQ` | **hazardous -- fixed in v0.139.0** | ignored its `quantile` entirely |\n"
         "| `DoubleMLRDD` | not demonstrated | `1.015` vs `1.103` |")),
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
# The CHANGELOG is in DESCENDING order -- the newest entry is at the TOP -- so
# the CURRENT published number is the FIRST occurrence.
_found = re.findall(r"requires the failure count to GROW at every step:\s*"
                    r"\*\*(\d+)\*\*\s+failures at the",
                    read(CHANGELOG))
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
