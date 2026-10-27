#!/usr/bin/env python3
"""Round 58 dry-run: break the secondary documents' claims twenty-five ways,
and watch the verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_secondary_docs_1650.py` holds the claims the four secondary
live documents make about the tree -- and a verifier that only ever prints "ok"
is indistinguishable from one that never fires.

So this driver copies the tree into a scratch clone, breaks each promise one
way at a time, and requires the failure count to GROW at every step.  A
contract nobody can break is a contract nobody is really checking.

THE MECHANISMS
===============
One per claim family the round-58 probe found unheld.  Each changes ONE thing
in ONE place, and each must trip a check that no earlier mechanism has
tripped: a mechanism that trips an already-tripped check is FLAT, and a flat
step means the mechanism is not being measured.

   1  the hook's tracked mode
   2  the workspace member count
   3  a `moon check` task count, put back
   4  publish.yml's check command
   5  the "the same command" claim, put back
   6  the `_test.mbt` claim, inverted
   7  the Python cross-check count
   8  where the QA LOOP lives
   9  where the CI-gating section lives
  10  the doc module's name
  11  a tutorial row in the table
  12  the tutorial target
  13  the "its own tests" claim
  14  `doc`'s workspace membership
  15  the package the tutorial command names
  16  where the verifiers live
  17  a menu entry's path
  18  a menu entry's title
  19  the audited toolchain, called "current"
  20  the patch-release gap
  21  a per-case frontend error count
  22  a case name in the results table
  23  who classifies the log
  24  the pilot's package
  25  the blockers file

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

Run: python _verify/_dryrun_round58_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r58")
DRIVER = "_verify/_dryrun_round58_1650.py"
VERIFIERS = [
    "_verify/_verify_secondary_docs_1650.py",
    "_verify/_verify_round14_upstream_1649.py",
]
DOCUMENTS = [
    ".githooks/README.md",
    "doc/README.mbt.md",
    "doc/menu.json",
    "_verify/upstream_prove_1649/README.md",
]
ADDED = [
    "_verify/_dryrun_round58_1650.py",
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
        fh.flush()
        os.fsync(fh.fileno())


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
rc, out = run(["git", "-C", WORK, "checkout", "--detach", COMMIT])
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "-C", WORK, "rev-parse", "HEAD"])
print("  %s -> %s" % (COMMIT, out.strip()))
# The clone MUST be a repository of its own: every git command below names it
# with `-C`, so a missing `.git` is an error and never the parent repo.
if not os.path.isdir(os.path.join(WORK, ".git")):
    print("!! the clone has no .git -- refusing to run")
    sys.exit(1)

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

HOOK = os.path.join(WORK, ".githooks", "README.md")
DOCRM = os.path.join(WORK, "doc", "README.mbt.md")
MENU = os.path.join(WORK, "doc", "menu.json")
UP = os.path.join(WORK, "_verify", "upstream_prove_1649", "README.md")


# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """The hook's tracked mode."""
    sub(HOOK, r"tracked with mode\s+`100644`", "tracked with mode `100755`")


def m2():
    """The workspace member count."""
    sub(HOOK, r"over the\s+23\s+members", "over the 24 members")


def m3():
    """A `moon check` task count, put back."""
    sub(HOOK, r"\(exit 0 on a clean tree\)",
        "(measured: `moon: ran 54 tasks`, exit 0 on a clean tree)")


def m4():
    """publish.yml's check command."""
    sub(HOOK, r"`moon check --target \"\$target\" --deny-warn`",
        "`moon check --target \"$target\"`")


def m5():
    """The 'the same command' claim, put back."""
    sub(HOOK, r"`publish\.yml` runs the\s+same pass with a target and `--deny-warn` added",
        "It is the same command `publish.yml` runs before it publishes")


def m6():
    """The `_test.mbt` claim, inverted."""
    sub(HOOK, r"`moon check` type-checks the `_test\.mbt` files",
        "`moon check` does not type-check the `_test.mbt` files")


def m7():
    """The Python cross-check count."""
    sub(HOOK, r"the 24 Python cross-checks", "the 25 Python cross-checks")


def m8():
    """Where the QA LOOP lives."""
    sub(HOOK, r"\.github/scripts/qa_loop/", ".github/workflows/")


