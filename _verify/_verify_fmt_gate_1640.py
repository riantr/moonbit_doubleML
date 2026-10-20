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

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
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
    dst = os.path.join(BASE, name)
    if os.path.isdir(dst):
        shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(SRC, dst)
    shutil.rmtree(os.path.join(dst, "_build"), ignore_errors=True)
    return dst


def run(cwd, *a):
    return subprocess.run(["moon", *a], cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


ver = run(ROOT, "version").stdout.strip()
print("toolchain: %s" % ver)
print()
print("=== arm A: does `moon fmt` rewrite the mangled file? ===")
aA = fresh("_fmtctl_vA")
tA = os.path.join(aA, "main.mbt")
sA = io.open(tA, encoding="utf-8", newline="").read()
io.open(tA, "w", encoding="utf-8", newline="").write(sA + "\n" + MANGLER)
bA = io.open(tA, encoding="utf-8", newline="").read()
run(aA, "fmt")
aA_after = io.open(tA, encoding="utf-8", newline="").read()
check("A: `moon fmt` rewrites the mangled file (so it WAS mis-formatted)",
      bA != aA_after)
shutil.rmtree(aA, ignore_errors=True)

print()
print("=== arm B: `moon fmt --check` on a CLEAN copy ===")
aB = fresh("_fmtctl_vB")
rB = run(aB, "fmt", "--check")
check("B: clean copy exits 0", rB.returncode == 0, "exit %d" % rB.returncode)
shutil.rmtree(aB, ignore_errors=True)

print()
print("=== arm C: `moon fmt --check` on a MANGLED copy ===")
aC = fresh("_fmtctl_vC")
tC = os.path.join(aC, "main.mbt")
sC = io.open(tC, encoding="utf-8", newline="").read()
io.open(tC, "w", encoding="utf-8", newline="").write(sC + "\n" + MANGLER)
rC = run(aC, "fmt", "--check")
cC = (rC.stdout or "") + (rC.stderr or "")
check("C: mangled copy exits non-zero", rC.returncode != 0,
      "exit %d" % rC.returncode)
check("C: the output names main.mbt", "main.mbt" in cC)
shutil.rmtree(aC, ignore_errors=True)

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
