"""Dry-run the round-44 checks against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 44 replaced a STRAITJACKET and gave four documents' claims an owner
that did not exist before.

The straitjacket: `_verify/_verify_dep_pins_1680.py` asserted that the
api_server example's `moonbitlang/async` pin DIFFERS from the library's.  That
is a check about a DOCUMENT'S SHAPE wearing the clothes of a check about a
DOCUMENT'S TRUTH: it forbids the tree from taking any other shape, including
the correct one -- and the correct shape was the example moving to the pin the
README's own dependency rule asks for.  The check now owns the class it was
meant to own ("a version a document names must be a version the tree
declares"), and the README's rule has a check of its own.

The owners: the layout block's paths (`_verify_layout_1680.py`), the bare-`moon
test` sentence (`_verify_count_referents_1650.py`), the installation guide's
verification framing (`_verify_shipped_docs_1643.py`) and the introduction's
`ml_m` rule (`_verify_score_argument_1650.py`).

A check that cannot fail is not a check, so each mechanism here breaks ONE
promise in the tree and the failure count must GROW at every step.

THE MECHANISMS
===============
  1. the layout block names `example/consumer_demo` again -- the example's
     PACKAGE name, where a repository PATH was meant;
  2. the dependency table's note quotes a pin the tree does not declare;
  3. the service sentence quotes a pin the example does not declare;
  4. the bare-`moon test` sentence credits the suite to the wrong backend;
  5. doc/001 states the blanket `ml_m` rule again -- which is false for
     `DoubleMLIIVM`, whose `ml_m` models the INSTRUMENT's propensity and still
     defaults to OLS;
  6. doc/002 drops the installed consumer's zero count.

THEY ARE CUMULATIVE
===================
Each mechanism is applied ON TOP of the ones before it.  Restoring between the
steps would REPAIR the earlier break -- mechanism 2 edits the same file
mechanism 1 edited, so restoring it puts the layout path back -- and the
count would FALL instead of growing, which proves nothing.  The driver runs in
a clone, so the tree it breaks is thrown away afterwards.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round CHANGED are copied in from the INDEX -- the index is what the
release will commit -- so the tree under test is exactly the tree that carries
the checks being exercised.

Run: python _verify/_dryrun_round44_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r44")
DRIVER = "_verify/_dryrun_round44_1650.py"

# The documents the exercised checks READ must come from the WORKING TREE
# too.  The clone is checked out from HEAD, so without these the tree under
# test is a MIX of two releases: the checks are this round's and the
# documents they read are the last round's -- and the baseline then fails for
# a reason that has nothing to do with the promise being broken.
#
# Round 24's driver copies the same list for the same reason, and round 35
# says it outright: "the CHANGELOG that publishes the failure count has to be
# IN the tree under test, or the published-count check is vacuous".
DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
    "doc/001_introduction/readme.mbt.md",
    "doc/002_installation/readme.mbt.md",
]

VERIFIERS = [
    "_verify/_verify_layout_1680.py",
    "_verify/_verify_count_referents_1650.py",
    "_verify/_verify_dep_pins_1680.py",
    "_verify/_verify_shipped_docs_1643.py",
    "_verify/_verify_score_argument_1650.py",
]


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


def current_version():
    """The library's version, read from the tree under test.

    It is DERIVED, never written down: a tracked file that names the current
    version must be a bump site (the round-9 rule), and this driver is not
    one.
    """
    txt = read(os.path.join(REPO, "moonbit_doubleML", "moon.mod"))
    m = re.search(r'version = "([^"]+)"', txt)
    if not m:
        raise SystemExit("!! the library manifest has no version")
    return m.group(1)


def commit(work, paths, message):
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
    """Run the verifiers in `work`.

    Returns (exit code, output, failure count, per-verifier failure lists).

    WHAT IS COUNTED
    ===============
    A failing CHECK.  The marker `*** FAIL ***` goes on each failing check
    line; a line whose WHOLE content is the marker is a section HEADER some
    verifiers print after their counter, and a header is not a check, so it
    is excluded.

    The count is by CONTAINMENT, not by prefix or by suffix: the verifier
    families print the marker in different positions -- at the front, at
    the back, in the middle -- and a rule that matched only one position
    would under-count the failures of the others.
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
    other families -- and this driver's first run read three of the four and
    said the counter and the summaries disagreed, with a count of 8 against a
    count of 7.  The missing one was "SUMMARY: N checks, M failures": the two
    words DIVERGE after "fail", so a pattern that looked for "failed" never
    saw it.

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

