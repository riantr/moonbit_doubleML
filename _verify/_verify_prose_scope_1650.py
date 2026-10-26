#!/usr/bin/env python3
"""Round 48 verifier: the three PROSE-SCOPE defects, and the claims that
replace them.

WHAT THIS EXISTS FOR
====================
A fresh-eyes prose audit of the README (round 48) read the prose sentences and
asked one question of each: does the sentence claim more than the tree
supports?  Three sentences claimed more, and all three were WATCHED claims --
the numbers in them were right, the SCOPE around them was not.  A watched
claim can still be wrong; "a verifier pins this string" says the string
survives, not that it is true.

The three defects
=================
D1  THE ATTRIBUTION PROMISED A COMPARISON THAT DOES NOT EXIST.
    "all three ship upstream, and are compared against it" -- the three being
    `DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary`.  The first is
    NOT compared against upstream.  `validate_plpr_with_python.py` compares
    UPSTREAM's theta against the HAND-ROLLED one, and never against the port's
    estimate; the two sides are also fitted on DIFFERENT rows (numpy's
    `default_rng` against the port's `chacha8_rng`), so the upstream fit is
    not even the port's fit.  And `pyexample_suite.py` -- the only
    `pyexample_*` script that covers a SET of estimators -- does not contain
    `plpr` at all.  So PLPR has NO upstream gate; the other two have one.

D2  THE SMALL-n CAUTION SAID BOTH SIDES FAIL.
    "Both this port and upstream fail there, in opposite directions" is false
    on the gate's own output.  The direction REVERSES with n: at n = 60 the
    port is well-behaved (se 0.76) and upstream is pathological (se 20.2); at
    n = 100 it is exactly the other way round (port se 7.5e5, upstream se
    0.83); at n = 160 neither fails.  "In opposite directions" is not a fixed
    opposition, it is a reversal -- and the upstream half of the claim (upstream
    really is ill-posed there) survives.

D3  "RUN UPSTREAM'S OWN CODE" IS FALSE FOR ONE OF THE NINE.
    The `pyexample_*` family is the UPSTREAM gate, and the README says the
    nine scripts "run upstream's own code".  Eight of them import the
    `doubleml` wheel; ONE -- `pyexample_rdd.py` -- imports `rdrobust`, a
    different package by a different route.  A reader who takes "upstream" to
    mean `doubleml-for-py` is wrong for one of the nine.

WHY THIS CHECKS THE TREE, NOT THE STRING
========================================
Each defect is fixed by a sentence, and a sentence can be fixed by a sentence.
So every check here is tied to something MEASURED:

  * the SET of estimators with an upstream gate is DERIVED from the
    `pyexample_*` scripts -- which estimator names appear in which script --
    and the README's roster is compared with it;
  * the small-n DIRECTION is DERIVED from the gate's own measured rows (the
    three `n=60 / 100 / 160` lines the gate prints on every run), by parsing
    the standard errors and asking which side is pathological at each n;
  * the reference package of each gate is DERIVED from the scripts' own
    imports.

A README that re-breaks any of the three fails here even if every other
check in the tree stays green.
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

READMEs = ["README.mbt.md", os.path.join("moonbit_doubleML", "README.mbt.md")]
flat = {}
raw = {}
for name in READMEs:
    with io.open(os.path.join(ROOT, name), encoding="utf-8") as fh:
        text = fh.read()
    raw[name] = text
    flat[name] = re.sub(r"\s+", " ", text)
readme = flat["README.mbt.md"]
readme_raw = raw["README.mbt.md"]

fails = []
NCHECK = 0


def check(label, cond, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-64s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        if detail:
            print("      %s" % detail)
        fails.append(label)


def read(path):
    with io.open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# the derivation: which estimators have an upstream gate
# ---------------------------------------------------------------------------
print("")
print("== the upstream-gated estimator set, derived from the pyexample scripts ==")

PYEX = sorted(f for f in os.listdir(ROOT)
               if f.startswith("pyexample_") and f.endswith(".py"))
check("the tree has nine pyexample gates", len(PYEX) == 9, "got %d: %s" % (len(PYEX), PYEX))

# The ESTIMATORS the package ships, from the source.  The `DoubleML*`
# structs also include the twelve `*Data` types, which are NOT estimators --
# the estimator table lists 22, and the census verifier owns the split.
SRC = os.path.join(ROOT, "moonbit_doubleML")
all_structs = set()
for dirpath, _dirnames, filenames in os.walk(SRC):
    for fn in filenames:
        if not fn.endswith(".mbt"):
            continue
        with io.open(os.path.join(dirpath, fn), encoding="utf-8",
                     errors="replace") as fh:
            src = fh.read()
        for m in re.finditer(r"pub\s+struct\s+(DoubleML\w+)\s*\{", src):
            all_structs.add(m.group(1))
ests = {n for n in all_structs if not n.endswith("Data")}
check("the source has 34 `DoubleML*` structs, 22 of them estimators",
      len(all_structs) == 34 and len(ests) == 22,
      "got %d structs / %d estimators" % (len(all_structs), len(ests)))

# Which estimator does each gate touch?  The gates are the UPSTREAM reference
# family: an estimator named in one of them has an upstream gate.
gated = {}
for f in PYEX:
    src = read(f)
    named = sorted(n for n in ests if n in src)
    gated[f] = named
union = sorted({n for names in gated.values() for n in names})
print("   gates: %s" % {os.path.basename(f): len(gated[f]) for f in PYEX})

check("`DoubleMLPLPR` has NO upstream gate",
      "DoubleMLPLPR" not in union,
      "gated: %s" % union)
check("`DoubleMLLPLR` HAS an upstream gate",
      "DoubleMLLPLR" in union, "gated: %s" % union)
check("`DoubleMLDIDCSBinary` HAS an upstream gate",
      "DoubleMLDIDCSBinary" in union, "gated: %s" % union)
check("`pyexample_suite.py` does not mention PLPR",
      "plpr" not in read("pyexample_suite.py").lower()
      and "DoubleMLPLPR" not in read("pyexample_suite.py"))

# ---------------------------------------------------------------------------
# D1 -- the Attribution
# ---------------------------------------------------------------------------
print("")
print("== D1: the Attribution's comparison claim ==")

for name in READMEs:
    f = flat[name]
    check("%s names the two that ARE compared against upstream" % name,
          "are compared against upstream's own classes" in f)
    check("%s says PLPR has no upstream gate" % name,
          "PLPR has no upstream gate" in f)
    check("%s does not claim all three are compared against it" % name,
          "all three ship upstream, and are compared against it" not in f)
    check("%s still says all three ship upstream" % name,
          "all three ship upstream" in f)

# ---------------------------------------------------------------------------
# D2 -- the small-n caution
# ---------------------------------------------------------------------------
print("")
print("== D2: the small-n direction ==")

lplr = read("pyexample_lplr.py")
rows = {}
for m in re.finditer(
        r"n=(\d+)\s+port\s+(-?[\d.e+-]+)\s+se\s+(-?[\d.e+-]+)\s*\|\s*"
        r"upstream\s+(-?[\d.e+-]+)\s+se\s+(-?[\d.e+-]+)", lplr):
    rows[int(m.group(1))] = (float(m.group(3)), float(m.group(5)))
check("the gate records the three small-n rows", set(rows) >= {60, 100, 160},
      "got %s" % sorted(rows))


def pathological(se_port, se_up):
    """Which side's standard error is pathological.

    A side is pathological when its standard error is BOTH large in absolute
    terms (a finite estimate with a standard error of 0.76 is not a failure)
    and much larger than the other side's.  The threshold is 10 on both
    counts: at n = 60 upstream's 20.1991 against the port's 0.762404 is a
    26x separation, and at n = 100 the port's 751657 against upstream's
    0.832026 is a 900 000x one -- while at n = 160 neither side is above 1.
    """
    a, b = se_port, se_up
    if a > 10 and a >= 10 * b:
        return "port"
    if b > 10 and b >= 10 * a:
        return "upstream"
    return "neither"


if set(rows) >= {60, 100, 160}:
    at60 = pathological(rows[60][0], rows[60][1])
    at100 = pathological(rows[100][0], rows[100][1])
    at160 = pathological(rows[160][0], rows[160][1])
    print("   n=60 pathological: %s | n=100: %s | n=160: %s" % (at60, at100, at160))
    check("at n=60 UPSTREAM is the pathological one", at60 == "upstream", at60)
    check("at n=100 the PORT is the pathological one", at100 == "port", at100)
    check("at n=160 NEITHER side is pathological", at160 == "neither", at160)
    check("the direction REVERSES between n=60 and n=100",
          at60 != at100 and "neither" not in (at60, at100))

for name in READMEs:
    f = flat[name]
    check("%s does not claim both sides fail in opposite directions" % name,
          "Both this port and upstream fail there, in opposite directions" not in f)
    check("%s says which side breaks depends on n" % name,
          "Which side breaks depends on n" in f)
    check("%s still warns that n < 200 is ill-posed" % name,
          "Treat `n < 200` as ill-posed for partially logistic regression" in f)

# ---------------------------------------------------------------------------
# D3 -- which reference each gate uses
# ---------------------------------------------------------------------------
print("")
print("== D3: the reference package of each upstream gate ==")

uses_doubleml, uses_rdrobust = [], []
for f in PYEX:
    src = read(f)
    if re.search(r"^\s*(?:from|import)\s+doubleml\b", src, re.M) \
            or re.search(r"\bdoubleml\.", src):
        uses_doubleml.append(f)
    if re.search(r"\brdrobust\b", src):
        uses_rdrobust.append(f)
print("   doubleml: %s" % uses_doubleml)
print("   rdrobust : %s" % uses_rdrobust)

check("eight of the nine gates import the doubleml wheel", len(uses_doubleml) == 8,
      "got %d: %s" % (len(uses_doubleml), uses_doubleml))
check("exactly one gate references rdrobust", len(uses_rdrobust) == 1,
      "got %d: %s" % (len(uses_rdrobust), uses_rdrobust))
check("the rdrobust gate is pyexample_rdd.py",
      uses_rdrobust == ["pyexample_rdd.py"], str(uses_rdrobust))
check("the rdrobust gate is NOT one of the doubleml gates",
      "pyexample_rdd.py" not in uses_doubleml)

for name in READMEs:
    f = flat[name]
    check("%s does not say the gates all run upstream's own code" % name,
          "scripts instead run upstream's own code" not in f)
    check("%s names the eight doubleml gates" % name,
          "upstream's own `doubleml` classes in eight of them" in f)
    check("%s names the rdrobust arm" % name,
          "`rdrobust` for the RDD arm" in f)

# ---------------------------------------------------------------------------
# the shape filter's own claims
# ---------------------------------------------------------------------------
print("")
print("== the round-48 shape filter ==")

# The estimator table still carries all 22 rows.  (The TABLE is read out of
# the RAW document: flattening the whitespace would destroy its rows.)
table = re.findall(r"^\|\s*`(DoubleML\w+)`\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$",
                   readme_raw, re.M)
trows = [(n, sc, d) for n, sc, d in table if "upstream" in d]
check("the estimator table still has 22 rows", len(trows) == 22, "got %d" % len(trows))
check("the estimator table still names every estimator",
      sorted(n for n, _, _ in trows) == sorted(ests),
      "table: %d / source: %d" % (len(trows), len(ests)))

# The migration paragraph no longer publishes release versions.
mig = re.search(r"The port used to default `ml_m`.*?their `ml_m` default is now", readme)
check("the migration paragraph is findable", mig is not None)
if mig:
    check("the migration paragraph no longer publishes release versions",
          not re.search(r"v\d+\.\d+\.\d+", mig.group(0)),
          mig.group(0)[:160])
    check("the migration paragraph names the seven classifier-defaulted estimators",
          len(set(re.findall(r"`(DoubleML\w+)`", mig.group(0)))) == 7,
          str(sorted(set(re.findall(r"`(DoubleML\w+)`", mig.group(0))))))

# The Features list no longer re-lists the 22 names.
feat = re.search(r"\*\*Pure-MoonBit, all-4-backends port of `doubleml-for-py`\*\*.*?"
                  r"estimators in (\d+) source files", readme, re.S)
check("the Features paragraph is findable", feat is not None)
if feat:
    check("the Features paragraph says 19 source files", feat.group(1) == "19",
          feat.group(1))

print("")
print("%d checks, %d failed" % (NCHECK, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
