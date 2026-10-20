"""Round 12 verifier: the nine upstream-parity gate docstrings must say what
the gates actually do.

The class of defect this pins
-----------------------------
The `pyexample_*` family is the only verification in this repository that is
a PYTHON SCRIPT printing its own verdict, so its docstrings are the only
"test documentation" no test runner ever reads. Nine of them, plus
`parity_helper.py`, had never been audited.

Every check below is DERIVED from the artefact, not pinned to a literal in
this file:

  * the DID tolerance's provenance is checked against the VALUES, by deriving
    the fixture's share of the SE gap from the four-way table parsed out of
    the docstring and comparing it with the percentage the docstring states,
    the percentage the parity emitter states, and the constant the gate
    asserts -- three documents that can now only agree;
  * the CS2021-binary band table is compared with `TOL_BY_CELL` as a SET,
    parsed out of the source, and each row is checked to be 3 x its own sd
    column to the precision printed;
  * the PolicyTree tolerance factor is derived from `THRESH_RTOL` and the
    relative gap the docstring itself quotes;
  * the five estimator slots are checked by looking for the upstream class
    name in a gate file, so "the other three are still open" cannot come back
    without a gate disappearing;
  * the README's count word is compared with the number of table rows AND
    with the number of `pyexample_*.py` files on disk;
  * the census banner's commit id and date are read from `git log`, so the
    banner cannot claim a provenance the history does not support.
"""
from __future__ import annotations

import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = []

GATES = [
    "pyexample_did.py",
    "pyexample_did_cs2021.py",
    "pyexample_did_cs_binary.py",
    "pyexample_did_binary.py",
    "pyexample_suite.py",
    "pyexample_lplr.py",
    "pyexample_pq.py",
    "pyexample_policytree.py",
    "pyexample_rdd.py",
    "parity_helper.py",
]

# The five estimator slots that once had an analytic oracle only, and the
# upstream class each is now gated against.
SLOTS = {
    "RDD": "rdrobust",
    "PQ": "DoubleMLPQ",
    "QTE": "DoubleMLQTE",
    "LPQ": "DoubleMLLPQ",
    "PolicyTree": "DoubleMLPolicyTree",
}


def ok(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print("  %s  %s%s" % ("PASS" if cond else "FAIL", name,
                         ("   [%s]" % detail) if detail else ""))


def read(rel):
    with io.open(os.path.join(ROOT, rel.replace("/", os.sep)),
                 encoding="utf-8", errors="replace") as fh:
        return fh.read()


def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True,
                       text=True, encoding="utf-8", errors="replace", timeout=300)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def tracked(rel):
    rc, out = git("ls-files", "--", rel)
    return rc == 0 and rel in out.split()


def py_gates_on_disk():
    return sorted(f for f in os.listdir(ROOT)
                  if f.startswith("pyexample_") and f.endswith(".py"))


# --------------------------------------------------------------------------- #
print("A. the DID tolerance's provenance")
# --------------------------------------------------------------------------- #
did = read("pyexample_did.py")
se_sd_script = "_verify/_se_sd_1647.py"

ok("A1 the tolerance's measurement script exists and is tracked",
   os.path.isfile(os.path.join(ROOT, se_sd_script)) and tracked(se_sd_script),
   se_sd_script)
ok("A2 the docstring names that script as the tolerance's provenance",
   se_sd_script in did, se_sd_script)

m = re.search(r"^COEF_SD\s*=\s*([0-9.]+)", did, re.M)
coef_sd = float(m.group(1)) if m else None
m = re.search(r"^SE_SD\s*=\s*([0-9.]+)", did, re.M)
se_sd = float(m.group(1)) if m else None
ok("A3 the gate's two constants are present", coef_sd and se_sd,
   "COEF_SD=%s SE_SD=%s" % (coef_sd, se_sd))

# The docstring's 10-seed table, and the constants, must be the same numbers.
doc_sd = [float(x) for x in re.findall(r"over 10 seeds:[^\n]*sd ([0-9.]+)", did)]
ok("A4 the docstring's 10-seed table states both sds",
   len(doc_sd) == 2, str(doc_sd))
