#!/usr/bin/env python3
"""Round 76 verifier: where each `validate_*` script's SECOND IMPLEMENTATION
comes from.

WHAT THIS EXISTS FOR
====================
The README said:

    Every script above compares the port against a second implementation
    written in this repository, which on its own can only catch a disagreement
    someone already thought to look for.

That was FALSE for two of the twenty-four.  `validate_pava_with_python.py`
compares the port against `sklearn.isotonic.isotonic_regression`, and
`validate_padjust_with_python.py` against
`statsmodels.stats.multitest.multipletests` -- third-party libraries, not
implementations written here.  The sentence claimed every one of the 24.

Nothing checked it, because the thing that is actually load-bearing -- the
README's claim that the port is checked against something INDEPENDENT of it --
is not what the sentence said.  The sentence said where the second
implementation comes from, and that was wrong.

THE DERIVATION
==============
A validator takes its reference from a THIRD-PARTY LIBRARY iff it imports, AT
MODULE LEVEL, a symbol from a third-party package under a namespace that NO
OTHER validator imports at module level.

  * `sklearn.linear_model` (ten validators), `sklearn.model_selection` (seven)
    and `pandas` (four) are shared.  They are nuisance learners, splitters and
    IO -- helpers, not references.  A namespace one validator alone uses is
    the opposite: it is the thing only that script needs, and the two such
    namespaces here are exactly the two references.
  * `scipy.optimize` is imported INSIDE a function, as a subroutine of this
    repository's own reference implementation, so it is not a reference and the
    module-level rule does not see it.
  * the upstream `doubleml` wheel is a separate category and is excluded; it
    has its own check (`_verify/_verify_tutorial_claims_1650.py`).
  * `parity_helper` is a LOCAL module -- the harness that runs the port's
    emitter -- so it is not third-party at all.

THE DECLARATION
===============
The README declares the same thing in prose: a count, the two scripts and the
two symbols.  The declaration and the derivation must agree, and a mismatch in
either direction is a failure.  That is the house pattern: the document
declares, the code derives, and a check that has never been shown to disagree
is a comment.

THE CONTROL ARM
================
Three synthetic corpora, and the rule has to disagree with the README's
declaration on each of them:

  1. a third validator with a namespace of its own -- the derived count moves
     to three, so the README's "Two" is wrong;
  2. the two reference namespaces shared with a third validator -- the derived
     set becomes empty, so the README's two are wrong;
  3. the README naming a symbol the code does not derive -- wrong.

Run: python _verify/_verify_validator_references_1680.py
"""
import ast
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
STDLIB = set(sys.stdlib_module_names)
LOCAL_FILES = {f[:-3] for f in os.listdir(ROOT) if f.endswith(".py")}

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %s  %-64s %s" % ("ok  " if ok else "*** FAIL ***", name, detail))
    if not ok:
        FAILS.append(name)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def third_party_imports(src):
    """The module-level third-party imports of one file.

    Returns [(namespace, symbol)], where the namespace is the MODULE PATH with
    the symbol removed -- so `from sklearn.linear_model import LinearRegression`
    and `import sklearn.linear_model.LogisticRegression` land in the same
    namespace `sklearn.linear_model`.
    """
    out = []
    for node in ast.parse(src).body:                 # module level ONLY
        if isinstance(node, ast.Import):
            for a in node.names:
                top = a.name.split(".")[0]
                if (top in STDLIB or top in LOCAL_FILES
                        or top in ("numpy", "doubleml")):
                    continue
                parts = a.name.split(".")
                ns = ".".join(parts[:-1]) if len(parts) > 1 else a.name
                out.append((ns, parts[-1]))
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                continue
            top = (node.module or "").split(".")[0]
            if (not top or top in STDLIB or top in LOCAL_FILES
                    or top in ("numpy", "doubleml")):
                continue
            for a in node.names:
                out.append((node.module, a.name))
    return out


def derive(corpus):
    """The validators whose reference comes from a third-party library.

    `corpus` is {filename: source}.  Returns {filename: (namespace, symbol)}.
    """
    per_file = {f: third_party_imports(src) for f, src in corpus.items()}
    users = {}
    for f, imps in per_file.items():
        for ns, _sym in imps:
            users.setdefault(ns, set()).add(f)
    derived = {}
    for f, imps in per_file.items():
        for ns, sym in imps:
            if len(users[ns]) == 1:                   # unique to this validator
                derived[f] = (ns, sym)
    return derived


