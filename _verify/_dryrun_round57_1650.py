#!/usr/bin/env python3
"""Round 57 dry-run: break AGENTS.md's claims twenty ways, and watch the
verifier notice.

WHAT THIS EXISTS FOR
====================
A verifier that has never been seen to FAIL is not evidence.
`_verify/_verify_agents_claims_1650.py` holds the claims AGENTS.md makes about
the tree -- the ones a mutation probe found that NOTHING in the repository was
holding -- and a verifier that only ever prints "ok" is indistinguishable from
one that never fires.

So this driver copies the tree into a scratch clone, breaks each promise one
way at a time, and requires the failure count to GROW at every step.  A
contract nobody can break is a contract nobody is really checking.

THE MECHANISMS
===============
One per claim family the round-57 probe found unheld.  Each changes ONE thing
in ONE place, and each must trip a check that no earlier mechanism has
tripped: a mechanism that trips an already-tripped check is FLAT, and a flat
step means the mechanism is not being measured.

   1  the `moon.work` member count
   2  the example count
   3  the example enumeration
   4  the doc package count
   5  the last doc package named
   6  the out-of-workspace directory count
   7  an out-of-workspace directory's name
   8  the library's directory
   9  the library's own `moon.mod` and `moon.pkg`
  10  the dependency carve-out, removed
  11  the dependency rule's `riantr/*` half
  12  the dependency rule's version example
  13  the HTTP service's async version
  14  the commit citation
  15  a public API call
  16  the "no test file" claim
  17  the smoke-test recipe's path
  18  the interface file's name
  19  the old `.mbti` instruction, put back
  20  the "no MoonBit source at the root" claim
  21  the deprecated-blocks file, CLAIMED to exist
  22  the deprecated-blocks file, ADDED to the tracked tree -- which proves the
     scope is the TRACKED tree and that the claim is watched, not merely
     asserted in prose

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

Run: python _verify/_dryrun_round57_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r57")
DRIVER = "_verify/_dryrun_round57_1650.py"
VERIFIERS = [
    "_verify/_verify_agents_claims_1650.py",
    "_verify/_verify_shipped_docs_1643.py",
]
DOCUMENTS = [
    "AGENTS.md",
]
ADDED = [
    "_verify/_dryrun_round57_1650.py",
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

AG = os.path.join(WORK, "AGENTS.md")

# ------------------------------------------------------------ the mechanisms
# CUMULATIVE: each mechanism is applied on top of the ones before it.
def m1():
    """The `moon.work` member count."""
    sub(AG, r"members \(\d+ total\)", "members (24 total)")


def m2():
    """The example count."""
    sub(AG, r"× \d+", "× 20")


def m3():
    """The example enumeration."""
    sub(AG, r"`pava`", "`pavaX`")


def m4():
    """The doc package count."""
    sub(AG, r"module of \d+ wasm-gc-targeted packages",
        "module of 7 wasm-gc-targeted packages")


def m5():
    """The last doc package named."""
    sub(AG, r"`006_python_check`", "`007_python_check`")


def m6():
    """The out-of-workspace directory count."""
    sub(AG, r"\w+ directories hold MoonBit source outside the workspace",
        "Two directories hold MoonBit source outside the workspace")


def m7():
    """An out-of-workspace directory's name."""
    sub(AG, r"`_prove_pilot2/`", "`_prove_pilot3/`")


def m8():
    """The library's directory."""
    sub(AG, r"The library lives at `moonbit_doubleML/`",
        "The library lives at `moonbit_doubleMLX/`")


def m9():
    """The library's own `moon.mod` and `moon.pkg`."""
    sub(AG, r"its own `moon\.mod` and\s+`moon\.pkg`",
        "its own `moon.mod` and\n  `moon.pkgx`")


def m10():
    """The dependency carve-out, removed."""
    sub(AG, r"`moonbit-community/sqlite3@0\.2\.3`, in `moonbit_doubleML/moon\.mod` --\n"
            r"  \*\*no `\.mbt` in the library imports it\*\* \(0 references\), so it is a dead\n"
            r"  entry, not a runtime dependency\.",
        "it is a dead entry, not a runtime dependency.")