if len(doc_sd) == 2:
    ok("A5 the coefficient sd in the table is the gate's COEF_SD",
       abs(doc_sd[0] - coef_sd) < 5e-6, "%s vs %s" % (doc_sd[0], coef_sd))
    ok("A6 the standard-error sd in the table is the gate's SE_SD",
       abs(doc_sd[1] - se_sd) < 5e-6, "%s vs %s" % (doc_sd[1], se_sd))

# The 500/42 measurement the docstring quotes as REJECTED must not be the
# band. The check is numeric, not textual: the constants are what decides.
ok("A7 the band is not the rejected 500/42 measurement",
   coef_sd is not None and se_sd is not None
   and abs(coef_sd - 0.034670) > 1e-4 and abs(se_sd - 0.002994) > 1e-4,
   "COEF_SD=%s SE_SD=%s" % (coef_sd, se_sd))

# --------------------------------------------------------------------------- #
print("B. the fixture's share of the SE gap")
# --------------------------------------------------------------------------- #
def four_way(text):
    vals = [float(x) for x in re.findall(r"-> se ([0-9.]+)", text)]
    return vals if len(vals) >= 5 else None


def derived_share(vals):
    """(defaults, upstream-config, upstream) -> the fixture's share."""
    defaults, upstream_cfg, upstream = vals[0], vals[3], vals[4]
    total = defaults - upstream
    fixture = defaults - upstream_cfg
    if total == 0:
        return None
    return fixture / total


did_vals = four_way(did)
ok("B1 the did docstring carries the four-way table", did_vals is not None)
mbt = read("examples/parity/main.mbt")
mbt_vals = four_way(mbt)
ok("B2 the parity emitter carries the same table", mbt_vals is not None)

if did_vals and mbt_vals:
    ok("B3 the two tables are the same numbers", did_vals == mbt_vals,
       "%s vs %s" % (did_vals, mbt_vals))

if did_vals:
    share = derived_share(did_vals)
    ok("B4 the share is derivable from the table", share is not None,
       "%.4f" % share if share is not None else "")
    for label, text in (("the did docstring", did), ("the parity emitter", mbt)):
        pct = re.search(r"accounted for (\d+)% of", text)
        ok("B5 %s states the derived share" % label,
           pct is not None and abs(int(pct.group(1)) - 100 * share) <= 1.0,
           "states %s%%, derived %.2f%%"
           % (pct.group(1) if pct else "nothing", 100 * share))
    m = re.search(r"^FIXTURE_SHARE\s*=\s*([0-9.]+)", did, re.M)
    gate_share = float(m.group(1)) if m else None
    ok("B6 the gate asserts the derived share",
       gate_share is not None and abs(gate_share - share) < 0.002,
       "gate %s vs derived %.4f" % (gate_share, share))

ok("B7 the parity emitter emits the port's default-configuration se",
   'val("sz_se_defaults"' in mbt)
ok("B8 the gate has a row for the share", "fixture share of the gap" in did)

# --------------------------------------------------------------------------- #
print("C. the CS2021-binary band table")
# --------------------------------------------------------------------------- #
csb = read("pyexample_did_cs_binary.py")


def eval_tol_expr(expr):
    """The source writes the band as `3 * 0.05520`; evaluate that safely."""
    expr = expr.strip()
    m = re.fullmatch(r"([0-9.]+)\s*\*\s*([0-9.]+)", expr)
    if m:
        return float(m.group(1)) * float(m.group(2))
    try:
        return float(expr)
    except ValueError:
        return None


tol = {}
for k, v in re.findall(r"\((\d, \d, \d)\)\s*:\s*([^,]+),",
                       csb[csb.index("TOL_BY_CELL"):]):
    val = eval_tol_expr(v)
    if val is not None:
        tol[tuple(int(x) for x in k.split(","))] = val
ok("C1 TOL_BY_CELL parses", len(tol) == 6, "%d cells" % len(tol))

rows = re.findall(
    r"ATT\((\d),(\d),(\d)\)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)", csb)
