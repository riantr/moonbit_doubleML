#!/usr/bin/env python3
"""Round 56 verifier: the TUTORIAL pages' numbers that NOTHING was holding.

WHAT THIS EXISTS FOR
====================
Round 54 held the numbers in `README.mbt.md` and in the skill.  The six
TUTORIAL pages under `doc/` -- the ones a reader opens AFTER the README --
and `examples/api_server/README.md` make numbers too: 22 estimators, 11
`LearnerDispatch` variants split 8/3, 18 DGP factories across 17
`dgp_*.mbt` modules, 24 Python validators and 9 `pyexample_*` gates, the
16/3/3 coverage split, the `quantile` / `quantiles` / `depth` defaults, 4
supported backends, two dead dependency entries with 0 imports each, a
16 MiB request-body cap.

A MUTATION PROBE measured who would notice.  It changed one number in one
page, ran every tracked verifier that reads that page, and asked which ones
failed.  Twenty-six of those claims had NO holder: nothing in the
repository's tracked verifiers would have failed if the page had said "17
regressors", "default `[0.7]`" or "the body cap is 32 MiB".

That is round 54's failure in a second place.  A number in prose is a
promise, and a promise nobody watches rots in silence: the next `.mbt`
file would have falsified "17 `dgp_*.mbt` modules" without a single red
line.

THE PROBE IS THE REASON THIS FILE EXISTS, AND IT IS ALSO ITS ARGUMENT
====================================================================
The claims this verifier holds are exactly the ones the probe found
unheld.  Claims that ARE held -- the `score` surface, the DGP signatures,
the coverage table, the test count -- are NOT re-derived here: two
verifiers disagreeing about one file is worse than one verifier being
wrong.  `_verify/_verify_score_argument_1650.py` holds the score counts,
`_verify/_verify_tutorial_claims_1650.py` holds the coverage table and
the DGP signatures, `_verify/_verify_doc_scope_1650.py` holds the
constructor census and the file counts, and `_verify/_verify_doc_claims_1650.py`
holds the api_server's port.

WHAT IS DERIVED, NOT ASSERTED
=============================
Every quantity is measured from the tree -- the estimator census, the
`LearnerDispatch` enum, the DGP factories and the accessors of the types
they RETURN, the Python script families, the constructor signatures and
their defaults, the propensity-learner defaults, the CI workflow, the
api_server's own source.  The claim is PARSED OUT OF THE DOCUMENT: a
reworded sentence changes what is checked, and a page that stops stating a
number simply loses those checks.

A number that appears in two sentences is two promises, so each
document's own statement is its own check.

WHAT IS NOT CHECKED, AND WHY
============================
  * UPSTREAM's counts -- "upstream ships 21 estimator classes", "upstream
    keeps those in four packages" -- are claims about ANOTHER package.  A
    verifier that must run in a fresh clone cannot check them, and the
    upstream tree is not in this repository.  The port's own count, which
    the same sentence states, IS checked.
  * A DATED measurement -- "the band was measured across 12 seeds", "moon
    0.1.20261023 vs CPython 3.13.14: `sqrt` 6/6 bit-exact" -- says which
    measurement it records, and that is the whole of the promise.
  * A RUNTIME verdict -- "1117 / 1117 tests pass on native" -- is what the
    CI gate's transcript records, and `_verify/_verify_shipped_docs_1643.py`
    holds it.

Run: python _verify/_verify_doc_numbers_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-64s %s" % (label[:64], detail))
    else:
        print("  *** FAIL *** %-56s %s" % (label[:56], detail))
        FAILS.append("%s -- %s" % (label, detail))


def git(*args):
    p = subprocess.run(["git"] + list(args), cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return p.returncode, ((p.stdout or "") + (p.stderr or ""))


def read(rel):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        return ""
    return io.open(p, encoding="utf-8", errors="replace").read()


def balanced(text, start, op="(", cl=")"):
    """The index of the closer that matches the opener at `start`."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == op:
            depth += 1
        elif text[i] == cl:
            depth -= 1
            if depth == 0:
                return i
    return -1


