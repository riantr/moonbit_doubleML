#!/usr/bin/env python3
"""Round 48 dry-run: prove that this round's NEW check bites, and that the
shape filter did not remove a promise.

WHAT THIS IS FOR
================
Every check this round added can, in principle, be a check that never fires.
The only way to know it fires is to break the promise it guards and watch it
go red -- and to watch the red count GROW, because a mechanism that breaks
nothing is a mechanism that proves nothing.

The round-48 promises, one per mechanism
========================================
  1  the Attribution's comparison claim   "all three ship upstream, and are
                                           compared against it" comes back
  2  the small-n caution                  "Both this port and upstream fail
                                           there, in opposite directions"
                                           comes back
  3  the upstream-gate reference          "the gates run upstream's own code"
                                           comes back -- the claim that is
                                           false for `pyexample_rdd.py`
  4  the migration paragraph              drops one of the seven
                                           classifier-defaulted estimators
  5  the estimator table                  drops a row

MECHANISMS ARE CUMULATIVE
=========================
Each mechanism is applied ON TOP of the ones before it, so a mechanism that
contributes nothing is caught by the growth check rather than being masked
by a later one.

THE TREE UNDER TEST
===================
A local clone of the COMMITTED tree, with this round's verifiers and the
DOCUMENTS they read copied in from the working tree.  The documents matter:
the CHANGELOG and the ENGINEERING banner publish this driver's failure
count, and a check that reads a document the tree under test does not carry
would be vacuous.

THE COUNT
=========
The count is the number of FAILING CHECK LINES across the verifiers.  Each
verifier prints its OWN summary, so the summaries are SUMMED and the driver's
counter counts the failing check lines across all of them.

Run: python _verify/_dryrun_round48_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r48")
DRIVER = "_verify/_dryrun_round48_1650.py"
VERIFIERS = [
    "_verify/_verify_prose_scope_1650.py",
    "_verify/_verify_api_promises_1650.py",
]
DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]


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


def sub(path, pattern, repl, expect=1):
    """Replace the regex `pattern` with `repl`, `expect` times.

    A REGEX, not a literal: the mechanisms must patch the text as it NOW
    STANDS, and the wording moves with every release.  A literal here would
    be a literal that goes stale -- and a stale literal is a mechanism that
    silently stops biting.
    """
    text = read(path)
    crlf = "\r\n" in text
    pat = pattern.replace("\n", "\r\n") if crlf and "\r\n" not in pattern else pattern
    rep = repl.replace("\n", "\r\n") if crlf and "\r\n" not in repl else repl
    n = len(re.findall(pat, text))
    if n != expect:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, pattern, n, expect))
    write(path, re.sub(pat, rep, text))


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
    """Run the verifiers in `work`; returns (rc, output, failure count, lists).

    WHAT IS COUNTED
    ===============
    A failing CHECK.  The marker `*** FAIL ***` goes on each failing check
    line; a line whose WHOLE content is the marker is a section HEADER some
    verifiers print after their counter, and a header is not a check, so it
    is excluded.

    The count is by CONTAINMENT, not by prefix or by suffix: the verifier
    families print the marker in different positions, and a rule that
    matched only one position would under-count the failures of the others.
    """
    total = 0
    by_verifier = []
    chunks = []
    rc = 0
    for rel in VERIFIERS:
        r, out = run([sys.executable, os.path.join(work, rel)], cwd=work,
                     timeout=3600)
        rc = rc or r
        chunks.append(out)
        lines = []
        for l in out.splitlines():
            if "*** FAIL ***" in l and l.strip() != "*** FAIL ***":
                lines.append(l.strip())
        by_verifier.append(lines)
        total += len(lines)
    return rc, "\n".join(chunks), total, by_verifier


def summaries_of(out):
    """The verifiers' own failure counts, in EVERY summary convention.

    FOUR conventions are in the contract, and this reader knows all four:

        "N checks, M failed"                  the common form
        "SUMMARY: N checks, M failures"       the same, with "failures"
        "checks failed: M"                    the form without the word "checks"
        "checks run: N, checks failed: M"     the form with both

    "failed" is NOT a prefix of "failures" -- the two words DIVERGE after
    the common prefix, so a rule that matched the prefix and then expected
    "failed" would miss the family that says "failures".
    """
    found = []
    for m in re.finditer(r"(\d+)\s+checks,\s*(\d+)\s+failed", out):
        found.append((m.group(1), m.group(2)))
    for m in re.finditer(r"SUMMARY:\s*(\d+)\s+checks,\s*(\d+)\s+failures", out):
        found.append((m.group(1), m.group(2)))
    for m in re.finditer(r"checks failed:\s*(\d+)", out):
        found.append(("?", m.group(1)))
    for m in re.finditer(r"checks run:\s*(\d+),\s*checks failed:\s*(\d+)", out):
        found.append((m.group(1), m.group(2)))
    return found


# ---------------------------------------------------------------- the clone
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
rc, out = run(["git", "diff", "--cached", "--name-only"])
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

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")


def both(pattern, repl, expect=1):
    """Patch BOTH copies of the README.

    The README exists twice and a check owns the two being byte-identical --
    so every mechanism patches BOTH, or the count would move for a reason
    that has nothing to do with the promise being broken.
    """
    sub(README, pattern, repl, expect)
    sub(SHIPPED, pattern, repl, expect)


# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0, by0 = verify(WORK)
print("  exit=%d  failures=%d" % (rc0, n0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
MECHANISMS = [
    ("the Attribution claims all three are compared against it",
     lambda: both(
         r"three ship upstream\. `DoubleMLLPLR` and `DoubleMLDIDCSBinary` are compared\n"
         r"against upstream's own classes; `DoubleMLPLPR`'s upstream fit is compared\n"
         r"against a hand-rolled reference on a different dataset from the port's, so\n"
         r"PLPR has no upstream gate\. The last candidate\n",
         "three ship upstream, and are compared against it. The last candidate\n")),

    ("the small-n caution claims both sides fail",
     lambda: both(
         r"Upstream\n   genuinely is ill-posed there -- non-finite standard errors and root\n"
         r"   warnings -- while this port damps its Newton step to keep the answer\n"
         r"   finite\. Which side breaks depends on n, so neither one is a safe\n"
         r"   reference for the other at that size\.\n",
         "Both\n   this port and upstream fail there, in opposite directions, and the port\n"
         "   damps its Newton step to keep the answer finite.\n")),

    ("the upstream gates claim to run upstream's own code",
     lambda: (both(r"scripts instead run a\nreference implementation on the port's rows",
                   "scripts instead run\nupstream's own code on the port's rows"),
              both(r" The reference is upstream's own `doubleml` classes in eight of\n"
                   r"them, and `rdrobust` for the RDD arm -- `doubleml-for-py` and `rdrobust` are\n"
                   r"different packages\.\n", ""))),

    ("the migration paragraph drops an estimator",
     lambda: both(r"`DoubleMLPQ`, `DoubleMLQTE` and `DoubleMLLPLR` --\n",
                  "`DoubleMLPQ` and `DoubleMLLPLR` --\n")),

    ("the estimator table drops a row",
     lambda: both(r"\| `DoubleMLPLR` \| partialling-out \| partially linear regression "
                  r"\*\(upstream\)\* \|\n", "")),
]

prev = n0
prev_by = by0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n, by = verify(WORK)
    grew = n > prev
    print("  %2d. %-56s failures %d -> %d  %s"
          % (i, desc[:56], prev, n, "GROW" if grew else "*** FLAT ***"))
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
    """The failure count the CHANGELOG publishes FOR THIS DRIVER.

    The lookup is SCOPED twice: to the ENTRY that names the driver, and
    within that entry to the BULLET that names it.  The CHANGELOG is in
    descending order, so the newest entry wins.
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
        flat = re.sub(r"\s+", " ", "\n".join(lines[head:tail]))
        found = re.findall(r"requires the failure count to GROW at every step: "
                           r"\*\*(\d+)\*\* failures at the", flat)
        if found:
            return int(found[0])
    return None


# --- the published failure count, witnessed -----------------------------------
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

# The SAME number, in the ENGINEERING banner.
_eng = read(os.path.join(REPO, "ENGINEERING.md"))
_eng_banner = _eng.split("## The README as it stood at", 1)[0]
_me = None
_eng_found = []
for _hit in reversed([m.start() for m in
                      re.finditer(re.escape(DRIVER), _eng_banner)]):
    _next = re.search(r"^> \* \*\*Round ", _eng_banner[_hit:], re.M)
    _passage = (_eng_banner[_hit:_hit + _next.start()] if _next
                else _eng_banner[_hit:])
    _flat = re.sub(r"\s+", " ", re.sub(r"(?m)^>[ \t]*", "", _passage))
    _eng_found = re.findall(r"ends at \*\*(\d+)\*\* failures", _flat)
    if _eng_found:
        _me = _hit
        break
if _me is None:
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r48_dryrun.out")
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