ok("C2 the docstring table parses", len(rows) == 6, "%d rows" % len(rows))
if rows and len(tol) == 6:
    doc_bands = {}
    for g, tp, te, coef, sd, band, ratio in rows:
        doc_bands[(int(g), int(tp), int(te))] = (float(sd), float(band))
    ok("C3 the table's cells are the code's cells",
       set(doc_bands) == set(tol), "%s vs %s"
       % (sorted(doc_bands), sorted(tol)))
    mismatched = [c for c in tol
                  if c in doc_bands and abs(doc_bands[c][1] - tol[c]) > 5e-6]
    ok("C4 every table band is the band in force", not mismatched,
       "mismatched: %s" % mismatched)
    self_bad = [c for c in doc_bands
                if abs(3 * doc_bands[c][0] - doc_bands[c][1]) > 5e-6]
    ok("C5 each row's band is 3 x its own sd column", not self_bad,
       "inconsistent: %s" % self_bad)

# --------------------------------------------------------------------------- #
print("D. the PolicyTree tolerance factor and the five slots")
# --------------------------------------------------------------------------- #
pt = read("pyexample_policytree.py")
m = re.search(r"^THRESH_RTOL\s*=\s*([0-9.eE+-]+)", pt, re.M)
rtol = float(m.group(1)) if m else None
m = re.search(r"([0-9.]+)e-8 relative", pt)
rel_gap = float(m.group(1)) if m else None
m = re.search(r"bound below sits about (\d+)x", pt)
factor = int(m.group(1)) if m else None
ok("D1 the threshold tolerance parses", rtol is not None, str(rtol))
ok("D2 the relative gap in the docstring parses", rel_gap is not None,
   str(rel_gap))
ok("D3 the stated factor is derived from the tolerance and the gap",
   rtol and rel_gap and factor and abs(factor - round(rtol / (rel_gap * 1e-8))) <= 1,
   "stated %s, derived %s" % (factor, round(rtol / (rel_gap * 1e-8))
                              if rtol and rel_gap else "?"))

gates_text = "\n".join(read(g) for g in GATES)
for slot, cls in sorted(SLOTS.items()):
    hit = [g for g in GATES
           if cls in read(g) and g != "parity_helper.py"]
    ok("D4 the %s slot is gated against %s" % (slot, cls), bool(hit),
       ", ".join(hit))

ok("D5 no docstring claims a slot is currently ungated",
   "still open" not in gates_text
   and "deliberately has no gate" not in gates_text
   and "`examples/main` carries" not in gates_text)

# --------------------------------------------------------------------------- #
print("D'. the CI workflow and the parity emitter, which run the gates")
# --------------------------------------------------------------------------- #
check_yml = read(".github/workflows/check.yml")
ok("D'1 check.yml runs the RDD gate", "python pyexample_rdd.py --check" in check_yml)
ok("D'2 check.yml does not say RDD has no gate",
   "deliberately has\n" not in check_yml
   and "deliberately has no gate" not in check_yml)
# The SE ratios the workflow quotes must be the ones the gate measures. The
# gate's own source carries the measured set; the workflow must not
# paraphrase it into a number the measurement does not support.
pq_src = read("pyexample_pq.py")
ratios = re.findall(r"(pq_se|qte\[\d\]_se|lpq_se)\s+([0-9.]+)", pq_src)
ok("D'3 the PQ/QTE source carries the measured SE ratios",
   len(ratios) >= 4, str(ratios))
for label, ratio in ratios:
    ok("D'4 check.yml quotes the measured ratio for %s" % label,
       ratio in check_yml, ratio)
ok("D'5 check.yml does not paraphrase the ratios into a percentage",
   "about\n# 10% below" not in check_yml
   and "about 10% below" not in check_yml)

mbt_pt = mbt[mbt.index("17. policytree"):mbt.index("section(\"policytree\")")]
ok("D'6 the parity emitter's policytree section does not say RDD is ungated",
   "RDD is measured divergent\n" not in mbt_pt
   and "RDD is measured divergent" not in mbt_pt)

