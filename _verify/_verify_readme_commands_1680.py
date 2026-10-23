"""Re-run every command the README tells a reader to run, and check the
quoted output against it.

This is the "verify the artefact, not the prose" rule applied to the
README's EXECUTABLE claims -- the Quick Start transcript and the HTTP
service recipe. Those are the claims a reader copies and pastes, so a
stale one is a broken first impression, not a cosmetic error.

Each check is: run the documented command, then assert the documented
string is in the real output.
"""
import io
import os
import re
import subprocess
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")

readme = io.open(README, encoding="utf-8").read()
fails = []


def check(label, condition, detail=""):
    print("  %-52s %s" % (label, "OK" if condition else "*** FAIL ***"))
    if not condition:
        fails.append("%s %s" % (label, detail))


def run(cmd, cwd=ROOT, timeout=1200):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       timeout=timeout, encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


print("== 1. the README must not quote a number the tree does not produce ==")

# --- moon test --target native --deny-warn
claimed = "Total tests: 1117, passed: 1117, failed: 0."
check("Quick Start quotes the native test total",
      claimed in readme, "the string is not in the README")
rc, out = run(["moon", "test", "--target", "native", "--deny-warn"],
              cwd=os.path.join(ROOT, "moonbit_doubleML"))
check("`moon test --target native --deny-warn` really prints that",
      rc == 0 and claimed in out, "rc=%d out=%s" % (rc, out[-300:]))

# --- moon run examples/main
rc, out = run(["moon", "run", "examples/main"])
check("`moon run examples/main` succeeds BARE", rc == 0, "rc=%d" % rc)
for line in ("estimated theta   = 1.092018247331361",
             "standard error    = 0.08875683254582736"):
    check("examples/main prints %r" % line[:34], line in out, out[-300:])
    check("README quotes %r" % line[:34], line in readme, "not in the README")

# --- the IRM validator
rc, out = run([sys.executable, "validate_irm_with_python.py"], timeout=1800)
m = re.search(r"PASS\s+\|mb - handrolled_nrep5\| \(theta\) = ([0-9.e-]+) < "
               r"max\(MODEL_TOL=0\.1, 2\.0\*handrolled_n5_se\) = ([0-9.e-]+)", out)
check("the IRM validator still PASSes", rc == 0 and m is not None,
      "rc=%d" % rc)
if m:
    line = ("PASS  |mb - handrolled_nrep5| (theta) = %s < "
            "max(MODEL_TOL=0.1, 2.0*handrolled_n5_se) = %s" % (m.group(1), m.group(2)))
    check("README quotes the IRM validator's current line", line in readme,
          "README has: %s" % (re.search(r"PASS  \|mb - handrolled_nrep5\|[^\n]*", readme) or ["(none)"])[0])

print("")
print("== 2. the README must not quote a path that does not exist ==")
m = re.search(r"^\$ (_build\S*api_server\S*\.exe)", readme, re.M)
if m:
    rel = m.group(1)
    # The path is a BUILD PRODUCT, so it is only there after the command the
    # README documents above it has been run.  The check runs that command,
    # so it does not depend on the tree having been built already -- a fresh
    # clone used to FAIL here for no reason of its own.
    cmd = None
    for line in reversed(readme[:m.start()].rstrip("\n").split("\n")[-4:]):
        if line.strip().startswith("$ "):
            cmd = line.strip()[2:].strip()
            break
    if cmd:
        rc, out = run(cmd.split(), timeout=1200)
        check("the documented build command runs (%s)" % cmd[:34], rc == 0,
              out[-200:])
    else:
        check("the README documents a build command for its binary path", False,
              "no $ command line above %s" % rel)
    full = os.path.join(ROOT, rel.replace("/", os.sep))
    check("the documented binary %s exists" % rel, os.path.isfile(full))
else:
    check("the README documents an api_server binary path", False, "not found")

print("")
print("== 3. every `moon run examples/<dir>` the README lists must work bare ==")
for d in sorted(set(re.findall(r"\$ moon run (examples/[a-z_]+)", readme))):
    rc, out = run(["moon", "run", d], timeout=900)
    check("`moon run %s` succeeds" % d, rc == 0, out[-200:])

print("")
print("== 4. the example metadata must agree with the README ==")
fuzz = io.open(os.path.join(ROOT, "examples", "fuzz", "moon.mod"),
               encoding="utf-8").read()
check("examples/fuzz says 11 surfaces", "11 surfaces" in fuzz, fuzz[:400])
main = io.open(os.path.join(ROOT, "examples", "main", "moon.mod"),
               encoding="utf-8").read()
check("examples/main says 12 estimators", "12 estimators" in main, main[:400])
fuzz_main = io.open(os.path.join(ROOT, "examples", "fuzz", "main.mbt"),
                    encoding="utf-8").read()
# Count SURFACES, not definitions. There are 12 `fn fuzz_*` definitions but
# `fuzz_plpr_panel` is a HELPER -- it builds the panel that `fuzz_plpr`
# consumes -- so the harness drives 11 surfaces, with 11 banners and 11
# derived seeds. Counting definitions would say 12 and be wrong.
_main_body = fuzz_main[fuzz_main.find("fn main {"):]
n_fuzz = len(re.findall(r"fuzz_(\w+)\(@moonbit_doubleML", _main_body))
n_defs = len(re.findall(r"^fn fuzz_\w+", fuzz_main, re.M))
n_surf = len(re.findall(r"println\(\"\[\d+/(\d+)\]", fuzz_main))
check("the fuzz harness drives %d surfaces" % n_surf,
      n_surf == 11 and ("[1/" + str(n_surf) + "]") in fuzz_main,
      "found %d" % n_surf)
check("the fuzz harness calls %d surfaces from main()" % n_fuzz,
      n_fuzz == 11, "found %d" % n_fuzz)
check("%d fuzz_* definitions == %d surfaces + 1 helper" % (n_defs, n_surf),
      n_defs == n_surf + 1, "defs=%d surfaces=%d" % (n_defs, n_surf))

print("")
print("=" * 78)
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
