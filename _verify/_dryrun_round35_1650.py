"""Dry-run the round-35 verifiers against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 35 closed two blind spots in the README's own checking:

  * `_verify/_verify_api_snippets_1680.py` only matched snippets written with
    the `@moonbit_doubleML.` prefix -- FOUR of the TEN constructors the README
    states.  That is how `DoubleMLLPLR::new(data, alpha=1.5)` (a parameter
    that does not exist) survived until a reader found it by hand.
  * NOTHING checked the README's source citations.  The DID paragraph cited
    `did.mbt:708` for "the observational DID score", and line 708 is the
    EXPERIMENTAL branch.

THE MECHANISMS
===============
Each mechanism breaks ONE promise in the tree and the failure count must GROW
at every step.  Both verifiers read the WORKING TREE, so a mechanism that only
wrote a file would be seen -- but the breakage is committed anyway, so the
tree under test is exactly the tree that was measured.

  1. a constructor's positional argument is named differently from the source
     (the `x` / `features` defect round 35 fixed);
  2. a constructor states an argument that does not exist (`alpha=1.5`);
  3. a constructor states a default the source does not have;
  4. a citation points one line off, so the cited line does not carry the
     token the sentence claims;
  5. a citation names a configuration and points at the branch that
     configuration does NOT select;
  6. the constructor-call SET moves -- a call is added -- so it runs LAST,
     because it changes the size the checks above are stated against;
  7. the citation SET moves -- a citation is added -- so it runs LAST for the
     same reason.

NOTHING HERE CARRIES A VERSION LITERAL
======================================
The version is READ from the tree under test.  A literal here would be a
tracked file naming a current version, and the round-9 check requires every
such file to be a site the bump script covers.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The two
verifiers are copied in from the WORKING TREE and committed, so the tree under
test is the one that carries the checks being exercised.

Run: python _verify/_dryrun_round35_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r35_mut")
VERIFIERS = [
    "_verify/_verify_api_snippets_1680.py",
    "_verify/_verify_citations_1650.py",
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
    """Stage the named paths and commit them IN THE CLONE."""
    rc, out = run(["git", "-C", work, "add", "--"] + paths, cwd=work)
    if rc != 0:
        raise SystemExit("!! git add failed: %s" % out.strip()[:300])
    rc, out = run(["git", "-C", work, "-c", "user.name=dry-run",
                   "-c", "user.email=dry-run@example.invalid",
                   "commit", "-m", message], cwd=work)
    if rc != 0:
        raise SystemExit("!! git commit failed: %s" % out.strip()[:300])
    return out.strip().splitlines()[0] if out.strip() else ""


def verify(work):
    """Run both verifiers in `work`; return (exit code, output, failure count).

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
# The clone carries the COMMITTED tree; the README under test is the one in
# the working tree, because that is the tree the round's fixes live in.
COPY_IN = list(VERIFIERS) + ["README.mbt.md", os.path.join("moonbit_doubleML",
                                                           "README.mbt.md")]
for rel in VERIFIERS:
    shutil.copy2(os.path.join(REPO, rel.replace("/", os.sep)),
                 os.path.join(WORK, rel.replace("/", os.sep)))
for rel in ("README.mbt.md", os.path.join("moonbit_doubleML", "README.mbt.md")):
    shutil.copy2(os.path.join(REPO, rel),
                 os.path.join(WORK, rel))
# the CHANGELOG that publishes the failure count has to be IN the tree under
# test, or the published-count check is vacuous
shutil.copy2(os.path.join(REPO, "CHANGELOG.md"),
             os.path.join(WORK, "CHANGELOG.md"))
COPY_IN.append("CHANGELOG.md")
print("  copied in %d files from the working tree:" % len(COPY_IN))
for rel in COPY_IN:
    print("    %s" % rel)
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checks")

README = os.path.join(WORK, "README.mbt.md")
CHANGELOG = os.path.join(WORK, "CHANGELOG.md")

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
    # -- 1. a positional argument is named differently -------------------------
    ("a constructor's positional argument is named differently",
     lambda: (patch(README,
                    "DoubleMLPolicyTree::new(features, orth_signal",
                    "DoubleMLPolicyTree::new(x, orth_signal"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a positional argument renamed"))),

    # -- 2. a constructor states an argument that does not exist ---------------
    ("a constructor states an argument that does not exist",
     lambda: (patch(README,
                    "DoubleMLLPLR::new(data).fit()",
                    "DoubleMLLPLR::new(data, alpha=1.5).fit()"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: an argument that does not exist"))),

    # -- 3. a constructor states a default the source does not have ------------
    ("a constructor states a default the source does not have",
     lambda: (patch(README,
                    "DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141)",
                    "DoubleMLPLR::new(data, n_folds=3, n_rep=1, seed=3141)"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a default the source does not have"))),

    # -- 4. a citation points one line off ------------------------------------
    ("a citation points one line off the token it claims",
     lambda: (patch(README, "`irm.mbt:430`", "`irm.mbt:429`"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a citation one line off"))),

    # -- 5. a citation names a configuration and points at the wrong branch ---
    ("a citation names a configuration and points at the wrong branch",
     lambda: (patch(README, "`did.mbt:97`", "`did.mbt:708`"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a citation in the wrong branch"))),

    # -- 6. the constructor-call SET moves: LAST on purpose ---------------------
    ("a constructor call is added",
     lambda: (patch(README,
                    "let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]",
                    "let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]\n"
                    "let data2 = @moonbit_doubleML.DoubleMLData::new(x, y, d)"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a constructor call is added"))),

    # -- 7. the citation SET moves: LAST on purpose ----------------------------
    ("a citation is added",
     lambda: (patch(README,
                    "direction (`ssm.mbt:73-74`):",
                    "direction (`ssm.mbt:73-74`, `ssm.mbt:73-74`):"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a citation is added"))),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    grew = n > prev
    print("  %d. %-58s failures %d -> %d  %s"
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
summaries = re.findall(r"(\d+) checks, (\d+) failed", out)
print("  the verifiers say   %s"
      % (", ".join("%s checks, %s failed" % s for s in summaries) if summaries else "NONE"))
if not summaries or sum(int(s[1]) for s in summaries) != n:
    print("!! the counter and the summaries disagree -- ABORT")
    sys.exit(1)
if rc == 0:
    print("!! the broken tree still exits 0 -- ABORT")
    sys.exit(1)

# --- the published failure count, witnessed -----------------------------------
_entry = None
for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                     read(CHANGELOG), re.M | re.S):
    if "_dryrun_round35_1650.py" in m.group(2):
        _entry = m.group(2)
        break
_found = re.findall(r"requires the failure count to GROW at every step:\s*"
                    r"\*\*(\d+)\*\*\s+failures at the", _entry or "")
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
print("OK: every mechanism contributed, and the counter agrees with the summaries")
