"""Round 73 dry-run: break ONE promise at a time and watch the count GROW.

Round 73 was a PRECISION round: nothing in the README was FALSE, and four
passages were looser than the tree supports.  This driver proves the new
checks BITE, and that the check the layout row sits beside still bites.

THE MECHANISMS
===============
Five of them, and each one breaks a promise the tree now holds:

  1  the `validate_*` paragraph's parenthetical -- put back the old contrast,
     which described ONE of the two gating scripts as comparing against
     upstream alone;
  2  the project-layout row's run count -- put back "12 estimators in 18
     runs", which counts the banners and leaves the fits unsaid;
  3  the Development section -- put back "for every round to date", and drop
     the caveat about the title line the ledger replaces;
  4  the ledger's header -- take out the note that says which round numbers
     are not used;
  5  a NUMBER -- change the hazard-margin factor by one, so the README
     carries a figure no verifier that reads it names.  The driver computes
     that figure rather than spelling it out: a driver that spells out the
     number it breaks holds that number, and the gate it is breaking would
     call its own mutation held.

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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r73")
DRIVER = "_verify/_dryrun_round73_1650.py"

DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

VERIFIERS = [
    "_verify/_verify_readme_precision_1680.py",
    "_verify/_verify_no_orphan_numbers_1680.py",
    "_verify/_verify_layout_1680.py",
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
LEDGER = os.path.join(WORK, "ENGINEERING.md")


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
#
# The `sub_once` calls are made DIRECTLY, not through a helper: the teeth
# verifier resolves a driver's anchors by walking its module-level calls, and
# a call hidden inside a helper's body is a call it cannot see.
M1_OLD = (r"against upstream and against a hand-rolled reference --\n"
          r"`validate_did_cs_binary_with_python\.py` \(the port's ATT against both\) and\n"
          r"`validate_lplr_with_python\.py` \(the port's coefficient against both\)\. The\n"
          r"other \*\*7\*\* import the wheel for")
M1_NEW = (r"against upstream rather than only against a hand-rolled reference --\n"
          r"`validate_did_cs_binary_with_python.py` (the port's ATT against upstream's)\n"
          r"and `validate_lplr_with_python.py` (the port's coefficient against upstream's\n"
          r"*and* the hand-rolled one, together). The other **7** import the wheel for")

M2_OLD = (r"  main/ +<- 12 estimators in \d+ printed runs, \d+ model fits:\n"
          r" +5 also run with n_rep=5, and RDD runs twice\n"
          r" +\(sharp, fuzzy\)")
M2_NEW = (r"  main/                  <- 12 estimators in 18 runs: 5 also run with\n"
          r"                            n_rep=5, and RDD runs twice (sharp, fuzzy)")

M3_OLD = (r"header is the correction ledger -- one entry per corrected round -- and its\n"
          r"body is this README as it stood at `(v[\d.]+)`, word for word, with the old\n"
          r"title line replaced by the heading above it\. The CURRENT gate commands are not\n"
          r"in that snapshot -- they are in `\.github/workflows/check\.yml` \(what CI runs\)\n")
M3_NEW = (r"header is the correction ledger for every round to date, and its body is this\n"
          r"README as it stood at `\1`, word for word. The CURRENT gate commands are not\n"
          r"in that snapshot -- they are in `.github/workflows/check.yml` (what CI runs)\n")

M4_OLD = (r"> \*The round numbers below are not contiguous\.\*  The corrections start\n"
          r"> at round \d+ and run to round \d+, and \d+ of the numbers in between\n"
          r"> \(rounds [\d-]+\) are not used\.\n>\n")
M4_NEW = ""

M5_OLD = r"down a factor of \*\*344\*\*"


def unheld_number(base):
    """A number no tracked reader of the README names.

    The driver must not hold the figure it breaks.  A driver that SPELLED OUT
    the number would put it in its own source -- and the driver reads the
    README, so the orphan-number gate would see the driver's own source and
    call its own mutation held.  So the figure is CHOSEN at run time, from
    the vocabulary the readers actually hold.

    The vocabulary is read from the WORKING TREE's whole `_verify/` tree, not
    from `git ls-files`: that is a SUPERSET of the reader set the gate uses in
    the clone (the clone carries HEAD's verifiers plus the ones copied in), so
    a number unheld here is unheld there.
    """
    named = set()
    for base_dir, _dirs, files in os.walk(os.path.join(REPO, "_verify")):
        for f in files:
            if not f.endswith(".py"):
                continue
            src = read(os.path.join(base_dir, f))
            if not re.search(r"README\.mbt\.md|readme\b", src):
                continue
            named |= set(re.findall(
                r"(?<![A-Za-z0-9_.])(\d{1,3}(?:[,_]\d{3})+|\d+)(?![0-9])", src))
    for n in range(base + 1, base + 1000):
        if str(n) not in named:
            return n
    raise SystemExit("!! no unheld number found near %d" % base)


M5_NEW = r"down a factor of **%d**" % unheld_number(344)

MECHANISMS = [
    ("the validate_* paragraph describes one gating script as upstream-only",
     lambda: (sub_once(README, M1_OLD, M1_NEW),
              sub_once(SHIPPED, M1_OLD, M1_NEW))),

    ("the layout row counts the banners and leaves the fits unsaid",
     lambda: (sub_once(README, M2_OLD, M2_NEW),
              sub_once(SHIPPED, M2_OLD, M2_NEW))),

    ("the Development section claims the ledger covers every round again",
     lambda: (sub_once(README, M3_OLD, M3_NEW),
              sub_once(SHIPPED, M3_OLD, M3_NEW))),

    ("the ledger stops saying which round numbers are not used",
     lambda: sub_once(LEDGER, M4_OLD, M4_NEW)),

    ("the README carries a number no verifier that reads it names",
     lambda: (sub_once(README, M5_OLD, M5_NEW),
              sub_once(SHIPPED, M5_OLD, M5_NEW))),
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r73_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 73 dry-run: the passages that were looser than the tree, "
             "broken %d ways\n" % len(MECHANISMS))
    fh.write("baseline %d failing checks; final %d\n" % (n0, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
