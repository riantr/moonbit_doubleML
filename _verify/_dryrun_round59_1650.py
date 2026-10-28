#!/usr/bin/env python3
"""Round 59 dry-run: break the README's SHAPE twenty-five ways, and watch the
verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_readme_shape_1650.py` holds the shape the two references have
-- and a verifier that only ever prints "ok" is indistinguishable from one that
never fires.

So this driver copies the tree into a scratch clone, breaks each promise one
way at a time, and requires the failure count to GROW at every step.  A
contract nobody can break is a contract nobody is really checking.

THE MECHANISMS, AND WHY THEY ARE IN THIS ORDER
===============================================
One per shape property the round-59 measurement found missing or unheld.  Each
changes ONE thing in ONE place, and each must trip a check that no earlier
mechanism has tripped: a mechanism that trips an already-tripped check is
FLAT, and a flat step means the mechanism is not being measured.

The mechanisms are CUMULATIVE, so their order is part of their design:

  * a mechanism that REMOVES a thing comes AFTER the mechanisms that edit it,
    because there is nothing left to edit afterwards; and
  * the anchors are DISJOINT, so one mechanism's edit never breaks the next
    mechanism's pattern.  A mechanism whose pattern no longer matches is not
    being measured -- it is an accident.

   1  the badge's repository
   2  the badge's alt text
   3  the badge's workflow
   4  the badge, after the status paragraph
   5  the badge, below the first section
   6  the badge, gone
   7  a version literal in the status paragraph
   8  the status paragraph's licence
   9  the status paragraph's backends
  10  the status paragraph's estimator count
  11  the status paragraph's section pointer
  12  the status paragraph's "not claimed"
  13  the status paragraph, below the first section
  14  the status paragraph, gone
  15  the console block
  16  the install command
  17  `moon update`
  18  the MoonBit import block
  19  the "not covered" section
  20  the licence section
  21  the attribution section
  22  the backend column
  23  the toolchain statement
  24  the test-count row
  25  the provenance file

WHAT IS COUNTED
===============
A failing CHECK.  The marker `*** FAIL ***` goes on each failing check line;
a line whose WHOLE content is the marker is a section HEADER some verifiers
print after their counter, and a header is not a check, so it is excluded.
The count is by CONTAINMENT, not by prefix or by suffix.

THE COUNT MUST NOT DEPEND ON THE CLONE
=======================================
The clone carries the WORKING TREE's state -- `git diff --name-only HEAD`
plus this round's new files -- because the tree under test is the tree the
fixes are in.  A clone built from the INDEX instead would be internally
inconsistent, and the count would measure the wrong tree.

Run: python _verify/_dryrun_round59_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r59")
DRIVER = "_verify/_dryrun_round59_1650.py"
VERIFIERS = [
    "_verify/_verify_readme_shape_1650.py",
]
README = "README.mbt.md"
ADDED = [
    "_verify/_dryrun_round59_1650.py",
    "_verify/_verify_readme_shape_1650.py",
]

# The badge line is found STRUCTURALLY, not by its current wording: an earlier
# mechanism may already have changed the alt text or the workflow name, and a
# mechanism that cannot find what the previous one broke is not being measured.
BADGE_LINE = re.compile(
    r"^\[!\[([^\]]*)\]\(([^)]*badge\.svg)\)\]\(([^)]*)\)\n", re.M)
# The status paragraph likewise: it is the run of quoted lines that opens with
# `> **Status**`, whatever the sentences between them now say.
STATUS_LINE = re.compile(r"^> \*\*Status\*\*.*(?:\n> .*)*\n", re.M)


def run(cmd, cwd=REPO, timeout=3600, stdin=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout,
                       input=stdin)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def read(path):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())


def sub(path, pattern, repl, expect=1, flags=0):
    """Replace the regex `pattern` with `repl`, `expect` times.

    A REGEX, not a literal: the mechanisms must patch the text as it NOW
    stands, and the wording moves with every release.  A literal here would
    be a second copy of the promise, and it would rot.
    """
    t = read(path)
    t2, n = re.subn(pattern, repl, t, count=expect, flags=flags)
    if n != expect:
        raise SystemExit("!! %s: pattern matched %d times, expected %d"
                         % (os.path.basename(path), n, expect))
    write(path, t2)


def cut(path, pattern, flags=0):
    """Remove the regex `pattern`.

    The pattern may be a COMPILED regex: `re.subn` refuses a flags argument
    beside one, and refusing is the right behaviour -- a compiled pattern
    already carries its own flags.
    """
    t = read(path)
    if hasattr(pattern, "subn"):
        t2, n = pattern.subn("", t, count=1)
    else:
        t2, n = re.subn(pattern, "", t, count=1, flags=flags)
    if n != 1:
        raise SystemExit("!! %s: pattern matched %d times, expected 1"
                         % (os.path.basename(path), n))
    write(path, t2)


def commit(work, paths, message):
    rc, out = run(["git", "-C", work, "add", "--"] + paths, cwd=work)
    if rc != 0:
        raise SystemExit("!! git add failed: %s" % out.strip()[:300])
    rc, out = run(["git", "-C", work, "-c", "user.name=dry-run",
                   "-c", "user.email=dry-run@example.invalid",
                   "commit", "-q", "-m", message], cwd=work)
    if rc != 0:
        if "nothing to commit" in out or "nothing added to commit" in out:
            return "(already in the tree)"
        raise SystemExit("!! git commit failed: %s" % out.strip()[:300])
    return out.strip().splitlines()[0] if out.strip() else ""


def verify(work):
    """Run the verifiers in `work`; returns (rc, output, failure count, lists)."""
    total = 0
    chunks = []
    by_verifier = []
    for rel in VERIFIERS:
        r, out = run([sys.executable, os.path.join(work, rel)], cwd=work,
                     timeout=3600)
        chunks.append(out)
        lines = []
        for l in out.splitlines():
            if "*** FAIL ***" in l and l.strip() != "*** FAIL ***":
                lines.append(l.strip())
        by_verifier.append(lines)
        total += len(lines)
    return (0 if total == 0 else 1), "\n".join(chunks), total, by_verifier


def summaries_of(out):
    """The verifiers' own failure counts, in EVERY summary convention."""
    found = []
    for pat, g in (
            (r"^\s*(\d+) checks, (\d+) failed\s*$", 2),
            (r"SUMMARY:\s*(\d+) checks, (\d+) failures", 2),
            (r"checks failed:\s*(\d+)", 1),
            (r"checks run:\s*(\d+),\s*checks failed:\s*(\d+)", 2),
    ):
        for m in re.finditer(pat, out, re.M):
            if g == 2:
                found.append((m.group(1), m.group(2)))
            else:
                found.append(("?", m.group(1)))
    return found


