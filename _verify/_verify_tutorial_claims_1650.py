#!/usr/bin/env python3
"""Round 27 verifier: the TUTORIAL documents' claims, derived from source.

WHY THIS EXISTS
===============
Rounds 21-26 audited the README's numbers, its test-verification claims, its
shape, its count referents, its names and its upstream-provenance grouping.
This one audits the four tutorial documents under `doc/` -- the ones a reader
opens AFTER the README, and which the README does not restate -- and the one
README paragraph that turned out to describe the `validate_*` family as more
self-contained than it is.

FOUR DEFECTS, ALL CONFIRMED AGAINST THE TREE
============================================
A  `doc/003_quick_start` published three exact numbers (`coef()`, `se()`,
   `confint()`) and NOTHING asserted them: the tutorial test only called
   `ignore(fitted.coef())` / `ignore(fitted.se())` and never mentioned
   `confint()`.  A published exact number needs an executable witness next to
   it, or it goes stale silently.

B  `doc/005_dgps`'s quick-reference table gave
   `make_irm_heterogeneous_data` the signature `(n_obs, theta, seed)`.  The
   real one is `(n_obs, dim_x, seed)` -- a `Double` where an `Int32` belongs.

C  `doc/005_dgps` also said every factory returns a struct with
   `x_get()` / `y_get()` / `d_get()`.  `make_lplr_LZZ2020` returns an
   `LplrData` with only `theta_get()` and `data_get()`.  The doc's own usage
   example does not compile for it.

D  `doc/006_python_check` described ONE family of Python cross-checks and
   claimed "No estimator ships without a Python cross-check".  The claim was
   true but only because it counted a second family the doc never mentioned:
   the 9 `pyexample_*` upstream gates.  Three estimators
   (`DoubleMLAPO`, `DoubleMLDIDMulti`, `DoubleMLQTE`) are covered ONLY by
   that family.  The same paragraph's step 2 claimed every `validate_*`
   script builds its reference "via the upstream `doubleml.DoubleMLXxx`" --
   true for 9 of the 24, false for the other 15.  And the README said the
   `pyexample_*` family was the only one whose reference is upstream, which
   2 of the 9 wheel-importing `validate_*` scripts also do.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the 22 port estimators -- a `DoubleML*` struct with a public `::new`,
    less the `*Data` containers;
  * the 18 DGP factories and each one's real parameter list, read from
    `dgp_*.mbt`;
  * each factory's accessor set, read from the accessors of its return type;
  * the cross-check coverage map: which script compares which estimator.
    A script covers an estimator when it NAMES it, or when it reads a parity
    section that reports it, or when it drives a dedicated example.

    Two stripping rules make that derivation honest, and both were learned by
    getting them wrong first:
      - a mention in a COMMENT or a DOCSTRING is not a dependency.  The
        docstring set comes from `ast`, because a MODULE docstring has no
        preceding token and a "previous token" guess misses it -- and a
        module docstring is prose full of estimator names ("the PLR/IRM
        validators"), which then reads as a dependency;
      - a parity section's producers are the estimator constructions in the
        ENCLOSING `fn sec_*()` function, not in the flat span between two
        `section("...")` markers, which spans two functions.
  * the 9 / 15 split: 9 of the 24 `validate_*` scripts import the upstream
    `doubleml` wheel in CODE.

Run: python _verify/_verify_tutorial_claims_1650.py
"""
import ast
import io
import os
import re
import sys
import tokenize

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-62s %s" % (label, detail))
    else:
        FAILS.append(label)
        print("  *** FAIL ***  %-56s %s" % (label, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def clip(s, n=52):
    """Shorten a phrase for a label, WITHOUT cutting a word in half."""
    if len(s) <= n:
        return s
    cut = s[:n]
    sp = cut.rfind(" ")
    return (cut[:sp] if sp > 0 else cut).rstrip()


def flat(p):
    """A document with its line wrapping and blockquote markers collapsed."""
    body = "\n".join(re.sub(r"^\s*>\s?", "", ln) for ln in read(p).split("\n"))
    return re.sub(r"\s+", " ", body).strip()


def py_code(path):
    """-> (name tokens, string literals) with COMMENTS and DOCSTRINGS removed."""
    with open(path, "rb") as fh:
        raw = fh.read()
    tree = ast.parse(raw)
    docpos = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                             ast.ClassDef)):
            body = getattr(node, "body", None)
            if body and isinstance(body[0], ast.Expr) and \
                    isinstance(body[0].value, ast.Constant) and \
                    isinstance(body[0].value.value, str):
                docpos.add((body[0].value.lineno, body[0].value.col_offset))
    names, strings, code = [], [], []
    for tok in tokenize.tokenize(io.BytesIO(raw).readline):
        if tok.type == tokenize.COMMENT:
            continue
        if tok.type == tokenize.NAME:
            names.append(tok.string)
        elif tok.type == tokenize.STRING and (tok.start[0], tok.start[1]) not in docpos:
            try:
                strings.append(eval(tok.string))
            except Exception:
                pass
        if tok.type not in (tokenize.COMMENT,):
            code.append((tok.start[0], tok.string))
    # the code LINES, with comments and docstrings blanked out
    lines = read(path).split("\n")
    for ln in doc_lines_of(path):
        if 1 <= ln <= len(lines):
            lines[ln - 1] = ""
    return names, strings, lines


