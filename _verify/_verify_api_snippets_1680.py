"""Check the README's copy-pasteable API snippets against the real signatures.

The "Library Use" block is what a reader pastes into their own project:

    let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
    let fitted = @moonbit_doubleML.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
    let coef = fitted.coef()
    let se   = fitted.se()
    let (lo, hi) = fitted.confint()

and it then says "Same shape for every other estimator -- e.g.
`DoubleMLIRM::new(data, ml_g?, ml_m?, n_folds?, n_rep?, seed?)`,
`DoubleMLDID::new(data, ml_g?, ml_m?, ...)`.fit()`."

A wrong parameter name in that block is a compile error in the reader's
project, so each name the README uses is checked against the real
signature.

ROUNDS 32-34 EXTENDED THIS FILE'S REACH
========================================

Until round 35 the checks below only matched snippets written with the
`@moonbit_doubleML.` prefix.  That covered FOUR of the TEN constructors the
README states: the other six were written unqualified (`DoubleMLLPLR::new(data)`,
`DoubleMLPolicyTree::new(...)`, `LogisticRegression::new()`, `RFClassifier::new()`,
`GBClassifier::new()`) or inside fenced code, and no check could see them.

That is how `DoubleMLLPLR::new(data, alpha=1.5)` -- a parameter that does not
exist -- survived until a reader found it by hand: the verifier's wording said
"the README's API snippets" while its extraction reached 40 % of them.

Round 35 therefore adds:

  * a COVERAGE check: the number of constructor calls the README states is
    declared, and the number this file checked must equal it.  The gap can no
    longer reopen silently.
  * EVERY constructor call, qualified or not, in prose or in a fenced block.
  * for each one: the type exists; every NAMED argument is a real parameter
    and is optional in the source; every named argument's stated DEFAULT equals
    the source's default; every POSITIONAL argument's NAME equals the source's
    parameter name at that position.
  * every `LearnerDispatch::x(` the README names must exist.
  * the API reference's accessor promises: the names in the "instead of"
    column must exist on the estimator they name, "the other 16" must be 16,
    and each of the 16 must expose the four methods the sentence promises.

The estimator set is DERIVED from the source (a `DoubleML*` type that has a
`::fit` method), not copied from the README -- otherwise the check would
confirm whatever the README says about itself.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
readme = io.open(os.path.join(ROOT, "README.mbt.md"), encoding="utf-8").read()

fails = []
NCHECK = 0

# The declared sizes.  A change to any of them is a change to the SET.
#
# Round 43: the published README's "pass a classifier explicitly" snippet now
# shows `DoubleMLCVAR::new(data, ml_m=...)`, and the LPLR snippet now builds
# its data with `DoubleMLBinaryData::new(x, y, d)` -- so the README states
# TWO constructor calls it did not state before.  The size moved 10 -> 12.
EXPECTED_CONSTRUCTOR_CALLS = 12
EXPECTED_ACCESSOR_ROWS = 6
EXPECTED_OTHER = 16
EXPECTED_ESTIMATORS = 22

# The README's generic placeholder -- not a real type.
PLACEHOLDER = "DoubleMLXxx"


def check(label, cond, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


# ---------------------------------------------------------------------------
# the source: every `pub fn Owner::method(` with its parameter list
# ---------------------------------------------------------------------------

def balanced(text, i):
    """The text inside the parentheses starting at `text[i]`, and the index
    after the closing parenthesis.  A regex cannot do this: a parameter list
    can contain a default value with its own parentheses, and a non-greedy
    match swallows the signatures that follow."""
    depth = 1
    j = i
    while j < len(text) and depth:
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
        j += 1
    return text[i:j - 1], j


def split_top(text, sep=","):
    out, buf, depth = [], "", 0
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == sep and depth == 0:
            out.append(buf)
            buf = ""
        else:
            buf += ch
    if buf.strip():
        out.append(buf)
    return [x.strip() for x in out if x.strip()]


def parse_params(body):
    """`name~ : Type = default` per chunk -> (name, optional, default)."""
    params = []
    for chunk in split_top(body):
        head, _, default = chunk.partition("=")
        m = re.match(r"^(\w+)\s*(~?)\s*:", head.strip())
        if not m:
            continue
        params.append((m.group(1), m.group(2) == "~", default.strip()))
    return params


SIGS = {}
for _name in sorted(os.listdir(LIB)):
    if not _name.endswith(".mbt"):
        continue
    _src = io.open(os.path.join(LIB, _name), encoding="utf-8", errors="replace").read()
    for _m in re.finditer(r"pub fn ([\w]+::[\w]+)\(", _src):
        _body, _ = balanced(_src, _m.end())
        SIGS.setdefault(_m.group(1), (_body, parse_params(_body)))

ALL_TYPES = sorted(set(re.findall(r"pub struct (DoubleML\w+)\b", "\n".join(
    io.open(os.path.join(LIB, n), encoding="utf-8", errors="replace").read()
    for n in sorted(os.listdir(LIB)) if n.endswith(".mbt")))))
FITTABLE = set(k.split("::")[0] for k in SIGS if k.endswith("::fit"))
ESTIMATORS = [t for t in ALL_TYPES if t in FITTABLE]


def signature(estimator):
    """The parameter list of `DoubleMLX::new(` as written in the source."""
    hit = SIGS.get("%s::new" % estimator)
    if not hit:
        return None, None
    return [p[0] for p in hit[1]], hit[0]


print("== the Library Use snippet ==")
params, raw = signature("DoubleMLData")
check("DoubleMLData::new exists", params is not None)
if params:
    for p in ("x", "y", "d"):
        check("DoubleMLData::new takes %r" % p, p in params, str(params))
    check("DoubleMLData::new's 3rd positional is d, not z",
          params[:3] == ["x", "y", "d"], str(params))

params, raw = signature("DoubleMLPLR")
check("DoubleMLPLR::new exists", params is not None)
if params:
    for p in ("data", "n_folds", "n_rep", "seed"):
        check("DoubleMLPLR::new takes %r" % p, p in params, str(params))
    check("n_folds default is 2", "n_folds~ : Int32 = 2" in raw, raw)
    check("n_rep default is 1", "n_rep~ : Int32 = 1" in raw, raw)
    check("seed default is 3141", "seed~ : Int32 = 3141" in raw, raw)

plr = io.open(os.path.join(LIB, "plr.mbt"), encoding="utf-8", errors="replace").read()
for acc in ("coef", "se", "confint"):
    check("DoubleMLPLR::%s() exists" % acc,
          ("pub fn DoubleMLPLR::%s(" % acc) in plr)
check("confint() returns (Double, Double)",
      re.search(r"pub fn DoubleMLPLR::confint\([^)]*\)\s*->\s*\(Double, Double\)", plr) is not None)

print("")
print("== the 'same shape for every other estimator' sentence ==")
m = re.search(r"`@moonbit_doubleML\.(DoubleML\w+)::new\(([^)]*)\)", readme)
seen = set()
for mm in re.finditer(r"`@moonbit_doubleML\.(DoubleML\w+)::new\(([^)]*)\)", readme):
    est, arglist = mm.group(1), mm.group(2)
    if est in seen:
        continue
    seen.add(est)
    params, raw = signature(est)
    check("%s::new exists" % est, params is not None)
    if not params:
        continue
    named = re.findall(r"(\w+)\?", arglist)
    for p in named:
        check("%s::new takes %r" % (est, p), p in params, str(params))
    # every PARAMETER the README shows must be one the constructor accepts
    ok = all(p in params for p in named)
    check("%s::new accepts every name the README shows" % est, ok, str(params))

# ---------------------------------------------------------------------------
# ROUND 35 -- every constructor the README states, qualified or not
# ---------------------------------------------------------------------------

print("")
print("== every constructor the README states (round 35) ==")


def readme_calls(pattern):
    """(owner, arglist) for every `Owner::method(args)` in the README, with
    the parentheses balanced."""
    out = []
    for mm in re.finditer(pattern, readme):
        body, _ = balanced(readme, mm.end())
        out.append((mm.group(1), body))
    return out


# A named argument's value is compared with the source's DEFAULT only when
# the value is a LITERAL -- a number, a string, a bool, `None`/`Some`.
#
# The README's convention is that a constructor call it states shows the
# source's defaults, so a literal that differs from the default is the
# README misstating it.  That is the rule round 35 was written for: a
# constructor that "states a default the source does not have".
#
# An EXPRESSION is not a stated default -- it is a choice the snippet is
# making.  Round 43's "pass a classifier explicitly" snippet passes
# `ml_m=LearnerDispatch::logistic_regression(...)`, deliberately NOT the
# source's default (`LearnerDispatch::linear_regression()`), because
# choosing a different learner is the whole point of the snippet.  Flagging
# that would be a false positive, and a rule with false positives teaches its
# reader to ignore it.
LITERAL = re.compile(r'^-?\d+(?:\.\d+)?$|^"[^"]*"$|^(?:true|false|None|Some)$')


def is_literal(v):
    return bool(LITERAL.match(v.strip()))


ctor_calls = [(o, a) for o, a in readme_calls(r"([A-Za-z_]\w*)::new\(")
              if o != PLACEHOLDER]

check("the constructor-call set is the declared size",
      len(ctor_calls) == EXPECTED_CONSTRUCTOR_CALLS,
      "found %d, declared %d" % (len(ctor_calls), EXPECTED_CONSTRUCTOR_CALLS))

checked = 0
for owner, arglist in ctor_calls:
    key = "%s::new" % owner
    hit = SIGS.get(key)
    if hit is None:
        check("%s::new exists" % owner, False, "no `pub fn %s(` in the library" % key)
        continue
    body, sparams = hit
    pnames = [p[0] for p in sparams]
    checked += 1
    check("%s::new exists" % owner, True)

    positional, named = [], []
    for a in split_top(arglist):
        if a == "...":
            continue
        if "=" in a:
            nm, _, val = a.partition("=")
            named.append((nm.strip(), val.strip()))
        elif a.endswith("?"):
            named.append((a[:-1].strip(), None))   # the optional marker
        else:
            positional.append(a)

    bad = []
    for i, a in enumerate(positional):
        if i >= len(pnames):
            bad.append("more positional args than the source has (%d)" % len(pnames))
            break
        if a != pnames[i]:
            bad.append("positional #%d is %r, the source calls it %r"
                       % (i + 1, a, pnames[i]))
    for nm, val in named:
        if nm not in pnames:
            bad.append("named arg %r is not a parameter" % nm)
            continue
        sp = [p for p in sparams if p[0] == nm][0]
        if not sp[1]:
            bad.append("named arg %r is not optional in the source" % nm)
        elif val is not None and sp[2] and val != sp[2] and is_literal(val):
            bad.append("named arg %r=%r, the source default is %r" % (nm, val, sp[2]))
    check("%s::new(%s) matches the source" % (owner, arglist),
          not bad, "; ".join(bad))

check("every constructor the README states was checked",
      checked == len(ctor_calls),
      "checked %d of %d" % (checked, len(ctor_calls)))

print("")
print("== every LearnerDispatch function the README names ==")
for mm in re.finditer(r"(LearnerDispatch)::(\w+)\(", readme):
    key = "%s::%s" % (mm.group(1), mm.group(2))
    check("%s::%s() exists" % (mm.group(1), mm.group(2)),
          key in SIGS, "no `pub fn %s(` in the library" % key)

# ---------------------------------------------------------------------------
# ROUND 35 -- the API reference's accessor promises
# ---------------------------------------------------------------------------

print("")
print("== the API reference's accessor promises (round 35) ==")

lines = readme.split("\n")
table_rows = []
in_table = False
for ln, line in enumerate(lines, 1):
    if line.startswith("| estimator | instead of | because |"):
        in_table = True
        continue
    if in_table:
        if not line.startswith("|"):
            break
        if set(line.replace("|", "").strip()) <= set("-: "):
            continue
        table_rows.append((ln, [c.strip() for c in line.strip().strip("|").split("|")]))

check("the accessor table has the declared number of rows",
      len(table_rows) == EXPECTED_ACCESSOR_ROWS,
      "found %d, declared %d" % (len(table_rows), EXPECTED_ACCESSOR_ROWS))

DEFAULT_SET = ("coef", "se", "confint")
table_estimators = []
for ln, cells in table_rows:
    est = cells[0].strip("` ")
    table_estimators.append(est)
    if len(cells) < 2 or "no scalar coefficient" in cells[1]:
        continue
    col = cells[1]
    left, _, right = col.partition("->")
    for nm in re.findall(r"`(\w+)`", left):
        if nm in DEFAULT_SET:
            continue
        check("%s::%s() exists" % (est, nm),
              "%s::%s" % (est, nm) in SIGS,
              "no `pub fn %s::%s(` in the library" % (est, nm))
    for nm in re.findall(r"`(\w+)`", right):
        check("%s::%s() exists" % (est, nm),
              "%s::%s" % (est, nm) in SIGS,
              "no `pub fn %s::%s(` in the library" % (est, nm))

check("the estimator set derived from the source is the declared size",
      len(ESTIMATORS) == EXPECTED_ESTIMATORS,
      "found %d, declared %d" % (len(ESTIMATORS), EXPECTED_ESTIMATORS))

m = re.search(r"The other (\d+) expose `\.(\w+)\(\)` / `\.(\w+)\(\)` / "
              r"`\.(\w+)\(\)` / `\.(\w+)\(\)`", readme)
if m is None:
    check("the 'the other N expose ...' sentence exists", False,
          "not found in its expected form")
else:
    n_claim = int(m.group(1))
    accessors = [m.group(2), m.group(3), m.group(4), m.group(5)]
    others = [e for e in ESTIMATORS if e not in table_estimators]
    check("the 'other N' count is the declared size",
          n_claim == EXPECTED_OTHER,
          "the README says %d, declared %d" % (n_claim, EXPECTED_OTHER))
    check("the estimators outside the table are the declared size",
          len(others) == n_claim,
          "found %d, the README says %d" % (len(others), n_claim))
    for est in others:
        for a in accessors:
            check("%s::%s() exists" % (est, a),
                  "%s::%s" % (est, a) in SIGS,
                  "no `pub fn %s::%s(` in the library" % (est, a))

print("")
print("%d checks, %d failed" % (NCHECK, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
