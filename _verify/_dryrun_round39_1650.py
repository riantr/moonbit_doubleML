"""Dry-run the round-39 verifiers against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 39 found that a SECOND USER-FACING DOCUMENT -- the agent skill --
had never been audited, and that two of the README's claims had no check
that could see them: a literature citation's page range, and the ORDER in
which a parenthetical pairs names with versions.

A check that cannot fail is not a check, so each mechanism here breaks ONE
promise in the tree and the failure count must GROW at every step.

The four verifiers under test:

  _verify/_verify_skill_claims_1650.py      the agent skill: its pin, its
                                            counts, its names
  _verify/_verify_citations_1650.py          the literature citations,
                                            against the publisher's record
  _verify/_verify_sandwich_coverage_1680.py the version<->estimator PAIRING
  _verify/_verify_package_claims_1650.py    the import isolation

THE MECHANISMS
===============
  1. the skill's api_server pin goes stale again;
  2. the skill's whitebox test-case count goes stale;
  3. the tree grows a 25th Python reference script;
  4. the PNAS page range goes back to the wrong one;
  5. the JASA citation is dropped from the README;
  6. the hac_se version pairing swaps back;
  7. the source's own hac_se version marker moves;
  8. the package manifest imports a third-party package.

THE NETWORK
===========
Mechanisms 4 and 5 are exercised by the citations verifier, which consults
the publisher over HTTPS -- so this dry-run NEEDS the network.  The pre-
flight below probes the publisher first and refuses to run without it: an
unreachable publisher would make the mechanism "contribute nothing", which
is a true statement about the check but not a measurement.  (A check that
cannot reach its subject SKIPS with a reason rather than failing, so a
network outage never turns the tree red -- it only makes this dry-run
unable to run.)

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round CHANGED are copied in from the WORKING TREE and committed,
so the tree under test is exactly the tree that carries the checks being
exercised.

Run: python _verify/_dryrun_round39_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r39_pkg")
VERIFIERS = [
    "_verify/_verify_skill_claims_1650.py",
    "_verify/_verify_citations_1650.py",
    "_verify/_verify_sandwich_coverage_1680.py",
    "_verify/_verify_package_claims_1650.py",
]
TOUCHED = [
    "README.mbt.md",
    os.path.join("moonbit_doubleML", "README.mbt.md"),
    "CHANGELOG.md",
    "skills",
    os.path.join("_verify", "_r18_build_readme_1650.py"),
    os.path.join("moonbit_doubleML", "moon.pkg"),
    os.path.join("moonbit_doubleML", "rdd.mbt"),
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
    STANDS, and the version literal in these files moves with every
    release.  A literal here would be a literal that goes stale.
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

    WHY THE EXCLUSION MATTERS
    =========================
    The count has to equal the number the verifiers report in their own
    summaries, because that is the number the CHANGELOG publishes.  A driver
    that counted the bare header would be inflated by one per failing
    verifier, and would publish a number no verifier ever reported.
    """
    total = 0
    by_verifier = []
    chunks = []
    rc = 0
    for rel in VERIFIERS:
        r, out = run([sys.executable, os.path.join(work, rel)], cwd=work,
                     timeout=1800)
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

    Two conventions are in the contract: the `N checks, M failed` form and
    the `checks failed: M` form.  A rule that read only one of them would
    under-count the failures of the other family -- the round-38 lesson,
    applied to the summary instead of the marker.
    """
    found = re.findall(r"(\d+) checks, (\d+) failed", out)
    found += [(None, m.group(1)) for m in re.finditer(r"checks failed: (\d+)", out)]
    return found


# --- the pre-flight: the citations arm needs the publisher --------------------
print("=== pre-flight: the publisher must be reachable ===")
try:
    import urllib.request
    req = urllib.request.Request(
        "https://api.crossref.org/works/10.1073/pnas.1510489113",
        headers={"User-Agent": "moonbit_doubleML-verify/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
    if b"7353-7360" not in body:
        print("!! the publisher answered, but not with the expected record")
        sys.exit(1)
    print("  the publisher answers, and the record carries the page range")
except Exception as e:  # noqa: BLE001
    print("!! the publisher is unreachable (%s: %s)" % (type(e).__name__, e))
    print("!! this dry-run needs the network -- ABORT (exit 3)")
    sys.exit(3)

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
ADDED = ["_verify/_verify_skill_claims_1650.py",
         "_verify/_verify_citations_1650.py",
         "_verify/_dryrun_round39_1650.py"]
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

R1 = os.path.join(WORK, "README.mbt.md")
R2 = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
SKILL = os.path.join(WORK, "skills", "moonbit_doubleML.md")
PKG = os.path.join(WORK, "moonbit_doubleML")
PKGFILE = os.path.join(PKG, "moon.pkg")
RDD = os.path.join(PKG, "rdd.mbt")
VALIDATOR = os.path.join(WORK, "validate_extra_1650_with_python.py")


def patch_readmes(old, new):
    sub_once(R1, old, new)
    sub_once(R2, old, new)
    commit(WORK, ["README.mbt.md",
                  os.path.join("moonbit_doubleML", "README.mbt.md")],
           "dry-run: the README's claim moved")


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
    # -- 1. the skill's api_server pin goes stale again ----------------------
    ("the skill's api_server pin goes stale again",
     lambda: (sub_once(SKILL,
                        r"riantr/moonbit_doubleML@\d+\.\d+\.\d+",
                        "riantr/moonbit_doubleML@0.52.0"),
              commit(WORK, [os.path.join("skills", "moonbit_doubleML.md")],
                     "dry-run: the skill's pin went stale"))),

    # -- 2. the skill's whitebox test-case count goes stale ------------------
    ("the skill's whitebox test-case count goes stale",
     lambda: (sub_once(SKILL, r"\*\*169\*\* test cases", "**170** test cases"),
              commit(WORK, [os.path.join("skills", "moonbit_doubleML.md")],
                     "dry-run: the skill's count went stale"))),

    # -- 3. the tree grows a 25th Python reference script --------------------
    ("the tree grows a 25th Python reference script",
     lambda: (write(VALIDATOR, "#!/usr/bin/env python3\nprint('probe')\n"),
              commit(WORK, ["validate_extra_1650_with_python.py"],
                     "dry-run: the tree grew a validator"))),

    # -- 4. the PNAS page range goes back to the wrong one -------------------
    ("the PNAS page range goes back to the wrong one",
     lambda: patch_readmes(r"113\(27\):7353-7360", "113(27):7353-7358")),

    # -- 5. the JASA citation is dropped from the README ---------------------
    # The SECOND citation, not the first.  Two mechanisms cannot both grow
    # the failure count when they break the SAME passage: the verifier's
    # unreadable-shape check short-circuits the field checks, so a dropped
    # PNAS citation would REPLACE mechanism 4's failure instead of adding
    # to it, and the count would stay flat.  The JASA arm is a promise of its
    # own -- and until this mechanism existed, NOTHING proved that arm could
    # fail at all.
    #
    # The pattern must reach the text as it NOW STANDS: the README is
    # hard-wrapped, so the citation spans two lines.
    ("the JASA citation is dropped from the README",
     lambda: patch_readmes(
         r"Wager & Athey\s+\(\d{4}, JASA\)",
         "Wager & Athey")),

    # -- 6. the hac_se version pairing swaps back ----------------------------
    ("the hac_se version pairing swaps back",
     lambda: patch_readmes(
         r"`DoubleMLRDD` \(v0\.96\.0\) and `DoubleMLBLP` \(v0\.97\.0\)",
         "`DoubleMLBLP` (v0.96.0) and `DoubleMLRDD` (v0.97.0)")),

    # -- 7. the source's own hac_se version marker moves ----------------------
    ("the source's own hac_se version marker moves",
     lambda: (sub_once(RDD,
                        r"/// v0\.96\.0\+: heteroskedasticity-consistent",
                        "/// v0.95.0+: heteroskedasticity-consistent"),
              commit(WORK, [os.path.join("moonbit_doubleML", "rdd.mbt")],
                     "dry-run: the source's version marker moved"))),

    # -- 8. the package manifest imports a third-party package ---------------
    ("the package manifest imports a third-party package",
     lambda: (sub_once(PKGFILE,
                        r'"moonbitlang/core/random",',
                        '"moonbitlang/core/random",\n  '
                        '"moonbit-community/sqlite3@0.2.3",'),
              commit(WORK, [os.path.join("moonbit_doubleML", "moon.pkg")],
                     "dry-run: the manifest imported a third-party package"))),
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
    if "_dryrun_round39_1650.py" in m.group(2):
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
# the count is published, and it is a LITERAL in the README builder -- which
# is how this round shipped a banner saying "**NFAIL**" because the
# placeholder was never substituted.  A number nothing checks is a number
# that rots silently, so it is witnessed here too.
#
# The banner lists the rounds ASCENDING (oldest first) -- the opposite of the
# CHANGELOG, which is DESCENDING -- and the ledger body follows it.  So the
# newest count is the LAST match INSIDE THE BANNER, and the banner is cut out
# of the document before the search: taking the first match in the whole file
# would find an earlier round's count, and taking the last would find the
# ledger body's.
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
if "NFAIL" in _eng_banner:
    print("!! the banner still carries an unsubstituted placeholder -- ABORT")
    sys.exit(1)
print("  OK -- the banner's number is the number this run measured")

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