def doc_lines_of(path):
    """The line numbers occupied by docstrings."""
    with open(path, "rb") as fh:
        raw = fh.read()
    tree = ast.parse(raw)
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                             ast.ClassDef)):
            body = getattr(node, "body", None)
            if body and isinstance(body[0], ast.Expr) and \
                    isinstance(body[0].value, ast.Constant) and \
                    isinstance(body[0].value.value, str):
                n = body[0].value
                for ln in range(n.lineno, (n.end_lineno or n.lineno) + 1):
                    out.add(ln)
    return out


# ============================================================================
# 1. the port's estimators
# ============================================================================
print("== 1. the port's estimators, from the library source ==")

est_file = {}
for name in sorted(os.listdir(LIB)):
    if not name.endswith(".mbt"):
        continue
    for m in re.finditer(r"pub fn (DoubleML\w+)::new\(", read(os.path.join(LIB, name))):
        est_file.setdefault(m.group(1), name)
PORT = sorted(s for s in est_file if not s.endswith("Data"))
PORTSET = set(PORT)
KEY = {e: e[len("DoubleML"):] for e in PORT}
print("   port estimators: %d" % len(PORT))

# ============================================================================
# 2. doc/003 -- the published table and its witness
# ============================================================================
print()
print("== 2. doc/003_quick_start: the published table has a witness ==")

DOC3 = os.path.join(ROOT, "doc", "003_quick_start", "readme.mbt.md")
TEST3 = os.path.join(ROOT, "doc", "003_quick_start", "using_test.mbt")

doc3 = read(DOC3)
test3 = read(TEST3)

PUB = {}
for m in re.finditer(r"\|\s*`(\w+)\(\)`\s*\|\s*`?([^|`]+?)`?\s*\|", doc3):
    PUB[m.group(1)] = m.group(2).strip()
print("   published quantities: %s" % sorted(PUB))

check("doc/003 publishes coef()", "coef" in PUB, PUB.get("coef", "-"))
check("doc/003 publishes se()", "se" in PUB, PUB.get("se", "-"))
check("doc/003 publishes confint()", "confint" in PUB, PUB.get("confint", "-"))

if "confint" in PUB:
    lo_hi = re.findall(r"-?\d+\.\d+", PUB["confint"])
    check("doc/003's confint() publishes two bounds", len(lo_hi) == 2,
          "got %d" % len(lo_hi))

# the witness: the test file must assert each published number
NUMS = []
if "coef" in PUB:
    NUMS.append(("coef", PUB["coef"]))
if "se" in PUB:
    NUMS.append(("se", PUB["se"]))
if "confint" in PUB:
    for i, n in enumerate(re.findall(r"-?\d+\.\d+", PUB["confint"])):
        NUMS.append(("confint[%d]" % i, n))

for label, num in NUMS:
    check("the tutorial test asserts %s = %s" % (label, num),
          num in test3, "not in using_test.mbt")