def m11():
    """The dependency rule's `riantr/*` half."""
    sub(AG, r"Non-official packages may only be `riantr/\*`",
        "Non-official packages may only be `moonbit-community/*`")


def m12():
    """The dependency rule's version example."""
    sub(AG, r"registry \(e\.g\. `moonbitlang/async@0\.22\.6`\)",
        "registry (e.g. `moonbitlang/async@0.22.5`)")


def m13():
    """The HTTP service's async version."""
    sub(AG, r"on top of\s+`moonbitlang/async@0\.22\.6`",
        "on top of\n  `moonbitlang/async@0.22.5`")


def m14():
    """The commit citation."""
    sub(AG, r"commit `2ae0127`", "commit `2ae01270`")


def m15():
    """A public API call."""
    sub(AG, r"`DoubleMLPLR::new\(\.\.\.\)\.fit\(\)`", "`DoubleMLPQR::new(...).fit()`")


def m16():
    """The 'no test file' claim."""
    sub(AG, r"ships \*\*no\*\* test file", "ships **one** test file")


def m17():
    """The smoke-test recipe's path."""
    sub(AG, r"`examples/api_server/README\.md`", "`examples/api_server/READMEXXX.md`")


def m18():
    """The interface file's name."""
    sub(AG, r"interface file `pkg\.generated\.mbti`", "interface file `pkg.mbti`")


def m19():
    """The old `.mbti` instruction, put back."""
    sub(AG, r"(The file is \*\*git-ignored\*\*)",
        r"\1 -- check the diffs of `.mbti` file to see if the changes are expected.")


def m20():
    """The 'no MoonBit source at the root' claim."""
    sub(AG, r"owns no MoonBit source itself", "owns some MoonBit source itself")


def m21():
    """The deprecated-blocks file, CLAIMED to exist."""
    sub(AG, r"No `deprecated\.mbt` file exists in the tree today\.",
        "A `deprecated.mbt` file exists in the tree today.")


def m22():
    """The deprecated-blocks file, ADDED to the tracked tree.

    The claim AGENTS.md makes is about the TREE, so it is broken by changing
    the TREE.  The file is committed in the scratch clone, because the
    verifier's scope is the TRACKED tree -- a file that only exists in the
    working copy is not a claim about the repository.
    """
    rel = "deprecated.mbt"
    write(os.path.join(WORK, rel), "// a deprecated block\n")
    commit(WORK, [rel], "dry-run: a deprecated-blocks file in the tracked tree")


MECHANISMS = [
    ("the moon.work member count", m1),
    ("the example count", m2),
    ("the example enumeration", m3),
    ("the doc package count", m4),
    ("the last doc package named", m5),
    ("the out-of-workspace directory count", m6),
    ("an out-of-workspace directory's name", m7),
    ("the library's directory", m8),
    ("the library's own moon.mod and moon.pkg", m9),
    ("the dependency carve-out, removed", m10),
    ("the dependency rule's riantr/* half", m11),
    ("the dependency rule's version example", m12),
    ("the HTTP service's async version", m13),
    ("the commit citation", m14),
    ("a public API call", m15),
    ("the 'no test file' claim", m16),
    ("the smoke-test recipe's path", m17),
    ("the interface file's name", m18),
    ("the old .mbti instruction, put back", m19),
    ("the 'no MoonBit source at the root' claim", m20),
    ("the deprecated-blocks file, claimed to exist", m21),
    ("a deprecated-blocks file in the tracked tree", m22),
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

capture = os.path.join(REPO, "_verify", "_dryrun1650", "r57_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 57 dry-run: AGENTS.md's claims, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline %d failing checks; final %d\n" % (base, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok and prev > base else "FAIL"))
    for i, (name, fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
print("capture written: %s" % capture)
sys.exit(0 if (ok and prev > base) else 1)
