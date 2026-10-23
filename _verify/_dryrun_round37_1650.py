"""Dry-run the round-37 verifiers against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 37 gave the README's POSITIVE API promises a check, and gave the
tracked verifier contract a check.  A check that cannot fail is not a
check, so each mechanism here breaks ONE promise in the tree and the
failure count must GROW at every step.

The three verifiers under test:

  _verify/_verify_api_promises_1650.py        the README's API promises
  _verify/_verify_sandwich_coverage_1680.py   the Status table's row
  _verify/_verify_contract_selfcontained_1650.py   the tracked contract

THE MECHANISMS
===============
  1. the README promises every estimator takes the four learner arguments;
  2. the learner table names the wrong estimator;
  3. the README states the wrong number of argument sets;
  4. the README states the wrong number of classifier-migrated structs;
  5. the migration paragraph drops an estimator;
  6. the OLS paragraph drops an estimator;
  7. the README says each DID variant takes its own data type again;
  8. the DID sentence puts the wrong estimator on a data type;
  9. the README stops naming `ml_pi`;
 10. the Status row's "Introduced" literal goes stale again;
 11. the Status row stops disclosing the `hac_se` surface;
 12. the Status row's "expose none" list names the wrong estimator;
 13. a tracked verifier hardcodes an absolute path;
 14. a tracked verifier's root stops reaching the repository root;
 15. a tracked verifier reads a file git does not track;
 16. a verifier over a downloaded tree loses its SKIP path.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round CHANGED are copied in from the WORKING TREE and
committed, so the tree under test is exactly the tree that carries the
checks being exercised -- the README under test, the CHANGELOG that
publishes the failure count, the verifiers themselves, and the builder
that assembles the README.

Run: python _verify/_dryrun_round37_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r37_api")
VERIFIERS = [
    "_verify/_verify_api_promises_1650.py",
    "_verify/_verify_sandwich_coverage_1680.py",
    "_verify/_verify_contract_selfcontained_1650.py",
]
# every file a mechanism below touches, and that this round changed
TOUCHED = [
    "README.mbt.md",
    os.path.join("moonbit_doubleML", "README.mbt.md"),
    "CHANGELOG.md",
    os.path.join("_verify", "_r18_build_readme_1650.py"),
    os.path.join("_verify", "_verify_shipped_docs_1643.py"),
    os.path.join("_verify", "_verify_op_table_1640.py"),
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


def patch(path, old, new, count=1):
    """Replace `old` with `new`, keeping the file's own line endings."""
    text = read(path)
    crlf = "\r\n" in text
    old = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
    new = new.replace("\n", "\r\n") if crlf and "\r\n" not in new else new
    n = text.count(old)
    if n != count:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, old[:70], n, count))
    write(path, text.replace(old, new))


def commit(work, paths, message):
    """Stage the named paths and commit them IN THE CLONE.

    A copy-in that is ALREADY in the tree has nothing to commit, and that is
    not an error: the clone is cut at HEAD, so once the release commit
    exists the new files come with it.  The dry-run is then re-runnable,
    which matters -- a check that can only be run once cannot be re-checked.
    """
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
    """Run the verifiers in `work`; return (exit code, output, failure count).

    The marker goes on EACH failing check line, at the end of the line in this
    verifier family; the summary's bare counter line carries no marker, so the
    two are never confused.
    """
    total = 0
    chunks = []
    rc = 0
    for rel in VERIFIERS:
        r, out = run([sys.executable, os.path.join(work, rel)], cwd=work, timeout=1800)
        rc = rc or r
        chunks.append(out)
        total += len([l for l in out.splitlines()
                      if l.rstrip().endswith("*** FAIL ***")])
    return rc, "\n".join(chunks), total


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

# --- copy the working tree's state in -----------------------------------------
# Everything the working tree CHANGES against HEAD goes in, not just the
# files a mechanism touches: the clone is cut at HEAD, so a change that is
# not copied in is not under test.  That is the round-34 rule -- the tree
# that is RELEASED must be the tree that was TESTED -- and the baseline
# below is what catches the omission.
rc, out = run(["git", "diff", "--name-only", "HEAD", "--"], cwd=REPO)
CHANGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
# the two files this round ADDED to the repository (staged, so they are not
# in `git diff` against HEAD's tree in a clone)
ADDED = ["_verify/_probe_ops_1640.mbt", "_verify/_qa_fast_1639.json"]
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
print("  copied in %d files from the working tree:" % len(COPY_IN))
for rel in COPY_IN:
    print("    %s" % rel)
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checks")

R1 = os.path.join(WORK, "README.mbt.md")
R2 = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
CHANGELOG = os.path.join(WORK, "CHANGELOG.md")
SHIPPED = os.path.join(WORK, "_verify", "_verify_shipped_docs_1643.py")
OPTABLE = os.path.join(WORK, "_verify", "_verify_op_table_1640.py")
APIPROM = os.path.join(WORK, "_verify", "_verify_api_promises_1650.py")
LAYOUT = os.path.join(WORK, "_verify", "_verify_layout_1680.py")
CENSUS = os.path.join(WORK, "_verify", "_verify_estimator_census_1680.py")


