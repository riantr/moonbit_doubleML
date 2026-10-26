#!/usr/bin/env python3
"""Round 54 dry-run: break the NUMBER-promise contract eight ways, and watch
the verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_number_promises_1650.py` holds the numbers the
current-surface documents state -- the README and the skill file -- against
the tree -- and a verifier that only ever prints "ok" is indistinguishable
from one that never fires.

So this driver copies the tree into a scratch clone, breaks the contract one
way at a time, and requires the failure count to GROW at every step.  A
contract nobody can break is a contract nobody is really checking.

THE MECHANISMS
===============
  1  the README's `.mbt` file count states a number the tree does not have
  2  the README's estimator count states a number the tree does not have
  3  the estimator table loses a row, so a name the tree has is not in it
  4  the skill file's whitebox FILE count is wrong
  5  the skill file's whitebox TEST-CASE count is wrong
  6  the sandwich-variance row names the wrong estimators, count unchanged
  7  the README's `score`-argument count is wrong
  8  the README's source-file count is wrong

Mechanism 6 is the interesting one: the COUNT stays right and the NAMES go
wrong.  A check that only compares counts cannot see it, and a check that
only compares names cannot see the others -- so the contract needs both.

WHAT IS COUNTED
===============
A failing CHECK.  The marker `*** FAIL ***` goes on each failing check line;
a line whose WHOLE content is the marker is a section HEADER some verifiers
print after their counter, and a header is not a check, so it is excluded.
The count is by CONTAINMENT, not by prefix or by suffix.

EVERY MECHANISM MUST ADD A NEW FAILURE
=======================================
A mechanism that trips a check that is ALREADY tripped is FLAT, and a flat
step means the mechanism is not being measured.  So the order below matters:
each step is chosen to fail at least one check no earlier step has failed.

THE COUNT MUST NOT DEPEND ON THE CLONE
=======================================
The clone carries the WORKING TREE's state -- `git diff --name-only HEAD`
plus this round's new files -- because the tree under test is the tree the
fixes are in.  A clone built from the INDEX instead would be internally
inconsistent, and the count would measure the wrong tree.

Run: python _verify/_dryrun_round54_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r54")
DRIVER = "_verify/_dryrun_round54_1650.py"
VERIFIERS = [
    "_verify/_verify_number_promises_1650.py",
]
DOCUMENTS = [
    "README.mbt.md",
    "skills/moonbit_doubleML.md",
]


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


def sub(path, pattern, repl, expect=1, flags=0):
    """Replace the regex `pattern` with `repl`, `expect` times.

    A REGEX, not a literal: the mechanisms must patch the text as it NOW
    STANDS, and the wording moves with every release.  A literal here would be
    a second copy of the promise, and it would rot.
    """
    t = read(path)
    t2, n = re.subn(pattern, repl, t, count=expect, flags=flags)
    if n != expect:
        raise SystemExit("!! %s: pattern matched %d times, expected %d"
                         % (os.path.basename(path), n, expect))
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
            (r"checks run:\s*(\d+),\s*checks failed:\s*(\d+)", 2)):
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
rc, out = run(["git", "checkout", "--detach", COMMIT], cwd=WORK)
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "rev-parse", "HEAD"], cwd=WORK)
print("  %s -> %s" % (COMMIT, out.strip()))

# --- copy the WORKING TREE's state in -----------------------------------------
rc, out = run(["git", "diff", "--name-only", "HEAD"])
STAGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
ADDED = [
    "_verify/_verify_number_promises_1650.py",
    "_verify/_dryrun_round54_1650.py",
]
COPY_IN = []
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + ADDED + STAGED:
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
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checks")

README = os.path.join(WORK, "README.mbt.md")
SKILL = os.path.join(WORK, "skills", "moonbit_doubleML.md")


# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """The README's `.mbt` file count states a number the tree does not have."""
    sub(README, r"\| `\.mbt` file count \| \*\*220\*\*",
        r"| `.mbt` file count | **221**")


def m2():
    """The README's estimator count states a number the tree does not have."""
    sub(README, r"\*\*22 estimators\*\* in 19 source files",
        r"**23 estimators** in 19 source files")


def m3():
    """The estimator table loses a row, so a name the tree has is not in it.

    The COUNT in the table's heading is untouched: this mechanism removes a
    ROW, so the only thing that can notice is a check that reads the names.
    """
    sub(README, r"^\| `DoubleMLCVAR` \|[^\n]*\n", "", flags=re.M)


def m4():
    """The skill file's whitebox FILE count is wrong."""
    sub(SKILL, r"There are \*\*26\*\* `\*_wbtest\.mbt` files",
        r"There are **27** `*_wbtest.mbt` files")


def m5():
    """The skill file's whitebox TEST-CASE count is wrong."""
    sub(SKILL, r"holding \*\*169\*\* test cases in total",
        r"holding **170** test cases in total")


def m6():
    """The sandwich-variance row names the wrong estimators, count unchanged.

    The count stays at 3 and the list still has three names -- but one of them
    is an estimator that DOES expose the API.  A check that only compares
    counts cannot see this, which is why the contract checks the names too.
    """
    sub(README, r"\(`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`\)",
        r"(`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLPLR`)")