# --------------------------------------------------------------------------
# 1.  THE TREE
# --------------------------------------------------------------------------
rc, out = git("ls-files")
TRACKED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]

PKG = "moonbit_doubleML/"
pkg_mbt = [t for t in TRACKED if t.startswith(PKG) and t.endswith(".mbt")
           and "/" not in t[len(PKG):]]
pkg_prod = [t for t in pkg_mbt if not t.endswith("_test.mbt")
            and not t.endswith("_wbtest.mbt")]
PROD_BODY = {rel: read(rel) for rel in pkg_prod}

# -- the estimator census: a `DoubleML*` struct that is not a `*Data` container
ESTIMATORS = sorted(set(
    m.group(1) for rel in pkg_prod
    for m in re.finditer(r"^\s*(?:pub\s+)?(?:struct|enum)\s+(DoubleML[A-Za-z0-9]*)",
                         PROD_BODY[rel], re.M)
    if not m.group(1).endswith("Data")))

# -- the `LearnerDispatch` variants, from the ENUM DEFINITION
variants = []
for rel in pkg_prod:
    body = PROD_BODY[rel]
    if "pub enum LearnerDispatch" in body:
        em = re.search(r"pub enum LearnerDispatch\s*\{(.*?)\n\}", body, re.S)
        if em:
            for ln in em.group(1).splitlines():
                mm = re.match(r"\s{2}([A-Z][A-Za-z0-9]*)\s*\(", ln)
                if mm:
                    variants.append(mm.group(1))
        break
CLASSIFIERS = ("LogisticRegression", "RandomForestClassifier",
               "GradientBoostingClassifier")
learners_reg = [v for v in variants if v not in CLASSIFIERS]
learners_cls = [v for v in variants if v in CLASSIFIERS]

# -- the Python cross-check families
validators = sorted(t for t in TRACKED if t.startswith("validate_")
                     and t.endswith("_with_python.py") and "/" not in t)
pyexamples = sorted(t for t in TRACKED if t.startswith("pyexample_")
                     and t.endswith(".py") and "/" not in t)
# A wheel importer is a script whose CODE imports the upstream package.  The
# `from doubleml... import` form matters as much as the `import doubleml`
# one: two of the nine use it.
WHEEL = re.compile(r"^\s*(?:import\s+doubleml\b|from\s+doubleml\b)", re.M)
wheel = [t for t in validators if WHEEL.search(read(t))]
hand = [t for t in validators if t not in wheel]

# -- the DGP factories, the modules they live in, and the files in all
dgp_mod = sorted(t for t in pkg_mbt if os.path.basename(t).startswith("dgp_")
                  and not t.endswith("_test.mbt"))
dgp_all = sorted(t for t in pkg_mbt if os.path.basename(t).startswith("dgp_"))

# A factory's accessors live on the TYPE IT RETURNS, and that type is not
# always declared in the factory's own module: `make_plr_turrell2018`
# returns `IrmHeterogeneousData`, which `dgp_irm_heterogeneous.mbt` declares.
# So the return type is read first, and the type's methods are looked up
# across the library.
type_methods = {}
for rel in pkg_prod:
    for m in re.finditer(r"pub fn ([A-Za-z0-9_]+)::([A-Za-z_][A-Za-z0-9_]*)\s*\(",
                         PROD_BODY[rel]):
        type_methods.setdefault(m.group(1), set()).add(m.group(2))

factory_type = {}
for rel in dgp_mod:
    body = PROD_BODY.get(rel) or read(rel)
    for m in re.finditer(r"pub fn (make_[A-Za-z0-9_]+)\s*\(", body):
        start = m.end() - 1
        end = balanced(body, start)
        if end < 0:
            continue
        tail = body[end + 1:end + 120]
        rm = re.search(r"->\s*([A-Za-z0-9_]+)", tail)
        if rm:
            factory_type[m.group(1)] = rm.group(1)