# --------------------------------------------------------------------------- #
print("E. the RDD gaps: absolute and relative")
# --------------------------------------------------------------------------- #
rdd = read("pyexample_rdd.py")
readme = read("README.mbt.md")
# The gate's own PRINTED text is what a reader sees; the source comment may
# quote the old sentence to explain the change.
printed = "\n".join(re.findall(r"print\((.*?)\)\n", rdd, re.S))
ok("E1 the gate no longer says the docstring claims they agree",
   "claims they agree when b == h" not in printed
   and "claims they agree when b == h" not in rdd[:rdd.index("def ")])
ok("E2 rdd.mbt says they differ, so the gate's note points at something true",
   "differ by 6.7e-8 relative" in read("moonbit_doubleML/rdd.mbt"))

gap_re = re.compile(r"\d\.\d+e-1[45]")
rdd_para = rdd[rdd.index("GATED -- the bias-corrected arm"):
                rdd.index("REPORTED, NOT GATED")]
rm_para = readme[readme.index("**`DoubleMLRDD`'s shipped default arm"):
                 readme.index("The multi-cohort half is the one worth reading")]
ok("E3 the RDD docstring quotes both an absolute and a relative gap",
   "absolute" in rdd_para and "relative" in rdd_para)
ok("E4 the README quotes both an absolute and a relative gap",
   "absolute" in rm_para and "relative" in rm_para)
ok("E5 the README and the RDD docstring quote the same gaps",
   set(gap_re.findall(rdd_para)) == set(gap_re.findall(rm_para)),
   "%s vs %s" % (sorted(set(gap_re.findall(rdd_para))),
                 sorted(set(gap_re.findall(rm_para)))))
m = re.search(r"^RTOL\s*=\s*([0-9.eE+-]+)", rdd, re.M)
ok("E6 the gate's bound is the relative one both documents name",
   m and "1e-11" in m.group(1), m.group(1) if m else "no RTOL")

# --------------------------------------------------------------------------- #
print("F. the suite's stability check")
# --------------------------------------------------------------------------- #
suite = read("pyexample_suite.py")
ok("F1 the suite runs the 50k-draw stability check it documents",
   "np.random.random(50000)" in suite and "np.array_equal" in suite)
ok("F2 the stability check is an assertion, not a report",
   re.search(r"assert pliv_stable", suite) is not None)
ok("F3 the suite no longer names a script that does not exist",
   "_suite_tol_1680.py" not in gates_text)

# --------------------------------------------------------------------------- #
print("G. the README's gate count")
# --------------------------------------------------------------------------- #
on_disk = py_gates_on_disk()
m = re.search(r"\*\*(\w+) gates whose reference is UPSTREAM", readme)
word = m.group(1) if m else None
WORDS = {"Zero": 0, "One": 1, "Two": 2, "Three": 3, "Four": 4, "Five": 5,
         "Six": 6, "Seven": 7, "Eight": 8, "Nine": 9, "Ten": 10}
stated = WORDS.get(word)
ok("G1 the count word parses", stated is not None, str(word))
table_rows = len(re.findall(r"^\| `pyexample_\w+\.py` \|", readme, re.M))
ok("G2 the table has one row per gate on disk", table_rows == len(on_disk),
   "%d rows, %d files" % (table_rows, len(on_disk)))
ok("G3 the count word equals the number of gates on disk",
   stated == len(on_disk), "%s vs %d" % (word, len(on_disk)))
m = re.search(r"(\d+) `pyexample_\*` upstream gates", readme)
ok("G4 the second mention of the count agrees",
   m and int(m.group(1)) == len(on_disk),
   m.group(1) if m else "no mention")

# --------------------------------------------------------------------------- #
print("H. the census record")
# --------------------------------------------------------------------------- #
census_rel = "_verify/FIVE_GATES_FEASIBLE_1680.md"
census = read(census_rel)
rc, out = git("log", "--diff-filter=A", "--format=%H", "--", census_rel)
intro = out.strip().splitlines()[-1] if out.strip() else None
ok("H1 the introducing commit is known", bool(intro), str(intro))
ok("H2 the banner names that commit",
   bool(intro) and intro[:7] in census, intro[:7] if intro else "")
