#!/usr/bin/env python3
"""Round 47: the bit-exact scope -- the item count, the key count, and the
transcendental bit-pattern counts.

WHAT THIS EXISTS FOR
====================
The README says three things that nothing in the tree would catch if they
rotted:

    25 of the 25 bit-exact items are IEEE-754 identical to CPython
    the 6 / 6 RNG keys are byte-identical
    sqrt 6/6, cos 6/6, sin 6/6, ln 5/6 bit-exact

The first two were PRESENT-CHECKED: `_verify/_verify_test_verification_1650.py`
asserts that the strings are in the document, which is a promise that the
document says a thing -- not that the thing is true.  The third had no probe
at all: the numbers lived in two docstrings and nowhere else, because
`examples/bitexact` deliberately emits NO transcendental (it must not: `ln`
differs from CPython by one ULP, and a fixture that emitted one could not be
a gate that passes).

So the counts were true and unwatched.  This measures them.

ONE DERIVATION PER FACT
=======================
  * the ITEM COUNT comes from the validator's own source: the number of
    `out[...]` assignments in `reference()` is the number of items it
    compares.  It is not typed in here.
  * the KEY COUNT comes from the fixture's own source: the seed list that
    `examples/bitexact/main.mbt` feeds to `seed_to_bytes`.
  * the TRANSCENDENTAL COUNTS come from a probe, because no in-tree fixture
    emits a transcendental.  The probe is generated into a temporary
    directory and run with `moon run`; it is NOT a tracked file, because a
    tracked fixture would be a second implementation of the thing the
    fixture deliberately refuses to be.

And then the SOURCE counts and the RUN counts are compared with each other.
A README that says 26 is caught by the README check; a validator that
silently drops an item is caught by the source-vs-run check; a fixture that
emits 5 seeds is caught by the fixture check.  Three different failures,
three different owners.

THE TRANSENDENTAL PROBE
========================
`examples/bitexact` emits no transcendental on purpose -- see its doc
comment.  This probe is a SEPARATE, throwaway program that does nothing but
print `sqrt`, `ln`, `cos` and `sin` of six arguments, so their IEEE-754 bit
patterns can be compared with CPython's.  The arguments are the same six the
docstrings name, and the count of them is the denominator the README
publishes, so the denominator is checked too.

The probe's SOURCE is fixed here, and the README's quoted bit patterns
(`1.0986122886681096` vs `1.0986122886681098`) are compared with what the
probe actually prints, so the document cannot drift away from the
measurement without the check noticing.

The probe is built as a PACKAGE -- a `moon.mod`, a `moon.pkg` and a
`main.mbt` -- and not as a single file.  Single-file execution does not
solve on the current core: the package `moon/test/single` that a single-file
run builds imports both `moonbitlang/core/async/gzip` and
`moonbitlang/core/compress/gzip` under the same alias `gzip`, and the solver
reports the conflict.  A package gets `@math` from the same core, so the
numbers this verifier compares are the same numbers.

Run: python _verify/_verify_bitexact_scope_1650.py
"""
import ast
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VALIDATOR = os.path.join(ROOT, "validate_bitexact_with_python.py")
FIXTURE = os.path.join(ROOT, "examples", "bitexact", "main.mbt")
README = os.path.join(ROOT, "README.mbt.md")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "*** FAIL ***", label, detail))
    if not ok:
        FAILS.append(label)


