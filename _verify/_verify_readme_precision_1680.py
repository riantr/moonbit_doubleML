#!/usr/bin/env python3
"""Round 73 verifier: the README's PRECISE statements about its companions.

WHY THIS EXISTS
===============
Round 73 was a PRECISION round: two INDEPENDENT fresh-eyes audits read the
published README line by line and both returned PASS on every measured value,
so nothing in the document was FALSE.  What they found were four passages that
were LOOSER than the tree supports -- each one true enough to pass a reader
who was not looking for the difference, and each one an invitation to the
wrong conclusion.

  P1  THE `validate_*` PARENTHETICAL.
      The paragraph said the two scripts that gate the port against upstream
      gate it "rather than only against a hand-rolled reference", and then
      gave ONE of them the parenthetical "(the port's ATT against upstream's)"
      while the other said "upstream's *and* the hand-rolled one, together".
      The scripts do not differ that way: BOTH compare the port against
      upstream AND against the hand-rolled reference.  The contrast invited a
      reader to conclude that the first gates upstream only -- which it does
      not.

  P2  THE PROJECT-LAYOUT ROW'S RUN COUNT.
      "12 estimators in 18 runs" counted the 18 BANNERS `examples/main`
      prints.  The driver makes 20 model fits: the two extra per-treatment PQ
      fits print their standard errors and no banner.

  P3  THE DEVELOPMENT SECTION'S DESCRIPTION OF `ENGINEERING.md`.
      It said the header is "the correction ledger for every round to date" --
      the header names the rounds it corrects, and they are not every round --
      and that the body is the old README "word for word", which it is except
      that the old title line is replaced by the heading the body sits under.

  P4  THE LEDGER'S OWN HEADER.
      It claimed "in full and word for word" while dropping the old README's
      title line, and it said nothing about the round numbers not being
      contiguous -- they skip a run in the middle.

WHAT IS CHECKED
===============
  A  the `validate_*` paragraph -- the set of scripts that GATE the port
     against upstream is DERIVED from the scripts themselves (a gate is a
     comparison that feeds a verdict; a printed difference is not a gate),
     and the paragraph must name exactly that set and describe what each of
     them compares against;
  B  the layout row -- both numbers are DERIVED from the driver;
  C  the Development section -- what it says `ENGINEERING.md` IS;
  D  the ledger's header -- one entry per corrected round, the coverage it
     states, and the title line it replaces.

A GATE IS NOT A PRINT
=====================
Three of the seven scripts the paragraph calls "context" -- `validate_irm`,
`validate_iivm` and `validate_pliv` -- PRINT `|moonbit - upstream|` and gate
against the hand-rolled reference only.  So the rule here is: a comparison
counts when it feeds a verdict, which is what a FAIL line is.  The seven
scripts' sources are read with that rule and the paragraph's split is checked
against the result.

Run: python _verify/_verify_readme_precision_1680.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

README = os.path.join(ROOT, "README.mbt.md")
LEDGER = os.path.join(ROOT, "ENGINEERING.md")

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


readme = read(README)
flat = re.sub(r"\s+", " ", readme)
ledger = read(LEDGER)

# ==========================================================================
# A.  the `validate_*` paragraph
# ==========================================================================
print()
print("A. the validate_* paragraph")

WINDOW = 4
PORT = re.compile(r"MoonBit|\bmb\b|mb\[|mb_", re.I)
UP = re.compile(r"upstream|\bup\b|up\[|up_|_up\b", re.I)
HR = re.compile(r"hand-?rolled|\bhr\b|hr\[|hr_|_hr\b", re.I)
# a VERDICT, not prose: "FAILS CLOSED" is a sentence, "FAIL" is a verdict
VERDICT = re.compile(r"\bFAIL\b|ok\s*=\s*False|raise SystemExit|assert ")

VALIDATE_DIR = ROOT


def gates_against(path, ref):
    """the verdict lines whose context compares the port with `ref`."""
    lines = read(path).split("\n")
    hits = []
    for i, l in enumerate(lines):
        if not VERDICT.search(l):
            continue
        ctx = "\n".join(lines[max(0, i - WINDOW):i + 1])
        if PORT.search(ctx) and ref.search(ctx):
            hits.append(i + 1)
    return hits


validate_scripts = sorted(f for f in os.listdir(VALIDATE_DIR)
                          if f.startswith("validate_") and f.endswith(".py"))
upstream_gaters = []
for f in validate_scripts:
    if gates_against(os.path.join(VALIDATE_DIR, f), UP):
        upstream_gaters.append(f)
        hand = bool(gates_against(os.path.join(VALIDATE_DIR, f), HR))
        print("    %-42s gates upstream AND hand-rolled: %s"
              % (f, "yes" if hand else "NO"))

check("exactly two validate_* scripts gate the port against upstream",
      len(upstream_gaters) == 2,
      "the rule finds %d: %s" % (len(upstream_gaters), upstream_gaters))
check("both of them gate the port against the hand-rolled reference as well",
      all(gates_against(os.path.join(VALIDATE_DIR, f), HR)
          for f in upstream_gaters),
      "one of them gates against upstream only")

# the paragraph
para = ""
m = re.search(r"The `validate_\*` family is not exclusively ours.*?separately "
              r"gated rows\.", flat)
if m:
    para = m.group(0)
check("the validate_* paragraph was found", bool(para),
      "the paragraph is not in the README")

check("the paragraph names validate_did_cs_binary_with_python.py",
      "validate_did_cs_binary_with_python.py" in para)
check("the paragraph names validate_lplr_with_python.py",
      "validate_lplr_with_python.py" in para)
check("the paragraph says the gating scripts compare against upstream AND "
      "against a hand-rolled reference",
      "against upstream and against a hand-rolled reference" in para,
      "the paragraph does not say both")
check("the old contrast -- one script against upstream alone -- is gone",
      "(the port's ATT against upstream's)" not in para
      and "rather than only against a hand-rolled reference" not in para,
      "the old parenthetical is still there")
check("both scripts are described as comparing against both",
      para.count("against both)") == 2,
      "the paragraph says 'against both' %d times" % para.count("against both)"))

# ==========================================================================
# B.  the project-layout row
# ==========================================================================
print()
print("B. the project layout row")

main = read(os.path.join(ROOT, "examples", "main", "main.mbt"))
banners = len(re.findall(r"=== (.+?) ===", main))
fits = len(re.findall(r"\.fit\(",
                       "\n".join(l for l in main.split("\n")
                                if not l.lstrip().startswith("//"))))
print("    the driver prints %d banners and makes %d model fits"
      % (banners, fits))

check("the layout row states the printed-run count and the model-fit count",
      ("12 estimators in %d printed runs, %d model fits" % (banners, fits))
      in readme,
      "the row does not say '12 estimators in %d printed runs, %d model fits'"
      % (banners, fits))
check("the old count -- 18 runs, with no fit count -- is gone",
      "12 estimators in 18 runs" not in readme,
      "the row still says '12 estimators in 18 runs'")
check("the row still explains the extra printed runs",
      "5 also run with" in flat and "RDD runs twice" in flat)

# ==========================================================================
# C.  the Development section
# ==========================================================================
print()
print("C. the Development section")

d = re.search(r"## Development\n(.*?)(?=\n## |\Z)", readme, re.S)
dev = re.sub(r"\s+", " ", d.group(1)) if d else ""
check("the Development section was found", bool(dev))

check("it says the header is the correction ledger",
      "header is the correction ledger" in dev)
check("it does not claim the ledger covers every round",
      "for every round to date" not in dev,
      "the section still claims 'for every round to date'")
check("it says the ledger has one entry per corrected round",
      "one entry per corrected round" in dev,
      "the section does not say what an entry is")
check("it names the title line the ledger replaces",
      "old title line replaced by the heading above it" in dev,
      "the section does not say the title line is replaced")
check("it does not claim the body is the old README word for word and "
      "nothing else",
      "word for word, with the old title line replaced" in dev,
      "the section claims the body verbatim without the caveat")

# ==========================================================================
# D.  the ledger's own header
# ==========================================================================
print()
print("D. the ledger's header")

banner = ledger.split("## The README as it stood at", 1)[0]
rounds = [int(x) for x in re.findall(r"\*\*Round (\d+)\.\*\*", banner)]
distinct = sorted(set(rounds))
print("    the banner names %d entries over %d rounds (%d..%d)"
      % (len(rounds), len(distinct), distinct[0], distinct[-1]))

check("the banner has one entry per corrected round",
      len(rounds) == len(distinct),
      "%d entries over %d rounds" % (len(rounds), len(distinct)))

gap = [n for n in range(distinct[0], distinct[-1] + 1) if n not in distinct]
flatbanner = re.sub(r"\s+", " ", banner)
check("the banner states that its round numbers are not contiguous",
      "round numbers below are not contiguous" in flatbanner,
      "the banner says nothing about the numbering")
if gap:
    runs = []
    start = prev = gap[0]
    for n in gap[1:]:
        if n == prev + 1:
            prev = n
            continue
        runs.append((start, prev))
        start = prev = n
    runs.append((start, prev))
    span = ", ".join(("rounds %d-%d" % (a, b)) if a != b else ("round %d" % a)
                     for a, b in runs)
    check("the banner's coverage matches the rounds it names",
          ("at round %d and run to round %d, and %d of the numbers in between"
           % (distinct[0], distinct[-1], len(gap))) in flatbanner
          and span in flatbanner,
          "the banner does not state %d..%d with %d unused (%s)"
          % (distinct[0], distinct[-1], len(gap), span))
else:
    check("the banner's coverage matches the rounds it names",
          "round numbers below are contiguous" in flatbanner)

check("the banner's 'in full and word for word' names the title line",
      "its title line aside" in flatbanner,
      "the banner still claims the old README in full, word for word")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)
print("ALL PASS")
