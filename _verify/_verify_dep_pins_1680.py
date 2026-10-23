"""Pin the dependency claims and the Quick Start's working directory.

Two claims that had drifted:

1. The dependency table's `moonbitlang/async@0.22.5` row said the api_server
   example "declares it in its own `moon.mod`". The example declares
   `moonbitlang/async@0.20.3` -- a DIFFERENT pin -- so the library's 0.22.5
   line is referenced by nothing at all. A table cell that names the wrong
   version is worse than no note.

2. The Quick Start block never said where to run it. All three commands work
   from the repository root; two of them FAIL from inside `moonbit_doubleML/`
   ("failed to resolve path `examples/main`" and "can't open file
   ...validate_irm_with_python.py"). The block was therefore correct but
   ambiguous, and a reader who guessed the library directory got two errors.
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
API = os.path.join(ROOT, "examples", "api_server")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def imports_of(moon_mod):
    txt = io.open(moon_mod, encoding="utf-8").read()
    return re.findall(r"\"([^\"]+@[^\"]+)\"", txt)


lib_imports = imports_of(os.path.join(LIB, "moon.mod"))
api_imports = imports_of(os.path.join(API, "moon.mod"))
print("library imports   : %s" % lib_imports)
print("api_server imports: %s" % api_imports)
print("")

# --------------------------------------------------- 1. the dependency table
lib_async = [i for i in lib_imports if i.startswith("moonbitlang/async")]
api_async = [i for i in api_imports if i.startswith("moonbitlang/async")]
check("the library declares exactly one async", len(lib_async) == 1, str(lib_async))
check("the example declares exactly one async", len(api_async) == 1, str(api_async))
check("the example's async pin differs from the library's",
      lib_async != api_async,
      "library=%s example=%s" % (lib_async, api_async))

row = re.search(r"^\|\s*`moonbitlang/async@([\d.]+)`\s*\|\s*no\s*\|\s*(.*?)\s*\|\s*$",
                readme, re.M)
check("the dependency table has an async row", row is not None)
if row:
    note = row.group(2)
    print("  note: %s" % note)
    check("the row's version is the library's own pin",
          row.group(1) == lib_async[0].split("@")[1],
          "row=%s library=%s" % (row.group(1), lib_async[0]))
    check("the note states the example's ACTUAL pin",
          api_async[0].split("@")[1] in note,
          "the example declares %s" % api_async[0])
    check("the old claim that the example declares 'it' is gone",
          "which declares it in its own `moon.mod`" not in readme)

# the library's .mbt files import neither
refs = 0
for f in os.listdir(LIB):
    if f.endswith(".mbt"):
        s = io.open(os.path.join(LIB, f), encoding="utf-8", errors="replace").read()
        refs += len(re.findall(r"moonbitlang/async|sqlite3", s))
check("the library's .mbt files reference neither package (0)", refs == 0,
      "got %d references" % refs)

# --------------------------------------- 2. the Quick Start's working directory
check("the README says to run the Quick Start from the repository root",
      re.search(r"Run these from the \*\*repository root\*\*", readme) is not None)
check("it says the two repo-root paths fail from moonbit_doubleML/",
      "fail from inside `moonbit_doubleML/`" in readme)

# measure it: the two commands must fail from the library dir
print("")
for cmd, marker in ((["moon", "run", "examples/main"], "examples/main"),
                     ([sys.executable, "validate_irm_with_python.py"],
                      "validate_irm_with_python.py")):
    p = subprocess.run(cmd, cwd=LIB, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    check("`%s` fails from the library dir" % " ".join(cmd[:2]),
          p.returncode != 0 and (marker in out or "No such file" in out
                                 or "failed to resolve" in out),
          "rc=%d out=%s" % (p.returncode, out[:160].replace("\n", " ")))

# and the validator must exist at the repo root
check("validate_irm_with_python.py exists at the repo root",
      os.path.isfile(os.path.join(ROOT, "validate_irm_with_python.py")))

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