def called(src, symbol):
    """Is `symbol` actually CALLED in this file?"""
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, ast.Call):
            f = node.func
            name = getattr(f, "id", None) or getattr(f, "attr", None)
            if name == symbol:
                return True
    return False


def audit(corpus, declared_count, declared_files, declared_symbols):
    """Compare the README's declaration with the derivation."""
    problems = []
    derived = derive(corpus)
    if len(derived) != declared_count:
        problems.append("the derived count is %d, the README says %d"
                        % (len(derived), declared_count))
    if sorted(derived) != sorted(declared_files):
        problems.append("the derived scripts are %s, the README names %s"
                        % (sorted(derived), sorted(declared_files)))
    derived_symbols = sorted(sym for _ns, sym in derived.values())
    if derived_symbols != sorted(declared_symbols):
        problems.append("the derived symbols are %s, the README names %s"
                        % (derived_symbols, sorted(declared_symbols)))
    for f, (_ns, sym) in derived.items():
        if f in corpus and not called(corpus[f], sym):
            problems.append("%s imports %s but never calls it" % (f, sym))
    return problems


# ------------------------------------------------------------------ the corpus
files = sorted(f for f in os.listdir(ROOT)
               if f.startswith("validate_") and f.endswith("_with_python.py"))
corpus = {f: read(os.path.join(ROOT, f)) for f in files}

# -------------------------------------------------------------- the declaration
readme = read(README)
m = re.search(
    r"(One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten) of them take that "
    r"implementation from a third-party library\s*--(.*?);",
    readme, re.S)
WORDS = {"One": 1, "Two": 2, "Three": 3, "Four": 4, "Five": 5, "Six": 6,
         "Seven": 7, "Eight": 8, "Nine": 9, "Ten": 10}

declared_count = None
declared_files = []
declared_symbols = []
if m:
    declared_count = WORDS[m.group(1)]
    tail = m.group(2)
    declared_files = re.findall(r"`(validate_\w+_with_python\.py)`", tail)
    declared_symbols = re.findall(r"`([A-Za-z_][A-Za-z0-9_]*)`", tail)
    declared_symbols = [s for s in declared_symbols
                        if not s.startswith("validate_")]
else:
    print("  *** FAIL ***  the README's third-party-library sentence is not "
          "findable")
    FAILS.append("the declaration is findable")
    N += 1

print("the corpus: %d `validate_*_with_python.py` scripts" % len(corpus))
print("the README declares: %s script(s), %s"
      % (declared_count,
         ", ".join(declared_files) if declared_files else "-"))
print()

if declared_count is not None:
    derived = derive(corpus)
    print("the derivation: %d script(s) take a third-party reference"
          % len(derived))
    for f in sorted(derived):
        ns, sym = derived[f]
        print("   %-40s %s.%s" % (f, ns, sym))
    print()
    problems = audit(corpus, declared_count, declared_files, declared_symbols)
    for p in problems:
        print("  *** FAIL ***  %s" % p)
    check("the declaration and the derivation agree", not problems,
          "" if not problems else "; ".join(problems)[:110])

# ------------------------------------------------------------------- the control
print()
print("the control arm: three synthetic corpora the rule has to disagree with")

# 1. a third validator with a namespace of its own
C1 = dict(corpus)
C1["validate_synthetic_with_python.py"] = (
    "import scipy.special\n"
    "\n"
    "def main():\n"
    "    return scipy.special.erf(1.0)\n")
p1 = audit(C1, declared_count, declared_files, declared_symbols)
check("a third unique namespace is REJECTED", bool(p1),
      "the derived count moves to %d" % len(derive(C1)))

# 2. the two reference namespaces shared with a third validator
C2 = dict(corpus)
C2["validate_synthetic_with_python.py"] = (
    "from sklearn.isotonic import isotonic_regression\n"
    "from statsmodels.stats.multitest import multipletests\n"
    "\n"
    "def main():\n"
    "    return isotonic_regression([1.0], [1.0]), multipletests([0.5])\n")
p2 = audit(C2, declared_count, declared_files, declared_symbols)
check("the two references becoming SHARED is REJECTED", bool(p2),
      "the derived count moves to %d" % len(derive(C2)))

# 3. the README naming a symbol the code does not derive
p3 = audit(corpus, declared_count, declared_files,
           list(declared_symbols[:-1]) + ["isotonic_regressionx"]
           if declared_symbols else ["isotonic_regressionx"])
check("a wrong symbol in the declaration is REJECTED", bool(p3),
      "the symbols must be the derived ones")

print()
print("=" * 78)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