check("the tutorial test asserts coef() against the published value",
      re.search(r"fitted\.coef\(\)\s*==\s*%s" % re.escape(PUB.get("coef", "x")),
                test3) is not None)
check("the tutorial test asserts se() against the published value",
      re.search(r"fitted\.se\(\)\s*==\s*%s" % re.escape(PUB.get("se", "x")),
                test3) is not None)
if "confint" in PUB:
    check("the tutorial test calls confint()",
          "fitted.confint()" in test3)
    check("the tutorial test asserts both confint() bounds",
          len(re.findall(r"(?:lo|hi)\s*==\s*-?\d+\.\d+", test3)) == 2,
          "got %d" % len(re.findall(r"(?:lo|hi)\s*==\s*-?\d+\.\d+", test3)))

check("the tutorial test still holds exactly one test",
      len(re.findall(r'^\s*test\s+"', test3, re.M)) == 1,
      "got %d" % len(re.findall(r'^\s*test\s+"', test3, re.M)))
check("doc/003 names the test that witnesses the table",
      "using_test.mbt" in doc3)
check("doc/003 says the values are backend-independent",
      "bit-identical" in flat(DOC3))

# ============================================================================
# 3. doc/005 -- the DGP factory table
# ============================================================================
print()
print("== 3. doc/005_dgps: the factory table matches the source ==")

DOC5 = os.path.join(ROOT, "doc", "005_dgps", "readme.mbt.md")
doc5 = read(DOC5)

FACT = {}          # factory -> (params, return type, file)
for fn in sorted(os.listdir(LIB)):
    if not (fn.startswith("dgp_") and fn.endswith(".mbt")):
        continue
    src = read(os.path.join(LIB, fn))
    for m in re.finditer(r"pub fn (make_\w+)\(\s*([^)]*?)\s*\)\s*->\s*(\w+)",
                         src, re.S):
        raw = m.group(2)
        params = []
        for part in raw.split(","):
            part = part.strip()
            if not part:
                continue
            name = part.split(":")[0].strip()
            params.append(name)
        FACT[m.group(1)] = (params, m.group(3), fn)
print("   DGP factories in the source: %d" % len(FACT))

# the doc's table
ROW = re.compile(r"^\|\s*`(make_\w+)`\s*\|([^|]*)\|\s*`\(([^)]*)\)`\s*\|\s*`([^`]+)`\s*\|",
                 re.M)
TBL = {m.group(1): (m.group(2).strip(), m.group(3), m.group(4)) for m in ROW.finditer(doc5)}
print("   rows in the doc's table: %d" % len(TBL))

check("the source and the table have the same factories",
      sorted(FACT) == sorted(TBL),
      "source-only=%s table-only=%s"
      % (sorted(set(FACT) - set(TBL)), sorted(set(TBL) - set(FACT))))

for fname in sorted(set(FACT) & set(TBL)):
    params, ret, srcfile = FACT[fname]
    _model, sig, tablefile = TBL[fname]
    want = ", ".join(params)
    check("the table's signature for %s matches the source" % fname,
          sig.strip() == want, "table=%r source=%r" % (sig.strip(), want))
    check("the table's file for %s matches the source" % fname,
          tablefile == srcfile, "table=%r source=%r" % (tablefile, srcfile))

# the accessor sets, read from each return type's accessors
ACC = {}
for fn in sorted(os.listdir(LIB)):
    if not fn.endswith(".mbt"):
        continue
    src = read(os.path.join(LIB, fn))
    for m in re.finditer(r"pub fn (\w+)::(\w+)\s*\(", src):
        ACC.setdefault(m.group(1), set()).add(m.group(2))

TRIO = {"x_get", "y_get", "d_get"}
with_trio, without = [], []
for fname in sorted(FACT):
    _params, ret, _f = FACT[fname]
    accs = ACC.get(ret, set())
    (with_trio if TRIO <= accs else without).append(fname)

print("   factories exposing x_get/y_get/d_get: %d" % len(with_trio))
print("   factories without the trio: %s" % without)

check("every factory exposes theta_get()",
      all("theta_get" in ACC.get(FACT[f][1], set()) for f in FACT),
      str([f for f in FACT if "theta_get" not in ACC.get(FACT[f][1], set())]))
