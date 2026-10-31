"""Round 76 dry-run: prove that this round's NEW checks bite.

WHAT THIS IS A WITNESS FOR
===========================
Round 76 added five checks that can fail silently, and a check that cannot
fail protects nothing:

  1  `_verify/_verify_upstream_version_claims_1680.py` -- the upstream-version
     claims in the two records the README NAMES.  Two of them still said
     0.11.3 in live claims after the upstream moved to 0.11.4, and nothing
     read a record's prose;
  2  `_verify/_verify_validator_references_1680.py` -- where each of the 24
     validators' SECOND IMPLEMENTATION comes from.  The README claimed all 24
     were written in this repository; two take their reference from a
     third-party library;
  3  `_verify/_verify_mutation_verdict_1680.py` -- the `mutation` check's
     verdict.  The README says it kills three mutants on one kernel, the
     check is scope=full, no workflow runs it, and its verdict had no witness;
  4  `_verify/_verify_upstream_line_refs_1680.py` -- the UPSTREAM
     `file:line` pointers.  The house file:line verifier counts them and
     refuses to resolve them, and the records the README names are outside
     its scope altogether: 37 upstream pointers, none of them ever resolved;
  5  `_verify/_verify_record_readme_refs_1680.py` -- the claims a record
     makes ABOUT the README.  One record claimed to be the only `_verify/`
     record the README cites, at the README's lines 1162 and 1217 -- and the
     README is 896 lines long and cites two records.

And it REPAIRED a sixth, `_verify/_verify_hazard_table_1680.py`, whose rule
was a lazy `.*?` that let the four estimators it checked be read from an
EARLIER sentence: once this round re-wrapped a nearby paragraph, the check
read the four HAZARDOUS estimators as the four that kept their OLS default.
The README was right and the checker was wrong, and the repair is proved by
the check's own control arm -- so the driver proves it here too.

So the driver breaks each of them, one at a time, and requires the failure to
appear.

THE MECHANISMS
===============
Thirteen, and each one breaks a promise this round's tree now holds:

  1  the README's third-party sentence names only ONE of the two validators --
      the declaration no longer matches the derivation;
  2  the README's count says "Three" -- a count the code does not derive;
  3  a LIVE claim in a cited record names the old upstream version -- the
      records must go RED when the installed upstream is not the version they
      are anchored to;
  4  the mutation record's verdict is neutered (3 of 3 becomes 2 of 3) -- the
      README's "kills three mutants" stops being true;
  5  the reference verifier's own comparison is neutered -- ITS CONTROL ARM
      MUST NOTICE.  A control that cannot report a rule which has stopped
      biting is a rubber stamp;
  6  the version-claims verifier's own comparison is neutered -- the same;
  7  the mutation verifier's own comparison is neutered -- the same;
  8  an upstream pointer in a cited record is moved past the end of the
      upstream file -- the pointer must go RED;
  9  a record's claim about WHICH README line cites it is wrong -- the
      record must go RED;
 10  a record's claim about HOW MANY records the README cites is wrong --
      the record must go RED;
 11  the upstream-line-refs verifier's own comparison is neutered -- ITS
      CONTROL MUST NOTICE;
 12  the record-readme-refs verifier's own comparison is neutered -- ITS
      CONTROL MUST NOTICE;
 13  the README names the wrong four estimators as the ones that kept their
      OLS default -- the hazard table's rule must go RED.

EACH MECHANISM IS INDEPENDENT
==============================
The tree under test is restored before every mechanism, so each one is judged
against a green baseline rather than against the wreckage of the one before
it.  A cumulative driver can pass a mechanism whose failure count happened to
grow for someone else's reason.

The tree under test is a CLONE with the working tree's state copied in: the
clone is checked out from HEAD, so without the copy the tree under test would
be a mix of two releases -- this round's checks and the last round's
documents -- and the baseline would be red for a reason that has nothing to do
with the promise being broken.

Run: python _verify/_dryrun_round76_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r76")
DRIVER = "_verify/_dryrun_round76_1650.py"

DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

CLAIMS = "_verify/_verify_upstream_version_claims_1680.py"
REFS = "_verify/_verify_validator_references_1680.py"
MUTV = "_verify/_verify_mutation_verdict_1680.py"
LINEREFS = "_verify/_verify_upstream_line_refs_1680.py"
RECREFS = "_verify/_verify_record_readme_refs_1680.py"
HAZARD = "_verify/_verify_hazard_table_1680.py"
RECORD = "_verify/_mutation_verdict_1680.json"

VERIFIERS = [CLAIMS, REFS, MUTV, LINEREFS, RECREFS, HAZARD]

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
LPLR = os.path.join(WORK, "_verify", "LPLR_GATE_BLINDNESS_1680.md")
PROV = os.path.join(WORK, "_verify", "UPSTREAM_PROVENANCE.md")
MUTREC = os.path.join(WORK, "_verify", "_mutation_verdict_1680.json")
CLAIMS_SRC = os.path.join(WORK, CLAIMS.replace("/", os.sep))
REFS_SRC = os.path.join(WORK, REFS.replace("/", os.sep))
MUTV_SRC = os.path.join(WORK, MUTV.replace("/", os.sep))
LINEREFS_SRC = os.path.join(WORK, LINEREFS.replace("/", os.sep))
RECREFS_SRC = os.path.join(WORK, RECREFS.replace("/", os.sep))


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
    stands, and a literal here would be a literal that goes stale.
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


def failures(out):
    """The house's failure marker."""
    return out.count("*** FAIL ***")


