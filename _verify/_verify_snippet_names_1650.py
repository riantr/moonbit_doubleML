#!/usr/bin/env python3
"""Round 25 verifier: the names the README uses must be the package's names.

WHY THIS EXISTS
===============
Round 24 audited the COUNTS.  Round 25 audited the NAMES, and found three
places where the published README named something the package does not have:

  1. `DoubleMLLPLR::new(data, alpha=1.5)` -- `DoubleMLLPLR::new` has no
     `alpha`.  The snippet is offered as copy-pasteable in a plain `moonbit`
     fence, so a reader who copies it gets a compile error.  `alpha` is the
     DGP's parameter, not the estimator's.
  2. "`LearnerDispatch::RandomForestClassifier` and
     `LearnerDispatch::GradientBoostingClassifier` are the nonlinear
     options" -- those are VARIANTS of the enum; the package's constructors
     are the functions `LearnerDispatch::random_forest_classifier` and
     `LearnerDispatch::gradient_boosting_classifier`.
  3. "**21 runnable example binaries** -- 16 CLI demos, an HTTP service, a
     consumer demo and a property-based fuzz harness" -- the decomposition
     sums to 19, and the two missing ones are the bit-exact and parity
     fixtures the README's own Examples section calls runnable binaries.

None of the three is a wrong NUMBER or a wrong CLAIM about behaviour.  They
are wrong NAMES, and a claim verifier reads claims: it cannot see that a
snippet names a parameter that does not exist.

WHAT IS CHECKED
===============
  A  every argument LABEL a snippet passes to a constructor is a real
     parameter of that constructor -- in the README's fences AND in the
     package's own docstrings, because a docstring is the IDE's documentation
  B  every `LearnerDispatch::X` the README names is a public FUNCTION of
     `LearnerDispatch`; the enum's variants are not callable the way the
     rest of the document says they are
  C  the example-binaries figure and its own decomposition close, and every
     example path the bullet names exists on disk
  D  the withdrawn forms are gone from the README and from the sources

Run: python _verify/_verify_snippet_names_1650.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
EX = os.path.join(ROOT, "examples")
README = os.path.join(ROOT, "README.mbt.md")

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


def fn_params(src, struct, meth):
    """The parameter names of `pub fn Struct::meth(...)`, or None."""
    m = re.search(r"pub fn %s::%s\((.*?)\)\s*->" % (re.escape(struct), re.escape(meth)),
                  src, re.S)
    if not m:
        return None
    return set(re.findall(r"(\w+)\s*~?\s*:", m.group(1)))


def sources():
    out = {}
    for name in sorted(os.listdir(PKG)):
        if name.endswith(".mbt"):
            out[name] = read(os.path.join(PKG, name))
    return out


SRC = sources()
readme = read(README)


def check_calls(body, where, require_ctor=True):
    """Every `Struct::method(label=...)` in `body` must name real parameters."""
    bad = []
    for m in re.finditer(r"\b(DoubleML\w+)::(\w+)\(([^()]*)\)", body):
        struct, meth, args = m.group(1), m.group(2), m.group(3)
        named = re.findall(r"(\w+)\s*=", args)
        if not named:
            continue
        found = False
        for s in SRC.values():
            params = fn_params(s, struct, meth)
            if params is not None:
                found = True
                for lbl in named:
                    if lbl not in params:
                        bad.append("%s::%s(%s=) -- the real parameters are %s"
                                   % (struct, meth, lbl, ", ".join(sorted(params))))
                break
        if not found:
            bad.append("%s::%s -- no such declaration in the package" % (struct, meth))
    for b in bad:
        check("%s: %s" % (where, b[:96]), False, "")
    return bad


# --------------------------------------------------------------------------- #
# A. the arguments a snippet passes must be real parameters
# --------------------------------------------------------------------------- #
print()
print("A. the arguments a snippet passes must be real parameters")

FENCE = re.compile(r"^[ \t]*(```[^\n]*)\n(.*?)^[ \t]*```", re.M | re.S)
fences = FENCE.findall(readme)
readme_bad = []
for lang, body in fences:
    readme_bad += check_calls(body, "README %s fence" % lang.strip())
check("the README's fences pass no non-existent argument",
      not readme_bad, "%d bad" % len(readme_bad))

# the package's own docstrings: the IDE shows them beside the declaration
doc_bad = []
for name, s in SRC.items():
    for m in re.finditer(r"^///[ \t]*```[^\n]*\n(.*?)^///[ \t]*```", s, re.M | re.S):
        doc_bad += check_calls(m.group(1), "%s docstring" % name)
check("the package's docstrings pass no non-existent argument",
      not doc_bad, "%d bad" % len(doc_bad))

check("the README's LPLR snippet calls the constructor without `alpha`",
      "DoubleMLLPLR::new(data).fit()" in readme)
check("the source docstring's LPLR snippet calls it without `alpha`",
      "DoubleMLLPLR::new(data).fit()" in SRC.get("lplr.mbt", ""))

# --------------------------------------------------------------------------- #
# B. every LearnerDispatch:: name the README uses is a public function
# --------------------------------------------------------------------------- #
print()
print("B. every `LearnerDispatch::` name the README uses is a public function")

learner_src = ""
for name, s in SRC.items():
    if "LearnerDispatch" in s:
        learner_src += s
fns = set(re.findall(r"pub fn LearnerDispatch::(\w+)", learner_src))
variants = set(re.findall(r"^\s{2}(\w+)\(", learner_src, re.M))
print("   public functions: %s" % ", ".join(sorted(fns)))
print("   enum variants   : %d" % len(variants))

used = sorted(set(re.findall(r"LearnerDispatch::(\w+)", readme)))
print("   the README names: %s" % ", ".join(used))
for u in used:
    check("`LearnerDispatch::%s` is a public function" % u, u in fns,
          "it is a VARIANT" if u in variants else "")

# --------------------------------------------------------------------------- #
# C. the example-binaries figure and its decomposition close
# --------------------------------------------------------------------------- #
print()
print("C. the example-binaries figure and its decomposition close")

pkgs = sorted(d for d in os.listdir(EX)
              if os.path.isfile(os.path.join(EX, d, "moon.mod")))
print("   example packages on disk: %d" % len(pkgs))

m = re.search(r"\*\*(\d+) runnable example binaries\*\*(.*?)\n\n", readme, re.S)
check("the example-binaries bullet is findable", m is not None)
if m:
    headline = int(m.group(1))
    bullet = m.group(0)
    check("the headline is the tree's example count",
          headline == len(pkgs), "says %d, tree has %d" % (headline, len(pkgs)))
    named = re.findall(r"`examples/([^/`]+)/`", bullet)
    check("every example path the bullet names exists on disk",
          all(n in pkgs for n in named), str(named))
    demos = re.search(r"\*\*(\d+) CLI demos\*\*", bullet) or \
        re.search(r"(\d+) CLI demos", bullet)
    check("the bullet states a CLI-demo count", demos is not None)
    if demos:
        n_cli = int(demos.group(1))
        check("the decomposition closes on the headline",
              n_cli + len(named) == headline,
              "%d CLI + %d named = %d, headline %d"
              % (n_cli, len(named), n_cli + len(named), headline))
    check("the bullet names the two fixture examples",
          "bitexact" in named and "parity" in named, str(named))

# --------------------------------------------------------------------------- #
# D. the withdrawn forms are gone
# --------------------------------------------------------------------------- #
print()
print("D. the withdrawn forms are gone")

WITHDRAWN = [
    ("alpha=1.5", [readme] + list(SRC.values())),
    ("LearnerDispatch::RandomForestClassifier", [readme]),
    ("LearnerDispatch::GradientBoostingClassifier", [readme]),
    ("16 CLI demos, an HTTP service", [readme]),
]
for needle, hay in WITHDRAWN:
    where = [i for i, h in enumerate(hay) if needle in h]
    check("%r appears nowhere" % needle, not where,
          "in %d place(s)" % len(where))

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
