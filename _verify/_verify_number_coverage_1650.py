"""Round 21 verifier: every number in the README has a witness.

THE PROBLEM THIS SOLVES
=======================
The README states a lot of numbers -- counts, versions, measured margins,
thresholds, line numbers in source files, seeds.  For twenty rounds those
numbers were audited ONE AT A TIME, by a human reading the document and
asking "is this still true?".  That works, until the day it does not: round
21 found three measured margins in the README that had been wrong since
v0.132.0, because nobody had gone back to the paragraph to ask.

So this file replaces the case-by-case habit with a MAP.

THE MAP
=======
Every number in the README's prose must land in exactly one of three
buckets, and the buckets are checked, not asserted:

  GUARDED     some tracked verifier reads the README and mentions the
              number.  The number is therefore already under test by
              something that can fail.
  DERIVED     this verifier derives the number itself, from the tree, by a
              rule stated in the code below -- a `file:line` pointer whose
              line must contain the claimed thing, a default that implies
              the figure, a seed that must appear in the harness.
  WITNESSED   the number is recorded somewhere else in this repository, in a
              TRACKED file that is not one of the README copies.  The
              witness must contain the number literally, or contain a value
              that rounds to it -- a historical measurement is usually
              recorded at more precision than the document quotes.

A number in none of the three is a FAILURE.  That is the whole point: a new
figure added to the README has to say where it came from, and a figure whose
verifier was deleted stops being guarded and has to be re-witnessed.

THE LEDGER IS NOT A WITNESS
===========================
`ENGINEERING.md` is deliberately EXCLUDED from the witness set.  It is the
README as it stood at v0.164.11, word for word, so every figure in it is a
copy of a figure that used to be in the README.  Letting the ledger vouch
for the README would make the check circular: it would pass for as long as
both documents said the same wrong thing.

WHAT THIS IS NOT
================
"GUARDED" is a proxy, not a proof.  It says a tracked verifier that reads
the README mentions the number -- not that the verifier would fail if the
number were wrong.  The stronger property is the one the repo already
enforces separately: a tracked verifier must be ABLE to fail (round 20's
`_verify_suite_bites_1650.py`).  The two together mean a number is either
under a test that can bite, or it is witnessed in a file that is tracked.

Run: python _verify/_verify_number_coverage_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

README = "README.mbt.md"
VD = "_verify"

FAILURES = []
CHECKS = 0


def check(label, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print("  PASS  %s" % label)
    else:
        print("  *** FAIL ***  %s%s" % (label, (" -- " + detail) if detail else ""))
        FAILURES.append(label)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ------------------------------------------------------------------ the map
# A number: an integer, a decimal, or a scientific value.  The trailing
# lookahead is "not a digit, and not a dot followed by a digit", so that a
# version ("0.164.13") is not read as three numbers and a figure written
# with a unit ("367x", "10x", "1e6") is not missed.
NUM = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\d]|\.\d)")

# The README quotes versions and dates in many places; they are not claims
# about the library's behaviour and every release step rewrites them.
SKIP_LINE = re.compile(r"v?0\.164\.\d+|20\d\d-\d\d-\d\d|\b20\d\d\b")

# ------------------------------------------------------------------ the input
readme = read(README)
lines = readme.split("\n")

in_code = False
prose = []
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if stripped.startswith("```"):
        in_code = not in_code
        continue
    if in_code:
        continue
    prose.append((i, line))

all_numbers = set()
per_line = []
for i, line in prose:
    if SKIP_LINE.search(line):
        continue
    nums = [n for n in NUM.findall(line) if float(n) >= 2 or "." in n or "e" in n.lower()]
    if not nums:
        continue
    per_line.append((i, nums, line))
    all_numbers.update(nums)

print()
print("A. the README's numbers")
check("the README has number-bearing prose lines", len(per_line) > 0)
print("  %d number-bearing prose lines, %d distinct numbers"
      % (len(per_line), len(all_numbers)))

# ---------------------------------------------------------- the guard set
tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace").stdout.split()
tracked_set = set(tracked)

guarders = {}
SELF = os.path.basename(__file__)
for rel in sorted(tracked):
    if not rel.startswith(VD + "/") or not rel.endswith(".py"):
        continue
    base = os.path.basename(rel)
    if not base.startswith("_verify_"):
        continue
    if base == SELF:
        # a verifier that guards itself is circular: it would vouch for
        # every number it happens to mention
        continue
    src = read(rel)
    if not re.search(r"README\.mbt\.md|readme\b", src):
        continue
    guarders[rel] = src

print("  %d tracked verifiers read the README" % len(guarders))

guarded = set()
for rel, src in guarders.items():
    for n in all_numbers:
        if re.search(r"(?<![\w.])%s(?![\d]|\.\d)" % re.escape(n), src):
            guarded.add(n)

# ------------------------------------------------------------ the derived set
# These are the figures the README states that CAN be re-derived from this
# tree, by a rule this file applies rather than merely remembers.
derived = {}
derived_rules = []


def derive(name, value, how):
    derived[name] = value
    derived_rules.append((name, how))


# 1. `1e6` -- the README says `propensity_clip` (default `1e-6`) "merely caps
#    that at `1e6`".  The cap is 1 / clip, so the figure follows from the
#    default, and the default is in the source.
clip_default = None
for rel in sorted(tracked):
    if not rel.startswith("moonbit_doubleML/") or not rel.endswith(".mbt"):
        continue
    src = read(rel)
    m = re.search(r"propensity_clip\s*~\s*:\s*Double\s*=\s*([0-9.eE+-]+)", src)
    if m:
        clip_default = (rel, float(m.group(1)))
        break
check("the propensity_clip default is in the source", clip_default is not None,
      "no `propensity_clip~ : Double = ...` assignment found")
if clip_default:
    rel, value = clip_default
    cap = 1.0 / value
    derive("1e6", cap, "1 / the propensity_clip default (%s = %g in %s)"
           % (rel, value, rel))
    check("the README's `1e6` is 1 / the propensity_clip default",
          abs(cap - 1e6) < 1e-6 * 1e6,
          "1 / %g = %g" % (value, cap))

# 2. the fuzz seed -- the README says the fuzz harness "replays one fixed
#    seed (20260824)".  The harness must contain that seed.
fuzz = "examples/fuzz/main.mbt"
fuzz_src = read(fuzz) if os.path.exists(fuzz) else ""
m = re.search(r"seed_to_bytes\((\d+)\)", fuzz_src)
check("the fuzz harness names its master seed", m is not None)
if m:
    derive(m.group(1), m.group(1),
           "the seed the fuzz harness passes to chacha8 (%s)" % fuzz)

# 3. `file:line` pointers -- the README cites lines in the port's source and
#    in the vendored upstream.  A pointer is a promise: the line must exist
#    AND must contain the thing the sentence claims.
#
#    Two tiers, because the two kinds of pointer promise different things.
#    A pointer INTO this repository names a file that is tracked, so the
#    check is: the file exists, and the line contains the claim.  A pointer
#    into the UPSTREAM Python package names a file that lives in the
#    installed `doubleml` distribution -- `_verify/_upstream_ps/` is a local
#    copy and is deliberately NOT tracked -- so the promise there is that the
#    pointer is RECORDED in a tracked file of this repository, and the
#    content check runs only when the upstream copy happens to be present.
POINTERS = [
    # label, target, lines, claim, recorder (None when the target is tracked here)
    ("irm.py:157", "_verify/_upstream_ps/doubleml-0.11.4/doubleml/irm/irm.py",
     (157,), "classifier=True", "moonbit_doubleML/irm_wbtest.mbt"),
    ("irm.py:161", "_verify/_upstream_ps/doubleml-0.11.4/doubleml/irm/irm.py",
     (161,), "predict_proba", "moonbit_doubleML/irm_wbtest.mbt"),
    ("did.mbt:708", "moonbit_doubleML/did.mbt", (708,), "w_d = d_i / m_i", None),
    ("ssm.mbt:73-74", "moonbit_doubleML/ssm.mbt", (73, 74), "pi", None),
]
for pointer, target, nums, claim, recorder in POINTERS:
    tracked_here = target in tracked_set
    if not tracked_here:
        # The target is not in this repository, so the promise has to be made
        # somewhere that IS: a tracked file of ours records the pointer.
        rec_src = read(recorder) if os.path.exists(recorder) else ""
        check("the pointer %s is recorded in a tracked file (%s)"
              % (pointer, recorder),
              pointer in rec_src and recorder in tracked_set,
              "%s does not record %s" % (recorder, pointer))
    else:
        check("the pointer %s names a tracked file (%s)"
              % (pointer, target), True)
    # the content: the named line must contain the thing the sentence claims
    if not os.path.exists(target):
        print("  SKIP  %s: %s is not in this checkout (the upstream copy is "
              "local, not tracked) -- the recorded pointer above is the promise"
              % (pointer, target))
        continue
    plines = read(target).split("\n")
    body = "\n".join(plines[nums[0] - 1:nums[-1]])
    check("the pointer %s resolves to content in %s" % (pointer, target),
          claim in body,
          "line %s of %s does not contain %r" % (pointer.split(":")[1],
                                                target, claim))
    for n in nums:
        derive(str(n), n, "the line number in the pointer %s (%s)"
               % (pointer, recorder or target))

# --------------------------------------------------------- the witness set
# The README copies are not witnesses of themselves, and neither is the
# ledger -- see the module docstring.
COPY_FILES = {"README.mbt.md", "README.md",
              "moonbit_doubleML/README.mbt.md", "ENGINEERING.md"}

witness_files = []
for rel in sorted(tracked):
    if rel in COPY_FILES:
        continue
    if not rel.endswith((".md", ".mbt", ".py", ".json", ".txt")):
        continue
    if not os.path.exists(rel):
        continue
    try:
        src = read(rel)
    except OSError:
        continue
    floats = []
    for token in NUM.findall(src):
        try:
            v = float(token)
        except ValueError:
            continue
        if v != v or abs(v) == float("inf"):
            continue
        floats.append(v)
    witness_files.append((rel, src, floats))


def decimals_of(num):
    return len(num.split(".")[1]) if "." in num else 0


def witness_of(num):
    """The first tracked file that records this number -- literally, or by
    holding a value that rounds to it.  A historical measurement is usually
    recorded at MORE precision than the document quotes, so a literal search
    alone would call the README wrong about a figure that is right."""
    pat = re.compile(r"(?<![\w.])%s(?![\d]|\.\d)" % re.escape(num))
    tol = 0.5 * (10 ** (-decimals_of(num)))
    target = float(num)
    for rel, src, floats in witness_files:
        if pat.search(src):
            return rel
        for v in floats:
            if abs(v - target) <= tol:
                return rel
    return None


# -------------------------------------------------------------- the verdict
print()
print("B. every number is guarded, derived, or witnessed")
unaccounted = []
witnessed = {}
for n in sorted(all_numbers):
    if n in guarded or n in derived:
        continue
    w = witness_of(n)
    if w is None:
        unaccounted.append(n)
    else:
        witnessed[n] = w

check("every number in the README is accounted for", not unaccounted,
      "no witness: %s" % unaccounted)

print("  guarded: %d, derived: %d, witnessed: %d, total: %d"
      % (len(guarded & all_numbers), len(set(derived) & all_numbers),
         len(witnessed), len(all_numbers)))

print()
print("C. the witnesses")
for n in sorted(witnessed):
    print("  %-12s <- %s" % (n, witnessed[n]))

print()
print("D. the derived figures")
for name, how in sorted(derived_rules):
    print("  %-12s %s" % (name, how))

print()
print("=" * 72)
print("%d checks, %d failed" % (CHECKS, len(FAILURES)))
if FAILURES:
    print("*** FAIL ***")
    for f in FAILURES:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