# --- copy the INDEX in: it is what the release will commit ------------------
rc, out = run(["git", "diff", "--cached", "--name-only"], cwd=REPO)
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
print("  copied in %d files from the index" % len(COPY_IN))
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checks")

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
DOC1 = os.path.join(WORK, "doc", "001_introduction", "readme.mbt.md")
DOC2 = os.path.join(WORK, "doc", "002_installation", "readme.mbt.md")

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
#
# CUMULATIVE: each mechanism is applied on top of the ones before it.
MECHANISMS = [
    ("the layout block names `example/consumer_demo` again",
     lambda: (sub_once(README,
                        r"library-user pattern \(`examples/consumer_demo`\)",
                        "library-user pattern (`example/consumer_demo`)"),
              sub_once(SHIPPED,
                       r"library-user pattern \(`examples/consumer_demo`\)",
                       "library-user pattern (`example/consumer_demo`)"))),

    ("the dependency table's note quotes a pin the tree does not declare",
     lambda: (sub_once(README,
                        r"at the same pin \(`moonbitlang/async@0\.22\.5`\)",
                        "at the same pin (`moonbitlang/async@0.20.3`)"),
              sub_once(SHIPPED,
                       r"at the same pin \(`moonbitlang/async@0\.22\.5`\)",
                       "at the same pin (`moonbitlang/async@0.20.3`)"))),

    ("the service sentence quotes a pin the example does not declare",
     lambda: (sub_once(README,
                        r"The service is built directly on `moonbitlang/async@0\.22\.5` --",
                        "The service is built directly on `moonbitlang/async@0.20.3` --"),
              sub_once(SHIPPED,
                       r"The service is built directly on `moonbitlang/async@0\.22\.5` --",
                       "The service is built directly on `moonbitlang/async@0.20.3` --"))),

    ("the bare-`moon test` sentence credits the suite to the wrong backend",
     lambda: (sub_once(README,
                        r"runs the suite on `wasm-gc` \(1123",
                        "runs the suite on `wasm` (1123"),
              sub_once(SHIPPED,
                       r"runs the suite on `wasm-gc` \(1123",
                       "runs the suite on `wasm` (1123"))),

    ("doc/001 states the blanket `ml_m` rule again",
     lambda: sub_once(DOC1,
                      r"for the six estimators\n  whose propensity enters the "
                      r"score as `1 / m_hat`",
                      "wherever the\n  propensity enters the score as `1 / m_hat`")),

    ("doc/002 drops the installed consumer's zero count",
     lambda: sub_once(DOC2,
                      r"Total tests: 0, passed: 0, failed: 0\.",
                      "Total tests: 1117, passed: 1117, failed: 0.")),
]

prev = n0
prev_by = by0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n, by = verify(WORK)
    grew = n > prev
    print("  %d. %-58s failures %d -> %d  %s"
          % (i, desc[:58], prev, n, "GROW" if grew else "*** FLAT ***"))
    if grew:
        for vi, lines in enumerate(by):
            for l in lines:
                if l not in prev_by[vi]:
                    print("        + %s" % l[:110])
    for vi in range(len(by)):
        if len(by[vi]) < len(prev_by[vi]):
            print("!! mechanism %d repaired a failure -- ABORT" % i)
            sys.exit(1)
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n
    prev_by = by

# the counter must agree with the verifiers' own summaries
rc, out, n, by = verify(WORK)
print()
print("=== the counter and the verifiers' own summaries ===")
print("  the driver counted %d failures" % n)
summaries = summaries_of(out)
print("  the verifiers say  %s"
      % (", ".join("%s/%s" % (c, f) for c, f in summaries) if summaries else "NONE"))
if not summaries or sum(int(f) for _c, f in summaries) != n:
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
# The banner is ASCENDING, so the LIVE claim for this driver is its LAST
# mention -- and a mention that publishes no count is not a publication,
# so the search falls back to an earlier one.  The passage is read with
# the banner's quote prefix stripped and its whitespace collapsed: the
# sentence that carries the number is hard-WRAPPED, and the break is
# followed by the quote prefix, not by a space.
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
if not _eng_found:
    print("  the ENGINEERING banner publishes no failure count -- ABORT")
    print("  (this run measured %d -- put that number in the banner)" % n)
    sys.exit(1)
_eng_published = int(_eng_found[0])
print("  the banner publishes %d; this run measured %d" % (_eng_published, n))
if _eng_published != n:
    print("!! the banner's count and the measured one disagree -- ABORT")
    sys.exit(1)
if "NFAIL44" in _eng_banner:
    print("!! the banner still carries an unsubstituted placeholder -- ABORT")
    sys.exit(1)
print("  OK -- the banner's number is the number this run measured")

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
