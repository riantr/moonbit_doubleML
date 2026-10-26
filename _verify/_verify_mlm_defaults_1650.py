#!/usr/bin/env python3
"""Round 51 verifier: the `ml_m` DEFAULT split, DERIVED from the source.

WHAT THIS EXISTS FOR
====================
The `ml_m` slot -- the propensity nuisance learner -- is the one constructor
argument whose default CHANGED the estimators' answers.  Seven of them now
default to a classifier and eight to a regressor, and that split is published
in the README, in `TUNE_DESIGN.md` and in the CHANGELOG.

It was also, until this round, published with no owner.  `TUNE_DESIGN.md` said
"logistic is the default `ml_m` for **6** estimators" -- twice -- while the
README, ninety lines from its own list, named SEVEN estimators, and the
CHANGELOG had already corrected a "6 / 6" claim to "**7 logistic / 8
linear**".  Nothing watched that document's number, so the two disagreed
silently.

The lesson is the one the repository has already learned about sentences: a
check that followed a SENTENCE would rot with the wording.  This one follows
the FACT.

THE MODEL
=========
The split is not a literal anywhere in this file.  It is read out of the
package, the way a reader would:

  * `LearnerDispatch::is_classifier` is the package's own decision procedure:
    its `match` arms say which variants are classifiers and which are
    regressors.  Those arms are the authority, so the classifier set is read
    from them and not from a list written here.

  * every `ml_m` default is read from the `DoubleMLXxx::new` signatures in
    the package's PRODUCTION files, and the factory it names is mapped onto
    the variant `is_classifier` knows.

A default that names a learner the package does not have is a check failure,
not a silent omission: that is the whole point of reading the split instead of
writing it down.

WHAT IS A LIVE DOCUMENT
========================
`CHANGELOG.md` and `ENGINEERING.md` are HISTORICAL -- the CHANGELOG is an
append-only record and the ENGINEERING body is the README as it stood at
v0.164.11.  They are allowed to record a number that was true when they were
written.  Everything else that a reader can open is LIVE, and a live document
that states a count for this set must state the measured one.

THE COUNT IS NOT PINNED HERE
============================
The set may legitimately grow -- a future release may migrate an eighth
estimator, and the split may change with it.  So no number is hard-coded:
the documents carry the published figures and this check holds them against
the source.  A migration that changes the source without changing the
documents is exactly what this check is for.

Run: python _verify/_verify_mlm_defaults_1650.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "*** FAIL ***", label, detail))
    if not ok:
        FAILS.append(label)


def read(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


def flat(text):
    """Whitespace-normalised text.

    A phrase can straddle a line break -- "the default `ml_m` for 6
    estimators" is written "for 6" at the end of one line and "estimators" at
    the start of the next -- and a line-based search misses it.  This is the
    round-36 lesson, applied to the documents this check reads.
    """
    return re.sub(r"\s+", " ", text)


NUMWORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
}


def number(token):
    """(value, ok) -- a count written as a digit or as an English word."""
    t = (token or "").strip().strip("*`_").lower()
    if t.isdigit():
        return int(t), True
    if t in NUMWORDS:
        return NUMWORDS[t], True
    return None, False


def snake_to_camel(name):
    return "".join(p[:1].upper() + p[1:] for p in name.split("_"))


def balanced(text, i):
    """text[i] == '(' ; the index of the matching ')'."""
    depth = 0
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def brace_block(text, i):
    """text[i] == '{' ; the index of the matching '}'."""
    depth = 0
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def learner_kinds():
    """(classifiers, regressors) -- the variant names, read from the source."""
    t = read(os.path.join(PKG, "learner.mbt"))
    m = re.search(r"pub fn LearnerDispatch::is_classifier\s*\([^)]*\)\s*->\s*Bool\s*\{",
                  t)
    if not m:
        return None, None
    end = brace_block(t, m.end() - 1)
    body = t[m.end():end + 1]
    cls, reg = [], []
    for mm in re.finditer(r"([A-Z][A-Za-z0-9_]*)\s*\(_\)\s*=>\s*(true|false)", body):
        (cls if mm.group(2) == "true" else reg).append(mm.group(1))
    return cls, reg


def production_files():
    out = []
    for f in sorted(os.listdir(PKG)):
        if not f.endswith(".mbt"):
            continue
        if re.search(r"_test\.mbt$", f):
            continue
        out.append(f)
    return out


def constructors():
    """{estimator: default expression} for every `ml_m` slot in the package.

    Also returns every `DoubleML*::new` constructor, so the estimator set
    (the ones that are not data types) can be derived from the same scan.
    """
    slots = {}
    all_ctors = set()
    for f in production_files():
        t = read(os.path.join(PKG, f))
        for m in re.finditer(r"pub fn (DoubleML[A-Za-z0-9_]*)::new\s*\(", t):
            name = m.group(1)
            all_ctors.add(name)
            end = balanced(t, m.end() - 1)
            params = t[m.end() - 1:end + 1]
            # `ml_m~ : LearnerDispatch = <expr>` -- the tilde is the optional
            # marker, and the default can span several lines.
            mm = re.search(r"ml_m\s*[~?]\s*:\s*LearnerDispatch\s*=\s*", params)
            if not mm:
                continue
            rest = params[mm.end():]
            if rest.startswith("("):
                stop = balanced(rest, 0)
                expr = rest[:stop + 1]
            else:
                expr = rest.split(",")[0]
            slots.setdefault(name, " ".join(expr.split()))
    return slots, all_ctors


def tuner_names():
    """The estimators that carry a `::tune` method."""
    out = set()
    for f in sorted(os.listdir(PKG)):
        if not f.endswith(".mbt"):
            continue
        t = read(os.path.join(PKG, f))
        for m in re.finditer(r"pub fn (DoubleML[A-Za-z0-9_]*)::tune\b", t):
            out.add(m.group(1))
    return out


# The documents a reader can open.  The CHANGELOG and the ENGINEERING body are
# historical and are deliberately NOT here: they record what was true when
# they were written.
LIVE_DOCS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "TUNE_DESIGN.md",
    "QUANTILE_HANDOFF.md",
    "doc/README.mbt.md",
    "skills/moonbit_doubleML.md",
    "examples/api_server/README.md",
    "AGENTS.md",
]

# The two shapes a document uses to state this set's size.
COUNT_PATTERNS = [
    r"\*\*(\w+)\*\*\s+estimators\s+now\s+default\s+to\s+a\s+classifier",
    r"default\s+`ml_m`\s+for\s+(\w+)\s+estimators",
]


def stated_counts(text):
    """[(value, token, where)] -- every count this document states."""
    f = flat(text)
    out = []
    for pat in COUNT_PATTERNS:
        for m in re.finditer(pat, f):
            value, ok = number(m.group(1))
            out.append((value if ok else None, m.group(1), m.start()))
    return out


# ==============================================================================
print("=" * 78)
print("A. the measurement -- the split, read out of the package")
print("=" * 78)

CLS, REG = learner_kinds()
check("the package's classifier decision procedure is findable",
      CLS is not None and len(CLS) > 0,
      "%d classifiers, %d regressors" % (len(CLS or []), len(REG or [])))

variants = set(CLS or []) | set(REG or [])
arms = re.findall(r"([A-Z][A-Za-z0-9_]*)\s*\(_\)\s*=>\s*(true|false)",
                  read(os.path.join(PKG, "learner.mbt")))
check("every learner variant is classified exactly once",
      len(arms) == len(variants) and len(arms) == len(set(n for n, _k in arms)),
      "%d arms, %d distinct variants" % (len(arms), len(set(n for n, _k in arms))))

SLOTS, CTORS = constructors()
check("at least one `ml_m` slot exists -- the instrument works",
      len(SLOTS) > 0,
      "%d estimators carry an `ml_m` slot" % len(SLOTS))

# map the factory a default names onto the variant is_classifier knows
kind_of = {}
unknown = []
cls_set = set(CLS or [])
for name, expr in sorted(SLOTS.items()):
    fm = re.search(r"LearnerDispatch::([a-z0-9_]+)", expr)
    if not fm:
        unknown.append("%s: %s" % (name, expr[:40]))
        continue
    variant = snake_to_camel(fm.group(1))
    if variant not in variants:
        unknown.append("%s: %s" % (name, expr[:40]))
        continue
    kind_of[name] = "classifier" if variant in cls_set else "regressor"

check("every `ml_m` default names a learner the package knows",
      not unknown,
      "; ".join(unknown[:4]) if unknown else "%d defaults, all known" % len(kind_of))

CLASSIFIERS = sorted(k for k, v in kind_of.items() if v == "classifier")
REGRESSORS = sorted(k for k, v in kind_of.items() if v == "regressor")
check("the classifier-defaulted and regressor-defaulted sets are disjoint",
      not (set(CLASSIFIERS) & set(REGRESSORS)),
      "%d classifier-defaulted, %d regressor-defaulted"
      % (len(CLASSIFIERS), len(REGRESSORS)))
check("the two sets together cover every estimator with an `ml_m` slot",
      set(CLASSIFIERS) | set(REGRESSORS) == set(SLOTS),
      "%d + %d = %d of %d slots"
      % (len(CLASSIFIERS), len(REGRESSORS),
         len(CLASSIFIERS) + len(REGRESSORS), len(SLOTS)))
check("no `ml_m` default is neither a classifier nor a regressor",
      len(CLASSIFIERS) + len(REGRESSORS) == len(SLOTS),
      "%d classified of %d slots" % (len(CLASSIFIERS) + len(REGRESSORS), len(SLOTS)))

ESTIMATORS = sorted(c for c in CTORS if not c.endswith("Data"))
print("  the measured split: %d classifier-defaulted, %d regressor-defaulted"
      % (len(CLASSIFIERS), len(REGRESSORS)))
print("    classifier-defaulted: %s" % ", ".join(CLASSIFIERS))
print("    regressor-defaulted : %s" % ", ".join(REGRESSORS))

# ==============================================================================
print()
print("=" * 78)
print("B. the README -- the set it publishes")
print("=" * 78)

README = read(os.path.join(ROOT, "README.mbt.md"))
rm = re.search(
    r"\*\*(\w+)\*\*\s+estimators\s+now\s+default\s+to\s+a\s+classifier\s*--\s*(.*?)\s*--",
    flat(README))
readme_count = None
readme_list = []
if rm:
    readme_count, ok = number(rm.group(1))
    if not ok:
        readme_count = None
    readme_list = re.findall(r"`(DoubleML[A-Za-z0-9_]+)`", rm.group(2))

check("the README publishes the set of classifier-defaulted estimators",
      rm is not None and len(readme_list) > 0,
      "%d named" % len(readme_list))
check("the README's count is readable as a number",
      readme_count is not None,
      "the count token is %r" % (rm.group(1) if rm else None))
check("the README's count agrees with the list it publishes",
      readme_count is not None and readme_count == len(readme_list),
      "count %s, %d named" % (readme_count, len(readme_list)))
check("the README's list is the measured classifier-defaulted set",
      sorted(readme_list) == CLASSIFIERS,
      "the README names %s" % ", ".join(sorted(readme_list)))
check("the README's count is the measured classifier-defaulted count",
      readme_count is not None and readme_count == len(CLASSIFIERS),
      "the README says %s, the package has %d" % (readme_count, len(CLASSIFIERS)))

# ==============================================================================
print()
print("=" * 78)
print("C. TUNE_DESIGN.md -- the numbers it states about the implementation")
print("=" * 78)

TD = read(os.path.join(ROOT, "TUNE_DESIGN.md"))
td_counts = stated_counts(TD)
check("TUNE_DESIGN states a count for the default `ml_m` set",
      len(td_counts) > 0,
      "%d counts: %s" % (len(td_counts), ", ".join(str(c[1]) for c in td_counts)))
check("every count TUNE_DESIGN states is the measured one",
      bool(td_counts) and all(c[0] == len(CLASSIFIERS) for c in td_counts),
      "; ".join("%s (measured %d)" % (c[1], len(CLASSIFIERS)) for c in td_counts)
      if td_counts else "none stated")

tv = re.search(r"\*\*(\d+)\*\*\s+variants", flat(TD))
check("TUNE_DESIGN's learner-variant count is the measured one",
      tv is not None and int(tv.group(1)) == len(variants),
      "TUNE_DESIGN says %s, the package has %d variants"
      % (tv.group(1) if tv else None, len(variants)))

tr = re.search(r"(\d+)\s+regressors\s*(?:and|\+)\s*(\d+)\s+classifiers",
                flat(TD))
check("TUNE_DESIGN's regressor/classifier split is the measured one",
      tr is not None and int(tr.group(1)) == len(REG)
      and int(tr.group(2)) == len(CLS),
      "TUNE_DESIGN says %s regressors / %s classifiers, the package has %d / %d"
      % (tr.group(1) if tr else "?", tr.group(2) if tr else "?",
         len(REG), len(CLS)))

TUNERS = tuner_names()
tune_est = sorted(t for t in TUNERS if t in ESTIMATORS)
tt = re.search(r"\*\*(\d+)\s+of\s+the\s+(\d+)\*\*\s+estimators", flat(TD))
check("TUNE_DESIGN's tune() count is the measured one",
      tt is not None and int(tt.group(1)) == len(tune_est)
      and int(tt.group(2)) == len(ESTIMATORS),
      "TUNE_DESIGN says %s of %s, the package has %d of %d"
      % (tt.group(1) if tt else "?", tt.group(2) if tt else "?",
         len(tune_est), len(ESTIMATORS)))

missing = sorted(set(ESTIMATORS) - set(tune_est))
# The exceptions are named in a sentence that opens with "The three
# exceptions" and closes with an em-dash; the names are what matter, so the
# window is taken from the word "exceptions" rather than from a fixed
# punctuation.
tm = re.search(r"exceptions(.{0,220})", flat(TD), re.S)
named = re.findall(r"`(DoubleML[A-Za-z0-9_]+)`", tm.group(1)) if tm else []
check("TUNE_DESIGN's named tune() exceptions are the measured ones",
      sorted(named) == missing,
      "TUNE_DESIGN names %s, the package lacks %s"
      % (", ".join(named), ", ".join(missing)))

# ==============================================================================
print()
print("=" * 78)
print("D. no live document disagrees")
print("=" * 78)

offenders = []
for rel in LIVE_DOCS:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    for value, token, _pos in stated_counts(read(p)):
        if value != len(CLASSIFIERS):
            offenders.append("%s says %s" % (rel, token))
check("no live document states a count for this set other than the measured one",
      not offenders,
      "; ".join(offenders[:4]) if offenders
      else "%d live documents, %d counts, all %d"
      % (len(LIVE_DOCS), sum(len(stated_counts(read(os.path.join(ROOT, d.replace('/', os.sep)))))
                               for d in LIVE_DOCS if os.path.isfile(
                                   os.path.join(ROOT, d.replace("/", os.sep)))),
         len(CLASSIFIERS)))

check("the README and TUNE_DESIGN agree with each other",
      readme_count is not None
      and bool(td_counts)
      and all(c[0] == readme_count for c in td_counts),
      "the README says %s, TUNE_DESIGN says %s"
      % (readme_count, ", ".join(str(c[1]) for c in td_counts) or "nothing"))

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