# --------------------------------------------------------------- the scratch tree
if os.path.isdir(WORK):
    try:
        shutil.rmtree(WORK)
    except PermissionError:
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
rc, out = run(["git", "-C", WORK, "checkout", "--detach", COMMIT])
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "-C", WORK, "rev-parse", "HEAD"])
print("  %s -> %s" % (COMMIT, out.strip()))
# The clone MUST be a repository of its own: every git command below names it
# with `-C`, so a missing `.git` is an error and never the parent repo.
if not os.path.isdir(os.path.join(WORK, ".git")):
    print("!! the clone has no .git -- refusing to run")
    sys.exit(1)

# --- copy the WORKING TREE's state in ----------------------------------------
rc, out = run(["git", "diff", "--name-only", "HEAD"])
STAGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
COPY_IN = []
for rel in list(VERIFIERS) + [DRIVER] + [README] + ADDED + STAGED:
    rel = rel.replace("\\", "/")
    if rel in COPY_IN:
        continue
    src = os.path.join(REPO, rel.replace("/", os.sep))
    if not os.path.isfile(src):
        continue
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    COPY_IN.append(rel)
print("  copied in %d files from the working tree" % len(COPY_IN))
commit(WORK, COPY_IN, "dry-run: the tree under test carries the shape checks")

RM = os.path.join(WORK, README)


# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """The badge's repository."""
    t = read(RM)
    m = BADGE_LINE.search(t)
    if not m:
        raise SystemExit("!! no badge line")
    t = t[:m.start()] + m.group(0).replace(
        "github.com/riantr/moonbit_doubleML", "github.com/somebody/other_repo") + \
        t[m.end():]
    write(RM, t)


def m2():
    """The badge's alt text."""
    sub(RM, r"\[!\[CI\]\(", "[![Build](")


def m3():
    """The badge's workflow."""
    sub(RM, r"actions/workflows/check\.yml", "actions/workflows/no_such_workflow.yml",
        expect=2)


def m4():
    """The badge, after the status paragraph."""
    t = read(RM)
    m = BADGE_LINE.search(t)
    if not m:
        raise SystemExit("!! no badge line")
    badge = m.group(0)
    t = t[:m.start()] + t[m.end():]
    i = t.index("## Features\n")
    t = t[:i] + badge + "\n" + t[i:]
    write(RM, t)


def m5():
    """The badge, below the first section."""
    t = read(RM)
    m = BADGE_LINE.search(t)
    if not m:
        raise SystemExit("!! no badge line")
    badge = m.group(0)
    t = t[:m.start()] + t[m.end():]
    t = t.rstrip("\n") + "\n\n" + badge
    write(RM, t)


def m6():
    """The badge, gone.

    Found positionally, not by a block pattern: an earlier mechanism may have
    moved the badge to the end of the file, where no blank line follows it.
    """
    t = read(RM)
    m = BADGE_LINE.search(t)
    if not m:
        raise SystemExit("!! no badge line")
    end = m.end()
    if t[end:end + 1] == "\n":
        end += 1
    write(RM, t[:m.start()] + t[end:])


def m7():
    """A version literal in the status paragraph.

    The literal is READ from the manifest, not typed here.  A typed one is a
    version in a place the bump script does not know about -- so it would go
    stale -- and it would stop biting the day the version scheme changed.  A
    mechanism that cannot bite is not being measured.
    """
    man = read(os.path.join(WORK, "moonbit_doubleML", "moon.mod"))
    m = re.search(r'(?m)^\s*version\s*=\s*"([^"]+)"', man)
    if not m:
        raise SystemExit("!! the manifest carries no version to inject")
    sub(RM, r"\*\*Status\*\*:", "**Status**: `%s`," % m.group(1))


def m8():
    """The status paragraph's licence."""
    sub(RM, r"MIT, pure MoonBit", "Apache-2.0, pure MoonBit")


def m9():
    """The status paragraph's backends."""
    sub(RM, r"`wasm-gc` and `js`,", "`wasm-gc`,")


def m10():
    """The status paragraph's estimator count."""
    sub(RM, r"with 22 estimators\.", "with 23 estimators.")


def m11():
    """The status paragraph's section pointer."""
    sub(RM, r"\*\*Development status\*\* below states",
        "**The table** below states")


def m12():
    """The status paragraph's 'not claimed'."""
    sub(RM, r"what is \*\*not\*\* claimed\.", "what is claimed.")


def m13():
    """The status paragraph, below the first section.

    Inserted before the SECOND section: the status paragraph already sits
    before the first one, so putting it back there would change nothing.
    """
    t = read(RM)
    m = STATUS_LINE.search(t)
    if not m:
        raise SystemExit("!! no status block")
    block = m.group(0)
    t = t[:m.start()] + t[m.end():]
    i = t.index("## Installation\n")
    t = t[:i] + block + "\n" + t[i:]
    write(RM, t)


def m14():
    """The status paragraph, gone."""
    t = read(RM)
    m = STATUS_LINE.search(t)
    if not m:
        raise SystemExit("!! no status block")
    end = m.end()
    if t[end:end + 1] == "\n":
        end += 1
    write(RM, t[:m.start()] + t[end:])


def m15():
    """The console block."""
    t = read(RM)
    t2, n = re.subn(r"```console\n.*?```\n", "", t, flags=re.S)
    if n < 1:
        raise SystemExit("!! no console block")
    write(RM, t2)


def m16():
    """The install command."""
    sub(RM, r"(?m)^moon add riantr/moonbit_doubleML$", "moon get riantr/moonbit_doubleML")