def read(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


def flatten(text):
    """Collapse hard-wrapped lines so a phrase can span a line break."""
    return re.sub(r"\s+", " ", text)


# --------------------------------------------------------------------------- #
print()
print("=" * 78)
print("A. the counts, read out of the sources that own them")
print("=" * 78)

src = read(VALIDATOR)

# ---- the item count: the `out[...]` assignments inside reference() ---------
item_names = []
try:
    tree = ast.parse(src)
    fn = None
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "reference":
            fn = node
    if fn is not None:
        for node in ast.walk(fn):
            if not isinstance(node, ast.Assign):
                continue
            for tgt in node.targets:
                if (isinstance(tgt, ast.Subscript)
                        and isinstance(tgt.value, ast.Name)
                        and tgt.value.id == "out"
                        and isinstance(tgt.slice, ast.Constant)):
                    item_names.append(tgt.slice.value)
except SyntaxError as exc:
    check("the validator parses as Python", False, str(exc))

N_ITEMS = len(item_names)
check("the validator's reference() compares a measurable number of items",
      N_ITEMS > 0, "%d items" % N_ITEMS)
print("     items compared by reference(): %d" % N_ITEMS)
print("     %s" % ", ".join(item_names))

# ---- the key count: the seed list the fixture feeds to seed_to_bytes -------
fix = read(FIXTURE)
m = re.search(r"for\s+\w+\s+in\s*\[([^\]]*)\]\s*\{", fix)
check("the fixture emits its RNG keys from one seed list", m is not None)
seeds = []
if m:
    seeds = [int(x.strip()) for x in m.group(1).split(",") if x.strip()]
check("the fixture's seed list holds whole numbers", bool(seeds),
      "%r" % (seeds,))
check("the fixture feeds that list to emit_key",
      bool(re.search(r"for\s+\w+\s+in\s*\[[^\]]*\]\s*\{\s*\n\s*emit_key\(", fix)),
      "the loop body is not emit_key")
check("the fixture calls seed_to_bytes", "seed_to_bytes" in fix)
N_KEYS = len(seeds)
print("     RNG keys the fixture emits: %d -- %s" % (N_KEYS, seeds))

# --------------------------------------------------------------------------- #
print()
print("=" * 78)
print("B. the run agrees with the sources")
print("=" * 78)

p = subprocess.run([sys.executable, VALIDATOR], cwd=ROOT, capture_output=True,
                   text=True, encoding="utf-8", errors="replace", timeout=900)
out = (p.stdout or "") + (p.stderr or "")
check("the bit-exact validator runs and passes", p.returncode == 0,
      "rc=%d" % p.returncode)
m = re.search(r"items\s+(\d+)/(\d+)\s+bit-exact,\s*keys\s+(\d+)/(\d+)\s+byte-identical",
              out)
check("the validator reports its item and key counts", m is not None,
      out[-200:] if not m else "")
run_items = run_item_total = run_keys = run_key_total = 0
if m:
    run_items, run_item_total, run_keys, run_key_total = (
        int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)))
    check("every item the validator compares is bit-exact",
          run_items == run_item_total,
          "%d of %d" % (run_items, run_item_total))
    check("every key the validator compares is byte-identical",
          run_keys == run_key_total,
          "%d of %d" % (run_keys, run_key_total))
    check("the run's item count is the source's item count",
          run_item_total == N_ITEMS,
          "run=%d source=%d" % (run_item_total, N_ITEMS))
    check("the run's key count is the fixture's key count",
          run_key_total == N_KEYS,
          "run=%d fixture=%d" % (run_key_total, N_KEYS))

# --------------------------------------------------------------------------- #
print()
print("=" * 78)
print("C. the transcendentals, measured by a probe")
print("=" * 78)

PROBE = """fn main {
  let vals : Array[Double] = [1.0, 2.0, 3.0, 0.5, 10.0, 100.0]
  for x in vals {
    println("sqrt " + x.to_string() + " " + x.sqrt().to_string())
    println("ln " + x.to_string() + " " + @math.ln(x).to_string())
    println("cos " + x.to_string() + " " + @math.cos(x).to_string())
    println("sin " + x.to_string() + " " + @math.sin(x).to_string())
  }
}
"""

probe_dir = os.path.join(tempfile.gettempdir(), "moonbit_doubleml_r47_probe")
shutil.rmtree(probe_dir, ignore_errors=True)
os.makedirs(probe_dir)
with io.open(os.path.join(probe_dir, "main.mbt"), "w", encoding="utf-8", newline="\n") as fh:
    fh.write(PROBE)