def m7():
    """The README's `score`-argument count is wrong."""
    sub(README, r"only \*\*7 of the 22 estimators take a `score`",
        r"only **8 of the 22 estimators take a `score`")


def m8():
    """The README's source-file count is wrong."""
    sub(README, r"22 `DoubleML\*` estimator structs in 19 production files",
        r"22 `DoubleML*` estimator structs in 20 production files")


MECHANISMS = [
    ("the README's `.mbt` file count is wrong", m1),
    ("the README's estimator count is wrong", m2),
    ("the estimator table loses a row", m3),
    ("the skill file's whitebox FILE count is wrong", m4),
    ("the skill file's whitebox TEST-CASE count is wrong", m5),
    ("the sandwich row names the wrong estimators", m6),
    ("the README's `score`-argument count is wrong", m7),
    ("the README's source-file count is wrong", m8),
]

prev = 0
prev_by = []
print()
print("=== the baseline: the tree as it stands ===")
rc0, out0, n0, by0 = verify(WORK)
print("  exit=%d failures=%d" % (rc0, n0))
if n0 != 0:
    print("!! the tree as it stands already fails -- the driver cannot measure growth")
    for l in by0[0][:20]:
        print("      %s" % l)
    sys.exit(1)
prev = n0
prev_by = by0

print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n, by = verify(WORK)
    grew = n > prev
    print("  %2d. %-58s failures %d -> %d  %s"
          % (i, desc[:58], prev, n, "GROW" if grew else "*** FLAT ***"))
    for vi, cur in enumerate(by):
        for l in cur:
            if l not in prev_by[vi]:
                print("        + %s" % l[:120])
    if not grew:
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n
    prev_by = by

print()
print("  the driver counted %d failures" % prev)

# --- the verifiers' own summaries must agree with the counter -----------------
print()
print("=== the published failure count, witnessed ===")
rc, out, n, by = verify(WORK)
print("  the driver counted %d failures" % n)
found = summaries_of(out)
if not found:
    print("!! no summary line in the verifiers' output -- ABORT")
    sys.exit(1)
for c, f in found:
    print("  %s checks, %s failed" % (c, f))
total = sum(int(f) for _c, f in found)
print("  the summaries add up to %d; the counter says %d" % (total, n))
if total != n:
    print("!! the counter and the summaries disagree -- ABORT")
    sys.exit(1)
if rc == 0:
    print("!! the broken tree still exits 0 -- ABORT")
    sys.exit(1)
print("  OK: the counter agrees with the summaries")


def published_count(text, driver):
    """The failure count the CHANGELOG publishes FOR THIS DRIVER."""
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
        flat = re.sub(r"\s+", " ", "\n".join(lines[head:tail]))
        found = re.findall(r"failure count to GROW at every step: \*\*(\d+)\*\* failures",
                           flat)
        if found:
            return int(found[0])
    return None


published = published_count(read(os.path.join(REPO, "CHANGELOG.md")),
                            os.path.basename(DRIVER))
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

_eng = read(os.path.join(REPO, "ENGINEERING.md"))
_eng_banner = _eng.split("## The README as it stood at", 1)[0]
_eng_found = []
for _hit in reversed([m.start() for m in
                      re.finditer(re.escape(DRIVER), _eng_banner)]):
    _next = re.search(r"^> \* \*\*Round ", _eng_banner[_hit:], re.M)
    _passage = (_eng_banner[_hit:_hit + _next.start()] if _next
                else _eng_banner[_hit:])
    _flat = re.sub(r"\s+", " ", re.sub(r"(?m)^>[ \t]*", "", _passage))
    _eng_found = re.findall(r"ends at \*\*(\d+)\*\* failures", _flat)
    if _eng_found:
        break
if not _eng_found:
    print("  the ENGINEERING banner publishes no failure count for this "
          "driver -- ABORT")
    print("  (this run measured %d -- put that number in the banner)" % n)
    sys.exit(1)
print()
print("=== the same count in the ENGINEERING banner ===")
_eng_published = int(_eng_found[0])
print("  the banner publishes %d; this run measured %d" % (_eng_published, n))
if _eng_published != n:
    print("!! the banner's count and the measured one disagree -- ABORT")
    sys.exit(1)
print("  OK -- the banner's number is the number this run measured")

# --- the capture ----------------------------------------------------------------
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r54_dryrun.out")
body = []
body.append("")
body.append("A. the baseline")
body.append("  the tree as it stands: exit=%d failures=%d" % (rc0, n0))
body.append("")
body.append("B. the mechanisms, one at a time")
for i, (desc, _apply) in enumerate(MECHANISMS, 1):
    body.append("  %2d. %s" % (i, desc))
body.append("")
body.append("C. the published failure count")
body.append("  the driver counted %d failures" % prev)
for c, f in found:
    body.append("  %s checks, %s failed" % (c, f))
body.append("")
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(body))
print("  wrote %s" % capture)

print()
print("VERDICT: PASS -- the dry-run bites (%d failures, every mechanism visible)"
      % prev)
