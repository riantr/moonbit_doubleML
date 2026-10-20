#!/usr/bin/env python3
"""Round 15 -- verify the six constructor-defaults records and the README.

WHAT THIS PINS.  Round 15 re-audited six `_verify/*.md` records
(`PORT_VS_UPSTREAM_DEFAULTS_1540`, `LEARNER_DEFAULTS_1530`, `N_FOLDS_1570`,
`IN_SAMPLE_NORMALIZATION_1570`, `SCORE_VOCABULARY_1550`, `PARITY_COMMENTS_1570`)
and the README's estimator-provenance claims.  The defects it found and fixed:

  * stale counts (213/216 `.mbt` files, 27/12/12/6-6 learner sites);
  * rotted `file.mbt:NNN` pointers;
  * a `score` vocabulary table that missed 5 upstream classes;
  * a PLR claim ("the port rejects upstream's spelling") that the fix in the
    very commit the record cites had already made false;
  * a headline "20x" measurement built by comparing two different estimators
    that share a name;
  * a constructor-divergence triple (49/42/7) that reproduces under no
    scoping of the sources it names;
  * README provenance labels that were CROSSED for the DID family;
  * method scripts and raw artefacts that were cited but never tracked.

HOW IT CHECKS.  Every expectation is DERIVED, not typed:

  * the numbers come from `_verify/_audit_r15_defaults_1650.py`, which reads
    the port's source and the INSTALLED upstream package;
  * the path promises are resolved against the filesystem AND against
    `git ls-files`, because a path in prose is a promise that the file
    exists AND is tracked;
  * the line pointers are resolved and their CONTENT checked against an
    anchor -- a pointer that resolves to the wrong line is still wrong;
  * the withdrawn claims are checked to be ABSENT, not merely to be
    contradicted elsewhere.

Run:  python _verify/_verify_round15_defaults_1650.py
Exit: 0 only if every check passes.
"""
import json
import os
import re
import inspect
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(os.environ.get("ROUND15_ROOT") or (Path(__file__).resolve().parent.parent))
PKG = ROOT / "moonbit_doubleML"
AUDIT = ROOT / "_verify" / "_audit_r15_defaults_1650.py"
AUDIT_JSON = ROOT / "_verify" / "_defaults_audit_1650.json"

RECORDS = [
    "_verify/PORT_VS_UPSTREAM_DEFAULTS_1540.md",
    "_verify/LEARNER_DEFAULTS_1530.md",
    "_verify/N_FOLDS_1570.md",
    "_verify/IN_SAMPLE_NORMALIZATION_1570.md",
    "_verify/SCORE_VOCABULARY_1550.md",
    "_verify/PARITY_COMMENTS_1570.md",
    # cited by two of the six (N_FOLDS_1570, IN_SAMPLE_NORMALIZATION_1570) and
    # tracked in this round so their "the inherited claim had the right number"
    # reference is checkable
    "_verify/N_FOLDS_INNER_1550.md",
]

# ------------------------------------------------------------------ results
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))


def read(p):
    return Path(p).read_text(encoding="utf-8", errors="replace")


# ------------------------------------------------------------------ 1. the audit
print("=" * 90)
print("ROUND 15 VERIFIER -- the six constructor-defaults records + README provenance")
print("=" * 90)

r = subprocess.run([sys.executable, str(AUDIT)], capture_output=True, cwd=str(ROOT))
check("audit script exits 0", r.returncode == 0, r.stderr.decode("utf-8", "replace")[-300:])
if not AUDIT_JSON.is_file():
    check("audit json exists", False, str(AUDIT_JSON))
    print("FATAL: no audit json")
    raise SystemExit(1)
A = json.loads(AUDIT_JSON.read_text(encoding="utf-8"))
check("audit json exists", True)

texts = {}
for rec in RECORDS:
    p = ROOT / rec
    check(f"record present: {Path(rec).name}", p.is_file())
    texts[rec] = read(p) if p.is_file() else ""

README = read(ROOT / "README.mbt.md")

