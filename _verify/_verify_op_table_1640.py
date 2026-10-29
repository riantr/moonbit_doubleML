"""Re-measure the operator bit-exactness table and check the README's numbers.

The README's determinism table says:

    sqrt       yes   same guarantee -- 6 / 6 measured
    cos, sin   observed 6 / 6
    ln         5 / 6   ln(3.0) differs by exactly 1 ULP:
                     MoonBit 1.0986122886681096, CPython 1.0986122886681098

That measurement was taken on `moon 0.1.20261012` vs CPython 3.14. This
re-measures it on whatever toolchain is installed NOW, and checks the
README's concrete numbers against it.

THE PROBE RUNS AS A PACKAGE
===========================
The probe used to be run as a single file: `moon run _verify/_probe_ops_1640.mbt`.
That no longer solves.  On the current core, a single-file run fails with

    Conflicting import alias: Both moonbitlang/core/async/gzip and
    moonbitlang/core/compress/gzip are imported into moon/test/single with
    the same alias 'gzip'.

-- the core ships both `core/async/gzip` and `core/compress/gzip`, and the
package `moon/test/single` that single-file execution builds imports both.
So the probe is generated into a PACKAGE instead: the same source, with a
`moon.mod` and a `moon.pkg`, run as `moon run <pkg>`.

That is the same measurement, not a weaker one.  What this verifier measures
is the CORE's `@math`, and a package gets `@math` from the same core the
single-file package would have.  Nothing the probe uses comes from this
repository's own manifest, so running it outside the tree changes nothing
about the numbers -- and running it INSIDE the tree is exactly what made the
single-file form fail in the first place.
"""
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = "_verify/_probe_ops_1640.mbt"
README = ROOT + r"\README.mbt.md"

ops = {
    "sqrt": lambda x: math.sqrt(x),
    "cos": math.cos,
    "sin": math.sin,
    "ln": math.log,
}


def bits(x):
    return struct.pack("<d", x)


print("== toolchains ==")
moon_v = subprocess.run(["moon", "version"], cwd=ROOT, capture_output=True,
                        text=True, encoding="utf-8", errors="replace")
print("moon   : %s" % (moon_v.stdout or "").strip().splitlines()[0])
print("python : %s" % sys.version.split()[0])
print()

# --- the probe, as a package -------------------------------------------------
PKG = os.path.join(tempfile.gettempdir(), "moonbit_doubleml_op_table_probe")
shutil.rmtree(PKG, ignore_errors=True)
os.makedirs(PKG)
shutil.copy2(os.path.join(ROOT, PROBE.replace("/", os.sep)),
             os.path.join(PKG, "main.mbt"))
with open(os.path.join(PKG, "moon.mod"), "w", encoding="utf-8", newline="\n") as fh:
    fh.write('name = "local/op-table-probe"\n\nversion = "0.0.1"\n')
with open(os.path.join(PKG, "moon.pkg"), "w", encoding="utf-8", newline="\n") as fh:
    fh.write('pkgtype(kind: "executable")\n')

out = subprocess.run(["moon", "run", "--target", "native", PKG], cwd=PKG,
                     capture_output=True, text=True, encoding="utf-8",
                     errors="replace", timeout=900)
if out.returncode != 0:
    print("probe failed: %s" % (out.stderr or out.stdout)[:400])
    sys.exit(1)

mine = {}
for line in out.stdout.splitlines():
    parts = line.split()
    if len(parts) == 3:
        mine[(parts[0], float(parts[1]))] = float(parts[2])

print("== re-measured on the CURRENT toolchain ==")
results = {}
for op in ("sqrt", "cos", "sin", "ln"):
    same = 0
    total = 0
    diffs = []
    for (o, arg), got in sorted(mine.items()):
        if o != op:
            continue
        total += 1
        want = ops[op](arg)
        if bits(got) == bits(want):
            same += 1
        else:
            d = abs(int.from_bytes(bits(got), "little")
                    - int.from_bytes(bits(want), "little"))
            diffs.append((arg, got, want, d))
    results[op] = (same, total, diffs)
    print("  %-5s %d/%d bit-exact" % (op, same, total))
    for arg, got, want, d in diffs:
        print("        arg %-6s moon %r  python %r  ulp=%d" % (arg, got, want, d))
print()

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


readme = open(README, encoding="utf-8").read()

# the README's counts
check("sqrt is 6/6", results["sqrt"][:2] == (6, 6), str(results["sqrt"][:2]))
check("cos is 6/6", results["cos"][:2] == (6, 6), str(results["cos"][:2]))
check("sin is 6/6", results["sin"][:2] == (6, 6), str(results["sin"][:2]))
check("ln is 5/6", results["ln"][:2] == (5, 6), str(results["ln"][:2]))

# the README's concrete ln(3.0) numbers
ln3 = [d for d in results["ln"][2] if d[0] == 3.0]
check("ln(3.0) is the one that differs", len(ln3) == 1, str(results["ln"][2]))
if ln3:
    arg, got, want, d = ln3[0]
    check("the difference is exactly 1 ULP", d == 1, "ulp=%d" % d)
    check("MoonBit's ln(3.0) is 1.0986122886681096",
          got == 1.0986122886681096, repr(got))
    check("CPython's ln(3.0) is 1.0986122886681098",
          want == 1.0986122886681098, repr(want))
    check("the README quotes MoonBit's value",
          "1.0986122886681096" in readme)
    check("the README quotes CPython's value",
          "1.0986122886681098" in readme)

# the README must not claim a toolchain it did not measure on
check("the README's table names no toolchain pair",
      "0.1.20261012" not in readme.split("| `ln` |")[1].split("\n")[0],
      "the ln row mentions a version")

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