FACTORIES = sorted(factory_type)


def has_accessor(factory, name):
    ty = factory_type.get(factory)
    if not ty:
        return False
    return name in type_methods.get(ty, set())


dgp_theta = [f for f in FACTORIES if has_accessor(f, "theta_get")]
dgp_xyz = [f for f in FACTORIES
           if all(has_accessor(f, a) for a in ("x_get", "y_get", "d_get"))]

# -- the recovery tests
recovery_tests = len(re.findall(r'^\s*test\s+"',
                                 read("moonbit_doubleML/dgp_recovery_test.mbt"),
                                 re.M))

# -- the constructor signatures: the `score` slot and the defaults
def signature(owner, method):
    """-> the parameter list of `owner::method`, or None."""
    for rel in pkg_prod:
        body = PROD_BODY[rel]
        m = re.search(r"pub fn %s::%s\s*\(" % (re.escape(owner),
                                               re.escape(method)), body)
        if not m:
            continue
        end = balanced(body, m.end() - 1)
        if end < 0:
            continue
        return body[m.end():end]
    return None


def params(sig):
    if sig is None:
        return []
    return re.findall(r"([a-z_][a-z0-9_]*)\s*~?\s*:", sig)


def default_of(sig, name):
    """-> the default expression of the named parameter, or None."""
    if sig is None:
        return None
    m = re.search(r"%s\s*~?\s*:[^=,]*=\s*" % re.escape(name), sig)
    if not m:
        return None
    rest = sig[m.end():]
    if rest.startswith("("):
        stop = balanced(rest, 0)
        return rest[:stop + 1] if stop > 0 else rest.split(",")[0]
    if rest.startswith("["):
        stop = rest.find("]")
        return rest[:stop + 1] if stop > 0 else None
    return rest.split(",")[0].strip()


score_on_new = sorted(n for n in ESTIMATORS
                      if "score" in params(signature(n, "new")))
score_on_fit = sorted(n for n in ESTIMATORS
                      if "score" in params(signature(n, "fit")))

# -- the propensity learner's default, per estimator
ml_m_default = {}
for n in ESTIMATORS:
    sig = signature(n, "new")
    if sig is None:
        continue
    m = re.search(r"ml_m\s*[~?]\s*:\s*LearnerDispatch\s*=\s*", sig)
    if not m:
        continue
    rest = sig[m.end():]
    if rest.startswith("("):
        stop = balanced(rest, 0)
        expr = rest[:stop + 1]
    else:
        expr = rest.split(",")[0]
    vm = re.search(r"LearnerDispatch::([A-Za-z0-9_]+)", expr)
    if vm:
        ml_m_default[n] = vm.group(1)
ml_m_logistic = sorted(n for n, v in ml_m_default.items()
                       if "logistic" in v.lower())

# -- the api_server's own limits
api_src = read("examples/api_server/main.mbt")
api_port = ""
mp = re.search(r"DEFAULT_PORT\s*(?::[^=]*)?=\s*(\d+)", api_src)
if mp:
    api_port = mp.group(1)
api_mib = ""
mm = re.search(r"let cap\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024", api_src)
if mm:
    api_mib = mm.group(1)

# -- the CI workflow: the backend matrix and the --deny-warn step
ci = read(".github/workflows/check.yml")
ci_targets = sorted(set(re.findall(r"target:\s*\[([^\]]*)\]", ci)[0].split())
                    ) if re.findall(r"target:\s*\[([^\]]*)\]", ci) else []
ci_targets = sorted(set(re.findall(
    r"target:\s*\[([^\]]*)\]", ci)[0].replace(",", " ").split())) \
    if re.findall(r"target:\s*\[([^\]]*)\]", ci) else []
ci_deny_warn = bool(re.search(r"moon test[^\n]*--deny-warn", ci))

