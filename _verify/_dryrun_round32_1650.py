"""Dry-run the measurements verifier against a tree whose measurements rot.

WHAT THIS PROVES
=================
`_verify/_verify_measurements_1650.py` holds the README's quoted
MEASUREMENTS to three rules: every ratio the prose states must be derivable
from the numbers its own passage prints, every number in a table cell must be
the correctly-rounded rendering of a value in the record that measured it, and
every small-n figure must be the correctly-rounded rendering of a value in the
record the README cites.

It also holds the CHANGELOG's publication of its OWN check count to the count
this run makes: the number the CHANGELOG publishes for this check is a promise
about the tree, and this check is the one that keeps it.

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

THE WITNESS IS THE LIVE PUBLICATION
===================================
The count is published in the CHANGELOG's NEWEST entry, and that is the
publication the verifier reads: it takes the FIRST one it finds, and the
CHANGELOG is in descending order.  An older entry's count is HISTORY -- no
check reads it -- so a mechanism that rewrote one of those would break a
promise nobody keeps, and the dry-run would prove nothing.  The witness is
therefore matched in the shape the verifier reads, and the drop takes EVERY
publication of it, so that the count becomes ABSENT rather than merely old.

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

# the CHANGELOG's witness: the one place that publishes this verifier's count.
#
# The SHAPE is the shape the verifier reads -- the name, then the count -- and
# the FIRST match is the LIVE publication: the CHANGELOG is in descending
# order, so its newest entry comes first, and the verifier reads that one.
# An older entry's count is HISTORY: no check reads it, so a mechanism that
# rewrote one would break nothing and the dry-run would prove nothing.
WITNESS = re.compile(r"_verify/_verify_measurements_1650\.py` \(\*\*(\d+)\*\* checks\)")
# The publication's SHAPE is not enumerated here.  A list of shapes is a list
# of literals, and the CHANGELOG grew a third spelling -- "- `name` (**N**
# checks) -- ..." -- that no list knew about: the count SURVIVED the drop, so
# "the count is GONE" was indistinguishable from "the count is WRONG", the
# mechanism contributed NOTHING, and the driver aborted.  A mechanism that
# cannot fail is not a mechanism.  The drop is DERIVED from WITNESS instead
# (see drop_witness_block), so it does not care how the count is spelled.
#
# PUBLICATION is the guard that keeps the drop from swallowing a line that
# publishes a DIFFERENT verifier's count.
PUBLICATION = re.compile(r"\(\*\*\d+\*\* checks\)")


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

    The deletion is DERIVED from the witness pattern, so it removes every
    publication however the CHANGELOG spells it.  A shape the drop did not
    recognise would SURVIVE it, the count would stay published, and this
    mechanism would contribute nothing -- which is exactly what happened when
    the newest entry spelled the publication "- `name` (**N** checks) -- ...".

    Each publication goes as a whole logical bullet: the line that carries
    the count, plus the lines that continue it -- indented, not the start of
    a new bullet, not carrying a count of their own, and stopped by a blank
    line.
    """
    text = read(path)
    lines = text.splitlines(keepends=True)
    kept = []
    dropped = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        if not WITNESS.search(line):
            kept.append(line)
            i += 1
            continue
        dropped += 1
        i += 1
        while i < len(lines):
            nxt = lines[i]
            body = nxt.rstrip("\r\n")
            if not body.strip():
                break
            if not body[:1].isspace():
                break
            if body.lstrip().startswith("- "):
                break
            if PUBLICATION.search(nxt):
                break
            i += 1
    if not dropped:
        raise SystemExit("!! the witness block is absent")
    kept_text = "".join(kept)
    if WITNESS.search(kept_text):
        raise SystemExit("!! a publication SURVIVED the drop -- the count is "
                         "still published, and the mechanism would contribute "
                         "nothing")
    write(path, kept_text)


def add_unknown_spelling(path):
    """Publish the count AGAIN, in a spelling the drop has never seen.

    The drop has to remove EVERY publication, whatever its spelling: a
    publication in a shape it does not know SURVIVES the drop, the count
    stays published, and "the count is GONE" becomes indistinguishable from
    "the count is WRONG" -- the mechanism contributes nothing and the driver
    aborts.  That is the defect this round found: the newest entry spelled
    its publication "- `name` (**N** checks) -- ...", and the drop's list of
    shapes had never seen it.

    So a SECOND publication is written, in a shape that starts with a
    PREFIX -- every enumerated shape started the line with the witness
    itself, so a line that starts with something else is a spelling no list
    of shapes could have held.  The count is COPIED from the live
    publication, so the two agree and the drop has to take both.
    """
    text = read(path)
    m = WITNESS.search(text)
    if not m:
        raise SystemExit("!! the witness is absent")
    h = re.search(r"(?m)^## \[", text)
    if not h:
        raise SystemExit("!! the CHANGELOG has no entry heading")
    insert_at = text.find("\n", h.start()) + 1
    if insert_at <= 0:
        raise SystemExit("!! the CHANGELOG's first heading has no line after it")
    addition = "\n- also published by %s\n" % m.group(0)
    write(path, text[:insert_at] + addition + text[insert_at:])


def drop_every_publication(path):
    """Publish the count in an unknown spelling, then drop every publication."""
    add_unknown_spelling(path)
    drop_witness_block(path)


def verify(work):
    """Run the verifier in `work`; return (exit code, output, failure count)."""
    rc, out = run([sys.executable, os.path.join(work, VERIFIER)],
                  cwd=work, timeout=3600)
    exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
    return rc, out, exact


def check_count(out):
    m = re.search(r"(\d+) checks, (\d+) failed", out)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def entry_naming(text, filename):
    """The CHANGELOG entry that names `filename` -- the newest one.

    The lookup below is scoped to the entry that names THIS driver.  Without
    the scope, a LATER round's entry -- which sits higher in the file and
    carries the same sentence -- would be read in its place.
    """
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                         text, re.M | re.S):
        if filename in m.group(2):
            return m.group(2)
    return None


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
    # A publication in a shape the drop does not know SURVIVES the drop, and
    # then "the count is GONE" is indistinguishable from "the count is
    # WRONG": the mechanism contributes nothing and the driver aborts.  So a
    # SECOND publication is written in a spelling the drop has never seen,
    # and the drop has to take BOTH.
    ("the CHANGELOG stops publishing the check count, in a spelling the drop has never seen",
     lambda: drop_every_publication(CHANGELOG)),

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
# dry-run ASSERTS its own published number.
#
# The count is TREE-DEPENDENT on purpose -- the verifier reports one failure
# per broken claim, and the tree under test here is deliberately broken.
#
# The CHANGELOG is in DESCENDING order -- the newest entry is at the TOP -- so
# the CURRENT published number is the FIRST occurrence.
_entry = entry_naming(read(CHANGELOG), "_dryrun_round32_1650.py")
published = published_count(read(CHANGELOG), "_dryrun_round32_1650.py")
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
