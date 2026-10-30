"""Round 72 dry-run: break ONE promise at a time and watch the count GROW.

Round 72 fixed three passages that had gone out of date and gave two of them
a holder.  This driver proves the new checks BITE, and that the two checks
they sit beside still bite.

THE MECHANISMS
===============
Six of them, and they break two different promises:

  * the VECTORISED SURFACE -- the public free functions `vectorized.mbt`
    exports, and the library files that call `vector_subtract`.  Four
    mechanisms: drop a helper from the list, name one the file does not
    export, understate the caller count, and call `matrix_predict` an
    element-wise wrapper again;
  * the README's CAVEATS -- the opening paragraph's API-shape caveat, and the
    Development section's pointer at the live gate commands.  Two mechanisms:
    drop the caveat, and put the stale pointer back.

Every mechanism is CUMULATIVE: it is applied on top of the ones before it, so
the failure count has to GROW at every step.  A mechanism whose count does not
grow is a mechanism that proves nothing, and the driver says so and stops.

The tree under test is a CLONE with the working tree's state copied in: the
clone is checked out from HEAD, so without the copy the tree under test would
be a mix of two releases -- this round's checks and the last round's
documents -- and the baseline would be red for a reason that has nothing to
do with the promise being broken.
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r72")
DRIVER = "_verify/_dryrun_round72_1650.py"

DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

VERIFIERS = [
    "_verify/_verify_vectorised_surface_1680.py",
    "_verify/_verify_readme_caveats_1680.py",
]


def run(cmd, cwd=REPO, timeout=3600, env=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout,
                       env=env)
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


def commit(work, paths, message):
    rc, out = run(["git", "-C", work, "add", "--"] + paths, cwd=work)
    if rc != 0:
        print(out)
        raise SystemExit("git add failed")
    rc, out = run(["git", "-C", work, "commit", "-m", message], cwd=work)
    if rc != 0:
        print(out)
        raise SystemExit("git commit failed")


def failures_of(out):
    """How many checks failed, in the verifiers' own words."""
    return len(re.findall(r"\*\*\* FAIL \*\*\*", out))


def verify(work, env=None):
    total, chunks = 0, []
    for rel in VERIFIERS:
        rc, out = run([sys.executable, os.path.join(work, rel.replace("/", os.sep))],
                      cwd=work, env=env)
        chunks.append(out)
        total += failures_of(out)
    return 1 if total else 0, "\n".join(chunks), total


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
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + CHANGED:
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
commit(WORK, COPY_IN, "dry-run: the tree under test carries this round's state")

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")


def both_readmes(pattern, repl):
    sub_once(README, pattern, repl)
    sub_once(SHIPPED, pattern, repl)


# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0 = verify(WORK)
print("  exit=%d  failures=%d" % (rc0, n0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# -------------------------------------------------------------- the mechanisms
MECHANISMS = [
    ("the vectorised list drops a helper the file exports",
     lambda: both_readmes(
         r"`vector_add`, `vector_divide`, `vector_multiply`,",
         "`vector_add`, `vector_divide`,")),

    ("the vectorised list names a helper the file does NOT export",
     lambda: both_readmes(
         r"`vector_add`, `vector_divide`,",
         "`vector_add`, `vector_divide`, `vector_hypot`,")),

    ("the vectorised paragraph understates how many files call it",
     lambda: both_readmes(
         r"and \d+ of the\nlibrary's own files call it today",
         "and 2 of the\nlibrary's own files call it today")),

    ("the vectorised paragraph calls matrix_predict an element-wise wrapper",
     lambda: both_readmes(
         r"The `vector_\*` helpers are pure\nelement-wise loop wrappers today; "
         r"`matrix_predict` is a\nKahan-compensated matrix-vector product\.",
         "The helpers are pure element-wise loop wrappers today.")),

    ("the opening paragraph loses the API-shape caveat again",
     lambda: both_readmes(
         r"`DoubleMLXxx::new\(\.\.\.\)\.fit\(\)` API shape across all 22 estimators -- six take a\n"
         r"different constructor, and those six are named in \*\*API reference\*\* -- with\n"
         r"robust variance estimation",
         "`DoubleMLXxx::new(...).fit()` API across all 22 estimators, with robust\n"
         "variance estimation")),

    ("the Development section goes back to pointing at the frozen snapshot",
     lambda: both_readmes(
         r"`ENGINEERING\.md` is the companion, and it is worth saying what it is: its\n"
         r"header is the correction ledger -- one entry per corrected round -- and its\n"
         r"body is this README as it stood at `v[\d.]+`, word for word, with the old\n"
         r"title line replaced by the heading above it\. That body is \*\*frozen at\n"
         r"`v[\d.]+`\*\* -- it carries the gate table as it stood at that release, so\n"
         r"it is a record, not a live view\. The \*\*current\*\* gate commands live in\n"
         r"`\.github/workflows/check\.yml` and `\.github/workflows/publish\.yml`, plus\n"
         r"`\.github/scripts/qa_loop/` \(the QA harness the CI job invokes\)\. All of them\n"
         r"are in the repository; the registry publishes this one\.",
         "The test suite, the Python cross-checks, the QA harness and the\n"
         "reproducibility commands are all documented in `ENGINEERING.md`, together with\n"
         "the history of the defects that moved the estimator defaults and the\n"
         "derivation of the upstream naming map. Both files are in the repository; the\n"
         "registry publishes this one.")),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    print()
    print("  %d. %s" % (i, desc))
    print("       failures: %d -> %d" % (prev, n))
    if n <= prev:
        print(out)
        print("!! the failure count did NOT grow -- this mechanism proves nothing")
        sys.exit(1)
    for l in out.splitlines():
        if "FAIL" in l:
            print("       %s" % l.strip()[:150])
    prev = n

print()
print("=" * 78)
ok = prev > n0
if ok:
    print("VERDICT PASS -- %d mechanisms, each one grew the failure count "
          "(%d -> %d)" % (len(MECHANISMS), n0, prev))
else:
    print("VERDICT FAIL -- the mechanisms did not each grow the count")
print("=" * 78)

# The capture is the cited raw log of the run, and it is TRACKED by
# convention: the round-59 driver publishes one, and the documents that
# describe the dry-run cite it.
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r72_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 72 dry-run: the claims that rotted, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline %d failing checks; final %d\n" % (n0, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
