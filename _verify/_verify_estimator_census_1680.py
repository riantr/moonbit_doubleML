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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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


def upstream_facts():
    """Read the installed upstream package for the facts the provenance
    grouping depends on: each class's docstring and the data classes it uses.

    Returns {class name: {"doc": str, "data": set}}.
    """
    import inspect
    import doubleml
    root = os.path.dirname(inspect.getfile(doubleml))
    out = {}
    for dp, _dn, fns in os.walk(root):
        if os.sep + "tests" in dp:
            continue
        for fn in sorted(fns):
            if not fn.endswith(".py"):
                continue
            ap = os.path.join(dp, fn)
            src = io.open(ap, encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"^class\s+(\w+)\s*[:(]", src, re.M):
                name = m.group(1)
                doc = ""
                dm = re.search(r'"""(.*?)"""', src[m.end():], re.S)
                if dm:
                    doc = " ".join(dm.group(1).split())
                out.setdefault(name, {"doc": doc,
                                      "data": set(re.findall(r"DoubleML\w*Data", src)),
                                      "file": os.path.relpath(ap, root).replace("\\", "/")})
    return out


def file_header(src):
    """The leading comment block of a MoonBit source file.

    That is where a file states what it models -- and it is at the TOP of the
    file, so a window taken from just before the constructor would miss it.
    """
    head = []
    for ln in src.split("\n"):
        s = ln.strip()
        if s.startswith("///") or s.startswith("//"):
            head.append(s)
            continue
        if s == "":
            if head:
                break
            continue
        break
    return " ".join(head)


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
             if "*(upstream)*" in d and "renamed" not in d and "no upstream" not in d
             and "no 1:1" not in d]
    renamed = [n for n, _, d in model_rows if "upstream, renamed" in d]
    variant = [n for n, _, d in model_rows if "no 1:1 class" in d]
    print("  *(upstream)*: %d  renamed: %d  no-1:1-class: %d"
          % (len(plain), len(renamed), len(variant)))

    # ------------------------------------------------------------ provenance
    # The EXPECTED grouping is DERIVED from the installed upstream package and
    # the port's own headers -- not written down as a literal.  The previous
    # version of this file asserted "20 upstream / 1 renamed / 1 port-only",
    # and that literal is precisely what made the README's claim
    # unchallengeable: the README was wrong ("DoubleMLDIDCrossSection has no
    # upstream counterpart"), and this file agreed with it.
    #
    # Round 15 replaced the literal with a derivation of its own, but that
    # derivation could not see a MANY-TO-ONE: it matched the port's
    # `DoubleMLDIDCS` to upstream's `DoubleMLDIDMulti` on a shared design
    # marker ("multi-period"), while ALSO matching the port's
    # `DoubleMLDIDMulti` to upstream's `DoubleMLDIDMulti` by name.  One
    # upstream class, two port estimators.
    #
    # The derivation now used is `_verify/_audit_r16_provenance_1650.py`, and
    # it is the ONLY one in the tree: it decides the correspondence by the
    # upstream class's DISTINGUISHING parameter and then applies the 1:1
    # constraint.  Two derivations in one tree would drift, and two
    # derivations disagreeing is the failure this round exists to repair.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import _audit_r16_provenance_1650 as audit
    derived = audit.derive()

    expected_plain = derived["plain"]
    expected_renamed = derived["renamed"]
    expected_variant = derived["no_upstream_class"]

    print("  derived: plain=%d renamed=%d no-1:1=%d"
          % (len(expected_plain), len(expected_renamed), len(expected_variant)))
    print("  derived renamed pairs: %s" % sorted(expected_renamed.items()))
    check("the derivation covers all 22 estimators",
          len(expected_plain) + len(expected_renamed) + len(expected_variant) == 22,
          "got %d" % (len(expected_plain) + len(expected_renamed)
                     + len(expected_variant)))
    check("no upstream class is claimed by two port estimators",
          derived["upstream_class_claimed_twice"] == [],
          "claimed twice: %s" % derived["upstream_class_claimed_twice"])

    check("the *(upstream)* rows are the derived name-identical ones",
          sorted(plain) == expected_plain,
          "README: %s / derived: %s" % (sorted(plain), expected_plain))
    check("the *(upstream, renamed)* rows are the derived renamed ones",
          sorted(renamed) == sorted(expected_renamed),
          "README: %s / derived: %s" % (sorted(renamed), sorted(expected_renamed)))
    check("the *(no 1:1 class)* rows are the derived ones",
          sorted(variant) == sorted(expected_variant),
          "README: %s / derived: %s" % (sorted(variant), sorted(expected_variant)))
    check("the three groups cover all 22 rows",
          len(plain) + len(renamed) + len(variant) == len(model_rows))
    check("the README's '19 are marked *(upstream)*' matches the table",
          "**19** are marked *(upstream)*" in readme,
          "the table says %d" % len(plain))
    check("the README's renamed count matches the table",
          ("**2** are marked\n*(upstream, renamed)*" in readme
           or "**2** are marked *(upstream, renamed)*" in readme),
          "the table says %d" % len(renamed))
    check("the README names the upstream class of every renamed row",
          all(("upstream `%s`" % u) in readme for u in expected_renamed.values()),
          "expected %s" % expected_renamed)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
