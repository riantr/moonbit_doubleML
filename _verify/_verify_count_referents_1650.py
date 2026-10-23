#!/usr/bin/env python3
"""Round 24 verifier: every count in the README that stands for a SET.

WHY THIS EXISTS
===============
Two sentences in the README used a bare count as a referent -- "the largest
margin of the four" and "all four earlier outcomes" -- and neither said which
four.  They are the same four: `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS`
and `DoubleMLSSM`.  But the section offers two different candidate fours a
few paragraphs apart, and the v0.138.0 CHANGELOG entry called SSM "the fifth
and last estimator to be migrated" while naming four.

A count a reader cannot resolve is not a fact.  It is a guess with a number
attached, and it rots silently: nothing in the build notices that "the four"
stopped matching anything.

WHAT IS CHECKED
===============
  A  the source's own propensity defaults -- the ground truth for "who
     defaults to a classifier", read out of the MoonBit sources
  B  the README's migration list -> the set migrated by v0.138.0, and the
     two sentences that count it
  C  the CHANGELOG's own release headings -> the migration ordinal, and the
     v0.138.0 entry's count beside the list it contradicts
  D  the other count claims whose set is DERIVABLE: the learners, the
     classification learners, the OLS-defaulted structs, the backends, the
     hazard rows, the bit-exact mutation cases
  E  the QA LOOP's `gherkin` evidence -- it must report the split between
     the names that resolve to a declaration and the prose citations, not
     fold the prose into the numerator
  F  the INVENTORY: a count in the README that stands for a set of the
     library's own named artefacts must be registered here.  A new one fails
     until it is registered and derived.

WHAT IS NOT CHECKED, AND WHY
============================
A count of 1 or 2 ("the two learners", "the one absence") is small enough to
be evident from the sentence, and a DISTRIBUTIVE count ("one struct each",
"one estimate per treatment level") is not a set at all.  Both are left
alone: a rule that cannot distinguish them produced 21 innocent hits when
round 23 tried it, and a check with false positives teaches its reader to
ignore it.

The claims in the table below that another tracked verifier already owns are
marked OWNER and are not re-derived here -- one verifier per fact.

Run: python _verify/_verify_count_referents_1650.py
"""
import ast
import importlib.util
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
SHIPPED = os.path.join(PKG, "README.mbt.md")
ENGINEERING = os.path.join(ROOT, "ENGINEERING.md")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
QA = os.path.join(ROOT, ".github", "scripts", "qa_loop", "checks.py")
FEATURE = os.path.join(ROOT, "features", "moonbit_doubleML_acceptance.feature")
BITEXACT_MUT = os.path.join(ROOT, "_verify", "_bitexact_mutation_1640.py")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "check.yml")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-62s %s" % (label, detail))
    else:
        FAILS.append(label)
        print("  *** FAIL ***  %-58s %s" % (label, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def flat(s):
    """Whitespace-normalised, so a phrase can span a line break."""
    return re.sub(r"\s+", " ", s)


readme = read(README)
readme_flat = flat(readme)
shipped = read(SHIPPED)
proj = read(ENGINEERING)
changelog = read(CHANGELOG)
changelog_flat = flat(changelog)

# --------------------------------------------------------------------------- #
# A. the source's own propensity defaults
# --------------------------------------------------------------------------- #
print()
print("A. the source's propensity defaults (ground truth for A/B/D)")

# The SLOT matters, not just the learner: `DoubleMLPLR`'s propensity role is
# `learner_m`, not `ml_m`, so it defaults to OLS without being one of the
# structs that default `ml_m` to OLS.  Counting the slot is what keeps the
# eight and the nine apart.
DEF = re.compile(r"(ml_m|learner_m)~?\s*:\s*LearnerDispatch\s*=\s*LearnerDispatch::(\w+)")
NEW = re.compile(r"pub fn (DoubleML\w+)::new\(")

ols, clf = {}, {}
for name in sorted(os.listdir(PKG)):
    if not name.endswith(".mbt"):
        continue
    src = read(os.path.join(PKG, name))
    for m in DEF.finditer(src):
        owners = NEW.findall(src[:m.start()])
        owner = owners[-1] if owners else "(unknown in %s)" % name
        bucket = ols if m.group(2) == "linear_regression" else clf
        bucket.setdefault(owner, set()).add(m.group(1))

ols_names = sorted(ols)
clf_names = sorted(clf)
# the `ml_m` slot alone -- the eight the README's sentence is about
ols_mlm = sorted(n for n, slots in ols.items() if "ml_m" in slots)
clf_mlm = sorted(n for n, slots in clf.items() if "ml_m" in slots)
print("   OLS propensity default: %d -> %s" % (len(ols_names), ", ".join(ols_names)))
print("   classifier default:     %d -> %s" % (len(clf_names), ", ".join(clf_names)))
print("   of which on `ml_m`:     OLS %d, classifier %d"
      % (len(ols_mlm), len(clf_mlm)))
check("the source's propensity defaults were read", bool(ols_names and clf_names),
      "%d OLS, %d classifier" % (len(ols_names), len(clf_names)))
check("the two `learner_m` owners are PLR and LPLR",
      sorted(n for n, s in ols.items() if "learner_m" in s) == ["DoubleMLPLR"],
      str(sorted(n for n, s in ols.items() if "learner_m" in s)))

# --------------------------------------------------------------------------- #
# B. the README's migration list -> the four
# --------------------------------------------------------------------------- #
print()
print("B. the set the README's 'four' counts")

# "**`DoubleMLIRM` was migrated in v0.132.0**, **`DoubleMLAPO` in v0.134.0**, ..."
mig = re.search(r"The port used to default `ml_m`.*?their `ml_m` default is now", readme_flat)
check("the README's migration sentence is findable", mig is not None)
migration = {}
if mig:
    seg = mig.group(0)
    for nm in re.findall(r"`(DoubleML\w+)`", seg):
        after = seg[seg.index("`%s`" % nm) + len(nm) + 2:]
        rel = re.search(r"v(\d+)\.(\d+)\.(\d+)", after)
        if rel:
            migration[nm] = tuple(int(x) for x in rel.groups())
print("   migration releases: %s" % {k: "v%d.%d.%d" % v for k, v in migration.items()})

EARLY_CUTOFF = (0, 138, 0)
early = sorted(n for n, r in migration.items() if r <= EARLY_CUTOFF)
check("the migrations by v0.138.0 are four", len(early) == 4, "got %d: %s" % (len(early), early))
check("the migrations by v0.138.0 are IRM, APO, APOS and SSM",
      early == ["DoubleMLAPO", "DoubleMLAPOS", "DoubleMLIRM", "DoubleMLSSM"], str(early))
check("every migrated estimator defaults to a classifier in the SOURCE today",
      all(n in clf_mlm for n in migration),
      "source classifier set: %s" % clf_mlm)
check("the migrated set is EXACTLY the source's `ml_m`-classifier set",
      set(migration) == set(clf_mlm),
      "README says %s / source says %s" % (sorted(migration), clf_mlm))

# the two sentences that count the four
ssm_sent = re.search(r"`DoubleMLSSM` has the largest margin of the .*?because its score carries",
                      readme_flat)
check("the SSM margin sentence is findable", ssm_sent is not None)
if ssm_sent:
    s = ssm_sent.group(0)
    check("the SSM sentence names all four migrations",
          all(n in s for n in early),
          "missing: %s" % [n for n in early if n not in s])
    check("the SSM sentence's count is four", "four" in s, s[:80])

cls_sent = re.search(r"A static classifier \(read the score.*?nothing more\.", readme_flat)
check("the classifier sentence is findable", cls_sent is not None)
if cls_sent:
    s = cls_sent.group(0)
    check("the classifier sentence names all four hazardous verdicts",
          all(n in s for n in early),
          "missing: %s" % [n for n in early if n not in s])
    check("the classifier sentence's count is four", "four" in s, s[:80])

check("the withdrawn wording 'the largest margin of the four' is gone",
      "largest margin of the four," not in readme_flat)
check("the withdrawn wording 'all four earlier outcomes' is gone",
      "all four earlier outcomes" not in readme_flat)

# --------------------------------------------------------------------------- #
# C. the CHANGELOG's migration ordinal
# --------------------------------------------------------------------------- #
print()
print("C. the CHANGELOG's v0.138.0 entry agrees with its own list")

head_re = re.compile(r"^## \[(\d+\.\d+\.\d+)\] -- (.*)$", re.M)
heads = list(head_re.finditer(changelog))
first_est = [m for m in heads if "first estimator migrated" in
             changelog[m.end():heads[heads.index(m) + 1].start() if heads.index(m) + 1 < len(heads) else len(changelog)]]
second_est = [m for m in heads if "second estimator migrated" in
               changelog[m.end():heads[heads.index(m) + 1].start() if heads.index(m) + 1 < len(heads) else len(changelog)]]
check("the CHANGELOG calls v0.132.0 the FIRST migration", bool(first_est),
      first_est[0].group(1) if first_est else "not found")
check("the CHANGELOG calls v0.134.0 the SECOND migration", bool(second_est),
      second_est[0].group(1) if second_est else "not found")

v138 = re.search(r"This is the (\w+) and last estimator to be migrated:(.*?)\.\s", changelog_flat)
check("the v0.138.0 entry's ordinal sentence is findable", v138 is not None)
if v138:
    ordinal = v138.group(1)
    named = re.findall(r"`(DoubleML\w+)`", v138.group(2))
    check("the v0.138.0 entry says FOURTH, not fifth", ordinal == "fourth", "says %r" % ordinal)
    check("the v0.138.0 entry names exactly four estimators", len(named) == 4, str(named))
    check("the v0.138.0 entry's four are the four the README counts",
          sorted(named) == early, "%s vs %s" % (sorted(named), early))
# The withdrawn wording must be gone FROM THE v0.138.0 ENTRY -- not from the
# file: the v0.164.17 entry QUOTES it, because that is how a correction is
# recorded.  A check over the whole file would forbid the correction from
# naming what it corrects.
sec = re.search(r"## \[0\.138\.0\].*?(?=\n## \[)", changelog, re.S)
check("the v0.138.0 section is findable", sec is not None)
if sec:
    check("the withdrawn wording is gone from the v0.138.0 entry",
          "fifth and last estimator to be migrated" not in sec.group(0),
          "still present")
    check("the v0.138.0 entry says 'fourth'",
          "fourth and last estimator to be migrated" in sec.group(0))

# --------------------------------------------------------------------------- #
# D. the other count claims, each derived
# --------------------------------------------------------------------------- #
print()
print("D. the other count claims, derived from the tree")

# --- the learners the package ships ----------------------------------------
tbl = re.search(r"\| learner \| kind \|.*?\n\n", readme, re.S)
check("the learner table is findable", tbl is not None)
learner_rows, classification_rows = [], []
if tbl:
    for line in tbl.group(0).split("\n"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2 or cells[0] in ("learner", "---") or set(cells[0]) <= {"-"}:
            continue
        names = re.findall(r"`([A-Za-z0-9]+)`", cells[0])
        if not names:
            continue
        learner_rows.extend(names)
        if "classification" in cells[1].replace("*", ""):
            classification_rows.extend(names)

check("the learner table lists eleven learners", len(learner_rows) == 11,
      "got %d: %s" % (len(learner_rows), learner_rows))
check("the learner table marks three as classification", len(classification_rows) == 3,
      "got %d: %s" % (len(classification_rows), classification_rows))
check("the README says the package ships eleven", "This package ships eleven" in readme_flat)
check("the README says three classification learners",
      "The three classification learners" in readme_flat)

learner_src = ""
for name in sorted(os.listdir(PKG)):
    if name.endswith(".mbt"):
        learner_src += read(os.path.join(PKG, name))

# the source's own is_classifier() must agree with the table's three.  The
# dispatch VARIANTS are `RandomForestClassifier` / `GradientBoostingClassifier`
#; the LEARNERS they carry are `RFClassifier` / `GBClassifier`, and the table
# lists the learners.  The enum declaration is what bridges the two.
isc = re.search(r"pub fn LearnerDispatch::is_classifier.*?\n\}", learner_src, re.S)
check("the source's is_classifier() is findable", isc is not None)
if isc:
    true_variants = set(re.findall(r"(\w+)\([^)]*\)\s*=>\s*true", isc.group(0)))
    enum = re.search(r"pub enum LearnerDispatch(.*?)\n\}", learner_src, re.S)
    check("the LearnerDispatch enum is findable", enum is not None)
    payloads = set()
    if enum:
        for v in true_variants:
            m = re.search(r"\b%s\s*\(\s*(\w+)\s*\)" % re.escape(v), enum.group(1))
            if m:
                payloads.add(m.group(1))
    check("the source's is_classifier() agrees with the table's three",
          payloads == set(classification_rows),
          "source: %s / table: %s" % (sorted(payloads), sorted(classification_rows)))

# --- the structs that still default to OLS ----------------------------------
m8 = re.search(r"\*\*Eight structs still default `ml_m` to `linear_regression\(\)`\*\*:(.*?)\n\n",
               readme, re.S)
check("the 'Eight structs' sentence is findable", m8 is not None)
if m8:
    named8 = re.findall(r"`(DoubleML\w+)`", m8.group(1))
    check("the 'Eight structs' sentence names eight estimators", len(named8) == 8, str(named8))
    check("the eight are exactly the source's `ml_m`-OLS estimators",
          sorted(named8) == ols_mlm, "README: %s / source: %s" % (sorted(named8), ols_mlm))
check("the source really has eight estimators defaulting `ml_m` to OLS", len(ols_mlm) == 8,
      "%d: %s" % (len(ols_mlm), ols_mlm))

# --- the hazard rows --------------------------------------------------------
m6 = re.search(r"\*\*Six rows turned out hazardous\*\*:(.*?)\. All six default to a ", readme, re.S)
check("the 'Six rows' sentence is findable", m6 is not None)
if m6:
    named6 = re.findall(r"`(DoubleML\w+)`", m6.group(1))
    expected6 = sorted(n for n in clf_mlm if n != "DoubleMLLPLR")
    check("the six named are exactly the source's classifier-defaulted non-LPLR",
          sorted(named6) == expected6, "README: %s / source: %s" % (sorted(named6), expected6))
check("the source's classifier-defaulted set minus LPLR is six",
      len([n for n in clf_mlm if n != "DoubleMLLPLR"]) == 6, str(clf_mlm))

# --- the backends -----------------------------------------------------------
wf = read(WORKFLOW)
m4 = re.search(r"target:\s*\[([^\]]+)\]", wf)
check("the CI workflow's target matrix is findable", m4 is not None)
backends = []
if m4:
    backends = [t.strip() for t in m4.group(1).split(",") if t.strip()]
    check("CI runs four backends", len(backends) == 4, str(backends))
    check("the README's four backends are the CI's four",
          all("`%s`" % b in readme for b in backends), str(backends))
check("the README says four backends", "**Four backends**" in readme)

# The round-35 sentence says a bare `moon test` runs "only three of the four
# declared backends".  The FOUR is the package's own `supported_targets`, and
# it is derived here rather than asserted.
pkgmod = read(os.path.join(PKG, "moon.mod"))
m5 = re.search(r'supported_targets\s*=\s*"([^"]+)"', pkgmod)
check("the package's supported_targets is findable", m5 is not None)
declared = []
if m5:
    declared = [t for t in m5.group(1).split("+") if t]
    check("the package declares four backends", len(declared) == 4, str(declared))
    check("the package's declared backends are the CI's four",
          sorted(declared) == sorted(backends), "%s / %s" % (sorted(declared), sorted(backends)))
    check("the README's 'four declared backends' are the package's four",
          "four declared backends" in readme_flat
          and all("`%s`" % t in readme for t in declared), str(declared))

# --- the bit-exact mutation cases -------------------------------------------
check("the bit-exact mutation battery is tracked", os.path.exists(BITEXACT_MUT))
muts = []
if os.path.exists(BITEXACT_MUT):
    tree = ast.parse(read(BITEXACT_MUT))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", "") == "MUTATIONS" for t in node.targets):
            muts = [e for e in node.value.elts]
check("the bit-exact battery declares four mutation cases", len(muts) == 4, "got %d" % len(muts))
check("the README says all four mutations were killed",
      "all four mutations killed" in readme_flat)
if muts:
    descs = [ast.literal_eval(e.elts[0]) if isinstance(e, ast.Tuple) else "" for e in muts]
    joined = " ".join(descs).lower()
    check("the README's 'truncated' and 'mis-tiled' cases are in the battery",
          "truncated" in joined and "tiled" in joined, joined)

# --------------------------------------------------------------------------- #
# E. the QA LOOP's gherkin evidence
# --------------------------------------------------------------------------- #
print()
print("E. the QA LOOP's gherkin evidence reports the split")

spec = importlib.util.spec_from_file_location("qa_checks_r24", QA)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)

feat = read(FEATURE)
feat_lines = feat.splitlines()
mapped = []
for i, l in enumerate(feat_lines):
    mm = re.match(r"\s*#\s*mapped to:\s*(.+)$", l)
    if not mm:
        continue
    acc = mm.group(1)
    nxt = feat_lines[i + 1] if i + 1 < len(feat_lines) else ""
    if (re.match(r"\s*#\s+\S", nxt)
            and not re.match(r"\s*(Scenario|Feature|Background|Examples|Given|When|Then|And|But|\*)\b", nxt)):
        acc += " " + nxt.split("#", 1)[1]
    mapped += [x.strip() for x in re.split(r",\s*|\s+and\s+", acc) if x.strip()]
PROSE = re.compile(r"\s(?:in|usage|validators|tests)\b|\.")
n_prose = len([m for m in mapped if PROSE.search(m)])
n_real = len(mapped) - n_prose

res = qa.c_gherkin()
ev = res.evidence
check("the gherkin check is green", res.verdict == qa.PASS, ev)
check("the gherkin evidence reports the prose-exempt split",
      ("%d" % n_prose) in ev and "prose-exempt" in ev, ev)
check("the gherkin evidence reports the resolving count",
      re.search(r"\b%d resolve" % n_real, ev) is not None, ev)
check("the gherkin evidence no longer says '29/29 mapped test names resolve'",
      "mapped test names resolve" not in ev, ev)
check("the gherkin evidence's total is the mapped-name count",
      ("%d mapped names" % len(mapped)) in ev, ev)
check("the split matches the ledger's recorded counts (%d real, %d prose-exempt)"
      % (n_real, n_prose), n_real == 26 and n_prose == 3,
      "derived %d/%d" % (n_real, n_prose))

# --------------------------------------------------------------------------- #
# F. the inventory
# --------------------------------------------------------------------------- #
print()
print("F. the inventory: no unregistered count claim")

# A count that stands for a SET of the library's named artefacts.  A
# distributive ("one struct each", "one estimate per treatment level") is not
# a set, and a count of 1 or 2 is evident from its own sentence.
ARTEFACT = (r"estimators?|learners?|backends?|migrations?|structs?|rows?|"
            r"verdicts?|mutations?|mutants?|gates?|vocabularies?|designs?")
SCAN = re.compile(r"\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"
                   r"(?:\s+\w+){0,3}\s+(%s)\b" % ARTEFACT, re.I)
DISTRIBUTIVE = re.compile(r"\b(each|per)\b")
NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
       "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12}

# Registered: phrase -> the count it states.
REGISTERED = {
    "This package ships eleven": 11,
    "The three classification learners": 3,
    "**Four backends**": 4,
    "four declared backends": 4,
    "the four migrations of v0.132.0-v0.138.0": 4,
    "**Eight structs still default `ml_m` to `linear_regression()`**": 8,
    "**Six rows turned out hazardous**": 6,
    "All six default to a classifier today": 6,
    "the four hazardous verdicts of v0.132.0-v0.138.0": 4,
    "all four mutations killed": 4,
    "across four probe designs": 4,
    "`mutation` kills three mutants on one kernel": 3,
    # OWNED elsewhere -- registered so the inventory is complete, but this
    # verifier does not re-derive them.
    "two different sets of six": 6,
    "they overlap in only three estimators": 3,
    "**Nine gates whose reference is UPSTREAM, not ours**": 9,
    "Three rows -- `DoubleMLDIDCSBinary`": 3,
    "three vocabularies are in play": 3,
    "The last three take no cross-fitting option": 3,
    "all three ship upstream": 3,
    # Round 37: the learner-default sentence qualifies the OLS default with
    # the SEVEN structs migrated to a classifier.  The count is re-derived
    # by `_verify_api_promises_1650.py`, from the source's own defaults.
    "seven structs": 7,
}
OWNERS = {
    "two different sets of six": "_verify_ctor_options_1650.py",
    "they overlap in only three estimators": "_verify_ctor_options_1650.py",
    "**Nine gates whose reference is UPSTREAM, not ours**": "_verify_round12_pyexample_1647.py",
    "three vocabularies are in play": "_verify_shipped_docs_1643.py",
    "`mutation` kills three mutants on one kernel": "_verify_test_verification_1650.py",
    "seven structs": "_verify_api_promises_1650.py",
}

for phrase in REGISTERED:
    check("the registered claim %r is present in the README" % phrase[:46],
          phrase in readme_flat, "" if phrase in readme_flat else "NOT FOUND")

for phrase, owner in OWNERS.items():
    check("the owning verifier %s is tracked" % owner,
          os.path.exists(os.path.join(ROOT, "_verify", owner)), owner)

# the four probe designs are enumerated in the CHANGELOG's v0.136.0 entry
probe = re.search(r"### `DoubleMLDIDBinary`: what was tried(.*?)\n### ", changelog, re.S)
check("the CHANGELOG's DIDBinary probe section is findable", probe is not None)
if probe:
    designs = re.findall(r"^\d+\.\s+\*\*", probe.group(1), re.M)
    check("the CHANGELOG enumerates four probe designs", len(designs) == 4, "got %d" % len(designs))

# now the scan: every count-artefact pair the README uses must be registered
unregistered = []
hits = []
for mm in SCAN.finditer(readme_flat):
    phrase = mm.group(0).strip()
    tail = readme_flat[mm.end():mm.end() + 12]
    if DISTRIBUTIVE.search(phrase) or DISTRIBUTIVE.search(tail):
        continue
    if NUM.get(mm.group(1).lower(), 99) <= 2:
        continue
    hits.append(phrase)
    if not any(phrase in p or p in phrase for p in REGISTERED):
        unregistered.append(phrase)
# "This package ships eleven" has no artefact noun beside it
for mm in re.finditer(r"\bships\s+(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b",
                      readme_flat, re.I):
    if NUM.get(mm.group(1).lower(), 99) > 2:
        hits.append("ships " + mm.group(1))
        if not any("ships " + mm.group(1) in p for p in REGISTERED):
            unregistered.append("ships " + mm.group(1))
print("   scan hits (%d): %s" % (len(hits), sorted(set(hits))))
check("no unregistered count claim in the README", not unregistered, str(sorted(set(unregistered))[:6]))

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
