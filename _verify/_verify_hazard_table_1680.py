"""Keep the README's per-estimator hazard table honest, mechanically.

The table has three moving parts, and each of them rotted at least once:

  * the set of estimators whose propensity default is OLS vs a classifier --
    derived from source, not from prose;
  * the split of that set into "hazardous" and "kept its OLS default";
  * the DID family, whose verdict ("not demonstrated", doubly robust) was
    measured in v0.137.0 but was missing from the table entirely.

The v0.163.9 round found the framing sentence wrong in three ways at once:
it called the table's eleven rows "all eleven remaining defaults ... measured
in v0.137.0" (they are not -- four were measured in v0.132.0-v0.136.0), it
said "the other eight keep their OLS default" in a present tense that no
longer held for four of them, and it never mentioned the five DID
estimators that were part of the v0.137.0 eleven.

This derives the sets from source and diffs them against the prose.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

# `ml_m` is the propensity slot for most estimators; PLR calls the same role
# `learner_m`. Both are "the propensity default" for the purpose of this table.
DEF = re.compile(r"(ml_m|learner_m)~?\s*:\s*LearnerDispatch\s*=\s*LearnerDispatch::(\w+)")
NEW = re.compile(r"pub fn (DoubleML\w+)::new\(")

ols, clf = {}, {}
for name in sorted(os.listdir(LIB)):
    if not name.endswith(".mbt"):
        continue
    src = io.open(os.path.join(LIB, name), encoding="utf-8", errors="replace").read()
    for m in DEF.finditer(src):
        owners = NEW.findall(src[:m.start()])
        owner = owners[-1] if owners else "(unknown in %s)" % name
        if m.group(2) == "linear_regression":
            ols.setdefault(owner, set()).add(m.group(1))
        else:
            clf.setdefault(owner, set()).add(m.group(1))

ols_names = sorted(ols)
clf_names = sorted(clf)
print("propensity default is OLS (%d): %s" % (len(ols_names), ", ".join(ols_names)))
print("propensity default is a classifier (%d): %s" % (len(clf_names), ", ".join(clf_names)))
print("")

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# ---------------------------------------------------------------- the table
# rows look like: | `DoubleMLIRM` | hazardous | coef `-225.86` vs `1.44` |
row_re = re.compile(r"^\|\s*(`DoubleML\w+`(?:, `DoubleML\w+`)*)\s*\|\s*(.+?)\s*\|", re.M)
table_rows = {}
for m in row_re.finditer(readme):
    names = re.findall(r"`(DoubleML\w+)`", m.group(1))
    # the "OLS default" column is the one that names a verdict; the cell may be
    # bold (`**hazardous -- fixed in v0.139.0**`), so strip the emphasis before
    # testing what it says.
    verdict = m.group(2).replace("**", "").strip()
    if verdict.lower().startswith(("hazardous", "not demonstrated")):
        for n in names:
            table_rows[n] = verdict

check("the hazard table was parsed (%d estimators)" % len(table_rows),
      len(table_rows) >= 16,
      "parsed: %s" % sorted(table_rows))

# ------------------------------------------------- the "six hazardous" claim
m = re.search(r"\*\*Six rows turned out hazardous\*\*:(.*?)\. All six default to a "
              r"classifier today\.", readme, re.S)
check("the 'Six rows turned out hazardous' sentence is findable", m is not None)
hazardous = re.findall(r"`(DoubleML\w+)`", m.group(1)) if m else []

# LPLR is the one classifier-defaulted estimator that is NOT a hazard: its
# degenerate SE is a different failure, root-caused in v0.140.0-v0.142.0.
expected_hazardous = sorted(n for n in clf_names if n != "DoubleMLLPLR")
check("'Six' is the right count (%d)" % len(expected_hazardous),
      len(hazardous) == len(expected_hazardous) == 6,
      "README names %d, source says %d" % (len(hazardous), len(expected_hazardous)))
check("the six named are exactly the classifier-defaulted non-LPLR estimators",
      sorted(hazardous) == expected_hazardous,
      "README: %s / source: %s" % (sorted(hazardous), expected_hazardous))
check("every one of the six is in the table with a 'hazardous' verdict",
      all(table_rows.get(n, "").lower().startswith("hazardous") for n in hazardous),
      "table: %s" % {n: table_rows.get(n) for n in hazardous})

# ------------------------------------------- the "kept their OLS default" claim
# The four names and the anchor must be in the SAME SENTENCE, so the gap
# between them may not contain a period.  This used to be a lazy `.*?`, and
# that was a latent bug: it let the four names come from ANY earlier run of
# four backticked estimators, and then walk forward to the anchor.
#
# It stayed hidden because the README happened to break the earlier run
# across a line -- "`DoubleMLAPO`,\n`DoubleMLAPOS`" -- and the pattern wants
# "`, `".  Round 76 re-wrapped a nearby sentence, the run became contiguous,
# and the check read `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and
# `DoubleMLSSM` -- the four HAZARDOUS estimators -- as the four that kept
# their OLS default.  The README was right and the checker was wrong.
#
# So the rule is now: no period between the names and the anchor.  The real
# sentence reads "`DoubleMLDIDBinary`, `DoubleMLCVAR`, `DoubleMLIIVM` and
# `DoubleMLPLR` (whose propensity role is `learner_m`, not `ml_m`) kept their
# OLS default **on measured evidence**", and the gap there is a parenthetical
# with no period in it.
KEPT_RE = re.compile(r"`(DoubleML\w+)`, `(DoubleML\w+)`, `(DoubleML\w+)` and `(DoubleML\w+)`[^.]*?"
                     r"kept their OLS default \*\*on\s+measured evidence\*\*", re.S)


def kept_names(text):
    """The four estimators the README says kept their OLS default."""
    m = KEPT_RE.search(text)
    return list(m.groups()) if m else []


m2 = KEPT_RE.search(readme)
check("the 'kept their OLS default' sentence is findable", m2 is not None)
kept = list(m2.groups()) if m2 else []
expected_kept = sorted(set(ols_names) & {"DoubleMLDIDBinary", "DoubleMLCVAR",
                                         "DoubleMLIIVM", "DoubleMLPLR"})
check("the four named are exactly the ones still on an OLS propensity default",
      sorted(kept) == expected_kept,
      "README: %s / source: %s" % (sorted(kept), expected_kept))
check("all four are OLS-defaulted in the source right now",
      all(n in ols_names for n in kept),
      "source OLS set: %s" % ols_names)
check("PLR's role is `learner_m`, not `ml_m`",
      "ml_m" not in ols.get("DoubleMLPLR", set())
      and "learner_m" in ols.get("DoubleMLPLR", set()),
      "DoubleMLPLR slots: %s" % sorted(ols.get("DoubleMLPLR", set())))

# ---------------------------------------------------- the control arm
# A checker that has never been shown to fail is a comment.  The bug above was
# invisible because the check had no arm that could see it, so the rule now
# has three: the names and the anchor in one sentence are found; an EARLIER
# four-name run in ANOTHER sentence is not stolen; and a broken anchor is not
# found at all.
print()
print("the control arm: what the rule does with a document it did not write")
GOOD = ("`DoubleMLDIDBinary`, `DoubleMLCVAR`, `DoubleMLIIVM` and `DoubleMLPLR` "
        "(whose propensity role is `learner_m`, not `ml_m`) kept their OLS default "
        "**on measured evidence** -- no flip was warranted.")
STOLEN = ("`DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and `DoubleMLSSM` are the "
          "four hazardous verdicts.  Something else entirely: "
          "`DoubleMLDIDBinary`, `DoubleMLCVAR`, `DoubleMLIIVM` and `DoubleMLPLR` "
          "kept their OLS default **on measured evidence**.")
BROKEN = ("`DoubleMLDIDBinary`, `DoubleMLCVAR`, `DoubleMLIIVM` and `DoubleMLPLR` "
          "(whose propensity role is `learner_m`, not `ml_m`) kept their OLS default "
          "**on some evidence**.")

check("the control document's own sentence is found",
      kept_names(GOOD) == ["DoubleMLDIDBinary", "DoubleMLCVAR", "DoubleMLIIVM",
                            "DoubleMLPLR"],
      "the rule must find the sentence it is written for")
check("an EARLIER four-name run in another sentence is NOT stolen",
      kept_names(STOLEN) == ["DoubleMLDIDBinary", "DoubleMLCVAR", "DoubleMLIIVM",
                             "DoubleMLPLR"],
      "the names must come from the sentence that carries the anchor")
check("a broken anchor is not found at all",
      kept_names(BROKEN) == [],
      "the rule must not find a sentence that is not there")

# ------------------------------------------------------- the DID family row
did_in_source = sorted(n for n in ols_names if n.startswith("DoubleMLDID"))
did_expected = [n for n in did_in_source if n != "DoubleMLDIDBinary"]
check("the table names every DID estimator except DIDBinary (%d)" % len(did_expected),
      all(table_rows.get(n, "").lower().startswith("not demonstrated")
          for n in did_expected),
      "source DID set: %s / table: %s"
      % (did_in_source, {n: table_rows.get(n) for n in did_in_source}))
check("DIDBinary itself is 'not demonstrated' too",
      table_rows.get("DoubleMLDIDBinary", "").lower().startswith("not demonstrated"))

# --------------------------------------------------- the stale framings gone
# Round 18 split the documentation in two, so a withdrawn framing must be
# absent from BOTH: it cannot come back in the document that replaced it.
_proj = ""
_proj_path = os.path.join(ROOT, "ENGINEERING.md")
if os.path.exists(_proj_path):
    _proj = io.open(_proj_path, encoding="utf-8").read()
_both = readme + "\n" + _proj
check("'the other eight' is gone", "other eight" not in _both)
check("'eleven remaining' is gone", "eleven remaining" not in _both)
check("the sentence no longer claims all eleven were measured in v0.137.0",
      "All eleven remaining defaults were measured in v0.137.0" not in _both)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