def m9():
    """Where the CI-gating section lives."""
    sub(HOOK, r"`ENGINEERING\.md`'s", "`README.mbt.md`'s")


def m10():
    """The doc module's name."""
    sub(DOCRM, r"^# `riantr/moonbit_doubleML-doc`", "# `riantr/moonbit_doubleML-docs`")


def m11():
    """A tutorial row in the table."""
    sub(DOCRM, r"\| `003_quick_start` \|", "| `003_quick_startX` |")


def m12():
    """The tutorial target."""
    sub(DOCRM, r"Every tutorial is a `wasm-gc` package",
        "Every tutorial is a `native` package")


def m13():
    """The 'its own tests' claim."""
    sub(DOCRM, r"its own `moon\.pkg` and its own tests",
        "its own `moon.pkg` and no tests")


def m14():
    """`doc`'s workspace membership."""
    sub(DOCRM, r"`doc` is a member of the\s+repository's `moon\.work` workspace",
        "`doc` is not a member of the repository's `moon.work` workspace")


def m15():
    """The package the tutorial command names."""
    sub(DOCRM, r"moon test --target wasm-gc -p 003_quick_start",
        "moon test --target wasm-gc -p 009_nope")


def m16():
    """Where the verifiers live."""
    sub(DOCRM, r"live under `_verify/`", "live under `_docs/`")


def m17():
    """A menu entry's path."""
    sub(MENU, r"\"003_quick_start\"", "\"003_quick_startX\"")


def m18():
    """A menu entry's title."""
    sub(MENU, r"\"title\": \"Quick Start\"", "\"title\": \"\"")


def m19():
    """The audited toolchain, called 'current'."""
    sub(UP, r"\*\*the audited", "**the current")


def m20():
    """The patch-release gap."""
    sub(UP, r"is\s+five\s+(?:>\s*)?patch releases after `v0\.10\.11`",
        "is seven patch releases after `v0.10.11`")


def m21():
    """A per-case frontend error count."""
    sub(UP, r"\| `b2_double_cmp` \| 6 \|", "| `b2_double_cmp` | 7 |")


def m22():
    """A case name in the results table."""
    sub(UP, r"\| `b0_control` \| 0 \| accepted \|", "| `b0_controlX` | 0 | accepted |")


def m23():
    """Who classifies the log."""
    sub(UP, r"`run_reaudit\.py` classifies the control `PLATFORM_ERROR` rather\s+than `PROVED`",
        "the controls are classified `PLATFORM_ERROR` rather than `PROVED` in "
        "`out/b0_control.log`")


def m24():
    """The pilot's package."""
    sub(UP, r"`_prove_pilot/moon\.pkg`", "`_prove_pilotX/moon.pkg`")


def m25():
    """The blockers file."""
    sub(UP, r"`_verify/UPSTREAM_BLOCKERS\.md`", "`_verify/UPSTREAM_BLOCKERSX.md`")


MECHANISMS = [
    ("the hook's tracked mode", m1),
    ("the workspace member count", m2),
    ("a `moon check` task count, put back", m3),
    ("publish.yml's check command", m4),
    ("the 'the same command' claim, put back", m5),
    ("the `_test.mbt` claim, inverted", m6),
    ("the Python cross-check count", m7),
    ("where the QA LOOP lives", m8),
    ("where the CI-gating section lives", m9),
    ("the doc module's name", m10),
    ("a tutorial row in the table", m11),
    ("the tutorial target", m12),
    ("the 'its own tests' claim", m13),
    ("`doc`'s workspace membership", m14),
    ("the package the tutorial command names", m15),
    ("where the verifiers live", m16),
    ("a menu entry's path", m17),
    ("a menu entry's title", m18),
    ("the audited toolchain, called 'current'", m19),
    ("the patch-release gap", m20),
    ("a per-case frontend error count", m21),
    ("a case name in the results table", m22),
    ("who classifies the log", m23),
    ("the pilot's package", m24),
    ("the blockers file", m25),
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

capture = os.path.join(REPO, "_verify", "_dryrun1650", "r58_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 58 dry-run: the secondary documents' claims, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline %d failing checks; final %d\n" % (base, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok and prev > base else "FAIL"))
    for i, (name, fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
print("capture written: %s" % capture)
sys.exit(0 if (ok and prev > base) else 1)