# -- the Python validators' tolerances
def tol_of(script, name):
    body = read(script)
    m = re.search(r"^\s*%s\s*=\s*([0-9.]+)" % re.escape(name), body, re.M)
    return m.group(1) if m else None


IRM_TOL = tol_of("validate_irm_with_python.py", "model_tol")
APOS_TOL = tol_of("validate_apos_with_python.py", "MODEL_TOL")
DIDCSBIN_TOL = tol_of("validate_did_cs_binary_with_python.py", "MODEL_TOL")

# -- the package's own manifest: the declared dependencies and their use
mod = read(PKG + "moon.mod")
mod_imports = []
im = re.search(r"^import\s*\{(.*?)\}", mod, re.M | re.S)
if im:
    mod_imports = [x.strip().strip('"') for x in im.group(1).split(",")
                   if x.strip()]
lib_bodies = {rel: read(rel) for rel in pkg_mbt}


def dep_references(pkgname):
    n = 0
    for body in lib_bodies.values():
        if pkgname in body:
            n += 1
    return n


# --------------------------------------------------------------------------
# 2.  THE DOCUMENTS
# --------------------------------------------------------------------------
DOCS = [
    ("001", "doc/001_introduction/readme.mbt.md"),
    ("002", "doc/002_installation/readme.mbt.md"),
    ("003", "doc/003_quick_start/readme.mbt.md"),
    ("004", "doc/004_estimators/readme.mbt.md"),
    ("005", "doc/005_dgps/readme.mbt.md"),
    ("006", "doc/006_python_check/readme.mbt.md"),
    ("api", "examples/api_server/README.md"),
]
RAW = {k: read(v) for k, v in DOCS}
# Whitespace is normalised before matching: a phrase that spans a line
# break -- "and 17\nof the 18" -- is one phrase, and a pattern that cannot
# see across the break reports a promise the document actually keeps.
TEXT = {k: re.sub(r"\s+", " ", v) for k, v in RAW.items()}

WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
         "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
         "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
         "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
         "twenty": 20}


def stated(doc, pattern):
    """-> the list of NUMBERS the document states for `pattern`."""
    out = []
    for m in re.finditer(pattern, TEXT[doc], re.S):
        for g in m.groups():
            if g is None:
                continue
            g = g.strip()
            if g.isdigit():
                out.append(int(g))
            elif g.lower() in WORDS:
                out.append(WORDS[g.lower()])
            else:
                out.append(None)
            break
    return out


# --------------------------------------------------------------------------
# 3.  THE MEASURES, and where each one is stated
# --------------------------------------------------------------------------
# (measure name, measured value, [(doc, pattern), ...])
MEASURES = [
    ("the estimator count", len(ESTIMATORS),
     [("001", r"for (\d+) in total"),
      ("004", r"(\d+) estimators, all reachable")]),
    ("the LearnerDispatch variants", len(variants),
     [("001", r"ships (\d+)\s+`LearnerDispatch` variants")]),
    ("the regressor learners", len(learners_reg),
     [("001", r"variants: (\d+) regressors")]),
    ("the classifier learners", len(learners_cls),
     [("001", r"and (\d+) classifiers")]),
    ("the declared dependency entries", len(mod_imports),
     [("001", r"does declare (\w+) entries")]),
    ("the Python validators", len(validators),
     [("001", r"cross-checkers \((\d+) scripts")]),
    ("the DGP modules", len(dgp_mod),
     [("001", r"across (\d+) `dgp_\*\.mbt` modules")]),
    ("the DGP factories", len(FACTORIES),
     [("005", r"(\d+) synthetic-data generators")]),
    ("the DGP factories with a theta_get()", len(dgp_theta),
     [("005", r"All (\d+) return a struct")]),
    ("the DGP factories with x_get() / y_get() / d_get()", len(dgp_xyz),
     [("005", r"and (\d+) of the \d+ also expose")]),
    ("the recovery tests", recovery_tests,
     [("005", r"holds \*\*(\w+)\*\* end-to-end recovery tests")]),
    ("the validators that import the upstream wheel", len(wheel),
     [("006", r"upstream's wheel in \*\*(\d+)\*\*")]),
    ("the validators that re-derive the reference", len(hand),
     [("006", r"hand-rolled here in \*\*(\d+)\*\*")]),
    ("the supported backends", len(ci_targets),
     [("002", r"all (\d+) supported"),
      ("003", r"runs on all (\d+) supported")]),
    ("the api_server's body cap in MiB", int(api_mib or 0),
     [("api", r"body cap is (\d+) MiB")]),
]

