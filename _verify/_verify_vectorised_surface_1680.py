#!/usr/bin/env python3
"""Hold the README's VECTORISED SURFACE -- the helpers, and who calls them.

WHY THIS EXISTS
===============
The README's Cross-fitting section names the public free functions
`vectorized.mbt` exports, and says which estimators route their residual
extraction through `vector_subtract`.  Until round 72 that claim was HELD BY
NOBODY: no tracked verifier read it, so it could rot in silence.

And it did rot.  Measured on the tree at v0.164.55:

  * the README listed FOUR helpers -- `matrix_predict`, `vector_subtract`,
    `vector_add`, `vector_scale`.  The file exports SIX: `vector_multiply`
    and `vector_divide` (both v0.82.0+) were missing from the list;
  * the README named the IRM and PLR paths as the callers of
    `vector_subtract`.  TWELVE library files call it.

So the document told a reader that the public surface was four functions when
it was six, and that one helper was used in two places when it was used in
twelve.  The helpers were added and the document was not, and nothing in the
repository noticed -- which is the whole failure mode this file closes.

WHAT IS CHECKED
===============
  V1  `vectorized.mbt` exists and exports at least one public free function;
  V2  the README has the paragraph that states the surface;
  V3  EVERY exported function is named in it -- a new helper that the
      document does not mention is a failure, which is the rot that happened;
  V4  NO function is named that the file does not export -- a stale name is
      the other half of the same rot;
  V5  the number of library files the README says call `vector_subtract` is
      the MEASURED number;
  V6  the measurement is taken from the tree: the production files that call
      it, excluding the file that defines it and its own test file;
  V7  the paragraph names the file it is about.

WHAT IS DERIVED, NOT ASSERTED
=============================
Every quantity is measured: the exported names come out of `vectorized.mbt`,
and the caller set comes from the library's own sources.  The README's claim
is PARSED OUT OF THE DOCUMENT -- a reworded sentence changes what is checked,
and a paragraph that stops stating the surface simply loses these checks.

WHAT IS NOT CHECKED, AND WHY
============================
  * The helpers' NUMERICAL behaviour -- that `vector_subtract` really
    subtracts -- is the library's own test suite's business, not a prose
    claim's.  `moonbit_doubleML/vectorized_test.mbt` covers it.
  * The historical "v0.81.0+" marker in the paragraph is a record of when the
    file appeared, like a dated measurement: it says which release it is.

Run: python _verify/_verify_vectorised_surface_1680.py
"""
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

PKG = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
VEC = os.path.join(PKG, "vectorized.mbt")

N = 0
FAILS = []


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %-62s %s" % (name[:62], "OK" if ok else "*** FAIL ***"))
    if not ok:
        FAILS.append(name)
        if detail:
            print("        %s" % detail)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ------------------------------------------------------------- the derivation
check("vectorized.mbt is in the tree", os.path.exists(VEC))
if not os.path.exists(VEC):
    print()
    print("=" * 74)
    print("checks: %d   failures: %d" % (N, len(FAILS)))
    sys.exit(1)

src = read(VEC)
EXPORTS = sorted(set(re.findall(r"pub fn (\w+)\s*\(", src)))

CALLERS = []
for f in sorted(os.listdir(PKG)):
    if not f.endswith(".mbt"):
        continue
    if f == "vectorized.mbt" or f.endswith("_test.mbt"):
        continue
    if "vector_subtract" in read(os.path.join(PKG, f)):
        CALLERS.append(f)

print("the exported public free functions: %s" % ", ".join(EXPORTS))
print("the library files that call `vector_subtract`: %d  %s"
      % (len(CALLERS), ", ".join(CALLERS)))
print()

check("vectorized.mbt exports at least one public free function",
      len(EXPORTS) > 0)
check("the caller set is not empty", len(CALLERS) > 0)
check("the defining file is not counted as its own caller",
      "vectorized.mbt" not in CALLERS)
check("the test file is not counted as a caller",
      "vectorized_test.mbt" not in CALLERS)

# ------------------------------------------------------------- the document
readme = read(README)

# the paragraph, BOUNDED to itself.  A regex that stops at the first "today."
# cuts the paragraph short -- and then a claim made AFTER that point cannot be
# seen, which is a check that cannot fail.
para_lines = []
grabbing = False
for l in readme.split("\n"):
    if "**Vectorised cross-fit helpers" in l:
        grabbing = True
    if grabbing:
        if not l.strip() and para_lines:
            break
        para_lines.append(l.strip())
para = " ".join(para_lines)
flat = re.sub(r"\s+", " ", readme)

check("the README states the vectorised surface", bool(para),
      "the Cross-fitting paragraph was not found")

if not para:
    print()
    print("=" * 74)
    print("checks: %d   failures: %d" % (N, len(FAILS)))
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)

check("the paragraph names the file it is about", "`vectorized.mbt`" in para)

missing = [f for f in EXPORTS if ("`%s`" % f) not in para]
check("every exported function is named in the paragraph", not missing,
      "not named: %s" % ", ".join(missing))

named = sorted(set(re.findall(r"`((?:matrix_predict|vector_\w+))`", para)))
stale = [f for f in named if f not in EXPORTS]
check("no function is named that the file does not export", not stale,
      "named but not exported: %s" % ", ".join(stale))

m2 = re.search(r"and (\d+) of the library's own files call it today", para)
stated = int(m2.group(1)) if m2 else None
check("the README states the caller count", stated is not None,
      "the phrase 'N of the library's own files call it today' was not found")
check("the stated caller count is the measured one", stated == len(CALLERS),
      "README says %s, the tree has %d" % (stated, len(CALLERS)))

# the claim is scoped: `matrix_predict` is NOT an element-wise wrapper, so the
# paragraph must not call ALL the helpers element-wise wrappers.
m3 = re.search(r"The helpers are pure element-wise loop wrappers", para)
check("the paragraph does not call matrix_predict element-wise", m3 is None,
      "the phrase 'The helpers are pure element-wise loop wrappers' is stale: "
      "matrix_predict is a matrix-vector product")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)
print("ALL PASS")