check("exactly one factory lacks the x_get/y_get/d_get trio",
      len(without) == 1, "got %s" % without)
check("that one is make_lplr_LZZ2020", without == ["make_lplr_LZZ2020"],
      "got %s" % without)
check("its return type is LplrData", FACT["make_lplr_LZZ2020"][1] == "LplrData",
      FACT["make_lplr_LZZ2020"][1])
check("it exposes data_get() instead",
      "data_get" in ACC.get("LplrData", set()), str(sorted(ACC.get("LplrData", set()))))

flat5 = flat(DOC5)
check("doc/005 states that 17 of the 18 expose the trio",
      "17" in flat5 and "x_get" in flat5 and "y_get" in flat5 and "d_get" in flat5)
check("doc/005 names the exception, its type and its accessor",
      "`make_lplr_LZZ2020`, which returns an `LplrData` carrying `theta_get()`"
      " and `data_get()`" in flat5,
      "the exact 'LplrData carrying theta_get() and data_get()' phrase is missing")
check("doc/005 does not claim the trio for all 18",
      "All 18 return a struct with `x_get()`" not in flat5,
      "the withdrawn 'all 18 expose the trio' claim is still present")
check("doc/005's usage example does not apply the trio to the LPLR DGP",
      "LPLR" in flat5 and "DoubleMLBinaryData" in flat5)

# the withdrawn signature must be gone
check("doc/005 no longer gives make_irm_heterogeneous_data a theta parameter",
      "make_irm_heterogeneous_data` | IRM, heterogeneous effects | `(n_obs, dim_x, seed)`"
      in flat5,
      "the corrected row is not present")

# ============================================================================
# 4. doc/006 -- the two cross-check families
# ============================================================================
print()
print("== 4. doc/006_python_check: the two families and the coverage map ==")

DOC6 = os.path.join(ROOT, "doc", "006_python_check", "readme.mbt.md")
doc6 = read(DOC6)
flat6 = flat(DOC6)

fam_a = sorted(f for f in os.listdir(ROOT)
               if re.match(r"^validate_.*_with_python\.py$", f))
fam_b = sorted(f for f in os.listdir(ROOT) if re.match(r"^pyexample_.*\.py$", f))
print("   validate_*_with_python.py: %d   pyexample_*.py: %d" % (len(fam_a), len(fam_b)))

# --- the parity sections and their producers -------------------------------
PARITY = os.path.join(ROOT, "examples", "parity", "main.mbt")
plines = read(PARITY).split("\n")
FUNC_RE = re.compile(r"^fn\s+(sec_\w+)\s*\(\s*\)\s*->\s*Unit\s*\{")
CONSTRUCT = re.compile(r"(DoubleML\w+)::new\(")
funcs = []
for i, ln in enumerate(plines):
    m = FUNC_RE.match(ln)
    if m:
        funcs.append([m.group(1), i, len(plines)])
for k in range(len(funcs) - 1):
    funcs[k][2] = funcs[k + 1][1]
sections = {}
for fname, a, b in funcs:
    body = "\n".join(plines[a:b])
    for m in re.finditer(r'section\("([^"]+)"\)', body):
        produced = []
        for c in CONSTRUCT.finditer(body):
            nm = c.group(1)
            if nm in PORTSET and nm not in produced:
                produced.append(nm)
        sections[m.group(1)] = produced
known = set(sections)


def example_estimators(exdir):
    p = os.path.join(ROOT, exdir.replace("/", os.sep))
    if not os.path.isdir(p):
        return []
    found = []
    for fn in sorted(os.listdir(p)):
        if fn.endswith(".mbt"):
            for m in CONSTRUCT.finditer(read(os.path.join(p, fn))):
                nm = m.group(1)
                if nm in PORTSET and nm not in found:
                    found.append(nm)
    return found