# --------------------------------------------------------------------------
# 4.  THE CHECKS
# --------------------------------------------------------------------------
print("=== the measures ===")
for name, value, _ in MEASURES:
    print("  %-56s %s" % (name, value))
print("  %-56s %s" % ("the CI backends", ", ".join(ci_targets)))
print("  %-56s %s" % ("the estimators taking score on new()",
                      ", ".join(score_on_new)))
print("  %-56s %s" % ("the estimators taking score on fit()",
                      ", ".join(score_on_fit)))
print("  %-56s %s" % ("the estimators defaulting ml_m to the classifier",
                      ", ".join(ml_m_logistic)))
print()

for name, measured, pats in MEASURES:
    for doc, pat in pats:
        nums = [n for n in stated(doc, pat) if n is not None]
        if not nums:
            check("%s -- %s states it nowhere" % (name, doc), True,
                  "measured %d" % measured)
            continue
        # A number that appears in two sentences is two promises, so each
        # statement is its OWN check: a page that states the same quantity
        # in two places cannot fail in one and pass in the other.
        for num in nums:
            check("%s -- %s states %d" % (name, doc, num), num == measured,
                  "the tree says %d" % measured)

# --------------------------------------------------------------------------
# 4b.  THE CLAIMS THAT ARE NOT COUNTS
# --------------------------------------------------------------------------
# -- the dead dependency entries: the manifest declares them, and no `.mbt`
# in the library imports either one.
for dep in mod_imports:
    pkgname = dep.split("@")[0]
    n = dep_references(pkgname)
    check("the library imports %s nowhere" % pkgname, n == 0,
          "%d reference(s)" % n)
m = re.search(r"measured: (\d+) references each", TEXT["001"])
check("the page states the dead entries' reference count",
      bool(m) and int(m.group(1)) == 0,
      m.group(1) if m else "the count is not there")

# -- the six estimators whose propensity enters as `1 / m_hat`
m = re.search(r"logistic classifier for the (\w+) estimators"
              r"(.*?)\. `DoubleMLLPLR`", TEXT["001"], re.S)
if not m:
    check("the page names the estimators that default ml_m to the classifier",
          False, "the sentence is not there")
else:
    claimed = WORDS.get(m.group(1).lower(), -1)
    named = re.findall(r"`(DoubleML[A-Za-z]+)`", m.group(2))
    # the six are the classifier-defaulting estimators OTHER than the LPLR,
    # which the page calls out separately
    measured = [n for n in ml_m_logistic if n != "DoubleMLLPLR"]
    check("the estimators defaulting ml_m to the classifier, other than LPLR",
          claimed == len(measured),
          "the page says %d; the tree says %d (%s)"
          % (claimed, len(measured), ", ".join(measured)))
    check("the page names the estimators that default ml_m to the classifier",
          sorted(named) == sorted(measured),
          "the page names %s; the tree says %s"
          % (", ".join(sorted(named)), ", ".join(sorted(measured))))
    check("every estimator the page names defaults to the classifier",
          all(ml_m_default.get(n, "").lower().find("logistic") >= 0
              for n in named),
          ", ".join("%s=%s" % (n, ml_m_default.get(n, "?"))
                    for n in named))
    check("DoubleMLLPLR also defaults ml_m to the classifier",
          "logistic" in ml_m_default.get("DoubleMLLPLR", "").lower(),
          ml_m_default.get("DoubleMLLPLR", "no default"))
    check("DoubleMLIIVM defaults ml_m to OLS",
          "linear" in ml_m_default.get("DoubleMLIIVM", "").lower(),
          ml_m_default.get("DoubleMLIIVM", "no default"))

