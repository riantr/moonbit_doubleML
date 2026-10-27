#!/usr/bin/env python3
"""Round 56 dry-run: break the TUTORIAL pages' numbers twenty-six ways, and
watch the verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_doc_numbers_1650.py` holds the numbers the six TUTORIAL
pages and the api_server README state -- the ones a mutation probe found
that NOTHING in the repository was holding -- and a verifier that only ever
prints "ok" is indistinguishable from one that never fires.

So this driver copies the tree into a scratch clone, breaks each promise one
way at a time, and requires the failure count to GROW at every step.  A
contract nobody can break is a contract nobody is really checking.

THE MECHANISMS
===============
One per claim the round-56 probe found unheld.  Each changes ONE number in
ONE page, and each must trip a check that no earlier mechanism has tripped:
a mechanism that trips an already-tripped check is FLAT, and a flat step
means the mechanism is not being measured.

  1  the introduction's estimator total
  2  the introduction's dead-dependency count
  3  the introduction's dead-dependency reference count
  4  the introduction's Python-validator count
  5  the introduction's LearnerDispatch variant count
  6  the introduction's regressor count
  7  the introduction's classifier count
  8  the introduction's propensity-learner set
  9  the introduction's DGP module count
 10  the introduction's `--deny-warn` verdict
 11  the installation page's backend count
 12  the quick-start page's backend count
 13  the estimators page's headline count
 14  the estimators page's `score` slot split
 15  the estimators page's `quantile` default
 16  the estimators page's `quantiles` default
 17  the estimators page's `depth` default
 18  the estimators page's DIDCSBinary score vocabulary
 19  the DGP page's `theta_get()` count
 20  the DGP page's `x_get()` / `y_get()` / `d_get()` count
 21  the DGP page's recovery-test count
 22  the DGP page's IRM tolerance
 23  the cross-check page's hand-rolled count
 24  the cross-check page's wheel count
 25  the cross-check page's coverage split
 26  the api_server's body cap
 27  a TRACKED file carrying a version literal that is not a bump site --
     which is the round-9 verifier's own contract, re-proved after its
     scope was changed from the filesystem to the tracked tree

WHAT IS COUNTED
===============
A failing CHECK.  The marker `*** FAIL ***` goes on each failing check line;
a line whose WHOLE content is the marker is a section HEADER some verifiers
print after their counter, and a header is not a check, so it is excluded.
The count is by CONTAINMENT, not by prefix or by suffix.

THE COUNT MUST NOT DEPEND ON THE CLONE
=======================================
The clone carries the WORKING TREE's state -- `git diff --name-only HEAD`
plus this round's new files -- because the tree under test is the tree the
fixes are in.  A clone built from the INDEX instead would be internally
inconsistent, and the count would measure the wrong tree.

Run: python _verify/_dryrun_round56_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r56")
DRIVER = "_verify/_dryrun_round56_1650.py"
VERIFIERS = [
    "_verify/_verify_doc_numbers_1650.py",
    "_verify/_verify_round9_docs_1644.py",
]
DOCUMENTS = [
    "doc/001_introduction/readme.mbt.md",
    "doc/002_installation/readme.mbt.md",
    "doc/003_quick_start/readme.mbt.md",
    "doc/004_estimators/readme.mbt.md",
    "doc/005_dgps/readme.mbt.md",
    "doc/006_python_check/readme.mbt.md",
    "examples/api_server/README.md",
]
ADDED = [
    "_verify/_dryrun_round56_1650.py",
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

    A rule that read only one shape would under-count the others, so all
    four are read: "N checks, M failed", "SUMMARY: N checks, M failures",
    "checks failed: M", and "checks run: N, checks failed: M".
    """
    found = []
    for pat, g in (
            (r"^\s*(\d+) checks, (\d+) failed\s*$", 2),
            (r"SUMMARY:\s*(\d+) checks, (\d+) failures", 2),
            (r"checks failed:\s*(\d+)", 1),
            (r"checks run:\s*(\d+),\s*checks failed:\s*(\d+)", 2),
    ):
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

# --- copy the WORKING TREE's state in ----------------------------------------
rc, out = run(["git", "diff", "--name-only", "HEAD"])
STAGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
COPY_IN = []
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + ADDED + STAGED:
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

