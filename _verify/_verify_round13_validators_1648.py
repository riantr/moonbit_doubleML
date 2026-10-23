"""Round-13 verifier: the 27 Python cross-validator docstrings, claim by claim.

WHAT THIS IS FOR
================
Round 13 audited the module docstrings of the 24 `validate_*_with_python.py`
scripts and the 3 repo-level harnesses -- the verification code that prints
its OWN verdict, and therefore the only place its claims are ever read.

Every check below DERIVES its expectation from the code the claim is about: a
constant is parsed out of the source and compared with the prose. A literal
copied from the prose into this file would rot exactly the way the claims it
checks rotted -- that is the defect this verifier exists to catch, so it must
not contain any. The one number this file does hold is a ULP COUNT, and that
is computed from the two doubles the docstring quotes, not written down.

THE THIRTEEN DEFECTS THIS PINS
===============================
  1. validate_suite_meta.py   the docstring said "Eight reference-only
     validators still print a literal PASS" and "the set is written out here"
     while `KNOWN_HARDCODED_VERDICT` was `set()` and the gate printed 0.
  2. validate_apos_with_python.py  "a wider UPSTREAM_TOL = 0.3" -- both
     constants were 0.3, and the upstream bound is the SMALLER of the two.
  3. validate_quantile_with_python.py  the 0.02 window was attributed to
     "the window the v0.49.0 APOS validator already used for the same DGP";
     the APOS validator has no 0.02 window and a different DGP.
  4. validate_quantile_with_python.py  "n=200" -- the DGP is 400 rows.
  5. validate_quantile_with_python.py  "1.4942 ... by a factor of 15" -- the
     measured deviation is 0.004230, so the margin is 4.73x, not 15.
  6. validate_cvar_with_python.py  "n=200" -- the panel is 400 rows.
  7. validate_cluster_iv_with_python.py  "Across 5 seeds ... 0.88 to 5.69
     (median ~1.27)" -- the sweep runs 30 seeds, is not reproducible run to
     run, and the prose presented three REPORTS as assertions.
  8. validate_cluster_iv_with_python.py  the ratio bucket table dropped every
     ratio below 0.1, so a table headed "n = 30" listed 29 seeds.
  9. validate_ssm_with_python.py + examples/ssm/main.mbt  the seed-99/7
     measurements (0.5255 / 0.4866) had gone stale; only seed 3141 was
     pinned by a test, and the pinned one had not drifted.
 10. validate_bootstrap_with_python.py  "Each is 2-3x the measured
     deviation" -- the real factors are 1.9x .. 6.7x.
 11. validate_cluster_plr_with_python.py  "one ulp apart at n=200" -- the
     measured gap is exactly 2.000 ULP.
 12. validate_did_cross_section_with_python.py  the pre-v0.102.0 numbers were
     presented as current, at sizes the example no longer uses.
 13. validate_did_cs_binary_with_python.py  "PRNG drift ... drives ~0.2 SE
     offsets" -- the DGP's outcome is deterministic and the SE is 0.

ONE LIVE CHECK
==============
The SSM measurements are the case where three sources (the docstring, the
code comment and the example header) could all be stale TOGETHER, and a
static consistency check cannot see that. So the SSM validator is run and
its live ratios are compared with the prose. A run that fails is a failure
of this verifier, not a skip.
"""
from __future__ import annotations

