#!/usr/bin/env python3
"""Round 55 dry-run: break the CITATION contract eight ways, and watch the
verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_path_promises_1650.py` holds every path a live document
names -- in prose and, since this round, as a CITATION with a line range --
against the tree, and a verifier that only ever prints "ok" is
indistinguishable from one that never fires.

So this driver copies the tree into a scratch clone, breaks the contract one
way at a time, and requires the failure count to GROW at every step.  A
contract nobody can break is a contract nobody is really checking.

THE MECHANISMS
===============
  1  a citation points PAST THE END of the file it names
  2  a citation names a file that is not in the tree
  3  a verdict record's citation names a file that is not in the tree
  4  an upstream citation is repointed at THIS package's tree
  5  a document's "not retained" declaration is deleted
  6  a declaration is narrowed, so it no longer covers what it covered
  7  a tracked source file is deleted, so a citation into it dangles
  8  a cited source file loses the lines the citation points at

Mechanisms 1 and 8 are the same property seen from two sides -- a citation
whose PLACE is not inside the file -- so they are separated: 1 moves the
citation, 8 shrinks the file.  Mechanisms 2 and 3 are separated the same way:
2 is in the README, 3 is in a verdict record.  Mechanism 4 is the only one
that touches the SCOPE device rather than a path: it proves that a citation
rooted at the package is IN scope, and that a citation rooted at upstream's
package is not.

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

Run: python _verify/_dryrun_round55_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r55")
DRIVER = "_verify/_dryrun_round55_1650.py"
VERIFIERS = [
    "_verify/_verify_path_promises_1650.py",
]
DOCUMENTS = [
    "README.mbt.md",
    "_verify/TODO-3-verdict.md",
    "_verify/v0.49.0-v0.50.0-review.md",
    "_verify/LEARNER_DEFAULTS_1530.md",
]
ADDED = [
    "_verify/_dryrun_round55_1650.py",
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
TODO3 = os.path.join(WORK, "_verify", "TODO-3-verdict.md")
REVIEW = os.path.join(WORK, "_verify", "v0.49.0-v0.50.0-review.md")
DEFAULTS = os.path.join(WORK, "_verify", "LEARNER_DEFAULTS_1530.md")
TUNE = os.path.join(WORK, "moonbit_doubleML", "tune.mbt")
SEED = os.path.join(WORK, "moonbit_doubleML", "seed.mbt")


# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """A citation points PAST THE END of the file it names."""
    sub(README, r"`ssm\.mbt:73-74`", "`ssm.mbt:7300-7400`")


def m2():
    """A citation names a file that is not in the tree."""
    sub(README, r"`apo\.mbt:320`", "`apo_missing.mbt:320`")


def m3():
    """A verdict record's citation names a file that is not in the tree."""
    sub(DEFAULTS, r"`did_cs\.mbt:312-324`", "`did_cs_missing.mbt:312-324`")


def m4():
    """An upstream citation is repointed at THIS package's tree.

    The scope device, not a path: a citation rooted at the package is IN
    scope, and one rooted at upstream's package is not.  Repointing the
    citation at `moonbit_doubleML/` must make it a promise about a file
    here -- and one that does not exist.
    """
    sub(README, r"`plm/lplr\.py:326`", "`moonbit_doubleML/lplr.py:326`")


def m5():
    """A document's "not retained" declaration is deleted.

    The declaration is a PARAGRAPH -- it wraps, because it is a list of
    paths and a list does not fit on one line -- so the whole paragraph goes,
    not just its first line.
    """
    sub(TODO3, r"(?ms)^\*\*Not retained in this repository\*\*:.*?\n\n", "")


def m6():
    """A declaration is narrowed, so it no longer covers what it covered."""
    sub(REVIEW, r"\*\*Not retained in this repository\*\*: `cmd/`",
        "**Not retained in this repository**: `cmd/apos/`")


def m7():
    """A tracked source file is deleted, so a citation into it dangles."""
    rc, out = run(["git", "-C", WORK, "rm", "-q", "--",
                   "moonbit_doubleML/seed.mbt"], cwd=WORK)
    if rc != 0:
        raise SystemExit("!! git rm failed: %s" % out.strip()[:300])


def m8():
    """A cited source file loses the lines the citation points at."""
    lines = read(TUNE).split("\n")
    write(TUNE, "\n".join(lines[:100]))


MECHANISMS = [
    ("a citation points past the end of the file it names", m1),
    ("a citation names a file that is not in the tree", m2),
    ("a verdict record's citation names a missing file", m3),
    ("an upstream citation is repointed at this package", m4),
    ("a document's declaration is deleted", m5),
    ("a declaration is narrowed", m6),
    ("a tracked source file is deleted", m7),
    ("a cited source file loses the lines the citation names", m8),
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r55_dryrun.out")
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