def verify():
    """Run the three verifiers; return their outputs and their counts."""
    outs = {}
    counts = {}
    for rel in VERIFIERS:
        rc, out = run([sys.executable, os.path.join(WORK, rel.replace("/", os.sep))],
                      cwd=WORK)
        outs[rel] = out
        counts[rel] = failures(out)
    return outs, counts


def restore():
    """Put the tree under test back to the committed state."""
    rc, out = run(["git", "-C", WORK, "checkout", "--", "."], cwd=WORK)
    if rc != 0:
        print(out)
        raise SystemExit("git checkout failed")


# ------------------------------------------------------------------ the clone
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

rc, out = run(["git", "diff", "--name-only", "HEAD"], cwd=REPO)
CHANGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
COPY_IN = []
for rel in list(VERIFIERS) + [RECORD, DRIVER] + DOCUMENTS + CHANGED:
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
rc, out = run(["git", "-C", WORK, "add", "--"] + COPY_IN, cwd=WORK)
if rc != 0:
    print(out)
    raise SystemExit("git add failed")
rc, out = run(["git", "-C", WORK, "commit", "-m",
               "dry-run: the tree under test carries this round's state"], cwd=WORK)
if rc != 0:
    print(out)
    raise SystemExit("git commit failed")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
outs, counts = verify()
for rel in VERIFIERS:
    print("  %-46s failures=%d" % (rel, counts[rel]))
if sum(counts.values()) != 0:
    for rel in VERIFIERS:
        print("---- %s ----" % rel)
        print(outs[rel][-3000:])
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# -------------------------------------------------------------- the mechanisms
#
# The `sub_once` calls are made DIRECTLY, not through a helper: the teeth
# verifier resolves a driver's anchors by walking its module-level calls, and
# a call hidden inside a helper's body is a call it cannot see.
#
# 1  the README names only ONE of the two third-party references
M1_OLD = r"`validate_pava_with_python\.py` against scikit-learn's `isotonic_regression`,"
M1_NEW = r"another script against scikit-learn's `isotonic_regression`,"

# 2  the README's count says THREE
M2_OLD = r"Two of them take that implementation from a third-party library"
M2_NEW = r"Three of them take that implementation from a third-party library"

# 3  a LIVE claim in a cited record names the old upstream version
M3_OLD = r"`set_sample_splitting` raises, and 0\.11\.4 ships no public setter for the"
M3_NEW = r"`set_sample_splitting` raises, and 0.11.3 ships no public setter for the"

# 4  the mutation record's verdict is neutered
M4_OLD = r'"killed": 3'
M4_NEW = r'"killed": 2'

# 5  the reference verifier's own comparison is neutered
M5_OLD = r"    problems = \[\]\n    derived = derive\(corpus\)"
M5_NEW = "    problems = []\n    return problems\n    derived = derive(corpus)"

# 6  the version-claims verifier's own comparison is neutered
M6_OLD = r"    problems = \[\]\n    if anchor is None:"
M6_NEW = "    problems = []\n    return problems\n    if anchor is None:"

# 7  the mutation verifier's own comparison is neutered
M7_OLD = r"    problems = \[\]\n    target, muts, targets = parse_mutation_check\(checks_src\)"
M7_NEW = ("    problems = []\n    return problems, None, []\n"
          "    target, muts, targets = parse_mutation_check(checks_src)")

# 8  an upstream pointer in a cited record is moved past the end of the file
M8_OLD = r"`plm/lplr\.py:326` sets `self\._coef_start_val = np\.average\(beta\)` and hands it"
M8_NEW = r"`plm/lplr.py:3260` sets `self._coef_start_val = np.average(beta)` and hands it"

# 9  a record's claim about WHICH README line cites it is wrong
M9_OLD = r"cites \(at its line 563;"
M9_NEW = r"cites (at its line 560;"

# 10  a record's claim about HOW MANY records the README cites is wrong
M10_OLD = r"This is \*\*one of the two\*\* `_verify/`"
M10_NEW = r"This is **the only** `_verify/`"

