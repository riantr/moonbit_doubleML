"""Dry-run the score-argument verifier against a tree whose claims are broken.

WHAT THIS PROVES
=================
`_verify/_verify_score_argument_1650.py` derives the `score` argument's
shape from the SOURCE -- the 9 score parameters and their owning methods,
the accepted set at each site, the internal cache-kind tags, the port's
accepted union and upstream's, measured on BOTH the vendored 0.11.4 tree
and the installed 0.11.4 wheel.

Round 28 found five false statements across `doc/004_estimators`, the
published README and `skills/moonbit_doubleML.md`.  The point of the
dry-run is that each of them is a sentence that READS FINE: a column
headed "the value you pass to `fit(score=...)`" that was right for one
estimator out of 22, a set of internal cache-kind tags presented as
accepted score values, an upstream vocabulary missing six of its fifteen
spellings, a list of six that named seven, and a family of 24 validators
of which 9 do not do what the sentence said.  No spelling check and no
number check sees any of them.

EACH MECHANISM IS PROVEN ON ITS OWN
====================================
The mechanisms are applied ONE AT A TIME and the verifier is run after each,
and the failure count must GROW at every step.  A mechanism that contributes
nothing is visible as a flat step, and the driver fails.  (Round 24's dry-run
had exactly that defect: one mechanism contributed ZERO failures, the total
was still > 0, and the dead mechanism hid inside a passing run.)

THE LAST TWO MECHANISMS PROVE THE DERIVATION IS LIVE
=====================================================
Mechanism 11 deletes a `score~` parameter from the SOURCE, so the derived
counts change and every document that stated them is caught.  Nothing in
the verifier is hard-coded to "7 estimators take a score argument": the
count is re-derived, so the documents that still say 7 fail.

Mechanism 12 mutates the vendored upstream tree, so the upstream
vocabulary is no longer the one the documents state -- and the vendored
0.11.4 and the installed 0.11.4 stop agreeing, which the verifier checks
separately.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the corrected documents, the
rebuilt README, the CHANGELOG entry that publishes this driver's count, the
new verifier and the UNTRACKED vendored upstream tree -- are copied in from
the WORKING TREE, and the claims are broken on top of that.

Run: python _verify/_dryrun_round28_1650.py
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r28_mut")
VERIFIER = "_verify/_verify_score_argument_1650.py"

COPY_IN = [
    "CHANGELOG.md",
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "doc/001_introduction/readme.mbt.md",
    "doc/004_estimators/readme.mbt.md",
    "skills/moonbit_doubleML.md",
    VERIFIER,
]

# `doc/001_introduction/readme.mbt.md` joined the list in round 44, when the
# verifier gained a check that reads the tutorial's `ml_m` rule.  The clone is
# checked out at HEAD, so without the copy-in it carried the OLD tutorial --
# the one with the blanket rule -- and the new check went red on the BASELINE,
# which the driver reads as "the dry-run would prove nothing".  A driver's copy
# list has to cover everything the verifier it drives READS.

# the vendored upstream tree is NOT tracked, so it has to be copied in
# explicitly -- without it the verifier reports no vendored 0.11.4 and the
# baseline is not green.
COPY_DIRS = ["_verify/_upstream_ps/doubleml-0.11.4"]


def run(cmd, cwd=REPO, timeout=3600):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def patch(path, old, new, count=1):
    """Replace `old` with `new`, keeping the file's own line endings."""
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    crlf = "\r\n" in text
    old = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
    new = new.replace("\n", "\r\n") if crlf and "\r\n" not in new else new
    n = text.count(old)
    if n != count:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, old[:60], n, count))
    text = text.replace(old, new)
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def verify(work):
    """Run the verifier in `work`; return (exit code, output, failure count)."""
    rc, out = run([sys.executable, os.path.join(work, VERIFIER)],
                  cwd=work, timeout=3600)
    exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
    return rc, out, exact


if os.path.isdir(WORK):
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

for rel in COPY_IN:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    print("  copied in %s" % rel)

for rel in COPY_DIRS:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copytree(src, dst)
    print("  copied in %s (directory)" % rel)