def attribute(path):
    """-> {estimator: the route that attributed it}."""
    names, strings, _lines = py_code(path)
    covered = {}
    for n in names:
        if n in PORTSET:
            covered.setdefault(n, "name")
    for s in strings:
        if not isinstance(s, str):
            continue
        for k in known:
            if s == k or (k.endswith("_") and s.startswith(k)):
                for e in sections[k]:
                    covered.setdefault(e, "section:%s" % k)
    for s in strings:
        if isinstance(s, str) and s.startswith("examples/"):
            ex = example_estimators(s)
            if len(ex) == 1:
                covered.setdefault(ex[0], "example:%s" % s)
            elif len(ex) > 1:
                blob = " ".join(str(x) for x in strings)
                for e in ex:
                    if re.search(r"\b%s\b" % re.escape(KEY[e]), blob):
                        covered.setdefault(e, "example:%s" % s)
    return covered


A, B = {}, {}
for f in fam_a:
    A[f] = attribute(os.path.join(ROOT, f))
for f in fam_b:
    B[f] = attribute(os.path.join(ROOT, f))

SA = set().union(*A.values()) if A else set()
SB = set().union(*B.values()) if B else set()
A_ONLY = sorted(SA - SB)
B_ONLY = sorted(SB - SA)
BOTH = sorted(SA & SB)
print("   family A covers %d, family B covers %d, union %d"
      % (len(SA), len(SB), len(SA | SB)))
print("   A-only: %s" % A_ONLY)
print("   B-only: %s" % B_ONLY)

check("the validate_* family has 24 scripts", len(fam_a) == 24, "got %d" % len(fam_a))
check("the pyexample_* family has 9 scripts", len(fam_b) == 9, "got %d" % len(fam_b))
check("every one of the 22 estimators is cross-checked",
      (SA | SB) == PORTSET, "uncovered=%s" % sorted(PORTSET - (SA | SB)))
check("exactly 3 estimators are covered only by the pyexample_* family",
      len(B_ONLY) == 3, "got %d" % len(B_ONLY))
check("they are DoubleMLAPO, DoubleMLDIDMulti and DoubleMLQTE",
      B_ONLY == ["DoubleMLAPO", "DoubleMLDIDMulti", "DoubleMLQTE"], str(B_ONLY))
check("exactly 3 estimators are covered only by the validate_* family",
      len(A_ONLY) == 3, "got %d" % len(A_ONLY))
check("they are DoubleMLDIDCS, DoubleMLDIDCrossSection and DoubleMLPLPR",
      A_ONLY == ["DoubleMLDIDCS", "DoubleMLDIDCrossSection", "DoubleMLPLPR"],
      str(A_ONLY))
check("the remaining 16 are covered by both", len(BOTH) == 16, "got %d" % len(BOTH))

# the doc states it -- and the numbers it states are the DERIVED ones, so a
# document that quotes a count the coverage map does not support fails here
check("doc/006 states the two family counts",
      "| `validate_*_with_python.py` | %d |" % len(fam_a) in flat6
      and "| `pyexample_*.py` | %d |" % len(fam_b) in flat6)
check("doc/006 states that all %d estimators are cross-checked" % len(PORT),
      "cross-check all **%d** estimators" % len(PORT) in flat6)
check("doc/006 states that %d are checked by both" % len(BOTH),
      "**%d** are checked by both families" % len(BOTH) in flat6)
check("doc/006 states that %d are checked only by the validate_* family" % len(A_ONLY),
      "**%d** are checked *only* by the" % len(A_ONLY) in flat6)
check("doc/006 states that %d are checked only by the pyexample_* family" % len(B_ONLY),
      "**%d** are checked *only* by the" % len(B_ONLY) in flat6)
# the two tables name the SETS, and the sets are the derived ones
check("doc/006's validate-only table row lists exactly the derived set",
      "| `validate_*` | %s |" % ", ".join("`%s`" % e for e in A_ONLY) in flat6,
      "want %s" % ", ".join(A_ONLY))
check("doc/006's pyexample-only table row lists exactly the derived set",
      "| `pyexample_*` | %s |" % ", ".join("`%s`" % e for e in B_ONLY) in flat6,
      "want %s" % ", ".join(B_ONLY))
for e in B_ONLY:
    check("doc/006 names %s as pyexample-only" % e, "`%s`" % e in flat6)