# The probe is a PACKAGE, not a single file.  Single-file execution does not
# solve on the current core: it reports a conflicting import alias between
# `moonbitlang/core/async/gzip` and `moonbitlang/core/compress/gzip`, because
# the package `moon/test/single` that a single-file run builds imports both.
# A package gets `@math` from the same core, so the measurement is the same.
with io.open(os.path.join(probe_dir, "moon.mod"), "w", encoding="utf-8", newline="\n") as fh:
    fh.write('name = "local/transcendental-probe"\n\nversion = "0.0.1"\n')
with io.open(os.path.join(probe_dir, "moon.pkg"), "w", encoding="utf-8", newline="\n") as fh:
    fh.write('pkgtype(kind: "executable")\n')

pp = subprocess.run(["moon", "run", "--target", "native", probe_dir], cwd=probe_dir,
                    capture_output=True, text=True, encoding="utf-8",
                    errors="replace", timeout=900)
check("the transcendental probe runs", pp.returncode == 0,
      (pp.stderr or "")[-200:] if pp.returncode else "")

moon_vals = {}
for line in (pp.stdout or "").splitlines():
    parts = line.split()
    if len(parts) == 3:
        try:
            moon_vals[(parts[0], float(parts[1]))] = float(parts[2])
        except ValueError:
            pass

import math
import struct

OPS = {"sqrt": math.sqrt, "ln": math.log, "cos": math.cos, "sin": math.sin}
ARGS = [1.0, 2.0, 3.0, 0.5, 10.0, 100.0]
N_ARGS = len(ARGS)
measured = {}
detail = {}
for op in ("sqrt", "cos", "sin", "ln"):
    exact = 0
    gaps = {}
    for x in ARGS:
        got = moon_vals.get((op, x))
        if got is None:
            continue
        want = OPS[op](x)
        same = struct.pack("<d", got) == struct.pack("<d", want)
        exact += 1 if same else 0
        if not same:
            ia = struct.unpack("<q", struct.pack("<d", got))[0]
            ib = struct.unpack("<q", struct.pack("<d", want))[0]
            gaps[x] = abs(ia - ib)
    measured[op] = (exact, N_ARGS)
    detail[op] = gaps
    print("     %-5s %d/%d bit-exact   gaps=%s" % (op, exact, N_ARGS, gaps))

check("the probe produced every value it was asked for",
      len(moon_vals) == len(OPS) * N_ARGS,
      "%d of %d" % (len(moon_vals), len(OPS) * N_ARGS))

# The INVARIANTS, not the measurement.  `sqrt` is correctly rounded by
# IEEE-754, so it MUST agree on every argument -- that is a property of the
# standard, not of this toolchain pair.  `ln` is NOT correctly rounded in
# any implementation, so it MUST disagree somewhere -- also a property, not
# a measurement.  The COUNTS are what the document publishes, and they are
# checked against the measurement in section D; they are not asserted here,
# because asserting "all six agree" would assert a falsehood about `ln`.
check("sqrt is bit-exact on every argument (IEEE-754 requires it)",
      measured["sqrt"][0] == N_ARGS,
      "measured %d of %d" % measured["sqrt"])
check("ln differs from CPython somewhere (libm is not correctly rounded)",
      measured["ln"][0] < N_ARGS,
      "measured %d of %d" % measured["ln"])

# ln(3.0) is the one that differs, and by exactly one ULP
ln3_moon = moon_vals.get(("ln", 3.0))
ln3_py = math.log(3.0)
check("ln(3.0) differs from CPython", ln3_moon is not None
      and struct.pack("<d", ln3_moon) != struct.pack("<d", ln3_py),
      "moon=%r python=%r" % (ln3_moon, ln3_py))
check("ln(3.0) differs by exactly one ULP",
      detail.get("ln", {}).get(3.0) == 1,
      "gap=%s" % detail.get("ln", {}).get(3.0))

# --------------------------------------------------------------------------- #
print()
print("=" * 78)
print("D. the README states what was measured")
print("=" * 78)

rd = read(README)
flat = flatten(rd)