def m17():
    """`moon update`."""
    sub(RM, r"moon update", "moon upgrade", expect=2)


def m18():
    """The MoonBit import block."""
    sub(RM, r"```moonbit", "```mbt", expect=4)


def m19():
    """The 'not covered' section."""
    sub(RM, r"(?m)^### Not covered, so not claimed$", "### Coverage notes")


def m20():
    """The licence section."""
    sub(RM, r"(?m)^## License$", "## Terms")


def m21():
    """The attribution section."""
    sub(RM, r"(?m)^## Attribution$", "## Credits")


def m22():
    """The backend column."""
    cut(RM, r"(?m)^\| Backends \|[^\n]*\n")


def m23():
    """The toolchain statement."""
    sub(RM, r"`moon\s+\d+\.\d+\.\d+`", "`the pinned moon`", expect=4)


def m24():
    """The test-count row.

    BOTH rows: the Status table carries one per target group, and renaming
    only one leaves the other to satisfy the check.
    """
    sub(RM, r"(?m)^\| Tests \(", "| Test counts (", expect=2)


def m25():
    """The provenance file."""
    sub(RM, r"_verify/UPSTREAM_PROVENANCE\.md", "_verify/UPSTREAM_PROVENANC.md",
        expect=3)


MECHANISMS = [
    ("the badge's repository", m1),
    ("the badge's alt text", m2),
    ("the badge's workflow", m3),
    ("the badge, after the status paragraph", m4),
    ("the badge, below the first section", m5),
    ("the badge, gone", m6),
    ("a version literal in the status paragraph", m7),
    ("the status paragraph's licence", m8),
    ("the status paragraph's backends", m9),
    ("the status paragraph's estimator count", m10),
    ("the status paragraph's section pointer", m11),
    ("the status paragraph's 'not claimed'", m12),
    ("the status paragraph, below the first section", m13),
    ("the status paragraph, gone", m14),
    ("the console block", m15),
    ("the install command", m16),
    ("`moon update`", m17),
    ("the MoonBit import block", m18),
    ("the 'not covered' section", m19),
    ("the licence section", m20),
    ("the attribution section", m21),
    ("the backend column", m22),
    ("the toolchain statement", m23),
    ("the test-count row", m24),
    ("the provenance file", m25),
]

# ------------------------------------------------------------------- the run
rc, out, total, by = verify(WORK)
print()
print("=== the baseline (nothing broken) ===")
print("  %d failing check(s)" % total)
for s in summaries_of(out):
    print("    the verifiers' own summary: %s checks, %s failed" % s)
for i, lines in enumerate(by):
    for l in lines:
        print("    %s: %s" % (os.path.basename(VERIFIERS[i]), l))
base = total
if base != 0:
    print("!! the baseline is not clean -- the verifiers fail before anything "
          "is broken")
    sys.exit(1)

print()
print("=== the mechanisms ===")
prev = base
ok = True
for i, (name, fn) in enumerate(MECHANISMS, 1):
    try:
        fn()
    except SystemExit as e:
        print("  %2d. %-52s !! %s" % (i, name, e))
        ok = False
        break
    rc, out, total, by = verify(WORK)
    grew = total > prev
    ok = ok and grew
    print("  %2d. %-52s %d -> %d  %s"
          % (i, name, prev, total, "GROW" if grew else "*** FLAT ***"))
    for j, lines in enumerate(by):
        for l in lines:
            print("        %s: %s" % (os.path.basename(VERIFIERS[j]), l[:110]))
    prev = total

print()
print("=" * 78)
if ok and prev > base:
    print("VERDICT PASS -- %d mechanisms, each one grew the failure count "
          "(%d -> %d)" % (len(MECHANISMS), base, prev))
else:
    print("VERDICT FAIL -- the mechanisms did not each grow the count")
print("=" * 78)

capture = os.path.join(REPO, "_verify", "_dryrun1650", "r59_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 59 dry-run: the README's shape, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline %d failing checks; final %d\n" % (base, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok and prev > base else "FAIL"))
    for i, (name, fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
print("capture written: %s" % capture)
sys.exit(0 if (ok and prev > base) else 1)