import ast
import io
import math
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.environ.get(
    "ROUND13_ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# The dry-run against the previous release sets this: the live check needs a
# buildable tree, and the point of the dry-run is to see the STATIC checks
# fail on the old text.
SKIP_LIVE = os.environ.get("ROUND13_SKIP_LIVE") == "1"

FAILURES: list[str] = []
CHECKS = 0


def check(name: str, ok: bool, detail: str = "") -> bool:
    global CHECKS
    CHECKS += 1
    if ok:
        print("  ok    %-58s %s" % (name, detail))
    else:
        print("  FAIL  %-58s %s" % (name, detail))
        FAILURES.append("%s :: %s" % (name, detail))
    return ok


def rel(p: str) -> str:
    return os.path.join(ROOT, p)


def read(p: str) -> str:
    with io.open(rel(p), "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def doc_of(p: str) -> str:
    """The module docstring, via the parser rather than by slicing."""
    return ast.get_docstring(ast.parse(read(p))) or ""


def const(src: str, name: str) -> float | None:
    m = re.search(r"^%s\s*=\s*([0-9.eE+-]+)\s*$" % re.escape(name), src, re.M)
    return float(m.group(1)) if m else None


def num_in(text: str, pattern: str, group: int = 1) -> float | None:
    m = re.search(pattern, text)
    return float(m.group(group)) if m else None


HISTORICAL = ("used to say", "used to describe", "used to misdescribe",
              "used to give", "used to be described", "paragraph used to",
              "this file used to", "this paragraph used to", "it used to")


def flat(text: str) -> str:
    """Collapse whitespace, so a phrase split across a line break still matches.

    A docstring is wrapped at ~72 columns, so a phrase like "no longer exists"
    can straddle two lines. Matching the raw text would miss exactly the
    corrections that name the old wording.
    """
    return re.sub(r"\s+", " ", text)


def is_historical(doc: str, phrase: str) -> bool:
    """True if `phrase` appears only as a quotation of what the text USED to say.

    A corrected document has to name the old wording to say that it was wrong.
    A bare "the old phrase is absent" check would forbid exactly the honest
    correction, so the check is: the phrase may appear, but only next to a
    marker that marks it as historical.
    """
    fdoc = flat(doc)
    fphrase = flat(phrase)
    if fphrase not in fdoc:
        return True
    for m in re.finditer(re.escape(fphrase), fdoc):
        window = fdoc[max(0, m.start() - 400):m.start()].lower()
        if not any(h.lower() in window for h in HISTORICAL):
            return False
    return True


def body_of(p: str) -> str:
    """The source with its module docstring removed -- code, not prose."""
    src = read(p)
    tree = ast.parse(src)
    if (tree.body and isinstance(tree.body[0], ast.Expr)
            and isinstance(tree.body[0].value, ast.Constant)
            and isinstance(tree.body[0].value.value, str)):
        lines = src.splitlines(True)
        return "".join(lines[tree.body[0].end_lineno:])
    return src


print("=" * 78)
print("Round 13: the 27 Python cross-validator docstrings")
print("=" * 78)

# ===================================================================== #
# 1. validate_suite_meta.py -- the "Eight validators" claim
# ===================================================================== #
print()
print("-- validate_suite_meta.py")
sm = read("validate_suite_meta.py")
sm_doc = doc_of("validate_suite_meta.py")

m = re.search(r"KNOWN_HARDCODED_VERDICT\s*=\s*set\(\s*([^)]*?)\s*\)", sm)
entries = set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()

check("suite_meta: KNOWN_HARDCODED_VERDICT is assigned a set(), not a dict",
      bool(m) and "= set(" in sm,
      "entries=%d" % len(entries))
check("suite_meta: the docstring no longer claims 'Eight' validators",
      is_historical(sm_doc, "Eight reference-only validators"))
m_count = re.search(r"holds (\d+) files", sm_doc)
check("suite_meta: the docstring states the set's size",
      m_count is not None,
      "stated=%s actual=%d" % (m_count.group(1) if m_count else "MISSING",
                               len(entries)))
check("suite_meta: the stated size matches the set",
      m_count is not None and int(m_count.group(1)) == len(entries))
if len(entries) == 0:
    check("suite_meta: an empty set is not described as 'written out here'",
          is_historical(sm_doc, "written out here"))
check("suite_meta: the count is machine-checked by the gate itself",
      re.search(r"holds \\d\\+ files|holds \(\\d\+\) files", sm) is not None
      or "KNOWN_HARDCODED_VERDICT` below holds (\\d+) files" in sm,
      "the gate reads its own docstring")
check("suite_meta: every entry on the list is a file on disk",
      all(os.path.exists(rel(e)) for e in entries),
      "checked %d entr(y|ies)" % len(entries))

# ===================================================================== #
# 2. validate_apos_with_python.py -- the "wider tolerance" claim
# ===================================================================== #
print()
print("-- validate_apos_with_python.py")
ap = read("validate_apos_with_python.py")
ap_doc = doc_of("validate_apos_with_python.py")
model_tol = const(ap, "MODEL_TOL")
up_tol = const(ap, "UPSTREAM_TOL")
check("apos: both tolerance constants parse", model_tol is not None and up_tol is not None,
      "MODEL_TOL=%s UPSTREAM_TOL=%s" % (model_tol, up_tol))
if model_tol is not None and up_tol is not None:
    check("apos: the docstring does not call an equal constant 'wider'",
          not (model_tol == up_tol
               and not is_historical(ap_doc, "a wider `UPSTREAM_TOL = 0.3`")),
          "both are %s" % model_tol)
    check("apos: the docstring states both constants' values",
          ("%g" % model_tol) in ap_doc and ("%g" % up_tol) in ap_doc)
check("apos: the MoonBit bound really is max(MODEL_TOL, ...)",
      "max(MODEL_TOL" in ap)
check("apos: the upstream bound really is UPSTREAM_TOL or ...",
      re.search(r"UPSTREAM_TOL\b", ap) is not None
      and re.search(r"abs\(up_coefs\[i\] - hr_coefs\[i\]\) < UPSTREAM_TOL\s*\n?\s*or",
                    ap) is not None,
      "the two shapes differ, so 'wider' was never right")
check("apos: the docstring states the two bound shapes",
      "max(MODEL_TOL" in ap_doc and "UPSTREAM_TOL or" in ap_doc)

# ===================================================================== #
# 3-5. validate_quantile_with_python.py
# ===================================================================== #
print()
print("-- validate_quantile_with_python.py")
qz = read("validate_quantile_with_python.py")
qz_doc = doc_of("validate_quantile_with_python.py")
qz_n = const(qz, "N")
qz_n = int(qz_n) if qz_n is not None else None
est_tol = const(qz, "EST_TOL")
med_tol = const(qz, "MEDIAN_TOL")

m_n = re.search(r"2-fold estimate on n\s*=\s*(\d+)", qz_doc)
check("quantile: the docstring states the estimator's sample size",
      m_n is not None,
      "stated=%s N=%s" % (m_n.group(1) if m_n else "MISSING", qz_n))
check("quantile: the stated sample size is the DGP's N",
      m_n is not None and qz_n is not None and int(m_n.group(1)) == qz_n)

# The APOS validator's window: derived from its own source, not remembered.
apos_has_002 = bool(re.search(r"0\.02", ap))
check("quantile: the APOS validator really has no 0.02 window",
      not apos_has_002,
      "the APOS source contains no 0.02 at all")
check("quantile: the docstring no longer attributes its window to APOS",
      is_historical(qz_doc, "APOS validator already used"))
check("quantile: the stale 'factor of 15' is gone",
      "factor of 15" not in qz_doc)
check("quantile: the docstring's window matches the code's EST_TOL",
      est_tol is not None and ("%g" % est_tol) in qz_doc,
      "EST_TOL=%s" % est_tol)
check("quantile: the docstring's median tolerance matches MEDIAN_TOL",
      med_tol is not None and ("%g" % med_tol) in qz_doc,
      "MEDIAN_TOL=%s" % med_tol)
check("quantile: the live margin is printed by the validator",
      "band margin" in qz)
check("quantile: the margin floor is asserted by the validator",
      "est_margin_ok" in qz and "1.5" in qz)
check("quantile: the median margin is asserted by the validator",
      "median_margin_ok" in qz and "/ 1000.0" in qz)

# ===================================================================== #
# 6. validate_cvar_with_python.py
# ===================================================================== #
print()
print("-- validate_cvar_with_python.py")
cv = read("validate_cvar_with_python.py")
cv_doc = doc_of("validate_cvar_with_python.py")
cv_n = const(cv, "N")
cv_n = int(cv_n) if cv_n is not None else None
m_n = re.search(r"2-fold estimate on n\s*=\s*(\d+)", cv_doc)
check("cvar: the docstring states the estimator's sample size",
      m_n is not None,
      "stated=%s N=%s" % (m_n.group(1) if m_n else "MISSING", cv_n))
check("cvar: the stated sample size is the panel's N",
      m_n is not None and cv_n is not None and int(m_n.group(1)) == cv_n)
check("cvar: the docstring names the panel's full size",
      cv_n is not None and ("%d rows" % cv_n) in cv_doc,
      "N=%s" % cv_n)

# ===================================================================== #
# 7-8. validate_cluster_iv_with_python.py
# ===================================================================== #
print()
print("-- validate_cluster_iv_with_python.py")
ci = read("validate_cluster_iv_with_python.py")
ci_doc = doc_of("validate_cluster_iv_with_python.py")
m = re.search(r"seeds\s*=\s*tuple\(range\((\d+),\s*(\d+)\)\)", ci)
n_seeds = int(m.group(2)) - int(m.group(1)) if m else None
check("cluster_iv: the seed range parses", n_seeds is not None, "n_seeds=%s" % n_seeds)
m_s = re.search(r"runs (\d+) seeds", ci_doc)
check("cluster_iv: the docstring states the seed count",
      m_s is not None and n_seeds is not None and int(m_s.group(1)) == n_seeds,
      "stated=%s actual=%s" % (m_s.group(1) if m_s else "MISSING", n_seeds))
if n_seeds is not None and n_seeds != 5:
    check("cluster_iv: no '5 seeds' claim survives",
          not re.search(r"\b5 seeds\b", ci_doc))
check("cluster_iv: the first ratio bucket starts at 0, so none is lost",
      re.search(r'\("\[0,\s*0\.1\)"', ci) is not None)
check("cluster_iv: the bucket census is checked against the total",
      "counted != n_total" in ci)
check("cluster_iv: the cross-implementation COEFFICIENT gap is measured",
      "COEFFICIENT relative gap" in ci)
check("cluster_iv: the unmeasured '3.5%' is gone from the docstring",
      "3.5%" not in ci_doc)
check("cluster_iv: the 5x-factor claim is no longer presented as an assertion",
      "within a 5x factor" not in ci_doc)
check("cluster_iv: the docstring separates assertions from reports",
      "REPORTED, not asserted" in ci_doc)
unseeded = "draw_sample_splitting" not in body_of("validate_cluster_iv_with_python.py")
check("cluster_iv: the docstring's reproducibility claim matches the source",
      (unseeded and "NOT reproducible" in ci_doc)
      or (not unseeded and "NOT reproducible" not in ci_doc),
      "upstream split is %s" % ("unseeded" if unseeded else "seeded"))

# ===================================================================== #
# 9. validate_ssm_with_python.py + examples/ssm/main.mbt
# ===================================================================== #
print()
print("-- validate_ssm_with_python.py + examples/ssm/main.mbt")
ss = read("validate_ssm_with_python.py")
ss_doc = doc_of("validate_ssm_with_python.py")
ss_ex = read("examples/ssm/main.mbt")
ss_lo = const(ss, "SE_RATIO_LO")
ss_hi = const(ss, "SE_RATIO_HI")

doc_ratios = dict((int(seed), float(val)) for val, seed in
                  re.findall(r"([0-9]\.[0-9]+) \(seed (\d+)\)", ss_doc))
check("ssm: the docstring states both seed ratios", len(doc_ratios) == 2,
      "doc says %s" % sorted(doc_ratios.items()))

cmt_ratios = {}
ss_comment = "\n".join(re.sub(r"^\s*#+\s?", "", l) for l in ss.splitlines())
for _m in re.finditer(
        r"Measured:\s+([0-9.]+)\s+\(seed\s+(\d+)\)\s+and\s+([0-9.]+)\s+\(seed\s+(\d+)\)",
        ss_comment):
    cmt_ratios[int(_m.group(2))] = float(_m.group(1))
    cmt_ratios[int(_m.group(4))] = float(_m.group(3))
check("ssm: the code comment states the same two ratios",
      cmt_ratios == doc_ratios,
      "comment %s" % sorted(cmt_ratios.items()))

ex_rows = {}
for seed, lo, hi, ratio in re.findall(
        r"seed\s+(\d+)\s+([0-9.]+) -> ([0-9.]+)\s+ratio ([0-9.]+)", ss_ex):
    ex_rows[int(seed)] = (float(lo), float(hi), float(ratio))
check("ssm: the example header carries a ratio for the two asserted seeds",
      all(s in ex_rows for s in doc_ratios),
      "header rows: %s" % sorted(ex_rows))
# The pinned TEST carries the same two measurements. Its assertion is on the
# relation, so the numbers could drift without the test failing -- which is
# exactly how they did drift.
test_doc = "\n".join(re.sub(r"^\s*///+\s?", "", l)
                     for l in read("moonbit_doubleML/expand_v107_test.mbt").splitlines())
test_ratios = {}
for _m in re.finditer(r"([0-9]\.[0-9]+) \(seed (\d+)\)", test_doc):
    test_ratios[int(_m.group(2))] = float(_m.group(1))
check("ssm: the pinned test quotes the same two ratios",
      test_ratios == doc_ratios,
      "test %s" % sorted(test_ratios.items()))
for seed, want in doc_ratios.items():
    if seed in ex_rows:
        lo, hi, ratio = ex_rows[seed]
        check("ssm: the header's ratio for seed %d matches the docstring" % seed,
              abs(ratio - want) < 5e-5,
              "header=%s doc=%s" % (ratio, want))
        derived = hi / lo if lo else float("inf")
        check("ssm: the header's SE pair reproduces the stated ratio (seed %d)" % seed,
              abs(derived - want) < 5e-4,
              "derived=%.6f stated=%.4f" % (derived, want))
        if ss_lo is not None and ss_hi is not None:
            check("ssm: the stated ratio for seed %d is inside the enforced band" % seed,
                  ss_lo < want < ss_hi,
                  "band=(%s, %s)" % (ss_lo, ss_hi))
    # the 3141 row is pinned by a test, so it must agree with that test
if 3141 in ex_rows:
    test_src = read("moonbit_doubleML/expand_v107_test.mbt")
    m3141 = re.search(r"ratio ([0-9.]+)\)", test_src)
    check("ssm: the header's seed-3141 ratio matches the pinned test",
          m3141 is not None
          and abs(float(m3141.group(1)) - ex_rows[3141][2]) < 5e-5,
          "test=%s header=%s" % (m3141.group(1) if m3141 else "MISSING",
                                 ex_rows[3141][2]))
    check("ssm: the header's seed-3141 SE pair reproduces its ratio",
          abs(ex_rows[3141][1] / ex_rows[3141][0] - ex_rows[3141][2]) < 5e-4,
          "derived=%.6f stated=%.4f" % (ex_rows[3141][1] / ex_rows[3141][0],
                                        ex_rows[3141][2]))

# The one LIVE check: three sources can be stale TOGETHER.
print()
print("-- live: the SSM validator's own numbers")
if SKIP_LIVE:
    print("  (skipped: ROUND13_SKIP_LIVE=1 -- the live check needs a buildable tree)")
    live_ok = True
    live_out = ""
else:
    live_ok = True
    try:
        r = subprocess.run([sys.executable, "validate_ssm_with_python.py"],
                           cwd=ROOT, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=900)
        live_out = (r.stdout or "") + (r.stderr or "")
        live_ok = r.returncode == 0
    except Exception as exc:  # noqa: BLE001
        live_out = "run failed: %r" % (exc,)
        live_ok = False
    check("ssm: the validator runs", live_ok,
          "exit ok" if live_ok else live_out.strip()[-200:])
live_ratios = {}
for _m in re.finditer(
        r"se ratio at 4x \(seed=\s*(\d+)\s*\)\s*=\s*([0-9.]+)", live_out):
    live_ratios[int(_m.group(1))] = float(_m.group(2))
for seed, want in doc_ratios.items():
    if seed in live_ratios:
        check("ssm: the live ratio for seed %d matches the prose" % seed,
              round(live_ratios[seed], 4) == round(want, 4),
              "live=%.6f prose=%.4f" % (live_ratios[seed], want))
    else:
        check("ssm: the live ratio for seed %d was found in the output" % seed,
              False, "no 'se ratio at 4x' line for seed %d" % seed)
live_theta = {}
for _m in re.finditer(
        r"theta \(seed=\s*(\d+)\s*\): \|theta-1\| = ([0-9.]+) -> ([0-9.]+)",
        live_out):
    live_theta[int(_m.group(1))] = (float(_m.group(2)), float(_m.group(3)))
cmt_theta = {}
for _m in re.finditer(r"\(([0-9.]+) / ([0-9.]+)\) \(seed (\d+)\)", ss):
    cmt_theta[int(_m.group(3))] = (float(_m.group(1)), float(_m.group(2)))
for seed, want in live_theta.items():
    if seed in cmt_theta:
        check("ssm: the live |theta-1| pair for seed %d matches the comment" % seed,
              cmt_theta[seed] == want,
              "live=%s comment=%s" % (want, cmt_theta[seed]))

# ===================================================================== #
# 10. validate_bootstrap_with_python.py
# ===================================================================== #
print()
print("-- validate_bootstrap_with_python.py")
bs = read("validate_bootstrap_with_python.py")
bs_doc = doc_of("validate_bootstrap_with_python.py")
m = re.search(r"TOL\s*=\s*\{(.*?)\}", bs, re.S)
bs_tol = {}
if m:
    for k, v in re.findall(r'"(\w+)":\s*([0-9.]+)', m.group(1)):
        bs_tol[k] = float(v)
check("bootstrap: the TOL table parses", len(bs_tol) == 4, "TOL=%s" % bs_tol)

rows = re.findall(
    r"^\s*(mean|var|m3|m4)\s+([0-9.]+)\s+->\s+tol\s+([0-9.]+)\s+\(([0-9.]+)x\)",
    bs_doc, re.M)
check("bootstrap: the docstring's table has one row per quantity",
      len(rows) == 4, "rows=%d" % len(rows))
margins = []
for key, dev, tol, margin in rows:
    check("bootstrap: the docstring's tolerance for %s matches the code" % key,
          key in bs_tol and abs(float(tol) - bs_tol[key]) < 1e-12,
          "doc=%s code=%s" % (tol, bs_tol.get(key)))
    derived = float(tol) / float(dev) if float(dev) else float("inf")
    check("bootstrap: the stated margin for %s is tol/dev" % key,
          abs(derived - float(margin)) < 0.05,
          "stated=%sx derived=%.3fx" % (margin, derived))
    margins.append(derived)
if margins:
    m_rng = re.search(r"runs from ([0-9.]+)x to ([0-9.]+)x", bs_doc)
    check("bootstrap: the docstring states the margin range",
          m_rng is not None,
          "stated=%s..%s" % (m_rng.group(1), m_rng.group(2))
          if m_rng else "MISSING")
    if m_rng:
        check("bootstrap: the stated margin range matches the table",
              abs(float(m_rng.group(1)) - min(margins)) < 0.05
              and abs(float(m_rng.group(2)) - max(margins)) < 0.05,
              "stated=%s..%s derived=%.2f..%.2f"
              % (m_rng.group(1), m_rng.group(2), min(margins), max(margins)))
    check("bootstrap: 'Each is 2-3x' is gone (it was true of neither end)",
          "Each is 2-3x" not in bs_doc)
    check("bootstrap: the real margin range really does defeat '2-3x'",
          min(margins) < 2.0 or max(margins) > 3.0,
          "range %.2f..%.2f" % (min(margins), max(margins)))
check("bootstrap: the live margin is printed by the validator",
      "largest deviation" in bs and "margin" in bs)

# ===================================================================== #
# 11. validate_cluster_plr_with_python.py
# ===================================================================== #
print()
print("-- validate_cluster_plr_with_python.py")
cp = read("validate_cluster_plr_with_python.py")
cp_doc = doc_of("validate_cluster_plr_with_python.py")
cp_tol = const(cp, "SINGLETON_REL_TOL")
m = re.search(r"`([0-9]\.[0-9]+)` vs `([0-9]\.[0-9]+)`", cp_doc)
check("cluster_plr: the docstring quotes the two doubles", m is not None)
if m:
    a, b = float(m.group(1)), float(m.group(2))
    ulp = math.ulp(a)
    ulps = abs(b - a) / ulp if ulp else float("inf")
    check("cluster_plr: the quoted gap is NOT one ULP", ulps > 1.5,
          "computed %.3f ULP" % ulps)
    check("cluster_plr: the docstring's ULP count matches the computed one",
          re.search(r"([0-9]+\.[0-9]+) ULP", cp_doc) is not None
          and abs(float(re.search(r"([0-9]+\.[0-9]+) ULP", cp_doc).group(1))
                  - ulps) < 0.01,
          "computed %.3f" % ulps)
    check("cluster_plr: 'one ulp apart' is gone",
          "one ulp apart" not in cp_doc)
    if cp_tol is not None:
        check("cluster_plr: the quoted gap is inside the enforced tolerance",
              abs(b - a) / a < cp_tol,
              "rel=%.3e tol=%g" % (abs(b - a) / a, cp_tol))
check("cluster_plr: the live ULP count is printed by the validator",
      "ULP" in cp and "math.ulp" in cp)

# ===================================================================== #
# 12. validate_did_cross_section_with_python.py
# ===================================================================== #
print()
print("-- validate_did_cross_section_with_python.py")
dc = read("validate_did_cross_section_with_python.py")
dc_doc = doc_of("validate_did_cross_section_with_python.py")
dc_lo = const(dc, "SE_RATIO_LO")
dc_hi = const(dc, "SE_RATIO_HI")
ex_dc = read("examples/did_cross_section/main.mbt")
m_n = re.search(r"let n = (\d+)", ex_dc)
m_n2 = re.search(r"let n2 = (\d+)", ex_dc)
check("did_cross_section: the example's two sizes parse",
      m_n is not None and m_n2 is not None,
      "n=%s n2=%s" % (m_n.group(1) if m_n else "?",
                      m_n2.group(1) if m_n2 else "?"))
if m_n and m_n2:
    want_sizes = "%s / %s" % (m_n.group(1), m_n2.group(1))
    check("did_cross_section: the docstring states the CURRENT example sizes",
          want_sizes in dc_doc,
          "expected %r" % want_sizes)
if dc_lo is not None and dc_hi is not None:
    band = "%s < ratio < %s" % (dc_lo, dc_hi)
    check("did_cross_section: the docstring states the asserted band",
          band in dc_doc, "expected %r" % band)
if "0.3654" in dc_doc:
    check("did_cross_section: the pre-v0.102.0 numbers are marked historical",
          "pre-v0.102.0" in flat(dc_doc)
          and "no longer exists" in flat(dc_doc))

# ===================================================================== #
# 13. validate_did_cs_binary_with_python.py
# ===================================================================== #
print()
print("-- validate_did_cs_binary_with_python.py")
db = read("validate_did_cs_binary_with_python.py")
db_doc = doc_of("validate_did_cs_binary_with_python.py")
y_lines = [l for l in db.splitlines() if re.match(r"\s*y\[", l)]
stochastic = any("rng" in l for l in y_lines)
check("did_cs_binary: the DGP's outcome assignment is found", bool(y_lines),
      "%d assignment line(s)" % len(y_lines))
check("did_cs_binary: the DGP's outcome really is deterministic",
      not stochastic,
      "no RNG draw in the outcome" if not stochastic else "outcome is random")
if not stochastic:
    check("did_cs_binary: the docstring says the outcome is deterministic",
          "DETERMINISTIC" in db_doc)
db_tol = const(db, "MODEL_TOL")
check("did_cs_binary: the docstring's MODEL_TOL matches the code",
      db_tol is not None and ("%g" % db_tol) in db_doc,
      "MODEL_TOL=%s" % db_tol)
check("did_cs_binary: the measured gap is printed by the validator",
      "measured gap" in db)

# ===================================================================== #
print()
print("=" * 78)
print("checks: %d   failures: %d" % (CHECKS, len(FAILURES)))
if FAILURES:
    for f in FAILURES:
        print("  - %s" % f)
    print("Round 13 validator docstrings: FAIL")
    sys.exit(1)
print("Round 13 validator docstrings: PASS")
sys.exit(0)