# -- the "0 errors under `moon test --deny-warn`" claim
check("CI runs `moon test` with --deny-warn", ci_deny_warn, "")
m = re.search(r"\*\*(\w+ errors?)\*\* under `moon test --deny-warn`",
              TEXT["001"])
check("the page states zero errors under --deny-warn",
      bool(m) and m.group(1).lower() in ("0 errors", "0 error"),
      m.group(1) if m else "the claim is not there")

# -- the score slot: `DoubleMLPLR` takes it on fit(), the others on new()
m = re.search(r"`DoubleMLPLR` takes it on `fit\(\)`,"
              r" the other (\w+) take it on `new\(\)`", TEXT["004"])
check("the estimators taking score on new()",
      bool(m) and WORDS.get(m.group(1).lower(), -1) == len(score_on_new),
      "the page says %s; the tree says %d (%s)"
      % (m.group(1) if m else "?", len(score_on_new),
         ", ".join(score_on_new)))
check("DoubleMLPLR takes score on fit(), not on new()",
      score_on_fit == ["DoubleMLPLR"] and "DoubleMLPLR" not in score_on_new,
      "fit: %s; new: %s" % (", ".join(score_on_fit), ", ".join(score_on_new)))

# -- the constructor defaults the page states.  The page's value and the
# tree's value are compared; a check that read only the source would pass
# however the page was worded.
for est, arg, pat, doc_value in (
        ("DoubleMLPQ", "quantile",
         r"`DoubleMLPQ` / `DoubleMLLPQ`: extra `quantile` arg \(a scalar, default `([0-9.]+)`\)",
         "0.5"),
        ("DoubleMLLPQ", "quantile",
         r"`DoubleMLPQ` / `DoubleMLLPQ`: extra `quantile` arg \(a scalar, default `([0-9.]+)`\)",
         "0.5"),
        ("DoubleMLQTE", "quantiles",
         r"`DoubleMLQTE` instead takes `quantiles` -- an `Array\[Double\]`, default `(\[[0-9.]+\])`",
         "[0.5]"),
        ("DoubleMLPolicyTree", "depth",
         r"`DoubleMLPolicyTree`: extra `depth` arg \(default (\d+)\)", "1")):
    got = default_of(signature(est, "new"), arg)
    check("%s's %s default in the tree" % (est, arg), got == doc_value,
          "the tree says %s" % got)
    # The page's value is read as TEXT: a default is a real number like
    # `0.5` or a list like `[0.5]`, and neither is an integer.
    dm = re.search(pat, TEXT["004"])
    check("%s's %s default as the page states it" % (est, arg),
          bool(dm) and dm.group(1) == doc_value,
          "the page says %s; the tree says %s"
          % (dm.group(1) if dm else "nothing", got))

# -- `DoubleMLDIDCSBinary` accepts only `observational`
guard = read("moonbit_doubleML/did_cs_binary.mbt")
accepted = set()
for g in re.findall(r'require\([^)]*score[^)]*\)', guard, re.S):
    accepted |= set(re.findall(r'"([^"]+)"', g))
check("DoubleMLDIDCSBinary accepts only `observational`",
      accepted == {"observational"},
      "the tree accepts %s" % (", ".join(sorted(accepted)) or "nothing"))
m = re.search(r"`DoubleMLDIDCSBinary` accepts (only )?`([^`]+)`", TEXT["004"])
check("the page says DoubleMLDIDCSBinary accepts only `observational`",
      bool(m) and bool(m.group(1)) and m.group(2) == "observational"
      and accepted == {"observational"},
      "the page says %s; the tree accepts %s"
      % (m.group(0) if m else "nothing", ", ".join(sorted(accepted))))