# ------------------------------------------------------------------ 2. tracked files
tracked = set()
for ln in subprocess.run(["git", "-C", str(ROOT), "ls-files"],
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace").stdout.splitlines():
    tracked.add(ln.replace("\\", "/"))

# ------------------------------------------------------------------ 3. path promises
# A path in prose is a promise: the file must exist AND be tracked.  Both the
# `_verify/...`-prefixed form and the bare sibling form (an Artifacts list
# naming a file in the same directory) are promises.
PATH_RE = re.compile(r"`(_verify/[A-Za-z0-9_./\\-]+?\.(?:mbt|py|txt|md|json|toml|mod|gz))`")
BARE_RE = re.compile(r"`([A-Za-z0-9_][A-Za-z0-9_.-]*\.(?:md|txt|py|json))`")


def _upstream_root():
    try:
        import doubleml
        return Path(inspect.getfile(doubleml)).parent
    except Exception:
        return None


UP_ROOT = _upstream_root()


def resolve_promise(name):
    """Where does a path promise live?  Returns (relpath, is_repo_file).

    A bare name may be a sibling of the record (`_verify/<name>`), a file at
    the repository root, or a reference to a file in the INSTALLED upstream
    package -- in which case it is a reference to someone else's source, and
    the promise is that it exists there.
    """
    if (ROOT / name).is_file():
        return name, True
    if (ROOT / "_verify" / name).is_file():
        return f"_verify/{name}", True
    if UP_ROOT is not None:
        for dirpath, _d, fns in os.walk(UP_ROOT):
            if name in fns:
                return None, False
    return None, True


missing, untracked = [], []
for rec in RECORDS:
    cands = [(m.group(1), True) for m in PATH_RE.finditer(texts[rec])]
    cands += [(m.group(1), False) for m in BARE_RE.finditer(texts[rec])]
    for p, prefixed in cands:
        if prefixed:
            rel = p
            if not (ROOT / rel).is_file():
                missing.append(f"{Path(rec).name} -> {rel}")
            elif rel not in tracked:
                untracked.append(f"{Path(rec).name} -> {rel}")
            continue
        rel, is_repo = resolve_promise(p)
        if rel is None:
            continue                      # an upstream file: not our promise
        if not (ROOT / rel).is_file():
            missing.append(f"{Path(rec).name} -> {rel}")
        elif rel not in tracked:
            untracked.append(f"{Path(rec).name} -> {rel}")
check("every path promise resolves on disk",
      not missing, "; ".join(sorted(set(missing))[:8]))
check("every path promise is TRACKED in git",
      not untracked, "; ".join(sorted(set(untracked))[:8]))

# the method scripts the records name must actually RUN
for script in ("_verify/_upstream_defaults_1540.py",
               "_verify/_enum_all_defaults_1540.py",
               "_verify/_audit_r15_defaults_1650.py",
               "_verify/_regen_capture_1650.py"):
    p = ROOT / script
    if not p.is_file():
        check(f"method script present: {script}", False)
        continue
    rr = subprocess.run([sys.executable, str(p)], capture_output=True, cwd=str(ROOT))
    check(f"method script runs (exit 0): {script}", rr.returncode == 0,
          rr.stderr.decode("utf-8", "replace")[-200:])

# ------------------------------------------------------------------ 4. line pointers
# A pointer must resolve AND its content must match an anchor.  The anchor
# table is the round-14 lesson applied: existence is not evidence.
ANCHORS = {
    ("did.mbt", 276): r"require\(n_folds <= data\.n_obs\(\)\)",
    ("did.mbt", 317): r"abort\(",
    ("did.mbt", 262): r'score~ : String = "observational"',
    ("did_binary.mbt", 352): r"pub fn DoubleMLDIDBinary::new",
    ("did_binary.mbt", 439): r"DoubleMLDID::new\(",
    ("did_binary.mbt", 441): r"Matrix::zeros\(4,",
    ("did_binary.mbt", 412): r"Placeholder",
    ("did_binary.mbt", 367): r'score~ : String = "observational"',
    ("did_cross_section.mbt", 191): r'score~ : String = "observational"',
    ("did_cs_binary.mbt", 731): r'score~ : String = "observational"',
    ("did_cs_binary.mbt", 756): r'require\(score == "observational"\)',
    ("lplr.mbt", 354): r'score~ : String = "nuisance_space"',
    ("plpr.mbt", 554): r'score~ : String = "partialling out"',
    ("plr.mbt", 417): r'score~ : String = "partialling-out"',
    ("plr.mbt", 676): r'score~ : String = "partialling-out"',
    ("plr.mbt", 421): r"require\(plr_is_po_score\(score\) \|\| plr_is_iv_score\(score\)\)",
    ("plr.mbt", 394): r"fn plr_is_po_score",
    ("plr.mbt", 395): r'"partialling-out" \|\| score == "partialling out"',
    ("plr.mbt", 400): r'"iv-type" \|\| score == "IV-type"',
    ("tune.mbt", 355): r'score~ : String = "partialling-out"',
    ("did_cs.mbt", 320): r"pub fn DoubleMLDIDCS::new",
    ("did_cs.mbt", 1240): r"pub fn DoubleMLDIDCS::fit",
    ("did_cs.mbt", 667): r"NaN",
    ("did_cs.mbt", 1390): r"nu2",
    ("did_cs.mbt", 1394): r"nu2",
    ("did_cs.mbt", 1407): r"mean\(d1t0\)",
    ("did_cs.mbt", 1426): r"let ti = self\.data\.t\[i\]\.to_double\(\)",
    ("did_cs.mbt", 1334): r"cond_d0_t0",
    ("did_cross_section.mbt", 1476): r"p_hat = mean\(d\)",
    ("sensitivity.mbt", 534): r"pub struct SensitivityResult",
    ("apo.mbt", 50): r"ml_m",
    ("cvar.mbt", 359): r"cf_y",
    ("cvar.mbt", 377): r"cf_y~ : Double = 0\.05",
    ("cvar.mbt", 378): r"cf_d~ : Double = 0\.05",
    ("iivm.mbt", 187): r"ml_r",
    ("did_multi.mbt", 326): r"ignore\(t_pre\)",
    ("did_multi.mbt", 117): r"require\(resolved\.length\(\) > 0\)",
    ("logistic.mbt", 134): r"require\(yi == 0\.0 \|\| yi == 1\.0\)",
    ("dgp_did_CS2021.mbt", 50): r"let n_periods = 4",
    ("lplr.mbt", 352): r"pub fn DoubleMLLPLR::new",
    ("lplr.mbt", 361): r"LogisticRegression::new\(\)",
    ("dgp_lplr_test.mbt", 41): r"test \"LPLR_estimator_recovers_theta\"",
}
PTR_RE = re.compile(r"`([A-Za-z0-9_]+\.mbt):(\d+)(?:-(\d+))?`")


def pkg_lines(name):
    p = PKG / name
    if not p.is_file():
        return None
    return read(p).split("\n")


unresolved, wrong_content = [], []
for rec in RECORDS:
    for m in PTR_RE.finditer(texts[rec]):
        fn, ln = m.group(1), int(m.group(2))
        lines = pkg_lines(fn)
        if lines is None:
            unresolved.append(f"{Path(rec).name} -> {fn} (no such file)")
            continue
        if ln > len(lines):
            unresolved.append(f"{Path(rec).name} -> {fn}:{ln} (file has {len(lines)} lines)")
            continue
        anchor = ANCHORS.get((fn, ln))
        if anchor and not re.search(anchor, lines[ln - 1]):
            wrong_content.append(f"{Path(rec).name} -> {fn}:{ln} :: {lines[ln-1].strip()[:60]}")
check("every `file.mbt:NNN` pointer in the six records resolves",
      not unresolved, "; ".join(unresolved[:8]))
check("every anchored pointer's CONTENT matches its anchor",
      not wrong_content, "; ".join(wrong_content[:8]))

# the anchors themselves must still hold against the live tree
anchor_drift = []
for (fn, ln), rx in ANCHORS.items():
    lines = pkg_lines(fn)
    if lines is None or ln > len(lines) or not re.search(rx, lines[ln - 1]):
        anchor_drift.append(f"{fn}:{ln} ({rx})")
check("every anchor in the verifier still matches the live tree",
      not anchor_drift, "; ".join(anchor_drift[:8]))

# ------------------------------------------------------------------ 5. the numbers
pkg = A["package"]
learner = A["learner"]
ctor = A["constructor_defaults"]

check("package census: 220 .mbt files", pkg["total_mbt"] == 220, str(pkg["total_mbt"]))
check("package census: 65 production", pkg["production"] == 65, str(pkg["production"]))
check("package census: 129 blackbox", pkg["blackbox"] == 129, str(pkg["blackbox"]))
check("package census: 26 whitebox", pkg["whitebox"] == 26, str(pkg["whitebox"]))
check("package census: 34 ::new definitions", pkg["new_definitions"] == 34,
      str(pkg["new_definitions"]))

check("learner sites: 15 ml_g", learner["ml_g"]["sites"] == 15)
check("learner sites: 15 ml_m", learner["ml_m"]["sites"] == 15)
check("learner sites: 2 ml_l", learner["ml_l"]["sites"] == 2)
check("learner sites: 1 ml_r", learner["ml_r"]["sites"] == 1)
check("learner sites: 33 total", A["learner_total_sites"] == 33)
check("ml_m split: 7 logistic / 8 linear",
      learner["ml_m"]["kinds"].get("logistic_regression") == 7
      and learner["ml_m"]["kinds"].get("linear_regression") == 8,
      json.dumps(learner["ml_m"]["kinds"]))
check("ml_m: LPLR has migrated to logistic",
      "DoubleMLLPLR" in learner["ml_m"]["estimators"]
      and A["mlm_table"][[r["estimator"] for r in A["mlm_table"]].index("DoubleMLLPLR")]["port"]
      == "logistic_regression")
check("ml_m invariant: every regressor-defaulted ml_m demands a classifier upstream",
      A["mlm_relation_subset"] is True)
check("ml_m invariant: no regressor-defaulted ml_m is upstream-legal as a regressor",
      A["mlm_relation_no_legal_regressor"] is True)
check("ml_m: 8 estimators default to a regressor", len(A["mlm_port_linear"]) == 8,
      str(A["mlm_port_linear"]))

for pname, want_sites in [("n_folds", 19), ("in_sample_normalization", 6),
                           ("propensity_clip", 14), ("n_folds_inner", 1),
                           ("normalize_ipw", 3), ("score", 6), ("seed", 19),
                           ("n_rep", 16), ("quantile", 3), ("treatment", 3),
                           ("anticipation_periods", 4), ("control_group", 4)]:
    got = ctor.get(pname, {}).get("sites")
    check(f"constructor default `{pname}`: {want_sites} sites", got == want_sites, str(got))

check("n_folds: 17 sites at 2, 2 at 5",
      ctor["n_folds"]["values"].get("2") == 17 and ctor["n_folds"]["values"].get("5") == 2,
      json.dumps(ctor["n_folds"]["values"]))
check("in_sample_normalization: false at all 6 sites",
      ctor["in_sample_normalization"]["values"].get("false") == 6)
check("score: 4 observational / 1 nuisance_space / 1 'partialling out'",
      ctor["score"]["values"].get('"observational"') == 4
      and ctor["score"]["values"].get('"nuisance_space"') == 1
      and ctor["score"]["values"].get('"partialling out"') == 1)

check("upstream: 18 classes validate a score", len(A["upstream_score"]) == 18,
      str(len(A["upstream_score"])))
check("upstream: `missing-at-random` is SSM's score",
      A["upstream_score"].get("irm/ssm.py", {}).get("accepts")
      == ["missing-at-random", "nonignorable"])
check("upstream: the 5 classes the old table missed are present",
      all(k in A["upstream_score"] for k in
          ("irm/cvar.py", "irm/lpq.py", "irm/pq.py", "irm/ssm.py", "plm/pliv.py")))

check("port score: plr.mbt accepts the space spelling",
      "partialling out" in A["port_score"].get("plr.mbt", []),
      str(A["port_score"].get("plr.mbt")))
check("port score: plpr.mbt does NOT accept the hyphen spelling",
      "partialling-out" not in A["port_score"].get("plpr.mbt", []),
      str(A["port_score"].get("plpr.mbt")))

# capture-scope divergence
cc = A["capture_class"]
check("capture scope: 51 upstream (estimator, parameter) pairs",
      cc["upstream_pairs"] == 51, str(cc["upstream_pairs"]))
check("capture scope: 30 declared on both sides", cc["both_declare"] == 30,
      str(cc["both_declare"]))
check("capture scope: 18 match, 12 differ", cc["match"] == 18 and cc["value_diff"] == 12,
      f"match={cc['match']} diff={cc['value_diff']}")
check("capture scope: 21 upstream-only (one-sided)", cc["upstream_only"] == 21,
      str(cc["upstream_only"]))
check("capture scope: 45 port-only (one-sided)", cc["port_only"] == 45,
      str(cc["port_only"]))
check("capture scope: the 49/42/7 triple does NOT reproduce",
      (cc["value_diff"] + cc["upstream_only"], cc["upstream_only"], cc["value_diff"])
      != (49, 42, 7))

# provenance
pe = A["provenance_evidence"]
check("provenance: upstream DoubleMLDIDCS has no control_group/anticipation_periods",
      not pe["DoubleMLDIDCS"]["control_group"]
      and not pe["DoubleMLDIDCS"]["anticipation_periods"])
check("provenance: upstream DoubleMLDIDMulti has both",
      pe["DoubleMLDIDMulti"]["control_group"]
      and pe["DoubleMLDIDMulti"]["anticipation_periods"])
check("provenance: upstream DoubleMLDIDCS takes DoubleMLDIDData (repeated cross-sections)",
      pe["DoubleMLDIDCS"]["data_types"] == ["DoubleMLDIDData"],
      str(pe["DoubleMLDIDCS"]["data_types"]))
check("provenance: upstream DoubleMLDIDMulti takes DoubleMLPanelData",
      pe["DoubleMLDIDMulti"]["data_types"] == ["DoubleMLPanelData"],
      str(pe["DoubleMLDIDMulti"]["data_types"]))
check("provenance: the port's DoubleMLDIDCS has both staggered parameters",
      A["port_did_params"].get("DoubleMLDIDCS", {}).get("control_group")
      and A["port_did_params"].get("DoubleMLDIDCS", {}).get("anticipation_periods"))
check("provenance: the port's DoubleMLDIDCrossSection has neither",
      not A["port_did_params"].get("DoubleMLDIDCrossSection", {}).get("control_group")
      and not A["port_did_params"].get("DoubleMLDIDCrossSection", {}).get("anticipation_periods"))
check("provenance: port->upstream map crosses the DID pair",
      A["port2up"].get("DoubleMLDIDCrossSection") == "DoubleMLDIDCS"
      and A["port2up"].get("DoubleMLDIDCS") == "DoubleMLDIDMulti")

# ------------------------------------------------------------------ 6. the records' text
R_LEARNER = texts["_verify/LEARNER_DEFAULTS_1530.md"]
R_SCORE = texts["_verify/SCORE_VOCABULARY_1550.md"]
R_NF = texts["_verify/N_FOLDS_1570.md"]
R_ISN = texts["_verify/IN_SAMPLE_NORMALIZATION_1570.md"]
R_PAR = texts["_verify/PARITY_COMMENTS_1570.md"]
R_PORT = texts["_verify/PORT_VS_UPSTREAM_DEFAULTS_1540.md"]


def body(txt):
    """The record MINUS its leading re-audit banner.

    The banner is a `was -> now` table, so it legitimately quotes the OLD
    values.  A stale-claim check must look at the BODY only -- otherwise a
    correct banner would fail the check it exists to satisfy.

    A banner line is a blockquote line (`>`), a blank line, or a continuation
    of a blockquote paragraph (indented, no `>`).  The banner ends at the
    first line that is none of those.
    """
    out = []
    lines = txt.split("\n")
    # the banner starts at the first blockquote line; the title (and anything
    # before it) is not part of it
    start = next((i for i, ln in enumerate(lines) if ln.startswith(">")), 0)
    out.extend(lines[:start])
    in_banner = True
    prev_quote = False
    for ln in lines[start:]:
        if in_banner:
            is_quote = ln.startswith(">")
            is_cont = (not is_quote) and prev_quote and ln.startswith("  ")
            is_blank = ln.strip() == ""
            if is_quote or is_cont or is_blank:
                prev_quote = is_quote
                continue                      # banner line: DROPPED
            in_banner = False
        out.append(ln)
    return "\n".join(out)


B_LEARNER, B_SCORE = body(R_LEARNER), body(R_SCORE)
B_NF, B_ISN = body(R_NF), body(R_ISN)
B_PAR, B_PORT = body(R_PAR), body(R_PORT)

check("LEARNER: states 220 .mbt files", "220" in R_LEARNER and "213" not in R_LEARNER.split("Scope:")[1][:80])
check("LEARNER: states 33 learner default sites", "33 learner" in R_LEARNER)
check("LEARNER: the stale 12/12 inventory is gone",
      "`ml_g` | 12 |" not in B_LEARNER and "`ml_m` | 12 |" not in B_LEARNER)
check("LEARNER: states the 15/15 inventory", "`ml_g` | 15 |" in B_LEARNER and "`ml_m` | 15 |" in B_LEARNER)
check("LEARNER: states the 7/8 ml_m split",
      "`logistic_regression` × 7" in B_LEARNER and "`linear_regression` × 8" in B_LEARNER)
check("LEARNER: no longer claims the ml_m queue is closed",
      "## 2. The `ml_m` queue is CLOSED" not in B_LEARNER)
check("LEARNER: records the 8/8 upstream-classifier relation",
      "8 of 8" in B_LEARNER)

check("SCORE: no longer claims the port rejects upstream's spelling",
      "The port rejects upstream's own default spelling" not in B_SCORE)
check("SCORE: records that the spelling was accepted in v0.155.0",
      "8308f09" in R_SCORE)
check("SCORE: the withdrawn single-spelling intersection is gone",
      'port accepted  ∩  upstream accepted  =  { "IV-type" }' not in B_SCORE)
check("SCORE: states the two-spelling PLR intersection",
      "`{partialling out, IV-type}`" in B_SCORE)
check("SCORE: the rotted pointers are gone",
      "`did.mbt:231`" not in B_SCORE and "`plr.mbt:388`" not in B_SCORE
      and "`lplr.mbt:350`" not in B_SCORE)
check("SCORE: states the 18-class upstream vocabulary",
      "18 upstream classes validate a `score`" in B_SCORE)
check("SCORE: names the five classes the old table missed",
      all(k in R_SCORE for k in ("irm/cvar.py", "irm/lpq.py", "irm/pq.py",
                                 "irm/ssm.py", "plm/pliv.py")))

check("N_FOLDS: the rotted DIDCS::fit pointer is gone", "`did_cs.mbt:1620`" not in R_NF)
check("N_FOLDS: states the current pointer", "`did_cs.mbt:1240`" in R_NF)

check("ISN: the 20x headline is withdrawn",
      "**The port's `DoubleMLDIDCS` is ~20× more sensitive to this flag than" in B_ISN
      and "WITHDRAWN" in B_ISN)
check("ISN: states the like-for-like comparison", "0.039" in B_ISN and "0.048" in B_ISN)
check("ISN: the 49/42/7 triple is withdrawn", "49 / 42 / 7" in R_ISN
      and "does not reproduce" in R_ISN)
check("ISN: states the 51/30/12/21/45 live numbers",
      all(s in B_ISN for s in ("**51**", "**30**", "**12**", "**21**", "**45**")))

check("PARITY: the rotted pointers are gone",
      "`apo.mbt:52-60`" not in B_PAR and "`cvar.mbt:354-357`" not in B_PAR
      and "`iivm.mbt:185`" not in B_PAR)
check("PARITY: no longer claims 17 estimators for the cf default",
      "all 17 estimators" not in B_PAR)
check("PARITY: states that cf is a method default, not a constructor parameter",
      "sensitivity_analysis()" in R_PAR)

check("PORT: the rotted file count is gone", "216 `.mbt` files" not in B_PORT)
check("PORT: states 220 .mbt files", "**220** `.mbt` files" in B_PORT)
check("PORT: the withdrawn single intersection is gone",
      'intersect only at\n> `"IV-type"`' not in B_PORT
      and "intersect only at" not in B_PORT)
check("PORT: the rotted pointers are gone",
      "`did.mbt:245`" not in B_PORT and "`did_cs.mbt:1328`" not in B_PORT
      and "`did_cs.mbt:1347`" not in B_PORT and "`did_cs.mbt:1259-1275`" not in B_PORT
      and "`did_cs.mbt:635`" not in B_PORT and "`did_cs.mbt:1388`" not in B_PORT)

# every record carries a re-audit banner
for rec, txt in texts.items():
    check(f"banner present: {Path(rec).name}",
          "Re-audited 2026-10-20" in txt and "What is NOT verified" in txt)

# ------------------------------------------------------------------ 7. README
check("README: 19 name-identical upstream rows", "**19** match a" in README
      or "**19** are marked *(upstream)*" in README)
check("README: no longer claims 20 name-identical",
      "**20** match a\nclass of the same name" not in README
      and "**20** are marked *(upstream)*" not in README)
check("README: no longer claims DIDCrossSection has no upstream counterpart",
      "has no upstream counterpart at all" not in README
      and "`DoubleMLDIDCrossSection` has no upstream counterpart" not in README)
check("README: the estimator table's DIDCS row no longer claims upstream's DIDMulti",
      "*(upstream, renamed)* -- upstream `DoubleMLDIDMulti` |" not in README,
      "round 16 moved DIDCS to *(upstream design, no 1:1 class)*: upstream's "
      "DoubleMLDIDMulti is the port's DoubleMLDIDMulti, 1:1")
check("README: the estimator table marks DIDCS as having no 1:1 upstream class",
      "| `DoubleMLDIDCS` | observational | DID with staggered adoption (Callaway-Sant'Anna) "
      "*(upstream design, no 1:1 class)*" in README)
check("README: the estimator table marks DIDCrossSection as renamed",
      "| `DoubleMLDIDCrossSection` | observational | Sant'Anna-Zhao 2020 cross-section DID *(upstream, renamed)* -- upstream `DoubleMLDIDCS` |" in README)
check("README: no longer claims a port-only estimator",
      "The one genuinely\nport-only estimator" not in README)
check("README: the Status table file count is still 220/65/129/26",
      "**220** `.mbt` files (**65** production + **129** blackbox test + **26** whitebox test)" in README)
# The version is DERIVED from moon.mod, not pinned to a list of recent
# versions: a pinned list is a list that rots on the next release, and this
# check is exactly what rotted -- it failed on v0.164.11 because the literal
# still said 0.164.9 / 0.164.10.
_moon_mod = read(ROOT / "moonbit_doubleML" / "moon.mod")
_m = re.search(r'version\s*=\s*"([0-9.]+)"', _moon_mod)
check("README: the Status table version matches moon.mod",
      bool(_m) and _m.group(1) in README,
      "moon.mod says %s" % (_m.group(1) if _m else "?"))

# ------------------------------------------------------------------ report
print()
fails = [r for r in results if not r[1]]
for name, ok, detail in results:
    if not ok:
        print(f"  FAIL  {name}" + (f"   [{detail}]" if detail else ""))
print()
print(f"checks: {len(results)}   passed: {len(results) - len(fails)}   failed: {len(fails)}")
raise SystemExit(1 if fails else 0)
