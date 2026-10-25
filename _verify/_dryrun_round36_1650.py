"""Dry-run the round-36 verifier against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 36 gave the README's NEGATIVE claims a check.  The "Not covered, so not
claimed" section is the only part of the document that says what the project
does NOT do, and until this round nothing verified any of it: the section was
trusted, and the whole point of a section about what is not covered is that it
must not be trusted.

A negative claim rots in BOTH directions.  A limit that is no longer a limit
is a false claim, and so is a limit that is EXAGGERATED -- the README used to
call one fuzz invocation "one case, not a fuzz" when one invocation is 11
surfaces at 300 trials each.

THE MECHANISMS
===============
Each mechanism breaks ONE promise in the tree and the failure count must GROW
at every step.  The verifier reads the WORKING TREE, so a mechanism that only
wrote a file would be seen -- but the breakage is committed anyway, so the
tree under test is exactly the tree that was measured.

  1. the README's fuzz paragraph overstates the limit again;
  2. the harness's trial count changes under the README;
  3. the QA check's evidence reverts to denying that the harness fuzzes;
  4. the `dependencies` check stops reporting the dead dependencies;
  5. the README's quoted `dependencies` message drifts from the check's;
  6. a CI workflow starts running the `mutation` check;
  7. the `coverage` check stops calling itself a proxy, and the README follows;
  8. a crash-regression corpus appears under `examples/fuzz/`;
  9. the mutation battery's target moves to a file that does not exist;
 10. the fuzz harness takes a seed parameter, so the argument is no longer
     ignored.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round CHANGED are copied in from the WORKING TREE and committed, so
the tree under test is the one that carries the checks being exercised -- the
README under test, the CHANGELOG that publishes the failure count, the QA
registry's `checks.py`, and the harness itself.

Run: python _verify/_dryrun_round36_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r36_neg")
VERIFIERS = [
    "_verify/_verify_not_covered_1650.py",
]
# every file a mechanism below touches, and that this round changed
TOUCHED = [
    "README.mbt.md",
    os.path.join("moonbit_doubleML", "README.mbt.md"),
    "CHANGELOG.md",
    os.path.join(".github", "scripts", "qa_loop", "checks.py"),
    os.path.join(".github", "workflows", "check.yml"),
    os.path.join("examples", "fuzz", "main.mbt"),
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
    not an error: the clone is cut at HEAD, so once the release commit exists
    the new files come with it.  The dry-run is then re-runnable, which
    matters -- a check that can only be run once cannot be re-checked.
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
    """Run the verifier in `work`; return (exit code, output, failure count).

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
COPY_IN = list(VERIFIERS) + [t for t in TOUCHED if t not in VERIFIERS]
for rel in COPY_IN:
    shutil.copy2(os.path.join(REPO, rel.replace("/", os.sep)),
                 os.path.join(WORK, rel.replace("/", os.sep)))
print("  copied in %d files from the working tree:" % len(COPY_IN))
for rel in COPY_IN:
    print("    %s" % rel)
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checks")

