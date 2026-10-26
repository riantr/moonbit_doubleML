#!/usr/bin/env python3
"""Round 53 dry-run: break the path-promise contract eight ways, and watch the
verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_path_promises_1650.py` holds every path NAMED IN PROSE in every
live document against the tree -- and a verifier that only ever prints "ok" is
indistinguishable from one that never fires.

So this driver copies the tree into a scratch clone, breaks the contract one way
at a time, and requires the failure count to GROW at every step.  A contract
nobody can break is a contract nobody is really checking.

THE MECHANISMS
===============
  1  a live document cites a repo-rooted path that is not in the repository
  2  a cited path is on disk but is no longer TRACKED
  3  a bare own-family script name names a script that does not exist
  4  the root README.md stops being a symlink
  5  the root README.md points at the wrong file
  6  a HISTORICAL RECORD banner is removed, so a historical document is live again
  7  a path that was inside a COMMAND span becomes a standalone path span --
     the loophole the "proof of absence" rule opens, closed on purpose
  8  a FOREIGN reference loses its attribution, so it becomes a promise

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

Run: python _verify/_dryrun_round53_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r53")
DRIVER = "_verify/_dryrun_round53_1650.py"
VERIFIERS = [
    "_verify/_verify_path_promises_1650.py",
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
    "_verify/CLUSTER_UPSTREAM_PARITY_1680.md",
    "_verify/PQ_QTE_SE_GAP_1680.md",
    "_verify/RELEASE-0.4.0.md",
    "_verify/T140-verdict.md",
    "_verify/_cluster_premise_1680.py",
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
PQQTE = os.path.join(WORK, "_verify", "PQ_QTE_SE_GAP_1680.md")
RELEASE = os.path.join(WORK, "_verify", "RELEASE-0.4.0.md")
T140 = os.path.join(WORK, "_verify", "T140-verdict.md")
SKILL = os.path.join(WORK, "skills", "moonbit_doubleML.md")


# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """A live document cites a repo-rooted path that is not in the repository."""
    sub(CLUSTER, r"`_verify/_cluster_premise_1680\.py`",
        r"`_verify/_cluster_phantom_1650.py`")


def m2():
    """A cited path is on disk but is no longer TRACKED.

    The file is still there -- a reader on this host could open it -- and it is
    not in the repository, so a clone does not have it.  That is the half of the
    promise that a `Test-Path` check cannot see.
    """
    rc, out = run(["git", "rm", "--cached", "--quiet",
                   "_verify/_cluster_premise_1680.py"], cwd=WORK)
    if rc != 0:
        raise SystemExit("!! git rm --cached failed: %s" % out.strip()[:300])


def m3():
    """A bare own-family script name names a script that does not exist."""
    sub(T140, r"`validate_pava_with_python\.py`", r"`validate_phantom_1650.py`")


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
    """A HISTORICAL RECORD banner is removed, so a historical document is live
    again -- and the paths it names are promises again."""
    sub(RELEASE, r"^> \*\*HISTORICAL RECORD[^\n]*\n", "", flags=re.M)


def m7():
    """A path that was inside a COMMAND span becomes a standalone path span.

    The "proof of absence" rule says a path named inside a longer span -- a
    command that shows the file is NOT there -- is not a promise.  This
    mechanism closes that loophole on purpose: the same path, standing alone,
    IS a promise, and the check must see the difference.
    """
    sub(PQQTE, r"`git log --all -- _verify/_pq_se_flag_1680\.py`",
        r"`_verify/_pq_se_flag_1680.py`")


def m8():
    """A FOREIGN reference loses its attribution, so it becomes a promise.

    The skill names one of another package's own files and says whose it is.
    Take the attribution away and the path is a claim about THIS tree -- and
    the file is not in it.  This is what makes the exemption narrow: it is the
    ATTRIBUTION that exempts the path, not the path's name.
    """
    sub(SKILL, r"moonbit-community/rabbita's", r"another package's")


MECHANISMS = [
    ("a live document cites a repo-rooted path that is not in the repository", m1),
    ("a cited path is on disk but is no longer TRACKED", m2),
    ("a bare own-family script name names a script that does not exist", m3),
    ("the root README.md stops being a symlink", m4),
    ("the root README.md points at the wrong file", m5),
    ("a HISTORICAL RECORD banner is removed, so a document is live again", m6),
    ("a path inside a command span becomes a standalone path span", m7),
    ("a foreign reference loses its attribution, so it becomes a promise", m8),
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r53_dryrun.out")
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
