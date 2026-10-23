"""Verify the README's API PROMISES against the source.

Round 36 checked the document's NEGATIVE claims ("not covered, so not
claimed").  This checks its POSITIVE ones -- the sentences that promise an
API shape -- and three of them did not survive the measurement:

  (a) "every estimator's `new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` /
      `ml_r` typed optionals".  Measured by the parameter's TYPE
      (`LearnerDispatch`), not by its name, the estimators take EIGHT
      distinct argument sets: two take no learner at all, one takes a
      single `learner`, and `ml_pi` is a fifth argument name the sentence
      never mentioned.

  (b) "Default is `LearnerDispatch::linear_regression()` (OLS)".  True for
      `ml_g` everywhere, FALSE for `ml_m` on the seven structs migrated to
      a classifier.

  (c) "each DID variant takes its own data type".  `DoubleMLDIDCS`,
      `DoubleMLDIDCSBinary` and `DoubleMLDIDMulti` all take
      `DoubleMLDIDCSData`.

Nothing here is hard-coded: the argument sets, the defaults, the migrated
list, the OLS list and the DID data types are all DERIVED from the source
in this file, and the README is required to state what the derivation
says.  A future round that changes an estimator's signature will fail
this check until the README follows it.

The source is read with comments and docstrings stripped, and the
argument list is scanned with a BALANCED parenthesis -- a naive
`\\(([^)]*)\\)` stops at the first `)`, which hides any parameter written
after a nested call (that mistake made three estimators look
learner-less).
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")

BLOCK = re.compile(r"/\*.*?\*/", re.S)
LINE = re.compile(r"//[^\n]*")
ARG = re.compile(r"^(ml_[a-z]+|learner(?:_[a-z]+)?)$")

WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
         "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
         "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
         "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
         "twenty": 20}


def strip_comments(text):
    return LINE.sub(" ", BLOCK.sub(" ", text))


def balanced(text, start):
    """The text inside the parentheses that begin at `start`."""
    depth = 0
    for i in range(start, len(text)):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return ""


def split_args(text):
    """Split an argument list on top-level commas."""
    out, depth, cur = [], 0, []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        out.append("".join(cur))
    return [a.strip() for a in out]


# ==============================================================================
# 1.  DERIVE FROM THE SOURCE
# ==============================================================================

learner_args = {}     # estimator -> sorted tuple of learner argument names
ctor_default = {}     # (estimator, argument) -> constructor default text
fit_default = {}      # (estimator, argument) -> fit() default text
data_type = {}        # estimator -> the *Data type its new() takes

for name in sorted(os.listdir(LIB)):
    if not name.endswith(".mbt") or "_test" in name or "wbtest" in name:
        continue
    body = strip_comments(io.open(os.path.join(LIB, name), encoding="utf-8",
                                   errors="replace").read())
    for m in re.finditer(r"pub\s+fn\s+(DoubleML\w+?)::(new|fit)\b", body):
        est, kind = m.group(1), m.group(2)
        if est.endswith("Data"):
            continue
        op = body.find("(", m.end())
        if op < 0:
            continue
        # an estimator with NO learner argument still belongs in the census:
        # "takes no learner" is one of the argument sets.
        learner_args.setdefault(est, set())
        for a in split_args(balanced(body, op)):
            if ":" not in a:
                continue
            nm, _, rest = a.partition(":")
            nm = nm.strip().rstrip("~")
            typ, _, dflt = rest.partition("=")
            typ = typ.strip()
            dflt = " ".join(dflt.split())
            if typ.replace("?", "").replace(" ", "") == "LearnerDispatch":
                learner_args.setdefault(est, set()).add(nm)
                slot = ctor_default if kind == "new" else fit_default
                slot.setdefault((est, nm), dflt)
            elif kind == "new" and typ.endswith("Data"):
                data_type.setdefault(est, typ)
groups = {}
for est, args in learner_args.items():
    groups.setdefault(tuple(sorted(args)), []).append(est)
for k in groups:
    groups[k].sort()

classifier_default = sorted(
    est for (est, nm), dflt in ctor_default.items()
    if nm == "ml_m" and "logistic_regression" in dflt)
ols_default = sorted(
    est for (est, nm), dflt in ctor_default.items()
    if nm == "ml_m" and dflt == "LearnerDispatch::linear_regression()")

did_family = sorted(e for e in data_type if "DID" in e)
did_types = {}
for e in did_family:
    did_types.setdefault(data_type[e], []).append(e)
for k in did_types:
    did_types[k].sort()

# ==============================================================================
# 2.  READ THE README
# ==============================================================================

readme = io.open(README, encoding="utf-8").read()
flat = " ".join(readme.split())

fails = []
notes = []
NCHECK = [0]


def check(label, cond, detail=""):
    NCHECK[0] += 1
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def note(text):
    notes.append(text)
    print("  %-62s %s" % (text, ""))


print("== derived from the source ==")
print("   estimators with a public new()/fit(): %d" % len(learner_args))
print("   distinct learner-argument sets: %d" % len(groups))
for k in sorted(groups, key=lambda t: (-len(t), t)):
    print("     %-28s %2d  %s" % (" / ".join(k) or "(none)", len(groups[k]),
                                 ", ".join(groups[k])))
print("   ml_m defaulted to a classifier: %d  %s"
      % (len(classifier_default), ", ".join(classifier_default)))
print("   ml_m defaulted to OLS:          %d  %s"
      % (len(ols_default), ", ".join(ols_default)))
print("   DID data types: %s"
      % ", ".join("%s -> %s" % (t, ", ".join(v)) for t, v in sorted(did_types.items())))
print("")

print("== (a) the universal learner promise ==")

# the table the promise was replaced with
rows = []
for line in readme.splitlines():
    s = line.strip()
    if not s.startswith("|") or not s.endswith("|"):
        continue
    cells = [c.strip() for c in s.strip("|").split("|")]
    if len(cells) != 2:
        continue
    names = re.findall(r"`([A-Za-z_][A-Za-z0-9_]*)`", cells[0])
    if not names and cells[0].lower() != "none":
        continue
    if not all(ARG.match(n) for n in names):
        continue
    ests = re.findall(r"`(DoubleML\w+)`", cells[1])
    if not ests:
        continue
    rows.append((tuple(sorted(names)), ests, s))

check("the README has a learner-arguments table", len(rows) > 0,
      "no two-column row of learner arguments was found")
check("the table has one row per derived argument set",
      len(rows) == len(groups),
      "table=%d derived=%d" % (len(rows), len(groups)))

table = {}
for key, ests, s in rows:
    table.setdefault(key, []).extend(ests)

derived = {k: list(v) for k, v in groups.items()}
check("the table's rows are exactly the derived groups",
      sorted(table.keys()) == sorted(derived.keys()),
      "table=%s derived=%s" % (sorted(table.keys()), sorted(derived.keys())))
for key in sorted(set(table) & set(derived)):
    check("the row %-28s names the derived estimators"
          % (" / ".join(key) or "(none)"),
          sorted(table[key]) == sorted(derived[key]),
          "readme=%s derived=%s" % (sorted(table[key]), sorted(derived[key])))

covered = sorted(e for v in table.values() for e in v)
check("the table names every estimator exactly once",
      covered == sorted(learner_args),
      "table=%d names, %d estimators" % (len(covered), len(learner_args)))

# the false promise is gone
check("the README no longer promises every estimator takes the four",
      "accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed optionals" not in flat
      and "every estimator's `new()` / `fit()` accept" not in flat,
      "the universal promise is still there")
check("the README says the set differs by estimator",
      "the set differs by estimator" in flat)

# the stated counts must be the derived ones
m = re.search(r"\*\*(\d+)\*\* argument sets over the \*\*(\d+)\*\* estimators", flat)
check("the README states the number of argument sets", m is not None)
if m:
    check("the stated argument-set count is the derived one",
          int(m.group(1)) == len(groups),
          "readme=%s derived=%d" % (m.group(1), len(groups)))
    check("the stated estimator count is the derived one",
          int(m.group(2)) == len(learner_args),
          "readme=%s derived=%d" % (m.group(2), len(learner_args)))

# the default sentence
m = re.search(r"except `ml_m` on the (\w+) structs migrated to a classifier", flat)
check("the README qualifies the OLS default", m is not None)
if m:
    word = WORDS.get(m.group(1).lower())
    check("the qualified count is the derived one",
          word == len(classifier_default),
          "readme=%s derived=%d" % (m.group(1), len(classifier_default)))

# the migrated paragraph must name exactly the classifier-defaulted estimators
i = flat.find("The port used to default `ml_m`")
check("the README has the migration paragraph", i >= 0)
if i >= 0:
    para = flat[i:flat.find("LearnerDispatch::is_classifier()", i)]
    named = sorted(set(re.findall(r"`(DoubleML\w+)`", para)))
    check("the migration paragraph names the classifier-defaulted estimators",
          named == classifier_default,
          "readme=%s derived=%s" % (named, classifier_default))

# the OLS paragraph must name exactly the OLS-defaulted estimators
i = flat.find("still default `ml_m` to `linear_regression()`")
check("the README has the OLS-default paragraph", i >= 0)
if i >= 0:
    para = flat[i:flat.find("Until each is migrated", i)]
    named = sorted(set(re.findall(r"`(DoubleML\w+)`", para)))
    check("the OLS paragraph names the OLS-defaulted estimators",
          named == ols_default,
          "readme=%s derived=%s" % (named, ols_default))
    m = re.search(r"\*\*(\w+)\*\* structs still default", flat)
    if m:
        word = WORDS.get(m.group(1).lower())
        check("the stated count of OLS-defaulted structs is the derived one",
              word == len(ols_default),
              "readme=%s derived=%d" % (m.group(1), len(ols_default)))

# the third argument names the table introduced
check("the README names `ml_pi`", "`ml_pi`" in flat)
check("the README names `ml_r`", "`ml_r`" in flat)
ml_pi = sorted(e for e, a in learner_args.items() if "ml_pi" in a)
ml_r = sorted(e for e, a in learner_args.items() if "ml_r" in a)
check("`ml_pi` belongs to exactly the derived estimator",
      ml_pi == ["DoubleMLSSM"], str(ml_pi))
check("`ml_r` belongs to exactly the derived estimator",
      ml_r == ["DoubleMLIIVM"], str(ml_r))
check("`ml_pi` reuses the `ml_m` choice at fit()",
      fit_default.get(("DoubleMLSSM", "ml_pi")) == "self.ml_m",
      str(fit_default.get(("DoubleMLSSM", "ml_pi"))))
check("`ml_r` reuses the constructor's choice at fit()",
      fit_default.get(("DoubleMLIIVM", "ml_r")) == "self.ml_r",
      str(fit_default.get(("DoubleMLIIVM", "ml_r"))))

print("")
print("== (b) the DID data types ==")

check("the README no longer says each DID variant takes its own data type",
      "each DID variant takes its own data type" not in flat,
      "the false claim is still there")

# the DID sentence must name every type and every estimator it belongs to
for t in sorted(did_types):
    check("the README names the DID data type %s" % t, "`%s`" % t in flat)

for t, ests in sorted(did_types.items()):
    for e in ests:
        check("the README puts %s on %s" % (e, t),
              re.search(r"`%s`[^.]{0,200}?`%s`" % (re.escape(e), re.escape(t)), flat)
              is not None
              or re.search(r"`%s`[^.]{0,200}?`%s`" % (re.escape(t), re.escape(e)), flat)
              is not None,
              "no sentence links %s to %s" % (e, t))

shared = sorted(t for t, v in did_types.items() if len(v) > 1)
check("at least one DID data type is shared", len(shared) >= 1, str(did_types))
for t in shared:
    check("the README says %s is shared by %d estimators"
          % (t, len(did_types[t])),
          all(e in flat for e in did_types[t]),
          "not all of %s are named" % (did_types[t],))

print("")
print("checks run: %d" % NCHECK[0])
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
