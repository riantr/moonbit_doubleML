"""Verify the Status table's sandwich-variance coverage.

The table says: "**15 / 22** expose the scalar `sandwich_se` /
`cluster_sandwich_se` / `bias_corrected_coef`; **4** more
(`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`)
expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose
none (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`)".

15 + 4 + 3 = 22, so the arithmetic is right. What is NOT checked by
arithmetic is whether the SETS are right -- that is read from the source
here: which estimator files expose a sandwich accessor at all, and which
of those expose a per-cell one.

Round 37 added the two things the row also asserts, which nothing
checked:

  * the "Introduced vX.Y.Z" LITERAL -- it said v0.89.0, but the
    CHANGELOG's own headings say v0.79.0 introduced the family (on
    `DoubleMLIRM` and `DoubleMLPLR`) and v0.89.0 was one step of the
    extension (10 -> 12 of 22).  A version literal rots silently,
    because nothing else on the page repeats it.  It is now derived from
    the CHANGELOG.

  * the "expose none" GROUP -- true of the sandwich API, misleading
    about robustness: `DoubleMLBLP` and `DoubleMLRDD` expose a
    heteroskedasticity-robust `hac_se` / `cluster_hac_se` under their own
    name, and the README did not mention `hac_se` AT ALL.  The row now
    discloses them, and the disclosure is checked.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
readme = io.open(os.path.join(ROOT, "README.mbt.md"), encoding="utf-8").read()

# estimator -> (has_scalar, has_percell)
estimators = {}
methods = {}
for name in sorted(os.listdir(LIB)):
    if not name.endswith(".mbt"):
        continue
    src = io.open(os.path.join(LIB, name), encoding="utf-8", errors="replace").read()
    for est in re.findall(r"pub fn (DoubleML\w+)::", src):
        if est.endswith("Data"):
            continue
        estimators.setdefault(est, {"scalar": False, "percell": False})
        methods.setdefault(est, set()).update(
            re.findall(r"pub fn %s::(\w+)\(" % est, src))
        if re.search(r"pub fn %s::(sandwich_se|cluster_sandwich_se|bias_corrected_coef)\(" % est, src):
            estimators[est]["scalar"] = True
        if re.search(r"pub fn %s::\w*sandwich\w*_at(_idx)?\(" % est, src):
            estimators[est]["percell"] = True

scalar = sorted(e for e, v in estimators.items() if v["scalar"])
percell_only = sorted(e for e, v in estimators.items() if v["percell"] and not v["scalar"])
none = sorted(e for e, v in estimators.items() if not v["scalar"] and not v["percell"])

# A robustness surface that is NOT the sandwich API: `hac_se` /
# `cluster_hac_se` under their own name.  `sensitivity_analysis_*` is
# the sensitivity value, not a variance estimator, so it does not count.
other_robust = sorted(
    e for e in none
    if any(re.match(r"(cluster_)?hac_se$", m) for m in methods.get(e, ())))
no_robust = sorted(e for e in none if e not in other_robust)


def hac_version(est):
    """The version that introduced this estimator's OWN `hac_se`.

    Read from the doc-comment above the definition -- the source marks it
    "v0.96.0+:" -- and NOT typed in here, so a rename or a re-version moves
    the answer with the code.
    """
    for name in sorted(os.listdir(LIB)):
        if not name.endswith(".mbt"):
            continue
        src = io.open(os.path.join(LIB, name), encoding="utf-8",
                      errors="replace").read()
        m = re.search(r"pub fn %s::hac_se\(" % est, src)
        if not m:
            continue
        for line in reversed(src[:m.start()].rstrip("\n").split("\n")):
            s = line.strip()
            if not s.startswith("//"):
                break
            v = re.search(r"v(\d+\.\d+\.\d+)\+", s)
            if v:
                return v.group(1)
    return None

# the version that INTRODUCED the sandwich family, read out of the
# CHANGELOG's own headings rather than typed in here
cl = io.open(CHANGELOG, encoding="utf-8", errors="replace").read()
sandwich_versions = []
for mm in re.finditer(r"^## \[(\d+\.\d+\.\d+)\] -- (.*)$", cl, re.M):
    if "sandwich" in mm.group(2).lower():
        sandwich_versions.append(tuple(int(x) for x in mm.group(1).split(".")))
INTRODUCED = ".".join(str(x) for x in min(sandwich_versions)) if sandwich_versions else ""
ALL_SANDWICH = sorted(scalar + percell_only)

print("estimators with a sandwich accessor: %d" % len(estimators))
print("  scalar  (%d): %s" % (len(scalar), ", ".join(scalar)))
print("  per-cell only (%d): %s" % (len(percell_only), ", ".join(percell_only)))
print("  none     (%d): %s" % (len(none), ", ".join(none)))
print("")

fails = []
checks = 0


def check(label, cond, detail=""):
    global checks
    checks += 1
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


row = re.search(r"\| Sandwich-variance coverage \|(.*?)\|", readme)
check("the Status table has a sandwich-variance row", row is not None)
if row:
    body = row.group(1)
    m = re.search(r"\*\*(\d+) / (\d+)\*\*", body)
    check("the table states 15 / 22", m is not None and m.group(1) == "15"
          and m.group(2) == "22", body[:80])
    check("the source agrees on the scalar count",
          m is not None and int(m.group(1)) == len(scalar),
          "table=%s source=%d" % (m.group(1) if m else "?", len(scalar)))
    m2 = re.search(r"\*\*(\d+)\*\* more \(([^)]*)\)", body)
    check("the table states 4 more", m2 is not None and m2.group(1) == "4",
          body[:120])
    if m2:
        named = re.findall(r"`(DoubleML\w+)`", m2.group(2))
        check("the table's per-cell names match the source",
              sorted(named) == percell_only,
              "table=%s source=%s" % (sorted(named), percell_only))
    m3 = re.search(r"\*\*(\d+)\*\* expose none[^()]*\(([^)]*)\)", body)
    check("the table states 3 expose none", m3 is not None and m3.group(1) == "3",
          body[-120:])
    if m3:
        named = re.findall(r"`(DoubleML\w+)`", m3.group(2))
        check("the table's 'none' names match the source",
              sorted(named) == none,
              "table=%s source=%s" % (sorted(named), none))

    # ---- round 37: the version literal, and what "none" leaves out ----
    m4 = re.search(r"Introduced v(\d+\.\d+\.\d+)", body)
    check("the table states the version that introduced the API",
          m4 is not None, body[-120:])
    if m4:
        check("the stated introduction version is the CHANGELOG's first one",
              m4.group(1) == INTRODUCED,
              "readme=v%s changelog=v%s" % (m4.group(1), INTRODUCED))

    m5 = re.search(r"extended to \*\*(\d+) / (\d+)\*\*", body)
    check("the table states the extended coverage", m5 is not None)
    if m5:
        check("the stated coverage is the source's coverage",
              int(m5.group(1)) == len(ALL_SANDWICH),
              "readme=%s source=%d" % (m5.group(1), len(ALL_SANDWICH)))
        check("the stated denominator is the estimator count",
              int(m5.group(2)) == len(estimators),
              "readme=%s source=%d" % (m5.group(2), len(estimators)))

    if other_robust:
        check("the table discloses the estimators with a non-sandwich robust SE",
              "hac_se" in body, body[-200:])
        for e in other_robust:
            check("the table names %s in the disclosure" % e,
                  "`%s`" % e in body, body[-200:])
    if no_robust:
        for e in no_robust:
            check("the table says %s has no robust SE at all" % e,
                  e in body and "no robust SE at all" in body, body[-200:])

    # ---- round 39: the version<->estimator PAIRING, not just the set -------
    # The disclosure read "`DoubleMLBLP` and `DoubleMLRDD` do expose a
    # heteroskedasticity-robust `hac_se` under their own name (v0.96.0 /
    # v0.97.0)".  Read positionally -- the way this document pairs names
    # with versions everywhere else -- that asserts BLP = v0.96.0 and
    # RDD = v0.97.0, and BOTH are false: rdd.mbt marks its `hac_se`
    # "v0.96.0+", blp_policy.mbt marks its own "v0.97.0+", and the
    # CHANGELOG's headings agree.  The SET of two versions was right, so
    # the defect was the ORDER -- and an order that reads as a claim is a
    # claim.
    for e in other_robust:
        src_ver = hac_version(e)
        chg_ver = None
        for mm in re.finditer(r"^## \[(\d+\.\d+\.\d+)\] -- (.*)$", cl, re.M):
            if e in mm.group(2) and "hac_se" in mm.group(2):
                chg_ver = mm.group(1)
                break
        check("the source and the CHANGELOG agree on %s's hac_se version" % e,
              src_ver is not None and src_ver == chg_ver,
              "source=v%s changelog=v%s" % (src_ver, chg_ver))
        check("the table pairs %s with v%s" % (e, src_ver),
              ("`%s` (v%s)" % (e, src_ver)) in body,
              "the pairing is not name-then-version")

print("")
print("checks run: %d" % checks)
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
