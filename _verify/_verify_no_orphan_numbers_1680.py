#!/usr/bin/env python3
"""Round 73 verifier: no NUMBER in the README is an orphan.

THE PROBLEM THIS SOLVES
========================
The README states a lot of numbers -- counts, versions, measured margins,
thresholds, line numbers in source files, seeds.  For twenty rounds those
numbers were audited ONE AT A TIME, by a human reading the document and
asking "is this still true?".  That works, until the day it does not: round
21 found three measured margins in the README that had been wrong since
v0.132.0, because nobody had gone back to the paragraph to ask.

Round 21 answered that with a MAP
(`_verify/_verify_number_coverage_1650.py`): every number in the README lands
in one of three buckets -- GUARDED, DERIVED, or WITNESSED.

THE GAP THIS FILLS
==================
The WITNESSED bucket is the weak one.  A witness is "a tracked file that
records the number", and a tracked file may be a SOURCE file that happens to
contain the same digits -- a line number, a column count, a constant.  So a
number can be accounted for by an accident.

The stronger property is the one this file checks:

    every number in the README's prose is NAMED by a tracked file under
    `_verify/` that READS the README.

A file that reads the document and names the number is holding it; one that
does not read the document is not holding it, whatever else it says.
Measured on the tree as it stood when this file was written: 88 distinct
numbers in the README's prose, 117 tracked files read it, and NOT ONE number
was unheld.

WHO IS A READER
===============
A tracked `.py` under `_verify/` whose source names a README path -- the same
rule `_verify/_verify_number_coverage_1650.py` uses, so the two agree about
who reads the document.  That set includes the DRY-RUN DRIVERS, and the file
says so out loud: a driver names the numbers it breaks, so a number only a
driver names is held WEAKLY.  The gate reports those separately, and the
count is printed with the run.

"NAMED" IS A PROXY, AND THE HOUSE SAYS SO OUT LOUD
===================================================
This file cannot tell a number that is NAMED ON PURPOSE from one that is
mentioned in passing -- a digit that happens to appear in a verifier's source
counts.  That is the same proxy the round-21 map uses, and the repo enforces
the stronger property separately: a tracked verifier must be ABLE TO FAIL
(`_verify/_verify_suite_bites_1650.py`).  Together they mean a number is
either under a test that can bite, or it is unheld -- and an unheld number is
a FAILURE here.

This file is EXCLUDED from the reader set.  A verifier that guards itself is
circular: it would vouch for every number it happens to mention.

WHAT IS ALLOWED TO BE UNNAMED
=============================
  * a citation YEAR -- four digits between 1900 and 2100.  A year is a date,
    not a count about the library's behaviour, and every release rewrites the
    ones that are versions.
  * anything inside a FENCED block -- a transcript's own output is a record
    of what a program printed, not a claim the README makes.
  * a HEADING -- a heading is a label.

Run: python _verify/_verify_no_orphan_numbers_1680.py
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
SELF = "_verify/_verify_no_orphan_numbers_1680.py"

N = 0
FAILS = []


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %-64s %s" % (name[:64], "OK" if ok else "*** FAIL ***"))
    if not ok:
        FAILS.append(name)
        if detail:
            print("        %s" % detail)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# a NUMBER
#
# A run of digits, not preceded by a letter, a digit, a dot or an underscore,
# and not followed by a digit.  So a version ("0.164.56") reads as no number
# at all -- the leading "0" is followed by a dot and a digit, and every other
# part is preceded by a dot -- and a figure with a thousands separator
# ("1,117") reads as ONE number.
# ---------------------------------------------------------------------------
NUM = re.compile(r"(?<![A-Za-z0-9_.])(\d{1,3}(?:[,_]\d{3})+|\d+)(?![0-9])")

# a citation YEAR.  The bounds are four-digit literals on purpose: a bound
# written as two digits would put those digits in this file's own source, and
# this file is excluded from the reader set -- but the habit is worth keeping,
# because the next verifier to read these numbers will not be.
YEAR = re.compile(r"^(19|20)\d{2}$")

# ---------------------------------------------------------------------------
# the README's prose
# ---------------------------------------------------------------------------
lines = read(README).split("\n")
in_code = False
prose = []          # (line number, [numbers], text)
for i, l in enumerate(lines, 1):
    if l.lstrip().startswith("```"):
        in_code = not in_code
        continue
    if in_code:
        continue                      # a transcript's own output is not a claim
    if l.startswith("#"):
        continue                      # a heading is a label
    nums = [n for n in NUM.findall(l) if not YEAR.match(n.replace(",", ""))]
    if not nums:
        continue
    prose.append((i, nums, l.strip()))

all_numbers = set()
for _i, nums, _l in prose:
    all_numbers.update(nums)
print()
print("A. the README's prose numbers")
check("the README has number-bearing prose", len(prose) > 0,
      "%d prose lines carry a number" % len(prose))
print("  %d prose lines, %d distinct numbers" % (len(prose), len(all_numbers)))

# ---------------------------------------------------------------------------
# the readers
#
# A verifier READS the README if it names a README path -- the same rule
# `_verify/_verify_number_coverage_1650.py` uses, so the two agree about who
# is a reader.
# ---------------------------------------------------------------------------
tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace").stdout.split()
readers = {}
for rel in sorted(tracked):
    if not rel.startswith(VD + "/") or not rel.endswith(".py"):
        continue
    if rel == SELF:
        continue                      # a verifier that guards itself is circular
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(path):
        continue
    src = read(path)
    if not re.search(r"README\.mbt\.md|readme\b", src):
        continue
    readers[rel] = set(NUM.findall(src))

print("  %d tracked verifiers read the README" % len(readers))
check("the reader set is not empty", len(readers) > 0,
      "no tracked file under _verify/ reads the README -- the gate would "
      "pass vacuously")
check("the gate is excluded from its own reader set", SELF not in readers,
      "the gate is reading itself")

# ---------------------------------------------------------------------------
# the verdict
# ---------------------------------------------------------------------------
print()
print("B. every number is named by a verifier that reads the README")
orphans = []
for i, nums, l in prose:
    for n in nums:
        if not any(n in r for r in readers.values()):
            orphans.append((i, n, l))

if orphans:
    print("  %d unheld number(s):" % len(orphans))
    for i, n, l in orphans[:20]:
        print("    L%-5d %-10s | %s" % (i, n, l[:92]))
    if len(orphans) > 20:
        print("    ... and %d more" % (len(orphans) - 20))

check("every number in the README's prose is named by a README-reading "
      "verifier", not orphans,
      "%d unheld: %s" % (len(orphans),
                         ", ".join("%s@L%d" % (n, i) for i, n, _l in orphans[:8])))

# ---------------------------------------------------------------------------
# the weak holders
#
# The readers are every tracked `.py` under `_verify/` that reads the README.
# Among them, the VERIFIERS are the ones the house calls verifiers -- the
# files named `_verify_*.py`.  A number named ONLY by something else -- a dry
# run driver, which holds the numbers it breaks, or a build script -- is held
# WEAKLY.  It is not a failure: the number IS named by something that reads
# the README.  It is reported, because the house's rule is that a number
# nothing holds rots in silence, and a number held by one script is one step
# from silence.
# ---------------------------------------------------------------------------
VERIFIER = re.compile(r"^_verify_[A-Za-z0-9_]+\.py$")
verifiers = {rel: nums for rel, nums in readers.items()
             if VERIFIER.match(os.path.basename(rel))}
weak = sorted(n for n in all_numbers
              if any(n in s for s in readers.values())
              and not any(n in s for s in verifiers.values()))
print()
print("C. the weak holders")
print("  %d reader(s), of which %d are verifiers (_verify_*.py)"
      % (len(readers), len(verifiers)))
if weak:
    print("  %d number(s) are named ONLY by something that is not a verifier:"
          % len(weak))
    for n in weak:
        where = sorted(rel for rel, s in readers.items() if n in s)
        print("    %-10s  %s" % (n, ", ".join(os.path.basename(w) for w in where)))
else:
    print("  every number is named by a VERIFIER as well")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)
print("ALL PASS")
