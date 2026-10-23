#!/usr/bin/env python3
"""Round 39 verifier: the AGENT SKILL's claims about the tree.

WHAT THIS PROVES
=================
`skills/moonbit_doubleML.md` is a SECOND USER-FACING DOCUMENT.  It is what a
coding agent reads before writing code against this library, so every claim
in it is a promise the tree has to keep -- exactly like the README's.

Until round 39 no check read it at all, and the rot showed immediately: the
skill quoted the api_server's declared library pin as

    "riantr/moonbit_doubleML@0.52.0"

while `examples/api_server/moon.mod` declared 0.164.32.  That is the SAME
rot the two tutorials had (fixed in v0.164.3), in the same shape, missed for
132 releases because the file is a DOCUMENT and nothing read it.

WHAT IS DERIVED, NOT ASSERTED
==============================
Every number and every name below is measured from the tree:

  * the whitebox test set -- the file count, the test-case count, and the
    two files the skill names with their case counts;
  * the example driver binaries -- the directory count and the `main.mbt` each
    one carries;
  * the Python cross-validators -- the `validate_*_with_python.py` glob, the
    three repo-level harnesses the glob does not pick up, and which scripts
    take their reference from the upstream wheel;
  * the learner dispatch -- the variants, by NAME;
  * the accessor set -- which estimators expose all four accessors, and which
    six do not, by NAME;
  * the estimator files -- the 19 files, and the three that hold two structs;
  * the DGP modules -- the 17 modules and the 35 files in all;
  * the api_server's declared pin.

WHAT IS NOT CHECKED, AND WHY
============================
The upstream `doubleml` wheel is not installed here, so "which script
imports it" is read from the scripts' own source, not from an import run.
The registry is not consulted: "the latest published version" is a network
fact, and a check that needs the network cannot be part of a contract that
must also run in a fresh clone.  The pin's FRESHNESS is checked against the
library's own current version, which is what the bump script maintains.

Run: python _verify/_verify_skill_claims_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
SKILL_PATH = os.path.join(ROOT, "skills", "moonbit_doubleML.md")
README_PATH = os.path.join(ROOT, "README.mbt.md")
MOONMOD = os.path.join(PKG, "moon.mod")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-62s %s" % ("ok" if ok else "*** FAIL ***", label))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))
        print("      %s" % detail)


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def flat(s):
    return re.sub(r"\s+", " ", s)


skill = read(SKILL_PATH)
sflat = flat(skill)
readme = read(README_PATH)
rflat = flat(readme)

tracked = set()
out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True,
                     encoding="utf-8", errors="replace").stdout
for line in out.splitlines():
    if line.strip():
        tracked.add(line.strip())

pkg_files = sorted(f for f in os.listdir(PKG) if f.endswith(".mbt"))
prod = [f for f in pkg_files if not f.endswith("_test.mbt")
        and not f.endswith("_wbtest.mbt")]
black = [f for f in pkg_files if f.endswith("_test.mbt")]
white = [f for f in pkg_files if f.endswith("_wbtest.mbt")]
lib = "\n".join(read(os.path.join(PKG, f)) for f in prod)

# --------------------------------------------------------------------------- #
print()
print("A. the api_server's declared library pin")

m = re.search(r'"riantr/moonbit_doubleML@([\d.]+)"', skill)
quoted = m.group(1) if m else None
manifest = read(os.path.join(ROOT, "examples", "api_server", "moon.mod"))
m2 = re.search(r'"riantr/moonbit_doubleML@([\d.]+)"', manifest)
declared = m2.group(1) if m2 else None
print("   the skill quotes : %s   the manifest declares: %s" % (quoted, declared))
check("the skill quotes the api_server's declared pin", quoted == declared,
      "skill %r vs manifest %r" % (quoted, declared))

mod = read(MOONMOD)
m3 = re.search(r'version = "([^"]+)"', mod)
current = m3.group(1) if m3 else None
print("   the library's own version: %s" % current)
check("the quoted pin is the library's current version", quoted == current,
      "quoted %r vs current %r" % (quoted, current))
check("the skill's pin is bumped with the release, not frozen",
      "riantr/moonbit_doubleML@%s" % current in skill,
      "the skill does not carry the current version")

# --------------------------------------------------------------------------- #
print()
print("B. the whitebox test set")

TESTCASE = re.compile(r'\btest\s+"')
per_file = {}
for f in white:
    per_file[f] = len(TESTCASE.findall(read(os.path.join(PKG, f))))
total_cases = sum(per_file.values())
print("   %d files, %d test cases" % (len(white), total_cases))
check("the skill's 26 whitebox files is the file count", len(white) == 26,
      "got %d" % len(white))
check("the skill's 169 whitebox test cases is the case count",
      total_cases == 169, "got %d" % total_cases)
check("kfold_wbtest.mbt holds the 5 cases the skill names",
      per_file.get("kfold_wbtest.mbt") == 5,
      "got %s" % per_file.get("kfold_wbtest.mbt"))
check("matrix_wbtest.mbt holds the 6 cases the skill names",
      per_file.get("matrix_wbtest.mbt") == 6,
      "got %s" % per_file.get("matrix_wbtest.mbt"))
check("the skill states 26 and 169",
      "**26** `*_wbtest.mbt` files" in sflat and "**169** test cases" in sflat,
      "the skill's whitebox figures are not the ones checked")

# --------------------------------------------------------------------------- #
print()
print("C. the example driver binaries")

ex_root = os.path.join(ROOT, "examples")
ex_dirs = sorted(d for d in os.listdir(ex_root)
                  if os.path.isdir(os.path.join(ex_root, d)))
with_main = [d for d in ex_dirs
             if os.path.isfile(os.path.join(ex_root, d, "main.mbt"))]
print("   %d example directories, %d with a main.mbt" % (len(ex_dirs), len(with_main)))
check("the skill's 21 driver binaries is the directory count", len(ex_dirs) == 21,
      "got %d" % len(ex_dirs))
check("every example directory carries a main.mbt",
      len(with_main) == len(ex_dirs),
      "without: %s" % [d for d in ex_dirs if d not in with_main])
CLI16 = ["apo", "apos", "cluster", "cvar", "datasets", "did_binary",
         "did_cross_section", "did_cs", "did_cs_binary", "did_multi", "lplr",
         "main", "pava", "plpr", "splitting", "ssm"]
check("the skill's 16 CLI demos all exist",
      all(d in ex_dirs for d in CLI16),
      "missing: %s" % [d for d in CLI16 if d not in ex_dirs])
check("the skill's 16 CLI demos are 16",
      len(CLI16) == 16 and len(set(CLI16)) == 16, "%d names" % len(CLI16))
NON_CLI = {"fuzz", "bitexact", "parity", "consumer_demo", "api_server"}
check("the examples the skill calls NOT CLI demos are exactly the other five",
      set(ex_dirs) - set(CLI16) == NON_CLI,
      "got %s" % sorted(set(ex_dirs) - set(CLI16)))

# --------------------------------------------------------------------------- #
print()
print("D. the Python cross-validators")

vp = sorted(f for f in os.listdir(ROOT)
            if f.startswith("validate_") and f.endswith("_with_python.py"))
others = sorted(f for f in os.listdir(ROOT)
                if f.startswith("validate_") and f.endswith(".py")
                and not f.endswith("_with_python.py"))
print("   %d validate_*_with_python.py, %d others: %s" % (len(vp), len(others), others))
check("the skill's 24 cross-validators is the glob's size", len(vp) == 24,
      "got %d" % len(vp))
HARNESSES = ["validate_plotting_scope.py", "validate_splitting_contract.py",
             "validate_suite_meta.py"]
check("the three harnesses the skill names are exactly the other three",
      others == HARNESSES, "got %s" % others)
check("each harness is tracked", all(h in tracked for h in HARNESSES),
      "not tracked: %s" % [h for h in HARNESSES if h not in tracked])
check("each harness lives at the repo root, as the skill says",
      all(os.path.isfile(os.path.join(ROOT, h)) for h in HARNESSES))
upstream_imports = [f for f in vp
                    if re.search(r"^\s*(?:import\s+doubleml\b|from\s+doubleml\b)",
                                 read(os.path.join(ROOT, f)), re.M)]
print("   %d of the %d import the upstream wheel" % (len(upstream_imports), len(vp)))
check("the skill's nine upstream-importing scripts is the count",
      len(upstream_imports) == 9, "got %d: %s" % (len(upstream_imports), upstream_imports))
check("the skill's fifteen hand-rolled scripts is the rest",
      len(vp) - len(upstream_imports) == 15,
      "got %d" % (len(vp) - len(upstream_imports)))

# --------------------------------------------------------------------------- #
print()
print("E. the learner dispatch")

DISPATCH = os.path.join(PKG, "learner.mbt")
dispatch_src = read(DISPATCH) if os.path.isfile(DISPATCH) else ""
variants = []
if dispatch_src:
    body = dispatch_src.split("enum LearnerDispatch", 1)[-1]
    variants = sorted(set(re.findall(r"^\s*([A-Z]\w+)\(", body, re.M)))
print("   the variants: %s" % variants)
REGRESSORS = ["Constant", "ElasticNet", "GradientBoosting", "Lasso",
              "LinearRegression", "Noop", "RandomForest", "Ridge"]
CLASSIFIERS = ["GradientBoostingClassifier", "LogisticRegression",
               "RandomForestClassifier"]
check("the skill's 11 learner variants is the count", len(variants) == 11,
      "got %d: %s" % (len(variants), variants))
check("the 8 regressors the skill names are exactly the regressors",
      sorted(REGRESSORS) == sorted(v for v in variants if v not in CLASSIFIERS),
      "got %s" % sorted(v for v in variants if v not in CLASSIFIERS))
check("the 3 classifiers the skill names are exactly the classifiers",
      sorted(CLASSIFIERS) == sorted(v for v in variants if v in CLASSIFIERS),
      "got %s" % sorted(v for v in variants if v in CLASSIFIERS))
check("the skill states 11 variants",
      "exactly 11 `LearnerDispatch` variants" in sflat,
      "the skill's learner count is not the one checked")

# --------------------------------------------------------------------------- #
print()
print("F. the accessor set")

EST = re.compile(r"pub\s+struct\s+(DoubleML\w+)")
ests = sorted({s for s in EST.findall(lib) if not s.endswith("Data")})
bodies = {}
for s in ests:
    bodies[s] = "".join(read(os.path.join(PKG, f)) for f in prod
                        if ("struct %s" % s) in read(os.path.join(PKG, f)))
FOUR = ("coef", "se", "confint", "bootstrap")


def has(s, a):
    return bool(re.search(r"pub\s+fn\s+%s::%s\b" % (s, a), bodies.get(s, "")))


full = sorted(s for s in ests if all(has(s, a) for a in FOUR))
diff = sorted(s for s in ests if not all(has(s, a) for a in FOUR))
print("   %d expose all four; %d differ: %s" % (len(full), len(diff), diff))
check("the skill's 16 estimators with all four accessors is the count",
      len(full) == 16, "got %d" % len(full))
check("the skill's six without is the count", len(diff) == 6,
      "got %d: %s" % (len(diff), diff))
SKILL_SIX = ["DoubleMLAPOS", "DoubleMLQTE", "DoubleMLDIDCS",
              "DoubleMLDIDMulti", "DoubleMLBLP", "DoubleMLPolicyTree"]
check("the six the skill names are exactly the six that differ",
      sorted(SKILL_SIX) == diff, "got %s" % diff)
SUBS = {
    "DoubleMLAPOS": ["coefs", "ses"],
    "DoubleMLQTE": ["coefs", "ses"],
    "DoubleMLDIDCS": ["coef_at", "se_at"],
    "DoubleMLDIDMulti": ["coef_at_idx", "se_at_idx"],
    "DoubleMLBLP": ["confint_joint"],
}
for s, names in SUBS.items():
    check("%s exposes the %s the skill names" % (s, " and ".join(names)),
          all(has(s, a) for a in names),
          "missing: %s" % [a for a in names if not has(s, a)])
check("DoubleMLPolicyTree has no scalar coefficient",
      not has("DoubleMLPolicyTree", "coef")
      and not has("DoubleMLPolicyTree", "coefs"),
      "it does expose a coefficient accessor")

# --------------------------------------------------------------------------- #
print()
print("G. the estimator files")

est_files = sorted(f for f in prod
                    if any(s for s in EST.findall(read(os.path.join(PKG, f)))
                           if not s.endswith("Data")))
two = []
for f in est_files:
    n = len({s for s in EST.findall(read(os.path.join(PKG, f)))
             if not s.endswith("Data")})
    if n >= 2:
        two.append(f)
print("   %d files hold the %d estimator structs; %d hold two: %s"
      % (len(est_files), len(ests), len(two), two))
check("the skill's 19 estimator files is the count", len(est_files) == 19,
      "got %d" % len(est_files))
THREE = ["apo.mbt", "quantile.mbt", "blp_policy.mbt"]
check("the three two-struct files the skill names are exactly the three",
      sorted(THREE) == sorted(two), "got %s" % sorted(two))
for f in THREE:
    check("%s holds two estimator structs" % f,
          len({s for s in EST.findall(read(os.path.join(PKG, f)))
               if not s.endswith("Data")}) == 2)

# --------------------------------------------------------------------------- #
print()
print("H. the DGP modules")

dgp_prod = sorted(f for f in prod if f.startswith("dgp_"))
dgp_test = sorted(f for f in black if f.startswith("dgp_"))
print("   %d modules, %d test files, %d files in all"
      % (len(dgp_prod), len(dgp_test), len(dgp_prod) + len(dgp_test)))
check("the skill's 17 DGP modules is the count", len(dgp_prod) == 17,
      "got %d" % len(dgp_prod))
check("the skill's 35 DGP files in all is the count",
      len(dgp_prod) + len(dgp_test) == 35,
      "got %d" % (len(dgp_prod) + len(dgp_test)))
check("seed.mbt exists and holds the seeded RNG helper",
      os.path.isfile(os.path.join(PKG, "seed.mbt"))
      and "chacha8_rng" in read(os.path.join(PKG, "seed.mbt")))

# --------------------------------------------------------------------------- #
print()
print("I. every file the skill names")

# A name that carries a `*` is a PATTERN, not a file: the promise is that the
# pattern matches something.  A name that belongs to ANOTHER repository is a
# reference to a file that is not ours to keep -- the skill says it "mirrors
# moonbit-community/rabbita's `skills/rabbita.md` layout", so that file is
# supposed to be absent here.
NAMED = sorted(set(re.findall(r"`([A-Za-z0-9_.*/]+\.(?:mbt|py|md|pkg))`", skill)))
# A name that carries a `*` is a PATTERN: the promise is that the pattern
# matches something.  A name that STARTS with `_` is a SUFFIX -- the skill
# writes "`_test.mbt` cannot reach" to mean the `*_test.mbt` family, and a
# suffix is not a file name.  A name that belongs to ANOTHER repository is a
# reference to a file that is not ours to keep -- the skill says it "mirrors
# moonbit-community/rabbita's `skills/rabbita.md` layout", so that file is
# supposed to be absent here.
GLOBS = [n for n in NAMED if "*" in n]
SUFFIXES = [n for n in NAMED if "*" not in n and n.startswith("_")]
FOREIGN = [n for n in NAMED if n == "skills/rabbita.md"]
CONCRETE = [n for n in NAMED if "*" not in n and n not in FOREIGN
            and not n.startswith("_")]
print("   the skill names %d: %d concrete, %d pattern(s), %d suffix, %d foreign"
      % (len(NAMED), len(CONCRETE), len(GLOBS), len(SUFFIXES), len(FOREIGN)))
missing = [n for n in CONCRETE
           if not (os.path.exists(os.path.join(PKG, n))
                   or os.path.exists(os.path.join(ROOT, n))
                   or os.path.exists(os.path.join(ROOT, "examples", n)))]
check("every concrete file the skill names exists", not missing,
      "missing: %s" % missing)
BASENAMES = set(os.path.basename(p) for p in tracked)
for g in GLOBS:
    rx = re.compile("^" + re.escape(g).replace(r"\*", ".*") + "$")
    hits = [f for f in BASENAMES if rx.match(f)]
    check("the pattern `%s` matches at least one tracked file" % g,
          bool(hits), "it matches nothing")
check("the skill names rabbita's own skill file as a FOREIGN reference",
      "moonbit-community/rabbita" in skill and "skills/rabbita.md" in skill,
      "the foreign reference is not attributed")
check("dgp_recovery_test.mbt is TRACKED, as the skill's band rule assumes",
      "moonbit_doubleML/dgp_recovery_test.mbt" in tracked,
      "it is not in the repository")

# --------------------------------------------------------------------------- #
print()
print("J. the DIDCS band measurement")

REC = os.path.join(ROOT, "_verify", "PORT_VS_UPSTREAM_DEFAULTS_1540.md")
rec = read(REC) if os.path.isfile(REC) else ""
changelog = read(os.path.join(ROOT, "CHANGELOG.md"))
check("the tracked record holds the 14.41 figure and the 12 seeds the skill quotes",
      "14.41" in rec and "12 seeds" in rec,
      "the record does not carry those figures")
check("the CHANGELOG holds the 2.41 SE-unit figure the skill quotes",
      "2.41" in changelog, "the CHANGELOG does not carry that figure")
check("the skill quotes the same figures",
      "14.41" in sflat and "2.41" in sflat and "12 seeds" in sflat,
      "the skill's figures are not the ones the record holds")

# --------------------------------------------------------------------------- #
print()
print("K. the toolchain literal, against the README's own")

m = re.search(r"\| Toolchain \| `(moon [\d.]+)`", rflat)
tool_readme = m.group(1) if m else None
tool_skill = re.search(r"`(moon [\d.]+)`", sflat)
tool_skill = tool_skill.group(1) if tool_skill else None
print("   the README says %r; the skill says %r" % (tool_readme, tool_skill))
check("the skill and the README name the same toolchain",
      tool_skill is not None and tool_skill == tool_readme,
      "skill %r vs README %r" % (tool_skill, tool_readme))

# --------------------------------------------------------------------------- #
print()
print("L. the counts the skill and the README share")

for label, skill_pat, readme_pat in [
    ("22 estimators", r"the 22 estimators", r"\*\*22\*\* `DoubleML\*` estimator structs"),
    ("19 estimator files", r"pack into 19", r"in 19 production files"),
    ("21 driver binaries", r"21 driver binaries", r"\*\*21 runnable example binaries\*\*"),
    ("24 cross-validators", r"24 of them are named", r"24 Python reference scripts"),
]:
    check("the %s is the same count in both documents" % label,
          re.search(skill_pat, sflat) is not None
          and re.search(readme_pat, rflat) is not None,
          "the two documents do not both state it")

# --------------------------------------------------------------------------- #
print()
print("=" * 74)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
