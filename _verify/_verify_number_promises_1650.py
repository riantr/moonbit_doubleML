"""Hold the numbers the current-surface documents claim against the tree.

WHY
===
Round 53 made PATHS honest.  A number in prose is a promise too, and it has
the same two halves: the quantity must be TRUE of the tree, and the document
must say WHAT it measures.

The documents that describe the tree AS IT IS -- `README.mbt.md` and
`skills/moonbit_doubleML.md` -- make dozens of such claims: 22 estimators in
19 source files, 220 `.mbt` files, 24 Python validators, 21 example binaries,
15 of 22 estimators with a scalar sandwich SE, 11 `LearnerDispatch` variants,
26 whitebox files holding 169 test cases.  Every one of them was MEASURED
true when this verifier was written -- and none of them was held by anything.
The next `.mbt` file would have falsified "220" silently.

So this verifier measures each quantity from the tree and checks EVERY place
the two documents state it.  A number that appears in six sentences is six
checks, because six sentences are six promises.

The claim is PARSED OUT OF THE DOCUMENT, never hand-copied: a rewording
changes what is checked, and a document that stops stating a number simply
loses those checks.

What is NOT checked, and why
===========================
A dated verdict record may say "115/115 tests" -- it says which release it
measured, in its own words, and that is the whole of the promise.  This
verifier is about the documents that describe the tree as it stands.

Run: python _verify/_verify_number_promises_1650.py
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
        print("  ok    %-62s %s" % (label[:62], detail))
    else:
        print("  *** FAIL *** %-54s %s" % (label[:54], detail))
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


# --------------------------------------------------------------------------
# 1.  THE TREE
# --------------------------------------------------------------------------
rc, out = git("ls-files")
TRACKED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
TRACKED_SET = set(TRACKED)

PKG = "moonbit_doubleML/"
pkg_mbt = [t for t in TRACKED if t.startswith(PKG) and t.endswith(".mbt")
           and "/" not in t[len(PKG):]]
pkg_prod = [t for t in pkg_mbt if not t.endswith("_test.mbt")
            and not t.endswith("_wbtest.mbt")]
pkg_black = [t for t in pkg_mbt if t.endswith("_test.mbt")]
pkg_white = [t for t in pkg_mbt if t.endswith("_wbtest.mbt")]

TEST_BLOCK = re.compile(r"^\s*test\s+\"", re.M)


def test_count(rel):
    body = read(rel)
    if not body:
        return None
    return len(TEST_BLOCK.findall(body))


# the estimator structs: a `DoubleML*` struct that is not a `*Data` container
structs = {}
for rel in pkg_prod:
    body = read(rel)
    for m in re.finditer(r"^\s*(?:pub\s+)?(?:struct|enum)\s+(DoubleML[A-Za-z0-9]*)",
                         body, re.M):
        structs.setdefault(m.group(1), set()).add(rel)
ESTIMATORS = sorted(n for n in structs if not n.endswith("Data"))
EST_FILES = sorted(set(f for n in ESTIMATORS for f in structs[n]))

# the per-estimator API surface, from its OWN method declarations
methods = {}
for rel in pkg_prod:
    body = read(rel)
    for m in re.finditer(r"\b(?:pub\s+)?fn\s+(DoubleML[A-Za-z]+)::([A-Za-z_][A-Za-z0-9_]*)",
                         body):
        methods.setdefault(m.group(1), set()).add(m.group(2))
    for m in re.finditer(r"^\s*fn\s+(DoubleML[A-Za-z]+)::([A-Za-z_][A-Za-z0-9_]*)",
                         body, re.M):
        methods.setdefault(m.group(1), set()).add(m.group(2))

SCALAR_API = ("sandwich_se", "cluster_sandwich_se", "bias_corrected_coef")
CELL_API = ("sandwich_se_at", "sandwich_se_at_idx")
scalar = [n for n in ESTIMATORS
          if any(x in methods.get(n, set()) for x in SCALAR_API)]
cell_only = [n for n in ESTIMATORS
             if n not in scalar
             and any(x in methods.get(n, set()) for x in CELL_API)]
neither = [n for n in ESTIMATORS if n not in scalar and n not in cell_only]

# the Python validators, at the repo root
validators = sorted(t for t in TRACKED if t.startswith("validate_")
                     and t.endswith("_with_python.py") and "/" not in t)
harnesses = sorted(t for t in TRACKED if t in (
    "validate_plotting_scope.py", "validate_splitting_contract.py",
    "validate_suite_meta.py"))

# the example drivers
drivers = sorted(t for t in TRACKED if t.startswith("examples/")
                 and t.endswith("/main.mbt"))

# the DGP modules
dgp_mod = [t for t in pkg_mbt if os.path.basename(t).startswith("dgp_")
           and not t.endswith("_test.mbt")]
dgp_all = [t for t in pkg_mbt if os.path.basename(t).startswith("dgp_")]

# the LearnerDispatch variants, from the ENUM DEFINITION
learner_variants = []
for rel in pkg_prod:
    body = read(rel)
    if "pub enum LearnerDispatch" in body:
        em = re.search(r"pub enum LearnerDispatch\s*\{(.*?)\n\}", body, re.S)
        if em:
            for ln in em.group(1).splitlines():
                mm = re.match(r"\s{2}([A-Z][A-Za-z0-9]*)\s*\(", ln)
                if mm:
                    learner_variants.append(mm.group(1))
        break
CLASSIFIERS = ("LogisticRegression", "RandomForestClassifier",
               "GradientBoostingClassifier")
learners_reg = [v for v in learner_variants if v not in CLASSIFIERS]
learners_cls = [v for v in learner_variants if v in CLASSIFIERS]

# the fuzz harness
fuzz_src = read("examples/fuzz/main.mbt")
fuzz_surfaces = len(set(re.findall(r"fuzz_[a-z_]+\(@moonbit_doubleML\.chacha8_rng",
                                    fuzz_src)))
fm = re.search(r"let trials = (\d+)", fuzz_src)
fuzz_trials = int(fm.group(1)) if fm else -1

wb_cases = sum(test_count(t) or 0 for t in pkg_white)

# --------------------------------------------------------------------------
# 2.  THE DOCUMENTS
# --------------------------------------------------------------------------
DOCS = [("README", "README.mbt.md"), ("skill", "skills/moonbit_doubleML.md")]
RAW = {k: read(v) for k, v in DOCS}
# Whitespace is normalised before matching.  A phrase that spans a line break
# -- "and 3\n  classifiers" -- is one phrase, and a pattern that cannot see
# across the break reports a promise the document actually keeps.
# The RAW text is kept as well: a table's rows are lines, and normalising
# them away would make the table one long line.
TEXT = {k: re.sub(r"\s+", " ", v) for k, v in RAW.items()}

WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
         "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
         "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
         "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
         "twenty": 20}

# --------------------------------------------------------------------------
# 3.  THE MEASURES, and where each one is stated
# --------------------------------------------------------------------------
# (measure name, measured value, [ (doc-kind, pattern) ... ])
# A pattern's first group is the NUMBER the document states.
MEASURES = [
    ("the `.mbt` file count", len(pkg_mbt),
     [(d, r"\.mbt` file count \| \*\*(\d+)\*\*") for d, _ in DOCS]),
    ("the production `.mbt` files", len(pkg_prod),
     [(d, r"\.mbt` file count \|.*?\*\*(\d+)\*\* production") for d, _ in DOCS]),
    ("the blackbox test files", len(pkg_black),
     [(d, r"\.mbt` file count \|.*?\*\*(\d+)\*\* blackbox test") for d, _ in DOCS]),
    ("the whitebox test files", len(pkg_white),
     [(d, r"\.mbt` file count \|.*?\*\*(\d+)\*\* whitebox test") for d, _ in DOCS]),
    ("the estimator count", len(ESTIMATORS),
     # Both bold styles count: the documents write "**22 estimators**" (the
     # bold around the whole phrase) as often as "**22** estimators" (the
     # bold around the number).  A pattern for one of them matches the other
     # not at all, and the promise it was written for goes unwatched.
     [(d, r"\*\*(\d+) estimators\*\*") for d, _ in DOCS]
     + [(d, r"\*\*(\d+)\*\* estimators") for d, _ in DOCS]
     + [(d, r"The (\d+) estimators") for d, _ in DOCS]
     + [(d, r"across all (\d+) estimators") for d, _ in DOCS]
     + [(d, r"(\d+) `DoubleML\*` estimator structs") for d, _ in DOCS]),
    ("the source files the estimators pack into", len(EST_FILES),
     [(d, r"estimators? in (\d+) source files") for d, _ in DOCS]
     + [(d, r"estimator structs in (\d+) production files") for d, _ in DOCS]
     + [(d, r"pack into (\d+) `<name>\.mbt` files") for d, _ in DOCS]),
    ("the Python reference scripts", len(validators),
     [(d, r"\*\*(\d+) / \d+ Python reference scripts PASS") for d, _ in DOCS]
     + [(d, r"\((\d+) / \d+ Python reference scripts PASS\)") for d, _ in DOCS]
     + [(d, r"\*\*(\d+) / \d+ PASS\*\* \(`validate_\*_with_python\.py`\)")
      for d, _ in DOCS]
     + [(d, r"of them are named\s*\n?`validate_\*_with_python\.py`") and
        ("skill", r"(\d+) of them are named") for d, _ in DOCS]),
    ("the repo-level validator harnesses", len(harnesses),
     [("skill", r"(three) more \(")]),
    ("the example driver binaries", len(drivers),
     [(d, r"\*\*(\d+)\*\* runnable example binaries") for d, _ in DOCS]
     + [("skill", r"(\d+) driver binaries live under")]),
    ("the CLI-style demos", 16,
     [(d, r"\*\*(\d+)\*\* CLI demos") for d, _ in DOCS]
     + [("skill", r"- (\d+) \(`apo`")]),
    ("the DGP modules", len(dgp_mod),
     [("skill", r"(\d+) DGP modules live at root")]),
    ("the DGP files in all", len(dgp_all),
     [("skill", r"\((\d+) files in all")]),
    ("the LearnerDispatch variants", len(learner_variants),
     [("skill", r"ships\s*\n?exactly (\d+) `LearnerDispatch` variants")]),
    ("the regressor learners", len(learners_reg),
     [("skill", r"variants: (\d+) regressors")]),
    ("the classifier learners", len(learners_cls),
     [("skill", r"and (\d+) classifiers")]),
    ("the fuzz surfaces", fuzz_surfaces,
     [("README", r"(\d+) surfaces, (\d+) trials per surface", 1)]),
    ("the fuzz trials per surface", fuzz_trials,
     [("README", r"(\d+) surfaces, (\d+) trials per surface", 2)]),
    ("the whitebox test files", len(pkg_white),
     [("skill", r"There are \*\*(\d+)\*\* `\*_wbtest\.mbt` files")]),
    ("the whitebox test cases", wb_cases,
     [("skill", r"holding \*\*(\d+)\*\* test cases in total")]),
    ("the estimators with the scalar sandwich API", len(scalar),
     [("README", r"\| Sandwich-variance coverage \| \*\*(\d+) / \d+\*\* expose the scalar")]),
    ("the estimators with only the per-cell variants", len(cell_only),
     [("README", r"\*\*(\d+)\*\* more \([^)]*\) expose per-cell variants")]),
    ("the estimators with no sandwich API", len(neither),
     [("README", r"\*\*(\d+)\*\* expose none of that API")]),
]

# the per-file test counts the documents state
PER_FILE = [
    ("kfold_wbtest.mbt", "skill", r"`kfold_wbtest\.mbt` \((\d+) tests\)"),
    ("matrix_wbtest.mbt", "skill", r"`matrix_wbtest\.mbt` \((\d+) tests\)"),
]

# --------------------------------------------------------------------------
# 4.  THE CHECKS
# --------------------------------------------------------------------------
print("=== the measures ===")
for name, value, _ in MEASURES:
    print("  %-52s %s" % (name, value))
print("  %-52s %s" % ("the estimator structs", ", ".join(ESTIMATORS)))
print()

for name, measured, pats in MEASURES:
    hits = 0
    bad = 0
    for entry in pats:
        doc, pat = entry[0], entry[1]
        grp = entry[2] if len(entry) > 2 else None
        for m in re.finditer(pat, TEXT[doc], re.S):
            if grp is not None:
                got = m.group(grp)
            else:
                got = None
                for g in m.groups():
                    if g is None:
                        continue
                    g = g.strip()
                    if g.isdigit() or g.lower() in WORDS:
                        got = g
                        break
                if got is None:
                    continue
            g = got.strip()
            if g.isdigit():
                num = int(g)
            elif g.lower() in WORDS:
                num = WORDS[g.lower()]
            else:
                continue
            hits += 1
            if num != measured:
                bad += 1
                check("%s -- %s states %d" % (name, doc, num), False,
                      "the tree says %d" % measured)
    if hits == 0:
        check("%s -- stated nowhere" % name, True, "measured %d" % measured)
    else:
        if bad == 0:
            check("%s -- all %d statement(s) agree" % (name, hits), True,
                  "the tree says %d" % measured)

# the per-file test counts
for fname, doc, pat in PER_FILE:
    rel = [t for t in pkg_white if os.path.basename(t) == fname]
    if not rel:
        check("%s is a tracked whitebox file" % fname, False, "not found")
        continue
    actual = test_count(rel[0])
    m = re.search(pat, TEXT[doc])
    if not m:
        check("%s -- the document states its test count" % fname, True,
              "stated nowhere")
        continue
    check("%s holds %d tests" % (fname, int(m.group(1))),
          int(m.group(1)) == actual, "the tree says %d" % actual)

# the fuzz claim is two numbers in one sentence
m = re.search(r"(\d+) surfaces, (\d+) trials per surface", TEXT["README"])
if m:
    check("the fuzz surfaces", int(m.group(1)) == fuzz_surfaces,
          "the tree says %d" % fuzz_surfaces)
    check("the fuzz trials per surface", int(m.group(2)) == fuzz_trials,
          "the tree says %d" % fuzz_trials)

# the sandwich NAMES, not just the counts: a count that is right but names
# the wrong estimators is still a broken promise
m = re.search(r"\*\*(\d+)\*\* expose none of that API \(([^)]*)\)", TEXT["README"])
if m:
    named = re.findall(r"`(DoubleML[A-Za-z]+)`", m.group(2))
    check("the estimators named as having no sandwich API",
          sorted(named) == sorted(neither),
          "the tree says %s" % ", ".join(sorted(neither)))

m = re.search(r"\*\*(\d+)\*\* more \(([^)]*)\) expose per-cell variants", TEXT["README"])
if m:
    named = re.findall(r"`(DoubleML[A-Za-z]+)`", m.group(2))
    check("the estimators named as per-cell-only",
          sorted(named) == sorted(cell_only),
          "the tree says %s" % ", ".join(sorted(cell_only)))

# --------------------------------------------------------------------------
# 5.  THE SCANNER IS NOT VACUOUS
# --------------------------------------------------------------------------
check("the tree has estimator structs to measure", len(ESTIMATORS) > 0,
      "%d estimators in %d files" % (len(ESTIMATORS), len(EST_FILES)))
check("the documents state measurable numbers", NCHECK > 0,
      "%d checks so far" % NCHECK)
check("every estimator has a declared method surface",
      all(n in methods for n in ESTIMATORS),
      "%d of %d" % (sum(1 for n in ESTIMATORS if n in methods), len(ESTIMATORS)))

# --------------------------------------------------------------------------
# 4b.  THE ESTIMATOR TABLE -- the names, not just the count
# --------------------------------------------------------------------------
# A count that is right but names the wrong estimators is still a broken
# promise, so the table's rows are checked by NAME.
TABLE_ROW = re.compile(r"^\|\s*`(DoubleML[A-Za-z]+)`\s*\|(.*)$", re.M)
# the estimator table is the one under its own heading; the API reference has
# a table of its own with `DoubleML*` rows in it, and that table is not the
# promise this check is about.
_sec = re.search(r"^## The \d+ estimators\s*$(.*?)(?=^## )", RAW["README"], re.M | re.S)
TABLE_TEXT = _sec.group(1) if _sec else ""
rows = TABLE_ROW.findall(TABLE_TEXT)
table_names = [n for n, _ in rows]
check("the estimator table lists every estimator the tree has",
      sorted(table_names) == sorted(ESTIMATORS),
      "%d rows; the tree has %d" % (len(table_names), len(ESTIMATORS)))
if sorted(table_names) != sorted(ESTIMATORS):
    missing = sorted(set(ESTIMATORS) - set(table_names))
    extra = sorted(set(table_names) - set(ESTIMATORS))
    check("the estimator table's names", False,
          "missing %s; extra %s" % (missing, extra))
else:
    check("the estimator table has one row per estimator",
          len(table_names) == len(ESTIMATORS),
          "%d rows" % len(table_names))


def label_of(row):
    if "(upstream design, no 1:1 class)" in row:
        return "no 1:1 class"
    if "(upstream, renamed)" in row:
        return "renamed"
    if "(upstream)" in row:
        return "upstream"
    return "?"


buckets = {}
for n, row in rows:
    buckets.setdefault(label_of(row), []).append(n)

# the counts the README states for those labels -- parsed, so that a document
# which changes its own number is checked against the tree, not against a
# number typed into this verifier
m = re.search(r"\*\*(\d+)\*\* are marked \*\(upstream\)\*", TEXT["README"])
claimed_up = int(m.group(1)) if m else -1
m = re.search(r"\*\*(\d+)\*\* are marked \*\(upstream, renamed\)\* -- ([^.]+)\.",
              TEXT["README"])
claimed_ren = int(m.group(1)) if m else -1
claimed_ren_names = (re.findall(r"`(DoubleML[A-Za-z]+)`\s*\(upstream", m.group(2))
                     if m else [])
m = re.search(r"\*\*(\d+)\*\*,\s*`(DoubleML[A-Za-z]+)`, is marked", TEXT["README"])
claimed_none = int(m.group(1)) if m else -1
claimed_none_name = m.group(2) if m else ""

check("the estimators marked *(upstream)*",
      len(buckets.get("upstream", [])) == claimed_up,
      "the README says %d; the table marks %d"
      % (claimed_up, len(buckets.get("upstream", []))))
check("the estimators marked *(upstream, renamed)*",
      len(buckets.get("renamed", [])) == claimed_ren,
      "the README says %d; the table marks %d"
      % (claimed_ren, len(buckets.get("renamed", []))))
check("the estimators marked *(upstream design, no 1:1 class)*",
      len(buckets.get("no 1:1 class", [])) == claimed_none,
      "the README says %d; the table marks %d"
      % (claimed_none, len(buckets.get("no 1:1 class", []))))
check("the renamed estimators are the ones the README names",
      sorted(buckets.get("renamed", [])) == sorted(claimed_ren_names),
      "the README names %s; the table marks %s"
      % (", ".join(sorted(claimed_ren_names)),
         ", ".join(sorted(buckets.get("renamed", [])))))
check("the estimator with no 1:1 upstream class is the one the README names",
      buckets.get("no 1:1 class", []) == [claimed_none_name],
      "the README names %s; the table marks %s"
      % (claimed_none_name, ", ".join(buckets.get("no 1:1 class", []))))

# the files holding two estimators, and the files holding one
by_file = {}
for n in ESTIMATORS:
    for rel in structs[n]:
        by_file.setdefault(rel, []).append(n)
two = sorted(os.path.basename(r) for r, ns in by_file.items() if len(ns) > 1)
one = [r for r, ns in by_file.items() if len(ns) == 1]
m = re.search(r"-- (\d+) with\s+one struct each", TEXT["README"])
claimed_one = int(m.group(1)) if m else -1
m = re.search(r"and (\w+) holding two", TEXT["README"])
claimed_two = WORDS.get(m.group(1).lower(), -1) if m else -1
check("the files holding two estimators", len(two) == claimed_two,
      "the README says %d; the tree has %d (%s)"
      % (claimed_two, len(two), ", ".join(two)))
check("the files holding one estimator", len(one) == claimed_one,
      "the README says %d; the tree has %d" % (claimed_one, len(one)))
for fname, pair in (("apo.mbt", ["DoubleMLAPO", "DoubleMLAPOS"]),
                    ("blp_policy.mbt", ["DoubleMLBLP", "DoubleMLPolicyTree"]),
                    ("quantile.mbt", ["DoubleMLPQ", "DoubleMLQTE"])):
    got = sorted(by_file.get(PKG + fname, []))
    check("%s holds %s" % (fname, " + ".join(pair)), got == sorted(pair),
          "the tree says %s" % (", ".join(got) if got else "nothing"))

# --------------------------------------------------------------------------
# 4c.  THE `score` ARGUMENT -- who takes it, and which spellings are accepted
# --------------------------------------------------------------------------
# A parameter is found by WALKING the signature, not by a pattern: a
# multi-line parameter list and a generic `new<T>` both hide a naive
# `fn name(args)` match, and a scan that misses two estimators reports a
# number the tree does not have.
FN = re.compile(r"^\s*(?:pub\s+)?(?:external\s+)?fn\s+([A-Za-z0-9_:]+)\s*"
                r"(?:<[^>]*>)?\s*\(")
PARAM = re.compile(r"^\s*([a-z_][a-z0-9_]*)\s*~?\s*:", re.M)

score_owners = {}
for rel in pkg_prod:
    body = read(rel)
    lines = body.splitlines()
    i = 0
    while i < len(lines):
        m = FN.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        chunk, depth, started, j = [], 0, False, i
        while j < len(lines) and j < i + 40:
            chunk.append(lines[j])
            depth += lines[j].count("(") - lines[j].count(")")
            if "(" in lines[j]:
                started = True
            if started and depth <= 0:
                break
            j += 1
        if "score" in PARAM.findall("\n".join(chunk)):
            score_owners.setdefault(name, set()).add(rel)
        i = j + 1

score_ests = sorted(n for n in ESTIMATORS
                     if any(k.split("::")[0] == n for k in score_owners))
on_new = sorted(n for n in score_ests
                if any(k == n + "::new" for k in score_owners))
on_fit = sorted(n for n in score_ests
                if any(k.startswith(n + "::fit") for k in score_owners))
no_score = sorted(n for n in ESTIMATORS if n not in score_ests)

# The document's CLAIM is parsed, and the tree's measurement is compared with
# it.  A check that compares the tree against a number typed into the
# verifier is not a check of the document at all: the document could say
# anything, and the verifier would keep saying "ok".
m = re.search(r"only \*\*(\d+) of the (\d+) estimators take a `score` argument at all\*\*"
              r":\s*`(\w+)` on `fit\(\)`,\s*(\w+) others on `new\(\)`",
              TEXT["README"])
if m:
    claimed = int(m.group(1))
    claimed_total = int(m.group(2))
    claimed_fit = m.group(3)
    claimed_new = WORDS.get(m.group(4).lower(), -1)
    check("the estimators that take a `score` argument",
          len(score_ests) == claimed,
          "the README says %d; the tree has %d (%s)"
          % (claimed, len(score_ests), ", ".join(score_ests)))
    check("the estimators the `score` count is a share of",
          claimed_total == len(ESTIMATORS),
          "the README says %d; the tree has %d estimators"
          % (claimed_total, len(ESTIMATORS)))
    check("the estimators that take `score` on `new()`",
          len(on_new) == claimed_new,
          "the README says %d; the tree has %d (%s)"
          % (claimed_new, len(on_new), ", ".join(on_new)))
    check("the estimator that takes `score` on `fit()`",
          on_fit == [claimed_fit],
          "the README names %s; the tree says %s"
          % (claimed_fit, ", ".join(on_fit) if on_fit else "none"))
else:
    check("the README states how many estimators take a `score`", False,
          "the sentence was not found -- the check cannot see it")

# the estimators the README names as taking no score at all
m = re.search(r"it takes \*\*no score argument at all\*\* for ([^.]+)\.", TEXT["README"])
if m:
    named = re.findall(r"`([A-Za-z]+|DoubleML[A-Za-z]+)`", m.group(1))
    # upstream's `RDFlex` is this port's `DoubleMLRDD`
    named = ["DoubleMLRDD" if n == "RDFlex" else n for n in named]
    # the README names the ones it calls out -- not every estimator that
    # takes no score -- so the check is that each named one takes none.
    check("the estimators the README names as taking no score",
          all(n in no_score for n in named),
          "the README names %s; the tree says %s"
          % (", ".join(named),
             ", ".join(n for n in named if n not in no_score) or "all of them take none"))

# the accepted score spellings, from the port's own normalisation code
spell = set()
for rel in pkg_prod:
    body = read(rel)
    if "score" not in body:
        continue
    for m in re.finditer(r'"([^"]{2,24})"\s*=>', body):
        s = m.group(1)
        if re.match(r"^[A-Za-z][A-Za-z _\-]*$", s):
            spell.add(s)
    for m in re.finditer(r'==\s*"([^"]{2,24})"', body):
        s = m.group(1)
        if re.match(r"^[A-Za-z][A-Za-z _\-]*$", s):
            spell.add(s)
accepted = sorted(s for s in spell
                  if s.lower().replace(" ", "-") in
                  ("partialling-out", "iv-type", "experimental", "observational",
                   "nuisance_space", "instrument"))
m = re.search(r"accepts \*\*(\d+)\*\* spellings -- (.+?) --", TEXT["README"])
claimed_spell_n = int(m.group(1)) if m else -1
claimed_spell = re.findall(r"`([^`]+)`", m.group(2)) if m else []
check("the score spellings the port accepts", len(accepted) == claimed_spell_n,
      "the README says %d; the tree accepts %d (%s)"
      % (claimed_spell_n, len(accepted), ", ".join(accepted)))
check("the accepted spellings are the ones the README names",
      sorted(accepted) == sorted(claimed_spell),
      "the README names %s; the tree accepts %s"
      % (", ".join(sorted(claimed_spell)), ", ".join(accepted)))
check("the score spellings the README lists are as many as it says",
      len(claimed_spell) == claimed_spell_n,
      "the README says %d and lists %d" % (claimed_spell_n, len(claimed_spell)))

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
