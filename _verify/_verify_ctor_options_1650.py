#!/usr/bin/env python3
"""The README's API reference must name the constructor differences too.

WHAT WAS WRONG
===============
The API reference opens with:

    every estimator is built `DoubleMLXxx::new(...).fit()`, with `n_folds` /
    `n_rep` / `seed` among the labelled options.  The *shape* is uniform;
    the signature and the accessor set are not, and the six exceptions are
    listed here rather than discovered later:

and then lists six estimators -- the ACCESSOR exceptions.  But the
signature differences are a DIFFERENT six, and the two sets overlap in only
three:

    accessor exceptions   DoubleMLAPOS, DoubleMLBLP, DoubleMLDIDCS,
                          DoubleMLDIDMulti, DoubleMLPolicyTree, DoubleMLQTE

    constructor           DoubleMLPQ, DoubleMLQTE, DoubleMLLPQ   (no `n_rep`)
    exceptions            DoubleMLBLP, DoubleMLRDD, DoubleMLPolicyTree
                                                       (no `n_folds`, `n_rep`
                                                        or `seed`)

A reader who looked for `DoubleMLPQ` or `DoubleMLRDD` in that table found
nothing, which is precisely the "discovered later" the sentence promised to
prevent: `DoubleMLPQ::new(data, n_rep = 5)` does not compile, and
`DoubleMLRDD::new(data, n_folds = 2)` does not either.

WHAT IS CHECKED
===============
The groups are DERIVED from the constructors' signatures in the package
source, not written down here, and the README's table is compared against
them.  A literal appears nowhere: adding an estimator, or changing what it
takes, changes what the README must say, and the check says so.

The accessor exceptions are a separate fact and a separate check
(`_verify_api_surface_1640.py` owns it).  This one owns the constructor
half, and it also asserts that the README no longer promises ONE set of
six where there are two.

Run: python _verify/_verify_ctor_options_1650.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %-62s %s" % (name, "OK" if ok else "*** FAIL ***"))
    if not ok:
        FAILS.append("%s -- %s" % (name, detail))
        if detail:
            print("        %s" % detail)


# ---------------------------------------------------------------- the source
src = {}
for base, dirs, files in os.walk(PKG):
    dirs[:] = [d for d in dirs if d not in ("_build", "_verify", "target", ".git")]
    for f in sorted(files):
        if f.endswith(".mbt"):
            src[f] = io.open(os.path.join(base, f), encoding="utf-8", errors="replace").read()

all_src = "\n".join(src.values())
ESTS = sorted(e for e in set(re.findall(r"struct\s+(DoubleML\w+)", all_src))
               if not e.endswith("Data"))

# the constructor signature of each estimator, and the options it takes
OPTIONS = ("n_folds", "n_rep", "seed")
opts = {}
for e in ESTS:
    sig = None
    for t in src.values():
        m = re.search(r"pub fn %s::new\s*\((.*?)\)\s*->" % re.escape(e), t, re.S)
        if m:
            sig = m.group(1)
            break
    if sig is None:
        continue
    opts[e] = tuple(o for o in OPTIONS if re.search(r"\b%s\b" % o, sig))

groups = {}
for e, o in opts.items():
    groups.setdefault(o, []).append(e)

print("estimators: %d" % len(ESTS))
for o in sorted(groups, key=lambda k: -len(groups[k])):
    print("  %-22s %2d  %s" % ("+".join(o) or "(none)", len(groups[o]),
                                ", ".join(sorted(groups[o]))))
print()

# ---------------------------------------------------------------- the README
readme = io.open(README, encoding="utf-8", errors="replace").read()

# the table this check owns: its header row is the contract
m = re.search(r"^\|\s*estimators\s*\|\s*`n_folds`\s*\|\s*`n_rep`\s*\|\s*`seed`\s*\|\s*$"
               r"(.*?)(?:\n[ \t]*\n|\Z)", readme, re.M | re.S)
check("the README's constructor-options table is findable", m is not None)
named_rows = {}       # frozenset of estimators -> the option flags
remainder = None      # the row that names no estimator
if m:
    for line in m.group(1).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 4 or set(cells[0]) <= set("-: "):
            continue
        flags = tuple(c.strip().strip("*").lower() for c in cells[1:])
        names = re.findall(r"`(DoubleML\w+)`", cells[0])
        if names:
            named_rows[tuple(sorted(names))] = flags
        else:
            remainder = (cells[0], flags)

# the estimators the table does not name are the "other" row
named_est = set()
for k in named_rows:
    named_est.update(k)
unnamed = set(opts) - named_est

check("the README's table names every estimator exactly once",
      sum(len(k) for k in named_rows) == len(named_est),
      "%d names for %d estimators" % (sum(len(k) for k in named_rows), len(named_est)))
check("the README's table has a row for the estimators it does not name",
      remainder is not None)

# every derived group must be either a named row or the remainder
for o, es in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    want = tuple("yes" if x in o else "no" for x in OPTIONS)
    key = tuple(sorted(es))
    if key in named_rows:
        check("the README names the %d estimator(s) taking %s"
              % (len(es), "+".join(o) or "none of the three"),
              named_rows[key] == want, "README says %s" % (named_rows[key],))
    else:
        check("the README's remaining row covers the %d estimator(s) taking %s"
              % (len(es), "+".join(o) or "none of the three"),
              set(es) == unnamed and remainder is not None
              and remainder[1] == want,
              "README says %s" % (str(remainder[1]) if remainder else "no row",))

if remainder is not None:
    # the count in the row's label must be the count of the estimators it covers
    m2 = re.search(r"(\d+)", remainder[0])
    check("the README's remaining row counts its estimators correctly",
          m2 is not None and int(m2.group(1)) == len(unnamed),
          "says %s, there are %d" % (m2.group(1) if m2 else "?", len(unnamed)))
    check("the README's remaining row is the group that takes all three",
          remainder[1] == tuple("yes" for _ in OPTIONS),
          "README says %s" % (str(remainder[1]),))

# the old sentence promised ONE set of six; there are two
check("the README no longer promises a single set of six exceptions",
      "the six exceptions are listed here rather than discovered later"
      not in readme)
check("the README says the two sets differ",
      "two different sets of six" in readme)

print()
print("=" * 74)
print("checks: %d   failures: %d" % (N, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)
print("ALL PASS")