# ---- the item count, in both of its spellings -----------------------------
items_spells = re.findall(r"(\d+)\s+of\s+the\s+(\d+)\s+bit-exact\s+items", flat)
check("the README states the bit-exact item count", bool(items_spells),
      "no 'N of the M bit-exact items' spelling found")
for a, b in items_spells:
    check("the README's item count is the measured one (%s of the %s)"
          % (a, b),
          int(a) == N_ITEMS and int(b) == N_ITEMS,
          "measured %d" % N_ITEMS)

# ---- the key count, in both of its spellings ------------------------------
key_spells = re.findall(r"(\d+)\s*/\s*(\d+)\s+RNG\s+keys", flat)
check("the README states the RNG key count", bool(key_spells),
      "no 'N / M RNG keys' spelling found")
for a, b in key_spells:
    check("the README's key count is the measured one (%s / %s)" % (a, b),
          int(a) == N_KEYS and int(b) == N_KEYS,
          "measured %d" % N_KEYS)

# ---- the transcendental rows ----------------------------------------------
# The row's NUMBERS are not always in the same column: `sqrt` says "yes" in
# the bit-exact column and "**6 / 6** measured" in the WHY column, while
# `cos`/`sin` carry "observed 6 / 6" in the bit-exact column.  So the whole
# row is searched, and the row is located by its OPERATION name -- which is
# the part that names the thing being measured.
for line in rd.split("\n"):
    if not line.startswith("|"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 3:
        continue
    ops = [o for o in re.findall(r"`(\w+)`", cells[0]) if o in OPS]
    if not ops:
        continue
    nums = re.findall(r"(\d+)\s*/\s*(\d+)", line)
    if not nums:
        continue
    a, b = nums[0]
    for op in ops:
        check("the README's %s row states the measured count (%s / %s)"
              % (op, a, b),
              int(a) == measured[op][0] and int(b) == N_ARGS,
              "measured %d / %d" % measured[op])

# ---- the second spelling of the item count -------------------------------
# "**25 / 25 items and 6 / 6 RNG keys, currently identical**" -- the bold
# spans the WHOLE phrase, so the closing `**` does not follow the numbers.
item_slash = re.findall(r"(\d+)\s*/\s*(\d+)\s+items\b", flat)
check("the README states the item count in its slash spelling too",
      bool(item_slash), "no 'N / M items' spelling found")
for a, b in item_slash:
    check("the README's slash item count is the measured one (%s / %s)"
          % (a, b),
          int(a) == N_ITEMS and int(b) == N_ITEMS,
          "measured %d" % N_ITEMS)

# ---- the quoted bit patterns ----------------------------------------------
check("the README quotes ln(3.0)'s MoonBit bit pattern",
      repr(ln3_moon) in flat,
      "the probe printed %r" % repr(ln3_moon))
check("the README quotes ln(3.0)'s CPython bit pattern",
      repr(ln3_py) in flat,
      "CPython prints %r" % repr(ln3_py))

# --------------------------------------------------------------------------- #
print()
print("=" * 78)
print("E. the in-tree sources state the same numbers")
print("=" * 78)

for label, text in (("the validator's docstring", src),
                    ("the fixture's docstring", fix)):
    for op in ("sqrt", "cos", "sin", "ln"):
        # The docstrings are INDENTED and one line each:
        #     sqrt  6/6 bit-exact      guaranteed by IEEE-754
        #     ///     ln    5/6 bit-exact        ln(3.0) differs ...
        # so the search is per line, on the RAW text -- flattening first
        # would join them and the line anchor would never match.
        m = re.search(r"^\s*(?:///\s*)?%s\s+(\d+)/(\d+)\s+bit-exact" % op,
                      text, re.M)
        check("%s states %s %d/%d" % (label, op, measured[op][0], N_ARGS),
              m is not None and int(m.group(1)) == measured[op][0]
              and int(m.group(2)) == N_ARGS,
              "the source says %s" % (m.group(0).strip() if m else "nothing"))

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
