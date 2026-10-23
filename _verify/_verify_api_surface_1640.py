"""Check the README's API-surface claim, and the six named exceptions.

The README used to say: "every estimator follows the same
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` shape and returns the
same `.coef()` / `.se()` / `.confint()` / `.bootstrap()` accessors. No
per-estimator interface drift."

Both halves were false. The shape (`new(...).fit()`) is uniform; the
signature and the accessor set are not, and six estimators differ. The
README now names them, so this derives the sets from the source and checks
the table against them.
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

ACCESSORS = ("coef", "se", "confint", "bootstrap")

srcs = {}
for f in sorted(os.listdir(LIB)):
    if f.endswith(".mbt"):
        srcs[f] = io.open(os.path.join(LIB, f), encoding="utf-8", errors="replace").read()

est_file = {}
for f, s in srcs.items():
    for m in re.finditer(r"pub fn (DoubleML\w+)::new\(", s):
        est_file.setdefault(m.group(1), f)
ests = sorted(s for s in est_file if not s.endswith("Data"))

have = {}
for e in ests:
    s = srcs[est_file[e]]
    have[e] = set(a for a in ACCESSORS
                  if re.search(r"pub fn %s::%s\b" % (re.escape(e), a), s))

uniform = [e for e in ests if set(ACCESSORS) <= have[e]]
exceptions = [e for e in ests if e not in uniform]
print("estimators            : %d" % len(ests))
print("with all four accessors: %d  -> %s" % (len(uniform), ", ".join(uniform)))
print("exceptions            : %d  -> %s" % (len(exceptions), ", ".join(exceptions)))
print()

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


check("16 estimators have all four accessors", len(uniform) == 16,
      "got %d" % len(uniform))
check("6 estimators are exceptions", len(exceptions) == 6,
      "got %d: %s" % (len(exceptions), exceptions))
check("the exceptions are the six the README names",
      exceptions == ["DoubleMLAPOS", "DoubleMLBLP", "DoubleMLDIDCS",
                     "DoubleMLDIDMulti", "DoubleMLPolicyTree", "DoubleMLQTE"],
      "got %s" % exceptions)

# the alternative accessors really exist
for e, names in (("DoubleMLAPOS", ("coefs", "ses")),
                 ("DoubleMLQTE", ("coefs", "ses")),
                 ("DoubleMLDIDCS", ("coef_at", "se_at")),
                 ("DoubleMLDIDMulti", ("coef_at_idx", "se_at_idx")),
                 ("DoubleMLBLP", ("confint_joint",)),
                 ("DoubleMLPolicyTree", ("leaf_influence", "leaf_se",
                                         "policy_value", "policy_value_se"))):
    s = srcs[est_file[e]]
    for n in names:
        check("%s::%s exists" % (e, n),
              re.search(r"pub fn %s::%s\b" % (re.escape(e), n), s) is not None)

# and the README's table names them with those accessors
#
# The README carries TWO tables whose first column is an estimator name: the
# estimator catalogue (Model | Score | Description) and the API-differences
# table (estimator | instead of | because).  A row search that takes the FIRST
# match finds the catalogue's row, which names no accessor at all, so the
# table is located by its own header first.
api_tbl = ""
m_api = re.search(r"^\|\s*estimator\s*\|\s*instead of\s*\|\s*because\s*\|\s*$"
                   r"(.*?)(?:\n[ \t]*\n|\Z)", readme, re.M | re.S)
check("the README's API-differences table is findable", m_api is not None)
if m_api:
    api_tbl = m_api.group(1)
for e in exceptions:
    m = re.search(r"^\|\s*`%s`\s*\|(.+?)\|\s*$" % re.escape(e), api_tbl, re.M)
    check("the README's table has a row for %s" % e, m is not None)
    if m:
        row = m.group(1)
        for n in ("coefs", "ses", "coef_at", "se_at", "coef_at_idx",
                  "se_at_idx", "confint_joint", "leaf_influence", "leaf_se",
                  "policy_value", "policy_value_se"):
            if n in row:
                break
        else:
            check("the %s row names its alternative accessors" % e, False, row)

check("the README says 'The other 16 expose'",
      "The other 16 expose" in readme)
check("the old overclaim is gone",
      "No per-estimator interface drift" not in readme)
check("the old overclaim shape is gone",
      "`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` shape" not in readme)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
