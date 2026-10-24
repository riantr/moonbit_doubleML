"""Dry-run the round-40 checks against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 40 found the LAST file in the tree still carrying a stale library pin
-- the doc project's own manifest -- and a class of published numbers that no
check owned: the ENGINEERING banner's check counts.  Four of them were false,
and one of those had never been true.

A check that cannot fail is not a check, so each mechanism here breaks ONE
promise in the tree and the failure count must GROW at every step.

The three checks under test:

  _verify/_verify_ledger_counts_1650.py   the banner's published counts must
                                          be the numbers the checks make
  _verify/_verify_example_pins_1650.py    the stale-literal scan, which now
                                          covers the doc project's manifest
  _verify/_verify_release_tree_1650.py    the tree at a REF, which now holds
                                          the doc project's manifest to the
                                          version like every other site

THE MECHANISMS
===============
  1. the banner's published count for a check goes stale;
  2. the banner publishes a count for a check that is not in the tree;
  3. the doc project's manifest pin goes stale;
  4. the CHANGELOG and the banner contradict each other.

MECHANISMS 1, 2 AND 4 BREAK THE LEDGER; 3 BREAKS THE PIN.  They cannot all
be broken by the same mutation: a mutation of the banner moves the count
that the ledger check reads, while a mutation of the manifest moves the count
that the pin and release-tree checks read.  Each one is proved separately,
because a class proved by one mechanism is a class with one mechanism.

THE NETWORK
===========
The ledger check RUNS every check the banner names, and one of them --
`_verify/_verify_citations_1650.py` -- consults the publisher over HTTPS.
That check SKIPS with a reason when the publisher is unreachable, and a skip
is still counted, so its count does not move with the network.  The
pre-flight below therefore REPORTS the publisher's reachability instead of
requiring it: a network outage must not make this dry-run unable to run.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round CHANGED are copied in from the WORKING TREE and committed,
so the tree under test is exactly the tree that carries the checks being
exercised.

Run: python _verify/_dryrun_round40_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r40_ledger")
VERIFIERS = [
    "_verify/_verify_ledger_counts_1650.py",
    "_verify/_verify_example_pins_1650.py",
    "_verify/_verify_release_tree_1650.py",
    "_verify/_verify_doc_claims_1650.py",
]
TOUCHED = [
    "ENGINEERING.md",
    "CHANGELOG.md",
    os.path.join("doc", "moon.mod"),
    os.path.join("_verify", "_r18_build_readme_1650.py"),
    os.path.join("_verify", "_bump_1636.py"),
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
    families print the marker in different positions, and a rule that
    matched only one position would under-count the failures of the other.
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
    """The verifiers' own failure counts, in either summary convention.

    Two conventions are in the contract: the `N checks, M failed` form (which
    also matches the `N checks, M failed, K skipped` form) and the
    `checks failed: M` form.  A rule that read only one of them would
    under-count the failures of the other family -- the round-38 lesson,
    applied to the summary instead of the marker.
    """
    found = re.findall(r"(\d+) checks, (\d+) failed", out)
    found += [(None, m.group(1)) for m in re.finditer(r"checks failed: (\d+)", out)]
    return found


# --- the pre-flight: the publisher's reachability is REPORTED, not required ---
print("=== pre-flight: the publisher ===")
try:
    import urllib.request
    req = urllib.request.Request(
        "https://api.crossref.org/works/10.1073/pnas.1510489113",
        headers={"User-Agent": "moonbit_doubleML-verify/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
    if b"7353-7360" not in body:
        print("  the publisher answered, but not with the expected record")
    else:
        print("  the publisher answers, and the record carries the page range")
except Exception as e:  # noqa: BLE001
    print("  the publisher is unreachable (%s: %s)" % (type(e).__name__, e))
    print("  (the citation check SKIPS rather than failing, so its count holds)")

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

print()
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
rc, out = run(["git", "diff", "--name-only", "HEAD", "--"], cwd=REPO)
CHANGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
ADDED = ["_verify/_verify_ledger_counts_1650.py",
         "_verify/_verify_doc_claims_1650.py",
         "_verify/_dryrun_round40_1650.py"]
COPY_IN = []
for rel in list(VERIFIERS) + [t for t in TOUCHED if t not in VERIFIERS] \
        + CHANGED + ADDED:
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

ENG = os.path.join(WORK, "ENGINEERING.md")
CHG = os.path.join(WORK, "CHANGELOG.md")
DOCMOD = os.path.join(WORK, "doc", "moon.mod")
DOC4 = os.path.join(WORK, "doc", "004_estimators", "readme.mbt.md")

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
MECHANISMS = [
    # -- 1. the banner's published count for a check goes stale ---------------
    ("the banner's published count for a check goes stale",
     lambda: (sub_once(ENG,
                        r"`_verify/_verify_sandwich_coverage_1680\.py` \(now \*\*20\*\* checks\)",
                        "`_verify/_verify_sandwich_coverage_1680.py` (now **21** checks)"),
              commit(WORK, ["ENGINEERING.md"],
                     "dry-run: the banner's count went stale"))),

    # -- 2. the banner publishes a count for a check that is not in the tree ---
    # The name is renamed, so the count it publishes belongs to a check that
    # does not exist.  The check it used to name is named nowhere in the
    # banner any more, so it drops out of the set -- and the check that took
    # its place cannot be run.
    #
    # The name is one the banner mentions ONCE: a rename that matched twice
    # would be a patch the driver refuses to make, because the mutation must
    # land on exactly one mention.
    ("the banner publishes a count for a check that is not in the tree",
     lambda: (sub_once(ENG,
                        r"_verify/_verify_not_covered_1650\.py",
                        "_verify/_verify_not_covered_9999.py"),
              commit(WORK, ["ENGINEERING.md"],
                     "dry-run: the banner named a check that is not in the tree"))),

    # -- 3. the doc project's manifest pin goes stale ------------------------
    # The doc project is a member of `moon.work`, so in-tree the pin is
    # inert -- the workspace member wins.  Outside the tree it is the only
    # thing that decides what gets installed, and it is what the stale-literal
    # scan and the release-tree check now hold to the version.
    ("the doc project's manifest pin goes stale",
     lambda: (sub_once(DOCMOD,
                        r"riantr/moonbit_doubleML@\d+\.\d+\.\d+",
                        "riantr/moonbit_doubleML@0.52.0"),
              commit(WORK, [os.path.join("doc", "moon.mod")],
                     "dry-run: the doc project's pin went stale"))),

    # -- 4. the CHANGELOG and the banner contradict each other ----------------
    # The banner publishes 58 checks for the skill check and the CHANGELOG
    # publishes 57 for the same check.  Neither document owns the number on
    # its own -- the check does -- so the two must be compared.
    #
    # A DIFFERENT check from mechanism 2's: that one took the skill check's
    # place in the banner, so contradicting the banner about the SAME check
    # would no longer be a contradiction.
    ("the CHANGELOG and the banner contradict each other",
     lambda: (sub_once(CHG,
                        r"`_verify/_verify_skill_claims_1650\.py` \(\*\*58\*\* checks\)",
                        "`_verify/_verify_skill_claims_1650.py` (**57** checks)"),
              commit(WORK, ["CHANGELOG.md"],
                     "dry-run: the CHANGELOG and the banner disagreed"))),
    # -- 5. the estimators tutorial's score count goes stale ------------------
    # The tutorial said 9; the source has 8.  Putting the 9 back has to make
    # the doc-claims check fail, or the check cannot see the defect it was
    # written for.
    ("the estimators tutorial's score count goes stale",
     lambda: (sub_once(DOC4,
                        r"\*\*8 `score` parameters, at 7 estimators\*\*",
                        "**9 `score` parameters, at 7 estimators**"),
              commit(WORK, [os.path.join("doc", "004_estimators", "readme.mbt.md")],
                     "dry-run: the tutorial's score count went stale"))),
]

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
                print("        + %s" % l[:100])
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

# --- the published failure count, witnessed -----------------------------------
_entry = None
for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                     read(os.path.join(REPO, "CHANGELOG.md")), re.M | re.S):
    if "_dryrun_round40_1650.py" in m.group(2):
        _entry = m.group(2)
        break
_found = re.findall(r"requires the failure count to GROW at every step:\s*"
                    r"\*\*(\d+)\*\*\s+failures at the end", _entry or "")
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

# The SAME number, in the ENGINEERING banner.  The banner is the other place
# the count is published, and a number nothing checks is a number that rots
# silently.
_eng = read(os.path.join(REPO, "ENGINEERING.md"))
_eng_banner = _eng.split("## The README as it stood at", 1)[0]
_eng_found = re.findall(r"ends at \*\*(\d+)\*\* failures", _eng_banner)
print()
print("=== the same count in the ENGINEERING banner ===")
if not _eng_found:
    print("  the ENGINEERING banner publishes no failure count -- ABORT")
    print("  (this run measured %d -- put that number in the banner)" % n)
    sys.exit(1)
_eng_published = int(_eng_found[-1])
print("  the banner publishes %d; this run measured %d" % (_eng_published, n))
if _eng_published != n:
    print("!! the banner's count and the measured one disagree -- ABORT")
    sys.exit(1)
if "NFAIL40" in _eng_banner:
    print("!! the banner still carries an unsubstituted placeholder -- ABORT")
    sys.exit(1)
print("  OK -- the banner's number is the number this run measured")

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
