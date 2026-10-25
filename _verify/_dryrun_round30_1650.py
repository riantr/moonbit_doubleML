"""Dry-run the pointer verifier against a tree whose pointers rot.

WHAT THIS PROVES
=================
An in-repo `file:line` pointer is a PROMISE: the thing the sentence names is
AT that line.  `_verify/_verify_file_line_refs_1650.py` owns that promise
today, and this driver breaks it one promise at a time and watches the
failure count GROW.

WHY THE VERIFIER MOVED
======================
This driver used to drive `_verify/_verify_citations_1650.py`, which derived
a `file:line` citation set from the tracked prose and asked every citation
whether the line it names mentions the thing the sentence names.  That file
was REWRITTEN in v0.164.33 into the publisher-record checker (the README's
literature citations), so the driver kept running -- and every mechanism it
applied became invisible: the checker it drove reads the README's three
journal citations and nothing else, and a source file grows a line above a
cited one without the README noticing.

The CLASS moved, not the promise: v0.164.36 gave the in-repo pointers an
owner of their own (`_verify/_verify_file_line_refs_1650.py`, **60** checks),
and this driver follows the class.  A driver that kept pointing at the
filename would keep exiting 0 on a broken tree, which is the failure this
whole suite exists to catch.

THE MECHANISMS
==============
The checker makes four checks per pointer, and each of them is broken here
on a pointer of its own -- a class proved on a pointer another mechanism
already broke is a class with one mechanism:

  1. the target file EXISTS and is TRACKED -- broken twice: a file that is
     not in the tree, and a file that is in the tree but is not tracked;
  2. the cited line is WITHIN the file -- broken twice: the file is
     truncated below the cited line, and a pointer names a line past the
     end of its file;
  3. the cited line is not BLANK -- broken on three files;
  4. the block that cites it names something the target file CARRIES --
     broken once.

  1. the CODE moves away from the prose -- a source file grows a line above
     a cited one (did.mbt), so the pointer lands on a line that carries
     nothing;
  2. the same, on a second file (irm.mbt);
  3. the same, on a third file (iivm.mbt);
  4. the PROSE moves away from the code -- the block stops naming what the
     target file carries (README.mbt.md);
  5. the cited line falls off the end of its file -- the file is truncated;
  6. a pointer names a line past the end of its file;
  7. a pointer names a file that is not in the tree;
  8. a pointer names a file that is in the tree but is not TRACKED;
  9. the SET SIZE moves -- a pointer appears in the prose that names a file
     that is not there.  It runs LAST on purpose: it changes the SET the
     other mechanisms are stated against.

THE SET, NOT THE COUNT
======================
Every mechanism but the last must leave the POINTER SET alone -- the set of
promises the checker derives from the prose.  A mechanism that quietly added
or dropped a pointer could hide a failure behind a different number, which
is the trap round 29's driver walked into.

The CHECK count is a different thing, and it is allowed to move: a pointer
whose line falls past the end of its file makes two checks instead of four,
so breaking that promise moves the count DOWN.  The count the CHANGELOG
publishes for this checker -- **60** -- is the count it makes on the HEALTHY
tree, and `_verify/_verify_ledger_counts_1650.py` is what holds it to that;
this driver breaks the tree on purpose, so the count it sees on the broken
tree is not the published one.

And no mechanism may REPAIR an earlier one: a failure that disappears is a
failure the mechanism undid, and a total that hides it is not a proof.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the repaired prose, the checker and
the CHANGELOG that publishes the counts -- are copied in from the WORKING
TREE and COMMITTED, so the tree under test is the tree that carries the
checker being exercised (a pointer's target must be TRACKED, and a file that
is only in the working tree is not tracked).

Run: python _verify/_dryrun_round30_1650.py
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
COMMIT = "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r30_mut")
VERIFIER = "_verify/_verify_file_line_refs_1650.py"

# the checker is not in HEAD yet on a round that writes it, so it is copied in
ALWAYS_COPY = [VERIFIER]


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


def truncate(path, keep):
    """Keep only the first `keep` lines, as the checker counts them.

    The checker reads a file and splits it on "\\n", so a file that ends with
    a newline has one more element than it has lines.  `keep` therefore counts
    ELEMENTS, not visible lines: keeping 43 leaves the file with 43 elements
    and line 44 out of range.
    """
    text = read(path)
    crlf = "\r\n" in text
    lines = text.split("\r\n") if crlf else text.split("\n")
    if len(lines) <= keep:
        raise SystemExit("!! %s: it has only %d lines, cannot truncate to %d"
                         % (path, len(lines), keep))
    tail = "\r\n" if crlf else "\n"
    out = tail.join(lines[:keep - 1]) + tail
    write(path, out)


def append(path, extra):
    text = read(path)
    crlf = "\r\n" in text
    if crlf and "\r\n" not in extra:
        extra = extra.replace("\n", "\r\n")
    write(path, text + extra)


def commit(work, paths, message):
    """Stage the named paths and commit them IN THE CLONE.

    A file that is only in the working tree is not TRACKED, and a pointer to
    an untracked file is a broken promise -- so the tree under test carries
    its own commits.

    A commit with NOTHING to commit is not a failure: the copy-in can be a
    no-op when the tree under test already carries those files.
    """
    rc, out = run(["git", "-C", work, "add", "--"] + paths, cwd=work)
    if rc != 0:
        raise SystemExit("!! git add failed: %s" % out.strip()[:300])
    rc, out = run(["git", "-C", work, "-c", "user.name=dry-run",
                   "-c", "user.email=dry-run@example.invalid",
                   "commit", "-m", message], cwd=work)
    if rc != 0:
        if "nothing to commit" in out or "nothing added to commit" in out:
            return "(already in the tree)"
        raise SystemExit("!! git commit failed: %s" % out.strip()[:300])
    return out.strip().splitlines()[0] if out.strip() else ""


def verify(work):
    """Run the checker in `work`; return (exit code, output, failure count).

    WHAT IS COUNTED
    ===============
    A failing CHECK.  The marker `*** FAIL ***` goes on each failing check
    line, and the count is by CONTAINMENT: the checker families print the
    marker at the front of the line, and a rule that matched only one
    position would under-count the failures of the others.
    """
    rc, out = run([sys.executable, os.path.join(work, VERIFIER)],
                  cwd=work, timeout=3600)
    exact = len([l for l in out.splitlines()
                 if "*** FAIL ***" in l and l.strip() != "*** FAIL ***"])
    return rc, out, exact


def summaries_of(out):
    """The checker's own counts, in either summary convention.

    Two conventions are in the contract: the `N checks, M failed` form and
    the `checks run: N, checks failed: M` form.  A rule that read only one
    of them would under-count the failures of the other family.
    """
    found = re.findall(r"(\d+) checks,\s*(\d+) failed", out)
    found += [(m.group(1), m.group(2)) for m in
              re.finditer(r"checks run:\s*(\d+),\s*checks failed:\s*(\d+)", out)]
    return found


def check_count(out):
    """(checks, failed) as the checker reports them, as integers."""
    sums = summaries_of(out)
    if not sums:
        return (None, None)
    c, f = sums[-1]
    return (int(c) if c is not None else None, int(f))


def pointer_count(out):
    """The number of in-repo pointers the checker derived.

    This is the tree's SHAPE: the set of promises the checker makes.  The
    CHECK count is not the same thing -- a pointer whose line falls past the
    end of its file makes two checks instead of four, so breaking a promise
    moves the check count down.  The pointer set is what a mechanism must not
    change behind the other mechanisms' backs.
    """
    m = re.search(r"in-repo pointers\s*:\s*(\d+)", out)
    return int(m.group(1)) if m else None


def failure_lines(out):
    """The failing checks, one line each."""
    return [l.strip() for l in out.splitlines()
            if "*** FAIL ***" in l and l.strip() != "*** FAIL ***"]


def published_count(text, driver):
    """The failure count the CHANGELOG publishes FOR THIS DRIVER.

    The lookup is SCOPED twice: to the ENTRY that names the driver, and
    within that entry to the BULLET that names it.  The CHANGELOG is in
    descending order, so the newest entry wins -- and a newest entry that
    publishes two drivers' counts must not bind one driver's number to the
    other's.
    """
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                         text, re.M | re.S):
        body = m.group(2)
        if driver not in body:
            continue
        # the bullet the driver is named in, with its continuation lines
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
        bullet = "\n".join(lines[head:tail])
        # The sentence that carries the number is hard-WRAPPED, so the
        # phrase is matched against a whitespace-COLLAPSED bullet.  A
        # pattern with literal spaces matches only the entries that
        # happen to keep the phrase on ONE line -- and the driver then
        # reads an OLDER entry's number and calls it its own.
        flat = re.sub(r"\s+", " ", bullet)
        found = re.findall(r"requires the failure count to GROW at every step: "
                           r"\*\*(\d+)\*\* failures at the", flat)
        if found:
            return int(found[0])
    return None


if os.path.isdir(WORK):
    try:
        shutil.rmtree(WORK)
    except PermissionError:
        # git writes its object files READ-ONLY, and Windows will not delete
        # a read-only file.  Make them writable and try again -- without
        # this the driver cannot be run twice, and a dry-run that only runs
        # once is a dry-run nobody re-runs.
        for _root, _dirs, _files in os.walk(WORK):
            for _f in _files:
                try:
                    os.chmod(os.path.join(_root, _f), stat.S_IWRITE)
                except OSError:
                    pass
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
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checker")

README = os.path.join(WORK, "README.mbt.md")
DID = os.path.join(WORK, "moonbit_doubleML", "did.mbt")
IRM = os.path.join(WORK, "moonbit_doubleML", "irm.mbt")
IIVM = os.path.join(WORK, "moonbit_doubleML", "iivm.mbt")
QUANTILE = os.path.join(WORK, "moonbit_doubleML", "quantile.mbt")
GHOST = os.path.join(WORK, "moonbit_doubleML", "ghost_not_tracked.mbt")

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
    # -- 1. the CODE moves away from the prose: the rot itself ---------------
    # A source file grows a line ABOVE a cited one, so the pointer -- a fixed
    # line number -- lands on the line that was inserted instead of on the
    # code it named.  The inserted line is BLANK, because that is the form of
    # the shift this checker can see: it checks that the cited line carries
    # something, and a blank line carries nothing.
    ("a source file grows a line above a cited one",
     lambda: patch(
         DID,
         "///     weight_resid   = (D - m) / (p_hat * (1 - m))",
         "\n///     weight_resid   = (D - m) / (p_hat * (1 - m))")),

    # -- 2. the same, on a SECOND file ---------------------------------------
    ("the same, on a second source file",
     lambda: patch(
         IRM,
         "      cv=Some(folds_to_cv_partition(folds)),",
         "\n      cv=Some(folds_to_cv_partition(folds)),")),

    # -- 3. the same, on a THIRD file ----------------------------------------
    ("the same, on a third source file",
     lambda: patch(
         IIVM,
         "      cv=Some(folds_to_cv_partition(folds)),",
         "\n      cv=Some(folds_to_cv_partition(folds)),")),

    # -- 4. the PROSE moves away from the code -------------------------------
    # The block that cites `ssm.mbt:73-74` names the estimators it compares,
    # and `DoubleMLSSM` is the only one of them the target file carries.
    # Renaming it leaves the block naming nothing the target file has, and
    # the pointer now points at a file that does not say what the sentence
    # says.
    ("the prose stops naming what the target file carries",
     lambda: patch(
         README,
         "`DoubleMLSSM` has the largest margin of the four migrations of\n"
         "v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and\n"
         "`DoubleMLSSM` -- because its score carries **two** reciprocals, one per\n",
         "`DoubleMLSSMX` has the largest margin of the four migrations of\n"
         "v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and\n"
         "`DoubleMLSSMX` -- because its score carries **two** reciprocals, one per\n")),

    # -- 5. the cited line falls off the end of its file ---------------------
    # The file is truncated below the cited line, so the pointer names a line
    # the file does not have.
    ("the cited line falls off the end of its file",
     lambda: truncate(QUANTILE, 216)),

    # -- 6. a pointer names a line past the end of its file ------------------
    ("a pointer names a line past the end of its file",
     lambda: patch(
         README,
         "`cvar.mbt:1005`",
         "`cvar.mbt:999999`")),

    # -- 7. a pointer names a file that is not in the tree -------------------
    ("a pointer names a file that is not in the tree",
     lambda: patch(
         README,
         "`did_cross_section.mbt:615`",
         "`did_cross_section_gone.mbt:615`")),

    # -- 8. a pointer names a file that is not TRACKED -----------------------
    # The file is IN the tree -- it is right there -- and it is not in the
    # index, so a clone does not have it.  A pointer to it is a promise only
    # this working tree keeps.
    #
    # The stub carries the identifier the citing block names, and the
    # pointer names a line the stub HAS, so the ONLY promise this mechanism
    # breaks is the trackedness one: a mechanism that breaks two at once
    # cannot say which one the failure was.
    ("a pointer names a file that is not tracked",
     lambda: (write(GHOST,
                    "pub fn ghost_not_tracked() -> Unit {\n"
                    "  // adjust_ps\n"
                    "}\n"),
              patch(
                  README,
                  "`ssm.mbt:671`",
                  "`ghost_not_tracked.mbt:1`"))),

    # -- 9. the SET SIZE moves: LAST on purpose -----------------------------
    # A pointer appears in the prose that names a file that is not there, so
    # the derived set GROWS: the checker makes four more checks, and the new
    # pointer is one of them.  It runs last because it changes the size the
    # mechanisms above are stated against.
    ("a pointer appears in the prose",
     lambda: append(
         README,
         "\nA pointer that names nothing: `not_in_this_tree.mbt:1`.\n")),
]

prev = n0
prev_checks = c0
prev_pointers = pointer_count(out0)
prev_fails = failure_lines(out0)
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    c, f = check_count(out)
    p = pointer_count(out)
    fails = failure_lines(out)
    grew = n > prev
    moved = "" if c == prev_checks else "  (the check count moved %d -> %d)" % (
        prev_checks, c)
    print("  %d. %-56s failures %d -> %d  %s%s"
          % (i, desc[:56], prev, n, "GROW" if grew else "*** FLAT ***", moved))
    # a mechanism must not REPAIR an earlier one: a failure that is gone is
    # a failure this mechanism undid, and the total would hide it.
    for l in prev_fails:
        if l not in fails:
            print("  !! mechanism %d REPAIRED a failure -- ABORT" % i)
            print("     %s" % l[:110])
            sys.exit(1)
    # every mechanism but the last must leave the POINTER SET alone: the set
    # is what the other mechanisms are stated against, and a mechanism that
    # quietly changed it could hide a failure behind a different count.
    if i < len(MECHANISMS) and p != prev_pointers:
        print("!! mechanism %d moved the pointer set (%d -> %d) -- ABORT"
              % (i, prev_pointers, p))
        sys.exit(1)
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n
    prev_checks = c
    prev_pointers = p
    prev_fails = fails

# the counter must agree with the checker's own summary
rc, out, n = verify(WORK)
c, f = check_count(out)
print()
print("=== the counter and the checker's own summary ===")
print("  the driver counted %d failures" % n)
print("  the checker says  %s checks, %s failed" % (c, f))
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
# The count is TREE-DEPENDENT on purpose -- the checker reports one failure
# per broken promise, and the tree under test here is deliberately broken.
# That is why the number this dry-run ends at is NOT the number the checker
# makes on the tree as it stands.
published = published_count(read(os.path.join(REPO, "CHANGELOG.md")),
                            "_dryrun_round30_1650.py")
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
