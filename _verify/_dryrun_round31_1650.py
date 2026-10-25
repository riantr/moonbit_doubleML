"""Dry-run the example-pin verifier against a tree whose pins are broken.

WHAT THIS PROVES
=================
`_verify/_verify_example_pins_1650.py` asks one question of every example
manifest: does its import pin name the library version the package is
actually at?

Round 31 found that **21 of 21** example manifests pinned the library at a
version from **159 releases ago** -- nineteen at `0.52.0` and two at
`0.162.0` -- while the package was at `0.164.24`.  Nothing could see it: in
the WORKSPACE the pin is INERT, because the workspace member wins, so every
example built against the current library while its manifest named an ancient
one.  Outside the workspace the pin decides what gets installed, and a user
who copies an example -- which is what the README's Examples section invites
-- gets a library the example was never written against.

THE MECHANISMS COVER THE THREE PROMISES
=========================================
A pin can go wrong in three ways, and the verifier has to catch all three:

  * an example's pin goes stale -- mechanism 1;
  * the README's own install instruction goes stale -- mechanism 2;
  * the published count drifts -- mechanisms 3 and 4.

Mechanism 5 moves the SET SIZE: an example manifest appears, so the declared
count of 21 no longer holds.  It runs LAST on purpose -- it changes the set
SIZE, which several of the other checks are stated against, so running it
earlier would break those checks and mask the mechanisms above it.

A MECHANISM MUST NOT REPAIR AN EARLIER ONE
==========================================
Round 29's driver failed at mechanism 4 with a FLAT step, and the reason was
worth keeping: a later mechanism moved a derived count onto exactly the value
an earlier mechanism had broken, so the failure count did not grow even
though the tree was still broken.  The fix is to give every mechanism a site
of its own, and to order them so that no later mechanism can move a derived
value onto a value an earlier one has already broken.  Here every mechanism
below has its own file, and the set-size mechanism is last.

Mechanisms 3 and 4 share the CHANGELOG's witness -- there is only one place
that publishes this verifier's check count -- so they cannot have sites of
their own.  They are still independent, and the driver proves it: mechanism 3
rewrites the count and mechanism 4 DELETES the block that carries it, each by
its own pattern, and neither pattern mentions the other's output.  The two
land on different verdicts, which is the point: a count that is WRONG and a
count that is ABSENT are different failures, and the verifier has to report
both.

NOTHING HERE CARRIES A VERSION LITERAL
======================================
The version is READ from the tree under test, and the published check count
is READ from the CHANGELOG under test.  A literal here would be a tracked
file naming a current version, and the round-9 check requires every such
file to be a site the bump script covers -- so the driver would have to be
bumped with every release, for no gain.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the re-pinned manifests, the bump
script, the new verifier and the CHANGELOG that publishes the count -- are
copied in from the WORKING TREE, and the claims are broken on top of that.

Run: python _verify/_dryrun_round31_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r31_mut")
VERIFIER = "_verify/_verify_example_pins_1650.py"

ALWAYS_COPY = [VERIFIER]

# the CHANGELOG's witness: the one place that publishes this verifier's count
WITNESS = re.compile(r"\(`_verify/_verify_example_pins_1650\.py` \(\*\*(\d+)\*\* checks\)\)")
WITNESS_BLOCK = re.compile(
    r"- \(`_verify/_verify_example_pins_1650\.py` \(\*\*\d+\*\* checks\)\) asks every\r?\n"
    r"  example manifest whether its import pin names the library version\r?\n"
    r"  the package is actually at\.\r?\n")


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


def lib_version(work):
    """The library's version, read from the tree under test."""
    src = read(os.path.join(work, "moonbit_doubleML", "moon.mod"))
    m = re.search(r'^version\s*=\s*"([^"]+)"', src, re.M)
    if not m:
        raise SystemExit("!! the tree under test has no library version")
    return m.group(1)


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
LPLR = os.path.join(WORK, "examples", "lplr", "moon.mod")
NEWEX = os.path.join(WORK, "examples", "r31_new", "moon.mod")

VER = lib_version(WORK)
PUBLISHED = WITNESS.findall(read(CHANGELOG))
if len(PUBLISHED) != 1:
    raise SystemExit("!! the CHANGELOG publishes this verifier's count %d times "
                     "(expected 1)" % len(PUBLISHED))
PUBLISHED = int(PUBLISHED[0])
print("  the tree under test is at %s; the CHANGELOG publishes %d checks"
      % (VER, PUBLISHED))

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
    # -- 1. an example's pin goes stale --------------------------------------
    ("an example manifest pins an old library",
     lambda: patch(
         LPLR,
         '"riantr/moonbit_doubleML@%s"' % VER,
         '"riantr/moonbit_doubleML@0.52.0"')),

    # -- 2. the README's own install instruction goes stale ------------------
    ("the README's install block names an old library",
     lambda: patch(
         README,
         '"riantr/moonbit_doubleML@%s"' % VER,
         '"riantr/moonbit_doubleML@0.52.0"')),

    # -- 3. the published check count is wrong -------------------------------
    ("the CHANGELOG publishes a wrong check count",
     lambda: set_witness_count(CHANGELOG, PUBLISHED - 1)),

    # -- 4. the published check count is gone --------------------------------
    ("the CHANGELOG stops publishing the check count",
     lambda: drop_witness_block(CHANGELOG)),

    # -- 5. the SET SIZE moves: LAST on purpose ------------------------------
    # A new example manifest appears, so the declared count of 21 no longer
    # holds.  It runs last because it changes the set SIZE, which several
    # checks above are stated against.
    ("an example manifest appears",
     lambda: (os.makedirs(os.path.dirname(NEWEX), exist_ok=True),
              io.open(NEWEX, "w", encoding="utf-8", newline="\n").write(
                  'name = "local/moonbit_doubleML-examples-r31_new"\n\n'
                  'version = "0.1.0"\n\n'
                  'import {\n'
                  '  "riantr/moonbit_doubleML@0.52.0",\n'
                  '}\n'))),
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
published = published_count(read(CHANGELOG), "_dryrun_round31_1650.py")
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
