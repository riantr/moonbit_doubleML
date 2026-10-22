"""Dry-run the release-tree verifier against a tree whose promises rot.

WHAT THIS PROVES
=================
`_verify/_verify_release_tree_1650.py` checks the tree at a REF rather than
the files on disk.  Round 33 published v0.164.27 with
`examples/api_server/moon.mod` pinning `0.164.26` while the library was at
`0.164.27`: the tree that was TESTED and the tree that was RELEASED were
different trees, because the commit captured the index and the `git add`
list for that release was hand-written.

THE MECHANISMS
===============
Each mechanism breaks ONE promise in the tree, COMMITS it, and the failure
count must GROW at every step.  Committing is the point: a verifier that
reads a ref cannot see an uncommitted edit, so a mechanism that only wrote a
file would prove nothing.

  1. a manifest's pin goes stale;
  2. a bump site stops naming the version;
  3. the two README copies differ;
  4. the README's status table stops naming the version;
  5. the README's install block stops pinning;
  6. the published check count is wrong;
  7. the SET SIZE moves -- a manifest appears -- so it runs LAST, because it
     changes the size several of the checks above are stated against.

Mechanism 6 rewrites the count and nothing else touches the CHANGELOG's
witness, so the two land on different verdicts: a count that is WRONG and a
count that is ABSENT are different failures.

NOTHING HERE CARRIES A VERSION LITERAL
======================================
The version is READ from the tree under test, and the published check count
is READ from the CHANGELOG under test.  A literal here would be a tracked
file naming a current version, and the round-9 check requires every such
file to be a site the bump script covers.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
verifier and the CHANGELOG that publishes the counts are copied in from the
WORKING TREE and committed, so the tree under test is the one that publishes
them -- otherwise the published-count check would be vacuous.

Run: python _verify/_dryrun_round34_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r34_mut")
VERIFIER = "_verify/_verify_release_tree_1650.py"

ALWAYS_COPY = [VERIFIER]


def run(cmd, cwd=REPO, timeout=1800):
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


def commit(work, paths, message):
    """Stage the named paths and commit them IN THE CLONE.

    A verifier that reads a ref cannot see an uncommitted edit, so every
    mechanism has to leave a COMMIT behind.
    """
    rc, out = run(["git", "-C", work, "add", "--"] + paths, cwd=work)
    if rc != 0:
        raise SystemExit("!! git add failed: %s" % out.strip()[:300])
    rc, out = run(["git", "-C", work, "-c", "user.name=dry-run",
                   "-c", "user.email=dry-run@example.invalid",
                   "commit", "-m", message], cwd=work)
    if rc != 0:
        raise SystemExit("!! git commit failed: %s" % out.strip()[:300])
    return out.strip().splitlines()[0] if out.strip() else ""


def verify(work):
    """Run the verifier in `work`; return (exit code, output, failure count)."""
    rc, out = run([sys.executable, os.path.join(work, VERIFIER)],
                  cwd=work, timeout=1800)
    exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
    return rc, out, exact


def check_count(out):
    m = re.search(r"(\d+) checks, (\d+) failed", out)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


if os.path.isdir(WORK):
    try:
        shutil.rmtree(WORK)
    except PermissionError:
        # git writes its object files READ-ONLY, and Windows will not delete
        # a read-only file.  Make them writable and try again.
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
COPY_IN = list(ALWAYS_COPY)
for rel in COPY_IN:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    shutil.copy2(src, dst)

# the CHANGELOG that publishes the counts has to be IN the tree under test,
# or the published-count check is vacuous.
shutil.copy2(os.path.join(REPO, "CHANGELOG.md"),
             os.path.join(WORK, "CHANGELOG.md"))
COPY_IN.append("CHANGELOG.md")

print("  copied in %d files from the working tree:" % len(COPY_IN))
for rel in COPY_IN:
    print("    %s" % rel)
commit(WORK, COPY_IN, "dry-run: the tree under test publishes the counts")

CHANGELOG = os.path.join(WORK, "CHANGELOG.md")
README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")

# the version the tree under test is at -- READ, never a literal
version = None
for line in read(os.path.join(WORK, "moonbit_doubleML", "moon.mod")).split("\n"):
    m = re.search(r'version = "([^"]+)"', line)
    if m:
        version = m.group(1)
        break
if version is None:
    raise SystemExit("!! the tree under test carries no library version")
print("  the tree under test is at %s" % version)

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
    # -- 1. a manifest's pin goes stale ---------------------------------------
    ("a manifest's pin goes stale",
     lambda: (patch(os.path.join(WORK, "examples", "apo", "moon.mod"),
                    'riantr/moonbit_doubleML@%s"' % version,
                    'riantr/moonbit_doubleML@0.0.1"'),
              commit(WORK, ["examples/apo/moon.mod"],
                     "dry-run: a stale manifest pin"))),

    # -- 2. a bump site stops naming the version ------------------------------
    ("a bump site stops naming the version",
     lambda: (patch(os.path.join(WORK, "doc", "002_installation",
                                  "readme.mbt.md"),
                    'riantr/moonbit_doubleML@%s"' % version,
                    'riantr/moonbit_doubleML@0.0.1"'),
              commit(WORK, ["doc/002_installation/readme.mbt.md"],
                     "dry-run: a site that names no version"))),

    # -- 3. the two README copies differ -------------------------------------
    ("the two README copies differ",
     lambda: (patch(SHIPPED, "# moonbit_doubleML", "# moonbit_doubleML "),
              commit(WORK, ["moonbit_doubleML/README.mbt.md"],
                     "dry-run: the README copies differ"))),

    # -- 4. the status table stops naming the version -------------------------
    ("the README's status table stops naming the version",
     lambda: (patch(README, "| `moon.mod` version | **%s** |" % version,
                    "| `moon.mod` version | **0.0.1** |"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: the status table names no version"))),

    # -- 5. the install block stops pinning -----------------------------------
    ("the README's install block stops pinning",
     lambda: (patch(README, '"riantr/moonbit_doubleML@%s"' % version,
                    '"riantr/moonbit_doubleML@0.0.1"'),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: the install block pins nothing"))),

    # -- 6. the published check count is wrong --------------------------------
    ("the CHANGELOG publishes a wrong check count",
     lambda: (patch(CHANGELOG,
                    "_verify/_verify_release_tree_1650.py` (**34** checks)",
                    "_verify/_verify_release_tree_1650.py` (**31** checks)"),
              commit(WORK, ["CHANGELOG.md"],
                     "dry-run: a wrong published count"))),

    # -- 7. the SET SIZE moves: LAST on purpose ------------------------------
    # A manifest appears, so the declared manifest count no longer holds.  It
    # runs last because it changes the set SIZE, which the checks above are
    # stated against.
    ("a manifest appears",
     lambda: (os.makedirs(os.path.join(WORK, "examples", "newone"),
                          exist_ok=True),
              write(os.path.join(WORK, "examples", "newone", "moon.mod"),
                    'name = "example/newone"\nversion = "0.1.0"\n\n'
                    'import {\n  "riantr/moonbit_doubleML@%s",\n}\n' % version),
              commit(WORK, ["examples/newone/moon.mod"],
                     "dry-run: a new manifest"))),
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
    print("  %d. %-56s failures %d -> %d  %s%s"
          % (i, desc[:56], prev, n, "GROW" if grew else "*** FLAT ***", moved))
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
# The lookup is SCOPED to the entry that names THIS driver, so a later
# round's entry cannot be read in its place.
_entry = None
for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                     read(CHANGELOG), re.M | re.S):
    if "_dryrun_round34_1650.py" in m.group(2):
        _entry = m.group(2)
        break
_found = re.findall(r"requires the failure count to GROW at every step:\s*"
                    r"\*\*(\d+)\*\*\s+failures at the", _entry or "")
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
