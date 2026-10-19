"""Derive the estimator census from the source and diff it against the README.

The README makes four related claims in two places:

  * "**22** `DoubleML*` estimator structs"           (Status table)
  * "22 `DoubleML*` estimators ... in 19 source files" (Features)
  * the Features paragraph's list of 22 names
  * the Models table: 22 rows, 20 marked *(upstream)*, 1 *(upstream, renamed)*,
    1 *(no upstream counterpart)*

All four can be derived from the source: an estimator is a `DoubleML*` struct
with a public `::new`, and the file it lives in is the file that defines it.
"""
import collections
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LIB = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

# ----------------------------------------------------------------- the census
files = sorted(f for f in os.listdir(LIB) if f.endswith(".mbt"))
blackbox = [f for f in files if f.endswith("_test.mbt")]
whitebox = [f for f in files if f.endswith("_wbtest.mbt")]
production = [f for f in files
              if f not in blackbox and f not in whitebox]

# an estimator is a struct with a public constructor. The `*Data` structs have
# one too, and are NOT estimators: the repo's own census is "22 estimators /
# 34 `DoubleML*` structs less 12 `*Data`".
est_file = {}
for name in files:
    src = io.open(os.path.join(LIB, name), encoding="utf-8", errors="replace").read()
    for m in re.finditer(r"pub fn (DoubleML\w+)::new\(", src):
        # the first ::new for a struct defines it; later ones are helpers
        est_file.setdefault(m.group(1), name)

all_structs = sorted(est_file)
data_structs = [s for s in all_structs if s.endswith("Data")]
ests = [s for s in all_structs if not s.endswith("Data")]
print("DoubleML* structs with a public ::new : %d" % len(all_structs))
print("  of which *Data (not estimators)       : %d" % len(data_structs))
print("estimators                             : %d" % len(ests))
print(".mbt files: %d total = %d production + %d blackbox + %d whitebox"
      % (len(files), len(production), len(blackbox), len(whitebox)))
print("source files holding the estimators     : %d" % len(set(est_file[s] for s in ests)))
print("")

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# --------------------------------------------------------- the file census
check("220 .mbt files", len(files) == 220, "got %d" % len(files))
check("65 production .mbt files", len(production) == 65, "got %d" % len(production))
check("129 blackbox test .mbt files", len(blackbox) == 129, "got %d" % len(blackbox))
check("26 whitebox test .mbt files", len(whitebox) == 26, "got %d" % len(whitebox))
check("the three parts add up",
      len(production) + len(blackbox) + len(whitebox) == len(files))

# --------------------------------------------------------- the estimators
check("22 estimators", len(ests) == 22, "got %d: %s" % (len(ests), ests))

n_src_files = len(set(est_file[s] for s in ests))
check("they live in 19 source files", n_src_files == 19,
      "got %d: %s" % (n_src_files, sorted(set(est_file[s] for s in ests))))
check("34 DoubleML* structs, 12 of them *Data",
      len(all_structs) == 34 and len(data_structs) == 12,
      "got %d structs / %d data" % (len(all_structs), len(data_structs)))

# the README's Features list
feat = re.search(r"\*\*Pure-MoonBit, all-4-backends port of `doubleml-for-py`\*\* -- 22 "
                 r"`DoubleML\*`\s*\nestimators \((.*?)\)\s*\nin (\d+) source files",
                 readme, re.S)
check("the Features paragraph is findable", feat is not None)
if feat:
    names = re.findall(r"`(DoubleML\w+)`", feat.group(1))
    print("")
    print("  Features list: %d names" % len(names))
    check("the Features list has 22 names", len(names) == 22, "got %d" % len(names))
    check("the Features list has no duplicates", len(set(names)) == len(names))
    check("the Features list matches the source exactly",
          sorted(names) == ests,
          "README: %s / source: %s" % (sorted(names), ests))
    check("the Features paragraph says '19 source files'",
          feat.group(2) == "19", "says %s" % feat.group(2))

# ------------------------------------------------------------ Models table
# rows look like: | `DoubleMLPLR` | partialling-out | partially linear regression *(upstream)* |
# the score column is prose, not a fixed vocabulary (ATE, LATE, MAR, IV, CVaR,
# policy score, quantile, local polynomial, ...), so match it loosely.
rows = re.findall(r"^\|\s*`(DoubleML\w+)`\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$",
                   readme, re.M)
model_rows = [(n, sc, d) for n, sc, d in rows
               if "upstream" in d or "port-only" in d]
print("")
print("  Models table rows: %d" % len(model_rows))
check("the Models table has 22 rows", len(model_rows) == 22, "got %d" % len(model_rows))
if model_rows:
    mnames = [n for n, _, _ in model_rows]
    check("the Models table names the same 22 estimators",
          sorted(mnames) == ests,
          "table: %s / source: %s" % (sorted(mnames), ests))

    # a row "marked (upstream)" carries the marker; it need not END with it
    # (the PolicyTree row continues "... + v0.98.0 honest split (...)").
    plain = [n for n, _, d in model_rows
             if "*(upstream)*" in d and "renamed" not in d and "no upstream" not in d]
    renamed = [n for n, _, d in model_rows if "upstream, renamed" in d]
    portonly = [n for n, _, d in model_rows if "no upstream counterpart" in d]
    print("  *(upstream)*: %d  renamed: %d  port-only: %d"
          % (len(plain), len(renamed), len(portonly)))
    check("20 rows are marked *(upstream)*", len(plain) == 20, "got %d" % len(plain))
    check("exactly one is *(upstream, renamed)*", len(renamed) == 1,
          "got %d: %s" % (len(renamed), renamed))
    check("exactly one is *(no upstream counterpart)*", len(portonly) == 1,
          "got %d: %s" % (len(portonly), portonly))
    check("the three groups cover all 22 rows",
          len(plain) + len(renamed) + len(portonly) == len(model_rows))
    check("the README's '20 are marked (upstream)' matches the table",
          "**20** are marked *(upstream)*" in readme)
    check("the renamed one is DoubleMLRDD", renamed == ["DoubleMLRDD"],
          "got %s" % renamed)
    check("the port-only one is DoubleMLDIDCrossSection",
          portonly == ["DoubleMLDIDCrossSection"], "got %s" % portonly)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