# -- the validators' tolerances the page states
for script, name, value in (("validate_irm_with_python.py", "model_tol", IRM_TOL),
                             ("validate_apos_with_python.py", "MODEL_TOL", APOS_TOL),
                             ("validate_did_cs_binary_with_python.py",
                              "MODEL_TOL", DIDCSBIN_TOL)):
    check("%s's tolerance" % script, value is not None,
          "the tree says %s" % value)
m = re.search(r"IRM validator uses `(0\.\d+)`", TEXT["005"])
check("the page states the IRM validator's tolerance",
      bool(m) and IRM_TOL is not None and float(m.group(1)) == float(IRM_TOL),
      "the page says %s; the tree says %s"
      % (m.group(1) if m else "?", IRM_TOL))
m = re.search(r"DIDCSBinary validators use `(0\.\d+)`", TEXT["005"])
check("the page states the APOS and DIDCSBinary validators' tolerance",
      bool(m) and APOS_TOL is not None and DIDCSBIN_TOL is not None
      and float(m.group(1)) == float(APOS_TOL) == float(DIDCSBIN_TOL),
      "the page says %s; the tree says APOS %s / DIDCSBinary %s"
      % (m.group(1) if m else "?", APOS_TOL, DIDCSBIN_TOL))

# -- the coverage split: the page's own three numbers PARTITION the
# estimators, and the table under them has one row per "only" family.
m = re.search(r"\*\*(\d+)\*\* are checked by both families,"
              r" \*\*(\d+)\*\* are checked \*only\* by the `validate_\*` family,"
              r" and \*\*(\d+)\*\* are checked \*only\* by the `pyexample_\*`"
              r" family", TEXT["006"])
if not m:
    check("the page states the coverage split", False,
          "the sentence is not there")
else:
    both, only_v, only_p = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    check("the coverage split partitions the estimators",
          both + only_v + only_p == len(ESTIMATORS),
          "the page says %d + %d + %d = %d; the tree has %d estimators"
          % (both, only_v, only_p, both + only_v + only_p, len(ESTIMATORS)))
    # the table under the sentence must have one row per "only" estimator
    rows = re.findall(r"^\|\s*`validate_\*`\s*\|(.+)\|$",
                       RAW["006"], re.M)
    n_only_v = len(re.findall(r"`DoubleML[A-Za-z]+`", rows[0])) if rows else -1
    rows2 = re.findall(r"^\|\s*`pyexample_\*`\s*\|(.+)\|$",
                        RAW["006"], re.M)
    n_only_p = len(re.findall(r"`DoubleML[A-Za-z]+`", rows2[0])) if rows2 else -1
    check("the table's validate-only row count matches the sentence",
          n_only_v == only_v,
          "the table lists %d; the sentence says %d" % (n_only_v, only_v))
    check("the table's pyexample-only row count matches the sentence",
          n_only_p == only_p,
          "the table lists %d; the sentence says %d" % (n_only_p, only_p))

# -- the api_server's port and body cap
m = re.search(r"hard-coded to `(\d+)`", TEXT["api"])
check("the api_server's hard-coded port",
      bool(m) and m.group(1) == api_port, "the source says %s" % api_port)

# --------------------------------------------------------------------------
# 5.  THE SCANNER IS NOT VACUOUS
# --------------------------------------------------------------------------
check("the tree has estimator structs to measure", len(ESTIMATORS) > 0,
      "%d estimators" % len(ESTIMATORS))
check("the documents state measurable numbers", NCHECK > 0,
      "%d checks so far" % NCHECK)
check("every measure is stated at least once",
      all(stated(doc, pat) for _, _, pats in MEASURES for doc, pat in pats),
      "%d measures" % len(MEASURES))
check("the derived quantities are not empty",
      all([len(ESTIMATORS), len(variants), len(FACTORIES), len(validators),
           len(ci_targets), len(dgp_theta), len(dgp_xyz)]),
      "the derivations produced nothing")

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
