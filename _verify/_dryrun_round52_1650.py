#!/usr/bin/env python3
"""Round 52 dry-run: break the reproduction-promise contract seven ways, and
watch the verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_repro_paths_1650.py` holds every live document's reproduction
commands, status lines and counts against the tree -- and a verifier that only
ever prints "ok" is indistinguishable from one that never fires.

So this driver copies the tree into a scratch clone, breaks the contract one
way at a time, and requires the failure count to GROW at every step.  A
contract nobody can break is a contract nobody is really checking.

THE MECHANISMS
===============
  1  a live document cites a script that is not in the repository
  2  a live status line names a script that is not in the repository
  3  a count that names a set is not the size of that set
  4  the root README.md stops being a symlink
  5  the root README.md points at the wrong file
  6  the "Original text" marker goes, so retracted text becomes live again
  7  a cited script is still on disk but is no longer TRACKED

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
This host materialises the root `README.md` symlink as a HARDLINK; a fresh
clone with `core.symlinks=false` writes a 13-byte stub.  So the verifier reads
a symlinked document from its BLOB, and the check count is the same in both
trees -- which is what makes a published count publishable.

Run: python _verify/_dryrun_round52_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r52")
DRIVER = "_verify/_dryrun_round52_1650.py"
VERIFIERS = [
    "_verify/_verify_repro_paths_1650.py",
]
# The files the mechanisms break, and the documents the contract reads.
#
# The root `README.md` is deliberately NOT copied in.  It is a symlink in the
# index, but this host materialises it in the working tree as a HARDLINK to
# `README.mbt.md`, so copying it in would turn the clone's symlink into a
# regular file -- which would break the very check these mechanisms exist to
# exercise, before the first mechanism ran.
DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "_verify/CLUSTER_UPSTREAM_PARITY_1680.md",
    "_verify/PQ_QTE_GATE_DESIGN_1680.md",
    "_verify/RDD_PARITY_1680.md",
    "_verify/DID_BINARY_PANIC_1680.md",
    "_verify/_cluster_premise_1680.py",
    "_verify/_cluster_var_est_1680.py",
    "_verify/_cluster_battery_1680.py",
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
    STANDS, and the wording moves with every release.  A literal here would
    be a second copy of the promise, and it would rot.
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
        # A copy-in that is ALREADY in the tree has nothing to commit, and
        # that is not an error: the clone is cut at HEAD, so once the release
        # commit exists the new files come with it.  The dry-run is then
        # re-runnable, which matters -- a check that can only be run once
        # cannot be re-checked.
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
    """The verifiers' own failure counts, in EVERY summary convention.

    FOUR conventions are in the contract, and this reader knows all four:

        "N checks, M failed"                  the common form
        "SUMMARY: N checks, M failures"       the same, with "failures"
        "checks failed: M"                    the form without the word "checks"
        "checks run: N, checks failed: M"     the form with both

    "failed" is NOT a prefix of "failures" -- the two words DIVERGE after the
    common prefix, so a rule that matched the prefix and then expected
    "failed" would miss the family that says "failures".
    """
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
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + STAGED:
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

CLUSTER = os.path.join(WORK, "_verify", "CLUSTER_UPSTREAM_PARITY_1680.md")
PQQTE = os.path.join(WORK, "_verify", "PQ_QTE_GATE_DESIGN_1680.md")
RDD = os.path.join(WORK, "_verify", "RDD_PARITY_1680.md")


# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """A live document cites a script that is not in the repository."""
    sub(CLUSTER, r"python _verify\\_cluster_premise_1680\.py",
        r"python _verify\\_cluster_phantom_1650.py")


def m2():
    """A live status line names a script that is not in the repository.

    The pattern spans a LINE BREAK: the document wraps the status line, and a
    pattern that assumes one line matches nothing.  A literal here would be a
    second copy of the promise, and it would rot the moment the wording moved.
    """
    sub(PQQTE, r"gate built since 2026-10-16\s+\(`pyexample_pq\.py`\)",
        r"gate built since 2026-10-16 (`pyexample_phantom_1650.py`)")


def m3():
    """A count that names a set is not the size of that set.

    The phrase is matched across a LINE BREAK: the document wraps it, and a
    pattern that assumes one line matches nothing.
    """
    sub(CLUSTER, r"the three scripts that do\s+exist",
        r"the two scripts that do exist")


def m4():
    """The root README.md stops being a symlink -- the MODE changes, and only
    the mode: the content is left exactly as it was, so this mechanism trips
    the mode check and NOT the target check."""
    rc, sha = run(["git", "rev-parse", ":README.md"], cwd=WORK)
    sha = sha.strip()
    rc, out = run(["git", "update-index", "--cacheinfo",
                   "100644,%s,README.md" % sha], cwd=WORK)
    if rc != 0:
        raise SystemExit("!! update-index failed: %s" % out.strip()[:300])


def m5():
    """The root README.md points at the wrong file -- the CONTENT changes, and
    only the content: the mode is read back out of the index, so this
    mechanism trips the target check and NOT the mode check.

    A mechanism that restores what an earlier one broke is FLAT: it trades one
    failing check for another and the count does not move.
    """
    rc, out = run(["git", "ls-files", "-s", "--", "README.md"], cwd=WORK)
    mode = out.split()[0]
    rc, sha = run(["git", "hash-object", "-w", "--stdin"], cwd=WORK,
                  stdin="moonbit_doubleML/README.mbt.md\n")
    sha = sha.strip()
    rc, out = run(["git", "update-index", "--cacheinfo",
                   "%s,%s,README.md" % (mode, sha)], cwd=WORK)
    if rc != 0:
        raise SystemExit("!! update-index failed: %s" % out.strip()[:300])


def m6():
    """The 'Original text' marker goes, so the retracted text becomes live."""
    sub(RDD, r"^# Original text \(retracted where marked above\)\n", "",
        flags=re.M)


def m7():
    """A cited script is still on disk but is no longer TRACKED."""
    rc, out = run(["git", "rm", "--cached", "--quiet",
                   "_verify/_cluster_var_est_1680.py"], cwd=WORK)
    if rc != 0:
        raise SystemExit("!! git rm --cached failed: %s" % out.strip()[:300])


MECHANISMS = [
    ("a live document cites a script that is not in the repository", m1),
    ("a live status line names a script that is not in the repository", m2),
    ("a count that names a set is not the size of that set", m3),
    ("the root README.md stops being a symlink", m4),
    ("the root README.md points at the wrong file", m5),
    ("the 'Original text' marker goes, so retracted text becomes live", m6),
    ("a cited script is on disk but is no longer TRACKED", m7),
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r52_dryrun.out")
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
