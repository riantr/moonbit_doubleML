"""The `moon fmt --check` claim must match what the tool actually does.

The README used to say the check "has not been shown to be able to fail" and
that it "exits 0 on a package containing a deliberately mis-formatted file,
silently". Both halves were wrong on the current toolchain, and the way they
were wrong is worth pinning down, because it is the same mistake twice:

  * the original control arm pointed `moon fmt` at a DIRECTORY WITH NO PACKAGE
    in it (no moon.pkg), so the tool had nothing to format and exited 0 -- a
    control that measures nothing, reporting INERT forever;
  * the v0.162.0 arm, re-run on the current toolchain, produced a THIRD
    answer: a non-zero exit caused by a long-path/`git diff` infrastructure
    error inside %TEMP%, which that arm's `else` branch read as
    "DISCRIMINATES" -- conflating "exited non-zero" with "detected the
    formatting".

So this verifier runs the three arms that actually decide it:
  A. `moon fmt` on a mangled copy REWRITES the file
     -> "mis-formatted" is proven, not assumed;
  B. `moon fmt --check` on a CLEAN copy exits 0;
  C. `moon fmt --check` on a MANGLED copy exits non-zero.
Only B and C together show the gate discriminates. A alone would be enough to
prove the file is bad; C alone would not be enough to show the red is about
the formatting.

And it asserts the README and both workflows say what was measured.
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "_verify")
SRC = os.path.join(ROOT, "examples", "main")
MANGLER = ("fn   mangled_probe(  a : Int ,b : Int )->Int {\n"
           "        let x=a+b   \n"
           "  x\n"
           "}\n")

fails = []


def check(label, cond, detail=""):
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def fresh(name):
    """A COPY of `examples/main`, OUTSIDE the workspace.

    Inside the workspace, `moon fmt --check` also formats the workspace's
    OTHER members, so it needs the workspace's build state -- which a
    checkout does not have, and which is not a statement about the copy.
    The copy therefore lives in a temp directory: the tool then formats
    the copy alone.

    Returns (the temp directory, the copy).
    """
    parent = tempfile.mkdtemp(prefix="fmtctl_")
    dst = os.path.join(parent, name)
    shutil.copytree(SRC, dst)
    shutil.rmtree(os.path.join(dst, "_build"), ignore_errors=True)
    return parent, dst


def snapshot(dst):
    """Every source file in the copy, by bytes."""
    out = {}
    for root, _dirs, files in os.walk(dst):
        if "_build" in root:
            continue
        for f in files:
            p = os.path.join(root, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, dst)] = fh.read()
    return out


def warm(dst):
    """Materialise the toolchain's format artefacts for this copy.

    `moon fmt --check` DIFFS the source against the formatted output the
    format task produces under `_build/<target>/release/format/`.  The
    task is keyed by the source's CONTENT, so a copy whose `_build` was
    deleted can be reported "up to date" with its output missing -- and
    the check then fails on a missing file rather than on a formatting
    difference.  That is a statement about the toolchain's cache, not
    about the tree, so the copy is warmed first.

    The warm-up runs `moon fmt`, which REWRITES mis-formatted sources.
    That is why the arms warm BEFORE they mangle: the warm-up's only
    lasting effect on the subject is the artefact it was after.  Whether
    it rewrote anything is reported, because "the tree is already
    formatted" is a fact about the tree and the copy's warm-up is where
    it shows up.
    """
    before = snapshot(dst)
    run(dst, "fmt")
    after = snapshot(dst)
    changed = sorted(k for k in set(before) | set(after)
                     if before.get(k) != after.get(k))
    return changed


def run(cwd, *a):
    return subprocess.run(["moon", *a], cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


ver = run(ROOT, "version").stdout.strip()
print("toolchain: %s" % ver)
print()
print("=== arm A: does `moon fmt` rewrite the mangled file? ===")
pA, aA = fresh("_fmtctl_vA")
warm(aA)
tA = os.path.join(aA, "main.mbt")
sA = io.open(tA, encoding="utf-8", newline="").read()
io.open(tA, "w", encoding="utf-8", newline="").write(sA + "\n" + MANGLER)
bA = io.open(tA, encoding="utf-8", newline="").read()
run(aA, "fmt")
aA_after = io.open(tA, encoding="utf-8", newline="").read()
check("A: `moon fmt` rewrites the mangled file (so it WAS mis-formatted)",
      bA != aA_after)
shutil.rmtree(pA, ignore_errors=True)

print()
print("=== arm B: `moon fmt --check` on a CLEAN copy ===")
pB, aB = fresh("_fmtctl_vB")
warm(aB)
rB = run(aB, "fmt", "--check")
check("B: clean copy exits 0", rB.returncode == 0, "exit %d" % rB.returncode)
shutil.rmtree(pB, ignore_errors=True)

print()
print("=== arm C: `moon fmt --check` on a MANGLED copy ===")
pC, aC = fresh("_fmtctl_vC")
# WARM FIRST, then mangle.  The warm-up runs `moon fmt`, which REWRITES a
# mis-formatted source -- so warming a mangled copy would FORMAT it and the
# check that follows would be run against a clean tree, and it would exit 0
# for the wrong reason.  Warming first leaves the artefact in place and the
# mangling as the only difference.
warm(aC)
tC = os.path.join(aC, "main.mbt")
sC = io.open(tC, encoding="utf-8", newline="").read()
io.open(tC, "w", encoding="utf-8", newline="").write(sC + "\n" + MANGLER)
rC = run(aC, "fmt", "--check")
cC = (rC.stdout or "") + (rC.stderr or "")
check("C: mangled copy exits non-zero", rC.returncode != 0,
      "exit %d" % rC.returncode)
check("C: the output names main.mbt", "main.mbt" in cC)
shutil.rmtree(pC, ignore_errors=True)

print()
print("=== the project document and the workflows say what was measured ===")
# Round 18 split the documentation in two.  The `moon fmt --check` gate is a
# CI gate -- it describes this repository's pipeline, not the library -- so its
# measurement lives in `ENGINEERING.md` and these checks read that.  A
# withdrawn wording must be absent from BOTH documents.
readme = io.open(os.path.join(ROOT, "README.mbt.md"), encoding="utf-8",
                 errors="replace").read()
proj = io.open(os.path.join(ROOT, "ENGINEERING.md"), encoding="utf-8",
               errors="replace").read()
flat = re.sub(r"\s+", " ", proj)
bothflat = re.sub(r"\s+", " ", readme + " " + proj)

check("the project document no longer carries the old bullet's opening",
      "`moon fmt --check` has not been shown to be able to fail" not in bothflat)
check("the project document no longer says it 'exits 0 on a package "
      "containing a deliberately mis-formatted file, silently'",
      "exits 0 on a package containing a deliberately mis-formatted file, "
      "silently" not in bothflat)
check("the project document says the check can fail", "can fail" in flat)
check("the project document gives the measured exit code",
      "4294967295" in proj)
check("the project document names the toolchain the measurement was taken on",
      "moon 0.1.20261016" in proj)

for wf in ("check.yml", "publish.yml"):
    p = os.path.join(ROOT, ".github", "workflows", wf)
    body = io.open(p, encoding="utf-8", errors="replace").read()
    check("%s no longer claims the check 'cannot fail'" % wf,
          "cannot fail on this toolchain" not in body
          and "this toolchain cannot" not in body)
    check("%s keeps --allow-inert as a policy for the INERT verdict" % wf,
          "--allow-inert" in body)

# the QA harness's own comment already records why the old verdict was wrong
checks_py = io.open(os.path.join(ROOT, ".github", "scripts", "qa_loop",
                                 "checks.py"), encoding="utf-8",
                    errors="replace").read()
check("the QA harness documents the load-bearing moon.pkg",
      "moon.pkg is LOAD-BEARING" in checks_py)

print()
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
