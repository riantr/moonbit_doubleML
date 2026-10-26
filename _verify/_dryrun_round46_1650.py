"""Dry-run the round-46 checks against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 46 fixed a promise that had no owner: seven script names in the README
that are not files.  It also closed three numbers that were true but
unwatched, and it repaired two dry-run drivers whose tree under test was two
releases at once.

The checks this round added:

  * `_verify/_verify_count_referents_1650.py` resolves every backticked file
    name the README spells to a tracked file in the tree.  A `validate_*`
    token with NO extension is a stem, and a stem no file carries is the
    defect round 46 fixed.
  * `_verify/_verify_estimator_census_1680.py` compares the Status table's own
    "22" and its own "220 / 65 / 129 / 26" with the census derived from the
    source.  The body sentence was watched; the table's row was not.
  * `_verify/_verify_example_kinds_1680.py` derives the number of CLI-style
    numeric demos -- the example packages in moon.work minus the ones that
    are not CLI-style -- and compares it with the README's own sentence.

A check that cannot fail is not a check, so each mechanism here breaks ONE
promise in the tree and the failure count must GROW at every step.

THE MECHANISMS
===============
  1. the seven script names go back to their bare stems -- the defect this
     round fixed, which no check owned;
  2. the Status table's estimator count is wrong;
  3. the Status table's .mbt census is wrong;
  4. the CLI-style demo count is wrong.

THEY ARE CUMULATIVE
===================
Each mechanism is applied ON TOP of the ones before it.  Restoring between
the steps would REPAIR the earlier break -- and the count would FALL instead
of growing, which proves nothing.  The driver runs in a clone, so the tree it
breaks is thrown away afterwards.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
checks this round changed are copied in from the WORKING TREE, and so are
the DOCUMENTS the checks read -- README, ENGINEERING and CHANGELOG.  Without
the documents the tree under test would be a MIX of two releases: this
round's checks and the last round's documents -- and the baseline would fail
for a reason that has nothing to do with the promise being broken.  Round
24's driver copies the same list, and round 35 says why: "the CHANGELOG that
publishes the failure count has to be IN the tree under test, or the
published-count check is vacuous".

Run: python _verify/_dryrun_round46_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r46")
DRIVER = "_verify/_dryrun_round46_1650.py"
VERIFIERS = [
    "_verify/_verify_count_referents_1650.py",
    "_verify/_verify_estimator_census_1680.py",
    "_verify/_verify_example_kinds_1680.py",
]
DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

# the seven names the README spells with the bare stem
STEMS = ["validate_apos", "validate_cluster_iv", "validate_cluster_plr",
         "validate_iivm", "validate_irm", "validate_pliv", "validate_plpr"]


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


def sub_once(path, pattern, repl):
    """Replace the regex `pattern` with `repl`, exactly once.

    A REGEX, not a literal: the mechanisms must patch the text as it NOW
    STANDS, and the numbers in these files move with every release.  A
    literal here would be a literal that goes stale.
    """
    text = read(path)
    crlf = "\r\n" in text
    pat = pattern.replace("\n", "\r\n") if crlf and "\r\n" not in pattern else pattern
    rep = repl.replace("\n", "\r\n") if crlf and "\r\n" not in repl else repl
    n = len(re.findall(pat, text))
    if n != 1:
        raise SystemExit("!! %s: %r matched %d times (expected 1)"
                         % (path, pattern, n))
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
    """Run the verifiers in `work`.

    Returns (exit code, output, failure count, per-verifier failure lists).

    WHAT IS COUNTED
    ===============
    A failing CHECK.  The marker `*** FAIL ***` goes on each failing check
    line; a line whose WHOLE content is the marker is a section HEADER some
    verifiers print after their counter, and a header is not a check, so it
    is excluded.

    The count is by CONTAINMENT, not by prefix or by suffix: the verifier
    families print the marker in different positions -- at the front, at the
    back, in the middle -- and a rule that matched only one position would
    under-count the failures of the others.
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

    A rule that read only one of them would under-count the failures of the
    other families -- and this driver's round-45 predecessor read three of
    the four and said the counter and the summaries disagreed.  The missing
    one was "SUMMARY: N checks, M failures": the two words DIVERGE after
    "fail", so a pattern that looked for "failed" never saw it.

    The "checks run: N, checks failed: M" form contains the "checks failed: M"
    form as a SUBSTRING, so it is counted first and then removed from the
    text the shorter pattern reads -- otherwise it would be counted twice.
    """
    found = []
    found += [(c, f) for c, f in re.findall(r"(\d+) checks,\s*(\d+) failed", out)]
    found += [(c, f) for c, f in re.findall(r"(\d+) checks,\s*(\d+) failures", out)]
    found += [(None, m.group(1)) for m in
              re.finditer(r"checks run:\s*\d+,\s*checks failed:\s*(\d+)", out)]
    rest = re.sub(r"checks run:\s*\d+,\s*checks failed:\s*\d+", "", out)
    found += [(None, m.group(1)) for m in re.finditer(r"checks failed:\s*(\d+)", rest)]
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
# The clone carries the COMMITTED tree.  The checks this round changed, and
# the documents they read, come from the working tree: the tree under test
# has to be the tree that will be released, or the driver proves something
# about a tree nobody ships.
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


def both(pattern, repl):
    """Patch BOTH copies of the README.

    The README exists twice and a check owns the two being byte-identical --
    so every mechanism patches BOTH, or the count would move for a reason
    that has nothing to do with the promise being broken.
    """
    sub_once(README, pattern, repl)
    sub_once(SHIPPED, pattern, repl)


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
    ("the seven script names are bare stems again",
     lambda: [both(r"`%s_with_python\.py`" % s, "`%s`" % s) for s in STEMS]),

    ("the Status table's estimator count is wrong",
     lambda: both(r"\| Estimators \| \*\*22\*\* `DoubleML\*` estimator structs",
                  "| Estimators | **21** `DoubleML*` estimator structs")),

    ("the Status table's .mbt census is wrong",
     lambda: both(r"\*\*220\*\* `\.mbt` files \(\*\*65\*\* production "
                  r"\+ \*\*129\*\* blackbox test \+ \*\*26\*\* whitebox test\)",
                  "**219** `.mbt` files (**64** production + **129** blackbox test "
                  "+ **26** whitebox test)")),

    ("the CLI-style demo count is wrong",
     lambda: both(r"16 are CLI-style numeric\s+demos",
                  "15 are CLI-style numeric demos")),
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
# Each verifier prints its OWN summary, so the summaries are SUMMED: three
# verifiers that fail 1, 2 and 1 times make a total of 4, and the driver's
# counter counts the failing CHECK lines across all three.
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
        # pattern with literal spaces matches only the entries that happen
        # to keep the phrase on ONE line -- and the driver then reads an
        # OLDER entry's number and calls it its own.
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

# The SAME number, in the ENGINEERING banner.  The banner is the other place
# the count is published, and a number nothing checks is a number that rots
# silently.
#
# The count that belongs to THIS driver is the one in the passage that NAMES
# it -- NOT the last count in the banner.  The banner lists the rounds
# ASCENDING (oldest first), so a LATER round's entry carries its own count,
# and the last "ends at **N** failures" in the banner stops being this
# driver's the moment the next round publishes one of its own.
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r46_dryrun.out")
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