README = os.path.join(WORK, "README.mbt.md")
DOC4 = os.path.join(WORK, "doc", "004_estimators", "readme.mbt.md")
SKILL = os.path.join(WORK, "skills", "moonbit_doubleML.md")
CSBIN = os.path.join(WORK, "moonbit_doubleML", "did_cs_binary.mbt")
SSM = os.path.join(WORK, "_verify", "_upstream_ps", "doubleml-0.11.4",
                   "doubleml", "irm", "ssm.py")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0 = verify(WORK)
print("  exit=%d  failures=%d" % (rc0, n0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# ------------------------------------------------------------ the mechanisms
MECHANISMS = [
    # -- doc/004: the cache-kind tags are presented as score values again -----
    ("doc/004's APO row says 'apo' again",
     lambda: patch(
         DOC4,
         "| `DoubleMLAPO` | — (fixed: APO) |",
         "| `DoubleMLAPO` | `apo` |")),

    # -- doc/004: the column is a bare value again ---------------------------
    ("doc/004's DID row says 'observational' again",
     lambda: patch(
         DOC4,
         "| `DoubleMLDID` | `new(score=...)` | difference-in-differences | "
         "`did.mbt` |",
         "| `DoubleMLDID` | `observational` | difference-in-differences | "
         "`did.mbt` |")),

    # -- doc/004: the count of score-taking estimators -----------------------
    ("doc/004 claims 21 of the 22 take a score argument",
     lambda: patch(
         DOC4,
         "**Only 7 of the 22 estimators take a `score` argument**",
         "**Only 21 of the 22 estimators take a `score` argument**")),

    # -- doc/004: the site table loses a row ---------------------------------
    ("doc/004's score-argument table loses the PLR row",
     lambda: patch(
         DOC4,
         "| `DoubleMLPLR` | `fit(score=...)` | `partialling-out` | "
         "`partialling-out`, `partialling out`, `iv-type`, `IV-type` |\n",
         "")),

    # -- doc/004: a site states a spelling the port does not accept -----------
    ("doc/004's PLPR row claims the hyphen spelling",
     lambda: patch(
         DOC4,
         "| `DoubleMLPLPR` | `new(score=...)` | `partialling out` | "
         "`partialling out`, `IV-type` |",
         "| `DoubleMLPLPR` | `new(score=...)` | `partialling out` | "
         "`partialling-out`, `IV-type` |")),

    # -- the README: the port's list is the old one, cache tags included ------
    ("the README's port list is the old one, cache-kind tags included",
     lambda: patch(
         README,
         "**8** spellings -- `partialling-out`, `partialling out`, `iv-type`,\n"
         "`IV-type`, `observational`, `experimental`, `nuisance_space` and\n"
         "`instrument` --",
         "**8** spellings -- `partialling-out`, `apo`, `pq`, `lpq`,\n"
         "`cvar`, `policy_tree`, `nuisance_space`, `observational` --")),

    # -- the README: upstream's list loses six spellings ---------------------
    ("the README's upstream list is the old 9-spelling one",
     lambda: patch(
         README,
         "upstream `doubleml-for-py` 0.11.4 uses `APO`, `ATE`, `PQ`, `LPQ`,\n"
         "`CVaR`, `LATE`, `ATTE`, `IV-type`, `experimental`, `instrument`,\n"
         "`missing-at-random`, `nonignorable`, `nuisance_space`, `observational`\n"
         "and `partialling out`;",
         "upstream `doubleml-for-py` 0.11.4 uses `APO`, `ATE`, `PQ`, `LPQ`,\n"
         "`CVaR`, `nuisance_space`, `partialling out`, `observational` and\n"
         "`missing-at-random`;")),

    # -- the README: the constructor paragraph stops naming the difference ----
    ("the README's constructor paragraph stops naming the score argument",
     lambda: patch(
         README,
         # The paragraph used to end with "its own data type."; it now ends
         # with the four-data-types sentence, so the anchor moved with it.
         # The mechanism still only deletes the score sentence.
         "`DoubleMLDIDCrossSectionData` for `DoubleMLDIDCrossSection`. The "
         "`score` argument is the one that moves between\n"
         "`new()` and `fit()`: `DoubleMLPLR` takes it on `fit()`, and\n"
         "`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCrossSection`,\n"
         "`DoubleMLDIDCSBinary`, `DoubleMLLPLR` and `DoubleMLPLPR` take it on\n"
         "`new()`.",
         "`DoubleMLDIDCrossSectionData` for `DoubleMLDIDCrossSection`.")),

    # -- the skills document: the six become seven ---------------------------
    ("the skills document folds LPLR into the six",
     lambda: patch(
         SKILL,
         "for the six estimators whose propensity enters the score as\n"
         "  `1 / m_hat` -- `DoubleMLIRM` (v0.132.0), `DoubleMLAPO`\n"
         "  (v0.134.0), `DoubleMLAPOS` (v0.135.0), `DoubleMLSSM` (v0.138.0)\n"
         "  and `DoubleMLPQ` / `DoubleMLQTE` (v0.139.0). A seventh,\n"
         "  `DoubleMLLPLR` (v0.163.3), also defaults `ml_m` to the classifier,\n"
         "  but its propensity enters the score as `d - m_hat`, not `1 / m_hat`\n"
         "  -- so do not add it to the six.",
         "for the seven estimators whose propensity enters the score as\n"
         "  `1 / m_hat` -- `DoubleMLIRM` (v0.132.0), `DoubleMLAPO`\n"
         "  (v0.134.0), `DoubleMLAPOS` (v0.135.0), `DoubleMLSSM` (v0.138.0),\n"
         "  `DoubleMLPQ` / `DoubleMLQTE` (v0.139.0) and `DoubleMLLPLR`\n"
         "  (v0.163.3).")),

    # -- the skills document: the validator family is one again --------------
    ("the skills document says all 24 re-derive the hand-rolled reference",
     lambda: patch(
         SKILL,
         "Fifteen of the 24 re-derive the hand-rolled reference\n"
         "  for one model and compare against the MoonBit output; the other nine\n"
         "  import upstream's `doubleml` wheel and take the reference from\n"
         "  there.",
         "They re-derive the hand-rolled reference for one\n"
         "  model and compare against the MoonBit output.")),

    # -- the DERIVATION is live: the source loses a score parameter ----------
    ("the SOURCE loses a score parameter, so the derived counts move",
     lambda: patch(
         CSBIN,
         "  score~ : String = \"observational\",\n",
         "")),

    # -- the upstream derivation is live: the vendored tree changes -----------
    ("the vendored upstream tree drops a spelling",
     lambda: patch(
         SSM,
         "[\"missing-at-random\", \"nonignorable\"]",
         "[\"missing-at-random\"]")),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    grew = n > prev
    print("  %d. %-70s failures %d -> %d  %s"
          % (i, desc[:70], prev, n, "GROW" if grew else "*** FLAT ***"))
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n

# the counter must agree with the verifier's own summary
rc, out, n = verify(WORK)
m = re.search(r"(\d+) checks, (\d+) failed", out)
print()
print("=== the counter and the verifier's own summary ===")
print("  the driver counted %d failures" % n)
print("  the verifier says  %s checks, %s failed" % (m.group(1), m.group(2)))
if not m or int(m.group(2)) != n:
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
# The CHANGELOG publishes the number of failures this dry-run ends at.  A
# published exact number with nothing asserting it goes stale silently, so the
# dry-run ASSERTS its own published number: it measures the final failure
# count and compares that with the number the CHANGELOG states.
#
# The count is TREE-DEPENDENT on purpose -- the verifier checks one thing per
# doc/004 row, per score site and per source file, so a tree with fewer rows
# runs fewer checks, and the tree under test here is deliberately broken.
# That is why the number this dry-run ends at is NOT the number the verifier
# makes on the tree as it stands.
CHANGELOG = os.path.join(WORK, "CHANGELOG.md")
# The CHANGELOG is in DESCENDING order -- the newest entry is at the TOP -- so
# the CURRENT published number is the FIRST occurrence.  (Taking the last one
# binds the witness to an entry that has already shipped.)
published = published_count(io.open(CHANGELOG, encoding="utf-8", errors="replace").read(), "_dryrun_round28_1650.py")
print()
print("=== the published failure count, witnessed ===")
if published is None:
    print("  the CHANGELOG publishes no failure count for this dry-run -- ABORT")
    sys.exit(1)
print("  the CHANGELOG publishes %d; this run measured %d" % (published, n))
if published != n:
    print("!! the published failure count and the measured one disagree -- ABORT")
    sys.exit(1)
print("  OK -- the published number is the number this run measured")

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