# 11  the upstream-line-refs verifier's own comparison is neutered
M11_OLD = r"    problems = \[\]\n    # the file upstream must HAVE"
M11_NEW = "    problems = []\n    return problems\n    # the file upstream must HAVE"

# 12  the record-readme-refs verifier's own comparison is neutered
M12_OLD = (r'    problems = \[\]\n    for n in sorted\(claimed\):\n'
           r'        if n not in actual:\n'
           r'            problems\.append\("claims README line %d, where the README cites no record" % n\)\n'
           r'    return problems')
M12_NEW = (r'    problems = []\n    return problems\n    for n in sorted(claimed):\n'
           r'        if n not in actual:\n'
           r'            problems.append("claims README line %d, where the README cites no record" % n)\n'
           r'    return problems')

# 13  the README names the wrong four estimators as the ones that kept their
#     OLS default
M13_OLD = r"`DoubleMLDIDBinary`, `DoubleMLCVAR`, `DoubleMLIIVM` and `DoubleMLPLR`"
M13_NEW = r"`DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and `DoubleMLSSM`"


def mechanism_1():
    sub_once(README, M1_OLD, M1_NEW)
    sub_once(SHIPPED, M1_OLD, M1_NEW)


def mechanism_2():
    sub_once(README, M2_OLD, M2_NEW)
    sub_once(SHIPPED, M2_OLD, M2_NEW)


def mechanism_3():
    sub_once(LPLR, M3_OLD, M3_NEW)


def mechanism_4():
    sub_once(MUTREC, M4_OLD, M4_NEW)


def mechanism_5():
    sub_once(REFS_SRC, M5_OLD, M5_NEW)


def mechanism_6():
    sub_once(CLAIMS_SRC, M6_OLD, M6_NEW)


def mechanism_7():
    sub_once(MUTV_SRC, M7_OLD, M7_NEW)


def mechanism_8():
    sub_once(LPLR, M8_OLD, M8_NEW)


def mechanism_9():
    sub_once(LPLR, M9_OLD, M9_NEW)


def mechanism_10():
    sub_once(LPLR, M10_OLD, M10_NEW)


def mechanism_11():
    sub_once(LINEREFS_SRC, M11_OLD, M11_NEW)


def mechanism_12():
    sub_once(RECREFS_SRC, M12_OLD, M12_NEW)


def mechanism_13():
    sub_once(README, M13_OLD, M13_NEW)
    sub_once(SHIPPED, M13_OLD, M13_NEW)


MECHANISMS = [
    ("the README names only ONE of the two third-party references",
     mechanism_1, REFS),
    ("the README's third-party count says THREE", mechanism_2, REFS),
    ("a live claim in a cited record names the old upstream version",
     mechanism_3, CLAIMS),
    ("the mutation record's verdict is neutered", mechanism_4, MUTV),
    ("the reference verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     mechanism_5, REFS),
    ("the version-claims verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     mechanism_6, CLAIMS),
    ("the mutation verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     mechanism_7, MUTV),
    ("an upstream pointer in a cited record is moved past the end of the file",
     mechanism_8, LINEREFS),
    ("a record's claim about WHICH README line cites it is wrong",
     mechanism_9, RECREFS),
    ("a record's claim about HOW MANY records the README cites is wrong",
     mechanism_10, RECREFS),
    ("the upstream-line-refs verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     mechanism_11, LINEREFS),
    ("the record-readme-refs verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     mechanism_12, RECREFS),
    ("the README names the wrong four estimators as the ones that kept their OLS default",
     mechanism_13, HAZARD),
]

print()
print("=== the mechanisms, one at a time, each from a green tree ===")
ok = True
for i, (desc, apply_it, rel) in enumerate(MECHANISMS, 1):
    restore()
    apply_it()
    outs, counts = verify()
    print()
    print("  %d. %s" % (i, desc))
    for r in VERIFIERS:
        print("       %-46s failures=%d" % (r, counts[r]))
    if counts[rel] <= 0:
        print("---- %s ----" % rel)
        print(outs[rel][-3000:])
        print("!! the check did NOT fail -- this mechanism proves nothing")
        ok = False
    else:
        for l in outs[rel].splitlines():
            if "*** FAIL ***" in l:
                print("       %s" % l.strip()[:150])

print()
print("=" * 78)
print("VERDICT %s -- every mechanism made the check it breaks fail"
      % ("PASS" if ok else "FAIL"))
print("=" * 78)

# The capture is the cited raw log of the run, and it is TRACKED by
# convention: the round-59 driver publishes one, and the documents that
# describe the dry-run cite it.
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r76_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 76 dry-run: this round's new checks, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline 0 failing checks; every mechanism made the check it "
             "breaks fail\n")
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn, rel) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s -- %s\n" % (i, name, rel))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
