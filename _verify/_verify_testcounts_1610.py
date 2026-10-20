#!/usr/bin/env python3
"""The README's headline test counts must be the tree's test counts.

The README states the test counts twice -- in the Status table and in the
Quick Start transcript -- and those numbers are the most prominent claim the
document makes.  This checks them against the TREE.

WHAT CHANGED, AND WHY
=====================
This script was written at round 6, when the package had 1114 tests, and it
pinned that number as a literal:

    ok = len(lib) == 1114 and len(doc) == 6 and len(lib) + len(doc) == 1120

Three things were wrong with that, and the first two are the same failure
the rest of this repository keeps hitting:

  1. THE LITERAL ROTS.  The library grew; the literal did not.  The script
     went on printing "static and runtime counts DISAGREE -- investigate
     before trusting either" -- an alarming verdict that was really just the
     script's own age -- and the number it disagreed with was the one the
     README was actually right about.

  2. IT COULD NOT FAIL.  The verdict was PRINTED and the script returned 0
     unconditionally.  A verifier that cannot fail is a script that prints
     a warning nobody is obliged to read.  The suite reported it as a green
     row with a red sentence in it, which is the worst of both worlds.

  3. IT PINNED A NUMBER INSTEAD OF AN INVARIANT.  The claim worth checking
     is not "the library has 1117 tests" -- that is a fact about today --
     but "the number the README states IS the number the tree has".  That
     invariant survives every future test added or removed.

So the expected numbers are now READ FROM THE README (the document under
audit), and the actual numbers come from the tree, by two independent
methods: the runtime `moon test` count and this static enumeration of the
`test "..."` declarations.  A literal appears nowhere.

WHAT IS NOT CHECKED HERE
========================
The RUNTIME half of the pair lives in the CI gate: it runs `moon test` on
all four backends and prints a `Total tests: N, passed: N, failed: 0.`
line.  This script does not re-run the suite -- it enumerates.  The two are
independent (execution vs enumeration), which is what makes their agreement
worth something, and the gate's own transcript is where the runtime number
is recorded.

Run: python _verify/_verify_testcounts_1610.py
"""
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
TEST = re.compile(r'\btest\s+"([^"]+)"')

NATIVE_ROW = re.compile(r"\| Tests \(native / wasm / js\) \| \*\*(\d+)")
WASMGC_ROW = re.compile(r"\| Tests \(wasm-gc\) \| \*\*(\d+)")
DOC_COUNT = re.compile(r"lib \+ (\d+) doc tutorial")
TRANSCRIPT = re.compile(r"Total tests: (\d+), passed: (\d+), failed: (\d+)")

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %-62s %s" % (name, "OK" if ok else "*** FAIL ***"))
    if not ok:
        FAILS.append(name)
        if detail:
            print("        %s" % detail)


def declarations(directory):
    """The `test "..."` declarations under a directory, by name."""
    acc = set()
    for base, dirs, files in os.walk(os.path.join(ROOT, directory)):
        dirs[:] = [x for x in dirs if x not in ("_build", "_verify", "target", ".git")]
        for f in files:
            if f.endswith(".mbt"):
                src = open(os.path.join(base, f), encoding="utf-8", errors="replace").read()
                acc.update(TEST.findall(src))
    return acc


lib = declarations("moonbit_doubleML")
doc = declarations("doc")
readme = open(README, encoding="utf-8", errors="replace").read()

print("lib test declarations      = %d" % len(lib))
print("doc test declarations      = %d" % len(doc))
print("lib + doc                  = %d" % (len(lib) + len(doc)))
print()

# --- 1. the Status table's native / wasm / js row -------------------------- #
m = NATIVE_ROW.search(readme)
stated_native = int(m.group(1)) if m else None
check("the README states the native / wasm / js test count",
      stated_native is not None, "row not found" if m is None else str(stated_native))
check("the README's native / wasm / js count is the tree's lib count",
      stated_native == len(lib),
      "README says %s, the tree has %d" % (stated_native, len(lib)))

# --- 2. the Status table's wasm-gc row ------------------------------------- #
m = WASMGC_ROW.search(readme)
stated_gc = int(m.group(1)) if m else None
check("the README states the wasm-gc test count",
      stated_gc is not None, "row not found" if m is None else str(stated_gc))
check("the README's wasm-gc count is the tree's lib + doc count",
      stated_gc == len(lib) + len(doc),
      "README says %s, the tree has %d" % (stated_gc, len(lib) + len(doc)))

# --- 3. the "+ N doc tutorials" the wasm-gc row attributes ----------------- #
m = DOC_COUNT.search(readme)
stated_doc = int(m.group(1)) if m else None
check("the README's doc-tutorial count is the tree's doc count",
      stated_doc == len(doc),
      "README says %s, the tree has %d" % (stated_doc, len(doc)))

# --- 4. the two rows agree with each other --------------------------------- #
check("the README's two rows are consistent with each other",
      stated_native is not None and stated_doc is not None
      and stated_gc == stated_native + stated_doc,
      "%s + %s vs %s" % (stated_native, stated_doc, stated_gc))

# --- 5. the Quick Start transcript ----------------------------------------- #
transcripts = TRANSCRIPT.findall(readme)
bad = [t for t in transcripts if int(t[0]) != len(lib) or t[1] != t[0] or t[2] != "0"]
check("every 'Total tests: N, passed: N, failed: 0.' in the README is the "
      "tree's lib count",
      bool(transcripts) and not bad,
      "%d transcript(s), %d wrong" % (len(transcripts), len(bad)))

print()
print("=" * 74)
print("checks: %d   failures: %d" % (N, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)
print("ALL PASS")