D001 = os.path.join(WORK, "doc", "001_introduction", "readme.mbt.md")
D002 = os.path.join(WORK, "doc", "002_installation", "readme.mbt.md")
D003 = os.path.join(WORK, "doc", "003_quick_start", "readme.mbt.md")
D004 = os.path.join(WORK, "doc", "004_estimators", "readme.mbt.md")
D005 = os.path.join(WORK, "doc", "005_dgps", "readme.mbt.md")
D006 = os.path.join(WORK, "doc", "006_python_check", "readme.mbt.md")
API = os.path.join(WORK, "examples", "api_server", "README.md")
MOD = os.path.join(WORK, "moonbit_doubleML", "moon.mod")

# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """The introduction's estimator total."""
    sub(D001, r"for \d+ in total", "for 23 in total")


def m2():
    """The introduction's dead-dependency count."""
    sub(D001, r"does declare \w+ entries", "does declare three entries")


def m3():
    """The introduction's dead-dependency reference count."""
    sub(D001, r"measured: 0\s+references each", "measured: 1\n  references each")


def m4():
    """The introduction's Python-validator count."""
    sub(D001, r"cross-checkers \(\d+ scripts", "cross-checkers (25 scripts")


def m5():
    """The introduction's LearnerDispatch variant count."""
    sub(D001, r"ships \d+\s+`LearnerDispatch` variants",
        "ships 12 `LearnerDispatch` variants")


def m6():
    """The introduction's regressor count."""
    sub(D001, r"variants: \d+ regressors", "variants: 9 regressors")


def m7():
    """The introduction's classifier count."""
    sub(D001, r"and \d+ classifiers", "and 4 classifiers")


def m8():
    """The introduction's propensity-learner set."""
    sub(D001, r"logistic classifier for the \w+ estimators",
        "logistic classifier for the seven estimators")


def m9():
    """The introduction's DGP module count."""
    sub(D001, r"across \d+ `dgp_\*\.mbt` modules", "across 18 `dgp_*.mbt` modules")


def m10():
    """The introduction's `--deny-warn` verdict."""
    sub(D001, r"\*\*\d+ errors?\*\* under", "**1 error** under")


def m11():
    """The installation page's backend count."""
    sub(D002, r"all \d+ supported", "all 5 supported")


def m12():
    """The quick-start page's backend count."""
    sub(D003, r"runs on all \d+ supported", "runs on all 5 supported")


def m13():
    """The estimators page's headline count."""
    sub(D004, r"\d+ estimators, all reachable", "23 estimators, all reachable")


def m14():
    """The estimators page's `score` slot split."""
    sub(D004, r"the other \w+ take it on `new\(\)`",
        "the other seven take it on `new()`")


def m15():
    """The estimators page's `quantile` default."""
    sub(D004, r"extra `quantile` arg \(a scalar, default\s+`([0-9.]+)`\)",
        "extra `quantile` arg (a scalar, default `0.7`)")


def m16():
    """The estimators page's `quantiles` default."""
    sub(D004, r"default `\[[0-9.]+\]`", "default `[0.7]`")


def m17():
    """The estimators page's `depth` default."""
    sub(D004, r"extra `depth` arg \(default \d+\)", "extra `depth` arg (default 2)")


def m18():
    """The estimators page's DIDCSBinary score vocabulary."""
    sub(D004, r"`DoubleMLDIDCSBinary` accepts only `observational`",
        "`DoubleMLDIDCSBinary` accepts `observational` and `experimental`")


def m19():
    """The DGP page's `theta_get()` count."""
    sub(D005, r"All \d+ return a struct", "All 19 return a struct")


def m20():
    """The DGP page's `x_get()` / `y_get()` / `d_get()` count."""
    sub(D005, r"and \d+\s+of the \d+ also expose", "and 16 of the 18 also expose")


def m21():
    """The DGP page's recovery-test count."""
    sub(D005, r"holds \*\*\w+\*\* end-to-end recovery tests",
        "holds **four** end-to-end recovery tests")


def m22():
    """The DGP page's IRM tolerance."""
    sub(D005, r"IRM validator uses `0\.\d+`", "IRM validator uses `0.2`")


def m23():
    """The cross-check page's hand-rolled count."""
    sub(D006, r"hand-rolled here in \*\*\d+\*\*", "hand-rolled here in **14**")


def m24():
    """The cross-check page's wheel count."""
    sub(D006, r"upstream's wheel in \*\*\d+\*\*", "upstream's wheel in **8**")


def m25():
    """The cross-check page's coverage split."""
    sub(D006, r"\*\*\d+\*\* are checked \*only\* by the\s+`validate_\*` family",
        "**4** are checked *only* by the `validate_*` family")