R1 = os.path.join(WORK, "README.mbt.md")
R2 = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
CHECKS = os.path.join(WORK, ".github", "scripts", "qa_loop", "checks.py")
WORKFLOW = os.path.join(WORK, ".github", "workflows", "check.yml")
FUZZ = os.path.join(WORK, "examples", "fuzz", "main.mbt")
CHANGELOG = os.path.join(WORK, "CHANGELOG.md")


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
    # -- 1. the README's fuzz paragraph overstates the limit -------------------
    ("the README's fuzz paragraph overstates the limit again",
     lambda: patch_readmes(
         "Each invocation is a real\nproperty-based run -- 11 surfaces, 300 trials per surface -- so the check\n"
         "repeats that one run, and no CI workflow runs it either.",
         "it is a re-run of one case, not a fuzz, and no CI workflow runs it either.")),

    # -- 2. the QA check's evidence denies that the harness fuzzes --------------
    ("the QA check's evidence reverts to denying the fuzzer",
     lambda: (patch(CHECKS,
                    'f"run ({scale_note}), so what repeats is that one run, not a sweep "\n'
                    '        "of seeds")',
                    'f"run ({scale_note}); it is a re-run of one case, not fuzzing")'),
              commit(WORK, [os.path.join(".github", "scripts", "qa_loop", "checks.py")],
                     "dry-run: the check's evidence denies the fuzzer"))),

    # -- 3. the README's quoted message drifts from the check's -----------------
    ("the README's quoted `dependencies` message drifts",
     lambda: patch_readmes(
         "(`2 declared; non-conforming:",
         "(`3 declared; non-conforming:")),

    # -- 4. the `dependencies` check stops reporting the dead dependencies ------
    ("the `dependencies` check stops reporting the dead dependencies",
     lambda: (patch(CHECKS,
                    '    return R("dependencies", "", WARN if notes else PASS,\n'
                    '             f"{len(deps)} declared; " + ("; ".join(notes) if notes else "all used and conforming")\n'
                    '             + "  [no vulnerability scanner in CI; moon update is not an audit]")',
                    '    return R("dependencies", "", PASS,\n'
                    '             f"{len(deps)} declared; all used and conforming"\n'
                    '             + "  [no vulnerability scanner in CI; moon update is not an audit]")'),
              commit(WORK, [os.path.join(".github", "scripts", "qa_loop", "checks.py")],
                     "dry-run: the check stopped reporting the dead deps"))),

    # -- 5. a CI workflow starts running the `mutation` check -------------------
    ("a CI workflow starts running the `mutation` check",
     lambda: (patch(WORKFLOW,
                    "--only api_test,security_dast --json qa_loop_services.json",
                    "--only api_test,security_dast,mutation --json qa_loop_services.json"),
              commit(WORK, [os.path.join(".github", "workflows", "check.yml")],
                     "dry-run: CI now runs the mutation check"))),

    # -- 6. a workflow runs --full WITHOUT --only -----------------------------
    # This is the hole in the OLD method.  Round 22's check decides "does CI
    # run this check?" by grepping the workflows for the check's ID, so a
    # workflow that selects the FULL scope without naming any id would run
    # the `fuzz` check and the grep would still report "no workflow runs it".
    # The new verifier applies the runner's OWN selection rule -- selected AND
    # (scope is not full OR --full was passed) -- so it sees the run.
    ("a workflow runs --full without --only",
     lambda: (patch(WORKFLOW,
                    "--only api_test,security_dast,mutation --json qa_loop_services.json",
                    "--json qa_loop_services.json"),
              commit(WORK, [os.path.join(".github", "workflows", "check.yml")],
                     "dry-run: a workflow selected the full scope by name"))),
    # -- 7. the coverage check stops calling itself a proxy ---------------------
    ("the `coverage` check stops calling itself a proxy",
     lambda: (patch(CHECKS, "PROXY, not line coverage:", "LINE COVERAGE:"),
              commit(WORK, [os.path.join(".github", "scripts", "qa_loop", "checks.py")],
                     "dry-run: the coverage check stopped saying PROXY"))),

    # -- 7. the README follows the coverage check ------------------------------
    ("the README follows the coverage check",
     lambda: patch_readmes(
         "test-reachability proxy, not instrumented line coverage",
         "instrumented line coverage")),

    # -- 8. a crash-regression corpus appears ----------------------------------
    ("a crash-regression corpus appears under examples/fuzz",
     lambda: (os.makedirs(os.path.join(WORK, "examples", "fuzz", "corpus"),
                          exist_ok=True),
              write(os.path.join(WORK, "examples", "fuzz", "corpus",
                                 "crash-001.txt"),
                     "seed=1\nsurface=p_adjust\n"),
              commit(WORK, [os.path.join("examples", "fuzz", "corpus",
                                         "crash-001.txt")],
                     "dry-run: a crash-regression corpus appeared"))),

    # -- 9. the mutation battery's target moves --------------------------------
    ("the mutation battery's target moves to a file that does not exist",
     lambda: (patch(CHECKS, 'tgt = "ps_processor.mbt"', 'tgt = "pava.mbt"'),
              commit(WORK, [os.path.join(".github", "scripts", "qa_loop", "checks.py")],
                     "dry-run: the mutation target moved"))),

    # -- 10. the fuzz harness takes a seed parameter ---------------------------
    ("the fuzz harness takes a seed parameter",
     lambda: (patch(FUZZ, "fn main {", "fn main(seed : Int) {"),
              commit(WORK, [os.path.join("examples", "fuzz", "main.mbt")],
                     "dry-run: the harness took a seed parameter"))),

    # -- 11. the fuzz check's seed arguments stop being different --------------
    ("the fuzz check's three seed arguments stop being different",
     lambda: (patch(CHECKS, 'for seed in ("1", "42", "3141"):',
                    'for seed in ("1", "42", "42"):'),
              commit(WORK, [os.path.join(".github", "scripts", "qa_loop", "checks.py")],
                     "dry-run: two seed arguments became the same"))),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    grew = n > prev
    print("  %2d. %-56s failures %d -> %d  %s"
          % (i, desc[:56], prev, n, "GROW" if grew else "*** FLAT ***"))
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n

# the counter must agree with the verifier's own summary
rc, out, n = verify(WORK)
print()
print("=== the counter and the verifier's own summary ===")
print("  the driver counted %d failures" % n)
summaries = re.findall(r"(\d+) checks, (\d+) failed", out)
print("  the verifier says   %s"
      % (", ".join("%s checks, %s failed" % s for s in summaries) if summaries else "NONE"))
if not summaries or sum(int(s[1]) for s in summaries) != n:
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
_entry = None
for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                     read(CHANGELOG), re.M | re.S):
    if "_dryrun_round36_1650.py" in m.group(2):
        _entry = m.group(2)
        break
published = published_count(read(CHANGELOG), "_dryrun_round36_1650.py")
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