def patch_readmes(old, new):
    patch(R1, old, new)
    patch(R2, old, new)
    return commit(WORK, ["README.mbt.md",
                         os.path.join("moonbit_doubleML", "README.mbt.md")],
                  "dry-run: the README's claim moved")


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
    # -- 1. the universal learner promise returns ------------------------------
    ("the README promises every estimator takes the four",
     lambda: patch_readmes(
         "**Learner injection via `LearnerDispatch`** -- the learner arguments are\n"
         "`LearnerDispatch` optionals, and **the set differs by estimator**, so there is\n"
         "no single argument to pass:",
         "**Learner injection via `LearnerDispatch`** -- every estimator's\n"
         "`new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed\n"
         "optionals. Default is `LearnerDispatch::linear_regression()` (OLS).\n"
         "Built-in learners:\n\n"
         "| learner arguments | estimators |\n"
         "|---|---|\n"
         "| none | `DoubleMLLPQ`, `DoubleMLPolicyTree` |")),

    # -- 2. the learner table names the wrong estimator ------------------------
    ("the learner table names the wrong estimator",
     lambda: patch_readmes(
         "`DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection`, `DoubleMLDIDMulti`, `DoubleMLIRM`, `DoubleMLLPLR` |",
         "`DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection`, `DoubleMLDIDMulti`, `DoubleMLIRM`, `DoubleMLSSM` |")),

    # -- 3. the stated number of argument sets is wrong ------------------------
    ("the README states the wrong number of argument sets",
     lambda: patch_readmes(
         "That is **8** argument sets over the **22** estimators.",
         "That is **9** argument sets over the **22** estimators.")),

    # -- 4. the stated number of migrated structs is wrong ---------------------
    ("the README states the wrong number of migrated structs",
     lambda: patch_readmes(
         "except `ml_m` on the seven\nstructs migrated to a classifier, named below.",
         "except `ml_m` on the eight\nstructs migrated to a classifier, named below.")),

    # -- 5. the migration paragraph drops an estimator -------------------------
    ("the migration paragraph drops an estimator",
     lambda: patch_readmes(
         "**`DoubleMLPQ` / `DoubleMLQTE` in\nv0.139.0** and **`DoubleMLLPLR` in v0.163.3**:",
         "**`DoubleMLPQ` in\nv0.139.0** and **`DoubleMLLPLR` in v0.163.3**:")),

    # -- 6. the OLS paragraph drops an estimator --------------------------------
    ("the OLS paragraph drops an estimator",
     lambda: patch_readmes(
         "`DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`,\n"
         "`DoubleMLDIDCrossSection`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,\n"
         "`DoubleMLDIDMulti`, `DoubleMLIIVM`.",
         "`DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`,\n"
         "`DoubleMLDIDCrossSection`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,\n"
         "`DoubleMLDIDMulti`.")),

    # -- 7. the DID data-type claim returns -----------------------------------
    ("the README says each DID variant takes its own data type again",
     lambda: patch_readmes(
         "and the DID variants take\nfour data types, not one each: `DoubleMLDIDData` for `DoubleMLDID`,",
         "and each DID variant takes\nits own data type. `DoubleMLDIDData` for `DoubleMLDID`,")),

    # -- 8. the DID sentence puts the wrong estimator on a data type -----------
    ("the DID sentence puts the wrong estimator on a data type",
     lambda: patch_readmes(
         "`DoubleMLDIDCS`, `DoubleMLDIDCSBinary` AND `DoubleMLDIDMulti`, and",
         "`DoubleMLDIDCS`, `DoubleMLDIDCSBinary` AND `DoubleMLDID`, and")),

    # -- 9. the README stops naming `ml_pi` ------------------------------------
    # Both places: the table's row and the sentence.  Removing it from the
    # sentence alone would not do -- the table names it too, so the
    # "the README names `ml_pi`" check would still pass.
    ("the README stops naming `ml_pi`",
     lambda: (patch_readmes(
         "| `ml_g` / `ml_m` / `ml_pi` | `DoubleMLSSM` |",
         "| `ml_g` / `ml_m` | `DoubleMLSSM` |"),
              patch_readmes(
                  "`ml_r` is\n"
                  "`DoubleMLIIVM`'s instrument propensity (at `fit()` it reuses the\n"
                  "constructor's choice) and `ml_pi` is `DoubleMLSSM`'s selection propensity\n"
                  "(at `fit()` it reuses the `ml_m` choice). ",
                  "`ml_r` is\n"
                  "`DoubleMLIIVM`'s instrument propensity (at `fit()` it reuses the\n"
                  "constructor's choice) and the selection propensity is `DoubleMLSSM`'s\n"
                  "own. "))),

    # -- 10. the Status row's version literal goes stale -----------------------
    ("the Status row's 'Introduced' literal goes stale again",
     lambda: patch_readmes(
         "Introduced v0.79.0 (on `DoubleMLIRM` and `DoubleMLPLR`), extended to **19 / 22** by v0.100.0 |",
         "Introduced v0.89.0 (on `DoubleMLIRM` and `DoubleMLPLR`), extended to **19 / 22** by v0.100.0 |")),

    # -- 11. the Status row stops disclosing the `hac_se` surface --------------
    ("the Status row stops disclosing the `hac_se` surface",
     lambda: patch_readmes(
         "heteroskedasticity-robust `hac_se` under their own name",
         "heteroskedasticity-robust `hacs_e` under their own name")),

    # -- 12. the Status row's 'expose none' list is wrong ----------------------
    ("the Status row's 'expose none' list names the wrong estimator",
     lambda: patch_readmes(
         "**3** expose none of that API (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`)",
         "**3** expose none of that API (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLPLR`)")),

    # -- 13. a tracked verifier hardcodes an absolute path ---------------------
    # A verifier that is NOT one of the three under test: a verifier that
    # points at the original tree stops seeing the clone's broken README,
    # so breaking one of the three would MASK the failures the earlier
    # mechanisms produced -- which is the whole point of this defect.
    ("a tracked verifier hardcodes an absolute path",
     lambda: (patch(LAYOUT,
                    'ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))',
                    'ROOT = r"D:\\src\\MiniMax\\Projects\\DoubleMachineLearning\\moonbit_doubleML"'),
              commit(WORK, [os.path.join("_verify", "_verify_layout_1680.py")],
                     "dry-run: a verifier hardcoded an absolute path"))),

    # -- 14. a tracked verifier's root stops reaching the repository root ------
    # A SUBDIRECTORY, not an outside path: it stays inside the repository, so
    # C1 and "points inside this repository" are unaffected, and the check
    # that fires is "reaches the repository root" -- a verifier anchored at
    # `_verify/` looks for the README one level too low.
    ("a tracked verifier's root stops reaching the repository root",
     lambda: (patch(OPTABLE,
                    'ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))',
                    'ROOT = os.path.dirname(os.path.abspath(__file__))'),
              commit(WORK, [os.path.join("_verify", "_verify_op_table_1640.py")],
                     "dry-run: a verifier's root stopped reaching the repository root"))),

    # -- 15. a tracked verifier reads a file git does not track ----------------
    ("a tracked verifier reads a file git does not track",
     lambda: (write(os.path.join(WORK, "_verify", "_r37_untracked_input.json"),
                    "{}\n"),
              patch(CENSUS,
                    'readme = io.open(README, encoding="utf-8").read()',
                    'readme = io.open(README, encoding="utf-8").read()\n'
                    '_untracked = io.open(os.path.join(ROOT, "_verify",\n'
                    '                                     "_r37_untracked_input.json"),\n'
                    '                      encoding="utf-8").read()'),
              commit(WORK, [os.path.join("_verify", "_verify_estimator_census_1680.py")],
                     "dry-run: a verifier read an untracked file"))),

    # -- 16. a downloaded-tree verifier loses its SKIP path --------------------
    ("a verifier over a downloaded tree loses its SKIP path",
     lambda: (patch(SHIPPED, "def skip(label, reason):", "def skipped(label, reason):"),
              patch(SHIPPED, 'print("  SKIP  %-64s %s" % (label, reason))',
                    'print("  skipped  %-64s %s" % (label, reason))'),
              patch(SHIPPED, "    skip(\"upstream sdist never says 'prescriptive'\",",
                    "    skipped(\"upstream sdist never says 'prescriptive'\","),
              patch(SHIPPED, "        skip(\"upstream sdist still declares the score string %r\" % s,",
                    "        skipped(\"upstream sdist still declares the score string %r\" % s,"),
              commit(WORK, [os.path.join("_verify", "_verify_shipped_docs_1643.py")],
                     "dry-run: a downloaded-tree verifier lost its SKIP path"))),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    grew = n > prev
    print("  %2d. %-58s failures %d -> %d  %s"
          % (i, desc[:58], prev, n, "GROW" if grew else "*** FLAT ***"))
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n

# the counter must agree with the verifiers' own summaries
rc, out, n = verify(WORK)
print()
print("=== the counter and the verifiers' own summaries ===")
print("  the driver counted %d failures" % n)
summaries = re.findall(r"checks failed: (\d+)", out)
print("  the verifiers say  %s"
      % (", ".join(summaries) if summaries else "NONE"))
if not summaries or sum(int(s) for s in summaries) != n:
    print("!! the counter and the summary disagree -- ABORT")
    sys.exit(1)
if rc == 0:
    print("!! the broken tree still exits 0 -- ABORT")
    sys.exit(1)

# --- the published failure count, witnessed -----------------------------------
_entry = None
for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                     read(CHANGELOG), re.M | re.S):
    if "_dryrun_round37_1650.py" in m.group(2):
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

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