for e in A_ONLY:
    check("doc/006 names %s as validate-only" % e, "`%s`" % e in flat6)
check("doc/006 says the pyexample family is not globbed",
      "explicit CI step" in flat6)
check("doc/006 names the two scripts that gate the port against upstream",
      "`validate_did_cs_binary_with_python.py`" in flat6
      and "`validate_lplr_with_python.py`" in flat6)
check("doc/006 states the 9 / 15 upstream-wheel split",
      "**9** of the 24 import the upstream `doubleml` wheel" in flat6
      and "the other **15** re-derive it" in flat6)
check("doc/006 keeps the no-estimator-without-a-cross-check claim",
      "No estimator ships without a Python cross-check." in flat6)

# --- the CI wiring -------------------------------------------------------
CI = read(os.path.join(ROOT, ".github", "workflows", "check.yml"))
check("the python-cross-check job needs moon-test",
      re.search(r"python-cross-check:.*?needs:\s*moon-test", CI, re.S) is not None)
check("the validate_* family runs by glob",
      "for s in validate_*_with_python.py; do" in CI)
check("the CI step greps the trailing line for an upper-case PASS",
      'case "$line" in' in CI and "*PASS*)" in CI)
for f in fam_b:
    check("CI has an explicit step for %s" % f,
          re.search(r"python\s+%s\s+--check" % re.escape(f), CI) is not None)

# --- the upstream wheel split --------------------------------------------
print()
print("== 5. who takes the reference from the upstream wheel ==")


def uses_upstream(path):
    names, _strings, _lines = py_code(path)
    return "doubleml" in names


WHEEL = [f for f in fam_a if uses_upstream(os.path.join(ROOT, f))]
NOWHEEL = [f for f in fam_a if f not in WHEEL]
print("   import the wheel: %d -- %s" % (len(WHEEL), WHEEL))
print("   do not:          %d" % len(NOWHEEL))

check("9 of the 24 validate_* scripts import the upstream wheel",
      len(WHEEL) == 9, "got %d" % len(WHEEL))
check("the other 15 do not", len(NOWHEEL) == 15, "got %d" % len(NOWHEEL))

# the two that GATE the port against upstream, checked for CONTENT
GATES = {
    "validate_did_cs_binary_with_python.py": [
        r"abs\(mb\[\"coef\"\] - up\[\"coef\"\]\)\s*>\s*MODEL_TOL",
        r"ok = False",
    ],
    "validate_lplr_with_python.py": [
        r"d_up\s*=\s*abs\(mb_theta - th_up\)",
        r"band_ok\s*=\s*d_up\s*<\s*band\s+and\s+d_hr\s*<\s*band",
        r"if not band_ok:",
        r"ok = False",
    ],
}
for fn, pats in GATES.items():
    src = read(os.path.join(ROOT, fn))
    for p in pats:
        check("%s still compares the port against upstream (%s)" % (fn, clip(p, 44)),
              re.search(p, src) is not None)

# ---- the gating SET is derived, not typed ---------------------------------
# The GATES dict above NAMES the two scripts that gate the port against
# upstream, and checks that each still does.  What it could not do was NOTICE
# a third script starting to gate, because the old rule was a line PATTERN:
# "a port token and an upstream token and a comparison operator on ONE
# line".  It misses the shape `validate_lplr` uses --
#
#     d_up = abs(mb_theta - th_up)
#     band_ok = d_up < band and d_hr < band
#
# -- where the comparison is on the NEXT line.  A rule that enumerates one
# shape stops biting when a file uses another, so the set is DERIVED instead:
# the upstream NAMES come from the AST (a name bound from a call into the
# wheel), and a wheel importer gates iff some line OUTSIDE a print call
# mentions one of them together with a port token.
#
# The upstream side is derived rather than pattern-matched on purpose: the
# obvious pattern -- "a name containing `up`" -- matches `group`.
PORT_TOK = re.compile(r"\b(?:mb\w*|moonbit\w*|port\w*)\b", re.I)