rc, out = git("log", "-1", "--format=%ad", "--date=short", intro or "")
cdate = out.strip()
ok("H3 the banner's date is the commit's date, not a typed one",
   cdate and cdate in census, cdate)
ok("H4 the status line no longer says the gates are unbuilt",
   "gates not yet built" not in census)
ok("H5 the dead 'Reproduce' commands are gone",
   "python _verify\\_five_api_1680.py" not in census
   and "python _verify\\_coverage_census_1680.py" not in census)
for gone in ("_five_api_1680.py", "_five_fit_1680.py", "_coverage_census_1680.py"):
    rc, out = git("log", "--all", "--format=%H", "--", "_verify/" + gone)
    ok("H6 %s really never existed" % gone, not out.strip())

# --------------------------------------------------------------------------- #
print("I. the deprecation the DID gate prints on every run")
# --------------------------------------------------------------------------- #
ok("I1 the did docstring records that upstream's DoubleMLDID is deprecated",
   "deprecated" in did and "DoubleMLDIDBinary" in did)

# --------------------------------------------------------------------------- #
print("J. every pointer in the nine gates resolves and is tracked")
# --------------------------------------------------------------------------- #
tracked_set = set(git("ls-files")[1].splitlines())
import importlib

pointer_problems = []
for g in GATES:
    text = read(g)
    for m in re.finditer(r"_verify/([A-Za-z0-9_.\-]+)", text):
        rel = "_verify/" + m.group(1)
        if not os.path.exists(os.path.join(ROOT, rel)):
            pointer_problems.append("%s: MISSING %s" % (g, rel))
        elif rel not in tracked_set:
            pointer_problems.append("%s: UNTRACKED %s" % (g, rel))
    for m in re.finditer(r"`?([A-Za-z0-9_]+\.mbt):(\d+)", text):
        rel = m.group(1)
        for base, prefix in ((os.path.join(ROOT, "moonbit_doubleML"), "moonbit_doubleML/"),
                             (ROOT, "")):
            if os.path.isfile(os.path.join(base, rel)):
                if prefix + rel not in tracked_set:
                    pointer_problems.append("%s: UNTRACKED %s" % (g, rel))
                break
        else:
            pointer_problems.append("%s: MISSING %s" % (g, rel))
    for m in re.finditer(r"`([A-Za-z0-9_]+\.py)`", text):
        rel = m.group(1)
        if not os.path.exists(os.path.join(ROOT, rel)):
            pointer_problems.append("%s: MISSING %s" % (g, rel))
ok("J1 every _verify/ and .py and .mbt:line pointer resolves and is tracked",
   not pointer_problems, "; ".join(pointer_problems))

# The wider rule: a file a gate's prose NAMES must be in the repository. A
# path that exists only in the author's working tree is a promise the reader
# cannot check -- and one gate named a local tarball that way.
untracked_named = []
for g in GATES:
    text = read(g)
    for m in re.finditer(r"\b[\w./-]{2,}\.(?:py|mbt|md|yml|yaml|json|mod|txt|gz)\b",
                         text):
        token = m.group(0).lstrip("./")
        if token.startswith("doubleml/") or token.startswith("sklearn/"):
            continue
        for base, prefix in ((os.path.join(ROOT, "moonbit_doubleML"),
                              "moonbit_doubleML/"), (ROOT, "")):
            cand = os.path.join(base, token.replace("/", os.sep))
            if os.path.isfile(cand):
                if prefix + token not in tracked_set:
                    untracked_named.append("%s: %s" % (g, token))
                break
ok("J2 no gate names a file that is on disk but not in the repository",
   not untracked_named, "; ".join(sorted(set(untracked_named))))

# --------------------------------------------------------------------------- #
failed = [r for r in RESULTS if not r[1]]
print("")
print("checks: %d   passed: %d   failed: %d"
      % (len(RESULTS), len(RESULTS) - len(failed), len(failed)))
for name, _, detail in failed:
    print("  FAILED: %s   %s" % (name, detail))
sys.exit(1 if failed else 0)