def m26():
    """The api_server's body cap."""
    sub(API, r"body cap is \d+ MiB", "body cap is 32 MiB")


def m27():
    """A TRACKED file carrying a version literal that is not a bump site.

    The round-9 verifier's scope was changed from the FILESYSTEM to the
    TRACKED tree, because a scratch clone of the tree sitting at the
    repository root used to make it report a dozen version sites that no
    reader could open.  This mechanism proves the check still has teeth:
    a TRACKED file that is not a bump site must still be reported.
    """
    ver = re.search(r'version\s*=\s*"([0-9.]+)"', read(MOD)).group(1)
    # The file goes at the REPOSITORY ROOT, not under `_verify/`: the
    # round-9 check skips that directory, so a file there would prove
    # nothing.  This is a scratch clone, so a root-level file is harmless.
    rel = "_r56_unbumped.md"
    p = os.path.join(WORK, rel)
    write(p, "# dry-run: a version literal with no bump site\n\n"
             "riantr/moonbit_doubleML@%s\n" % ver)
    commit(WORK, [rel], "dry-run: a version literal with no bump site")


MECHANISMS = [
    ("the introduction's estimator total", m1),
    ("the introduction's dead-dependency count", m2),
    ("the introduction's dead-dependency reference count", m3),
    ("the introduction's Python-validator count", m4),
    ("the introduction's LearnerDispatch variant count", m5),
    ("the introduction's regressor count", m6),
    ("the introduction's classifier count", m7),
    ("the introduction's propensity-learner set", m8),
    ("the introduction's DGP module count", m9),
    ("the introduction's --deny-warn verdict", m10),
    ("the installation page's backend count", m11),
    ("the quick-start page's backend count", m12),
    ("the estimators page's headline count", m13),
    ("the estimators page's score slot split", m14),
    ("the estimators page's quantile default", m15),
    ("the estimators page's quantiles default", m16),
    ("the estimators page's depth default", m17),
    ("the estimators page's DIDCSBinary score vocabulary", m18),
    ("the DGP page's theta_get() count", m19),
    ("the DGP page's x_get() / y_get() / d_get() count", m20),
    ("the DGP page's recovery-test count", m21),
    ("the DGP page's IRM tolerance", m22),
    ("the cross-check page's hand-rolled count", m23),
    ("the cross-check page's wheel count", m24),
    ("the cross-check page's coverage split", m25),
    ("the api_server's body cap", m26),
    ("a tracked version literal with no bump site", m27),
]

# ------------------------------------------------------------------- the run
rc, out, total, by = verify(WORK)
print()
print("=== the baseline (nothing broken) ===")
print("  %d failing check(s)" % total)
for s in summaries_of(out):
    print("    the verifiers' own summary: %s checks, %s failed" % s)
for i, lines in enumerate(by):
    for l in lines:
        print("    %s: %s" % (os.path.basename(VERIFIERS[i]), l))
base = total
if base != 0:
    print("!! the baseline is not clean -- the verifiers fail before anything "
          "is broken")
    sys.exit(1)

print()
print("=== the mechanisms ===")
prev = base
ok = True
for i, (name, fn) in enumerate(MECHANISMS, 1):
    try:
        fn()
    except SystemExit as e:
        print("  %2d. %-52s !! %s" % (i, name, e))
        ok = False
        break
    rc, out, total, by = verify(WORK)
    grew = total > prev
    ok = ok and grew
    print("  %2d. %-52s %d -> %d  %s"
          % (i, name, prev, total, "GROW" if grew else "*** FLAT ***"))
    for j, lines in enumerate(by):
        for l in lines:
            print("        %s: %s" % (os.path.basename(VERIFIERS[j]), l[:110]))
    prev = total

print()
print("=" * 78)
if ok and prev > base:
    print("VERDICT PASS -- %d mechanisms, each one grew the failure count "
          "(%d -> %d)" % (len(MECHANISMS), base, prev))
else:
    print("VERDICT FAIL -- the mechanisms did not each grow the count")
print("=" * 78)

capture = os.path.join(REPO, "_verify", "_dryrun1650", "r56_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 56 dry-run: the tutorial pages' numbers, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline %d failing checks; final %d\n" % (base, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok and prev > base else "FAIL"))
    for i, (name, fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
print("capture written: %s" % capture)
sys.exit(0 if (ok and prev > base) else 1)