def upstream_names(src):
    """The names a script binds from a call into the upstream wheel."""
    tree = ast.parse(src)
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name.split(".")[0] == "doubleml":
                    imported.add(a.asname or a.name)
        elif isinstance(node, ast.ImportFrom):
            if (node.module or "").split(".")[0] == "doubleml":
                for a in node.names:
                    imported.add(a.asname or a.name)

    def is_upstream_call(c):
        if not isinstance(c, ast.Call):
            return False
        f = c.func
        if isinstance(f, ast.Name):
            return f.id in imported or f.id.startswith("upstream")
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name):
            return f.value.id in imported or f.value.id.startswith("upstream")
        return False

    names = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        if not any(is_upstream_call(c) for c in ast.walk(node.value)):
            continue
        for t in node.targets:
            for sub in ast.walk(t):
                if isinstance(sub, ast.Name):
                    names.add(sub.id)
    return names


def print_lines(src):
    """The line numbers that sit inside a print(...) argument."""
    out = set()
    for node in ast.walk(ast.parse(src)):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        fname = getattr(f, "id", None) or getattr(f, "attr", None)
        if fname != "print":
            continue
        for arg in node.args:
            for sub in ast.walk(arg):
                if hasattr(sub, "lineno"):
                    out.add(sub.lineno)
    return out


DERIVED = {}
for f in WHEEL:
    src = read(os.path.join(ROOT, f))
    uns = upstream_names(src)
    pl = print_lines(src)
    hits = []
    for i, ln in enumerate(src.split("\n"), 1):
        if i in pl:
            continue
        if PORT_TOK.search(ln) and any(re.search(r"\b%s\b" % re.escape(u), ln)
                                        for u in uns):
            hits.append(ln.strip()[:70])
    if hits:
        DERIVED[f] = hits

check("the derived gating set is the two scripts that are named as gating",
      sorted(DERIVED) == sorted(GATES),
      "derived=%s named=%s" % (sorted(DERIVED), sorted(GATES)))
for f in WHEEL:
    check("%s %s the port against upstream"
          % (f, "gates" if f in DERIVED else "does not gate"),
          (f in DERIVED) == (f in GATES),
          "derived=%s, named=%s" % (f in DERIVED, f in GATES))

# the README's paragraph
READ = os.path.join(ROOT, "README.mbt.md")
flatr = flat(READ)
check("the README says the validate_* family is not exclusively ours",
      "The `validate_*` family is not exclusively ours" in flatr)
check("the README states the 9 / 24 wheel split",
      "**9** of its 24 scripts import the upstream `doubleml` wheel" in flatr)
check("the README names the two scripts that gate the port against upstream",
      "`validate_did_cs_binary_with_python.py`" in flatr
      and "`validate_lplr_with_python.py`" in flatr)

# the README's OWN "2" and "7" -- the numbers the paragraph publishes.  They
# were not tied to anything: the paragraph could have said "**3** of those
# gate" and every check would still have been green.
m2 = re.search(r"\*\*(\d+)\*\*\s+of\s+those\s+gate\s+the\s+port\s+against\s+upstream",
               flatr)
check("the README states how many of them gate the port against upstream",
      m2 is not None, "the phrase is not there")
if m2:
    check("the README's gating count is the derived count",
          int(m2.group(1)) == len(DERIVED),
          "the README says %s, the derivation finds %d"
          % (m2.group(1), len(DERIVED)))
m7 = re.search(r"[Tt]he\s+other\s+\*\*(\d+)\*\*\s+import\s+the\s+wheel", flatr)
check("the README states how many import the wheel for context",
      m7 is not None, "the phrase is not there")
if m7:
    check("the README's context count is the wheel importers minus the gating ones",
          int(m7.group(1)) == len(WHEEL) - len(DERIVED),
          "the README says %s, the derivation finds %d"
          % (m7.group(1), len(WHEEL) - len(DERIVED)))
check("the README's upstream-gate count word still parses",
      re.search(r"\*\*(\w+) gates whose reference is UPSTREAM", read(READ)) is not None)
check("the README's gate table still has one row per gate on disk",
      len(re.findall(r"^\| `pyexample_\w+\.py` \|", read(READ), re.M)) == len(fam_b))
check("the shipped README copy is byte-identical to the root README",
      read(READ) == read(os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")))

print()
print("=" * 74)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
