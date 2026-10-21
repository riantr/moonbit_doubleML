#!/usr/bin/env python3
"""Round 28 verifier: the `score` argument -- where it lives, what it accepts,
and which estimators have one at all.

WHY THIS EXISTS
===============
Rounds 21-27 audited the README's numbers, its test-verification claims, its
shape, its count referents, its names, its upstream-provenance grouping and
the four tutorial documents.  This one audits the `score` argument -- the one
API parameter that is NOT where the README's own shape said it would be.

FIVE DEFECTS, ALL CONFIRMED AGAINST THE TREE
============================================
A  `doc/004_estimators` framed its "Port `score` string" column as "the value
   you pass to `fit(score=...)`".  The port has 9 `score` parameters at 7
   estimators: `DoubleMLPLR` takes it on `fit()`, six others take it on
   `new()`, and 15 of the 22 take no score argument at all.  The column was
   right for exactly ONE estimator.

B  The same column filled eight rows with strings that are not score values
   at all -- `apo`, `apos`, `pq`, `qte`, `lpq`, `cvar`, `policy_tree`.  They
   are the port's INTERNAL cache-kind tags (the `hash_hyperparams(...)` kind,
   and `policy_tree` the `estimator_kind`).  A reader following the document
   wrote `DoubleMLAPO::new(data).fit(score="apo")`, which does not compile.

C  The README's "three vocabularies" note repeated the mistake: five of the
   eight strings it listed as accepted by the port are ones no estimator
   accepts.

D  The same note listed 9 of the 15 spellings upstream actually uses --
   `ATTE`, `LATE`, `experimental`, `instrument`, `nonignorable` and `IV-type`
   were missing.

E  `skills/moonbit_doubleML.md` said `ml_m` defaults to the classifier "for
   the six estimators whose propensity enters the score as `1 / m_hat`" and
   then named SEVEN.  The seventh, `DoubleMLLPLR`, is not one of them: its
   propensity enters its score as `d - m_hat`.  The same document said all 24
   `validate_*` scripts re-derive the hand-rolled reference, which is true of
   15 -- the other nine take theirs from upstream's wheel.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the 22 port estimators;
  * every `score~ : String` parameter, its owning type, the METHOD it sits
    on (`new` / `fit` / `fit_cluster` / `tune`) and its default;
  * the set each site accepts -- read from the `require(...)` that guards
    the parameter, with the `*_is_*_score` helper predicates resolved, and
    CROSS-CHECKED against every `score == "..."` comparison in the same file;
  * the cache-kind tags: the string literals handed to `hash_hyperparams(...)`
    and `estimator_kind(...)`, with COMMENTS and DOCSTRINGS removed, so a
    tag mentioned in prose is not counted as a tag;
  * the port's accepted union, and the upstream one -- measured on BOTH the
    vendored 0.11.4 tree and the installed 0.11.3 wheel, which must agree;
  * the logistic-defaulting `ml_m` estimators, so the skills document has to
    account for every one of them;
  * the 15 / 9 split of the `validate_*` family, by CODE (the wheel import),
    not by prose.

Run: python _verify/_verify_score_argument_1650.py
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
        print("  ok    %-64s %s" % (label, detail))
    else:
        FAILS.append(label)
        print("  *** FAIL ***  %-58s %s" % (label, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def flat(p):
    """A document with its line wrapping and blockquote markers collapsed."""
    body = "\n".join(re.sub(r"^\s*>\s?", "", ln) for ln in read(p).split("\n"))
    return re.sub(r"\s+", " ", body).strip()


def code_only(path):
    """-> the file's source with COMMENTS and DOCSTRINGS blanked out.

    A mention in a comment or a docstring is not a dependency (round 27's
    rule).  The docstring set comes from `ast`, because a MODULE docstring
    has no preceding token and a "previous token" guess misses it.
    """
    with open(path, "rb") as fh:
        raw = fh.read()
    lines = read(path).split("\n")
    try:
        tree = ast.parse(raw)
    except SyntaxError:
        return lines
    docpos = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                             ast.ClassDef)):
            body = getattr(node, "body", None)
            if body and isinstance(body[0], ast.Expr) and \
                    isinstance(body[0].value, ast.Constant) and \
                    isinstance(body[0].value.value, str):
                docpos.add((body[0].value.lineno, body[0].value.col_offset))
    blank = set()
    for tok in tokenize.tokenize(io.BytesIO(raw).readline):
        if tok.type == tokenize.COMMENT:
            blank.add(tok.start[0])
        elif tok.type == tokenize.STRING and (tok.start[0], tok.start[1]) in docpos:
            blank.add(tok.start[0])
    out = list(lines)
    for ln in blank:
        if 1 <= ln <= len(out):
            out[ln - 1] = ""
    return out


def mbt_files():
    return [f for f in sorted(os.listdir(LIB)) if f.endswith(".mbt")
            and not f.startswith("_")
            and not f.startswith("expand_v")
            and not f.endswith("_test.mbt")
            and not f.endswith("_wbtest.mbt")]


# `pub fn DoubleMLDID::new(` -- group 1 is the TYPE, group 2 the METHOD.
FUNC_RE = re.compile(r"^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)\s*(?:::([A-Za-z_]\w*))?\s*\(")


def owner_of(lines, idx):
    """-> (type, method) of the function whose signature holds line `idx`.

    Walk BACKWARDS: the score parameter sits in a signature, so the nearest
    preceding header is the one that owns it.  A free function (no `::`) is
    skipped -- it may be a nested helper, and the method further back is the
    owner that matters.
    """
    for i in range(idx, -1, -1):
        fm = FUNC_RE.match(lines[i])
        if fm and fm.group(2):
            return fm.group(1), fm.group(2)
    return None, None


def fn_span(lines, header_idx):
    """The braces-balanced body of the function whose header is at header_idx."""
    depth = 0
    started = False
    out = []
    for i in range(header_idx, len(lines)):
        out.append(lines[i])
        depth += lines[i].count("{") - lines[i].count("}")
        if "{" in lines[i]:
            started = True
        if started and depth <= 0:
            break
    return out


# ==============================================================================
print("=" * 78)
print("1. the port's score parameters, derived from the source")
print("=" * 78)

SRC = {f: code_only(os.path.join(LIB, f)) for f in mbt_files()}

EST_RE = re.compile(r"pub\s+struct\s+(DoubleML\w+)\s*\{")
ESTIMATORS = set()
for f, lines in SRC.items():
    for ln in lines:
        m = EST_RE.search(ln)
        if m and not m.group(1).endswith("Data"):
            ESTIMATORS.add(m.group(1))
check("the port has 22 estimators", len(ESTIMATORS) == 22,
      "got %d" % len(ESTIMATORS))

SITES = []
for f, lines in SRC.items():
    for i, ln in enumerate(lines):
        if re.search(r"score~\s*:\s*String", ln):
            t, m = owner_of(lines, i)
            d = ""
            if "=" in ln:
                d = ln.split("=", 1)[1].strip().rstrip(",").strip().strip('"')
            SITES.append((f, i + 1, t, m, d))
SITES.sort(key=lambda s: (s[0], s[1]))

check("the port has 9 score parameters", len(SITES) == 9, "got %d" % len(SITES))
for s in SITES:
    print("        %-20s :%-5d %-22s %s" % (s[0], s[1], s[2], s[3]))

OWNER_TYPES = sorted(set(s[2] for s in SITES))
check("they sit at 7 estimators", len(OWNER_TYPES) == 7,
      "got %d: %s" % (len(OWNER_TYPES), OWNER_TYPES))
ON_NEW = sorted(set(s[2] for s in SITES if s[3] == "new"))
ON_FIT = sorted(set(s[2] for s in SITES if s[3] == "fit"))
check("six take it on new()", len(ON_NEW) == 6, str(ON_NEW))
check("one takes it on fit()", ON_FIT == ["DoubleMLPLR"], str(ON_FIT))
check("the new() six are the DID family, LPLR and PLPR",
      ON_NEW == ["DoubleMLDID", "DoubleMLDIDBinary", "DoubleMLDIDCSBinary",
                 "DoubleMLDIDCrossSection", "DoubleMLLPLR", "DoubleMLPLPR"],
      str(ON_NEW))
NO_SCORE = sorted(ESTIMATORS - set(OWNER_TYPES))
check("15 of the 22 estimators take no score argument", len(NO_SCORE) == 15,
      "got %d" % len(NO_SCORE))


def file_accepted(f):
    """-> (the spellings the guarding require accepts, the spellings the code
    compares `score` against).  The second is a cross-check on the first."""
    lines = SRC[f]
    guarded = set()
    for i, ln in enumerate(lines):
        if "require(" not in ln or "score" not in ln:
            continue
        guarded |= set(re.findall(r'"([^"]*)"', ln))
        for helper in re.findall(r"\b(\w*_is_\w*_score)\b", ln):
            for j, hl in enumerate(lines):
                if re.match(r"^\s*(?:pub\s+)?fn\s+%s\s*\(" % helper, hl):
                    for bl in fn_span(lines, j):
                        guarded |= set(re.findall(r'"([^"]*)"', bl))
                    break
    compared = set()
    for ln in lines:
        for m in re.finditer(r"score\s*==\s*\"([^\"]*)\"", ln):
            compared.add(m.group(1))
    return guarded, compared


ACCEPTED = {}
for f, ln, t, m, d in SITES:
    guarded, compared = file_accepted(f)
    check("%s's score guard and its comparisons agree" % f, guarded == compared,
          "guard=%s compared=%s" % (sorted(guarded), sorted(compared)))
    info = ACCEPTED.setdefault(t, {"method": m, "default": d, "accepts": set(),
                                   "files": set()})
    info["accepts"] |= guarded
    info["files"].add(f)
    if info["method"] != m:
        # PLR has the argument on more than one method -- the DEFAULT is the
        # same at each of them, which is what the documents state.
        check("%s's score default is the same on every method" % t, info["default"] == d,
              "%s vs %s" % (info["default"], d))
PORT_UNION = set()
for t, info in ACCEPTED.items():
    PORT_UNION |= info["accepts"]
check("the port's accepted union is 8 spellings", len(PORT_UNION) == 8,
      "got %d: %s" % (len(PORT_UNION), sorted(PORT_UNION)))
check("the port's union is the documented one",
      PORT_UNION == {"partialling-out", "partialling out", "iv-type", "IV-type",
                     "observational", "experimental", "nuisance_space", "instrument"},
      str(sorted(PORT_UNION)))
def accepts_of(t):
    """The accepted set of an estimator -- or the empty set if it has none.

    A verifier that CRASHES on a broken tree reports a harness failure, not
    a verdict: the driver would count zero failures and the defect would
    hide inside a passing run.  Every lookup of a derived fact goes through
    here, so a missing fact is a FAILED CHECK, not an exception.
    """
    return ACCEPTED.get(t, {}).get("accepts", set())


def default_of(t):
    return ACCEPTED.get(t, {}).get("default", "")


def method_of(t):
    return ACCEPTED.get(t, {}).get("method", "")


check("DoubleMLPLR accepts four spellings",
      accepts_of("DoubleMLPLR") == {"partialling-out", "partialling out",
                                    "iv-type", "IV-type"},
      str(sorted(accepts_of("DoubleMLPLR"))))
check("DoubleMLDIDCSBinary accepts only observational",
      accepts_of("DoubleMLDIDCSBinary") == {"observational"},
      str(sorted(accepts_of("DoubleMLDIDCSBinary"))))
check("DoubleMLPLPR accepts the SPACE spelling, not the hyphen one",
      accepts_of("DoubleMLPLPR") == {"partialling out", "IV-type"},
      str(sorted(accepts_of("DoubleMLPLPR"))))
check("DoubleMLPLR defaults to the HYPHEN spelling",
      default_of("DoubleMLPLR") == "partialling-out", default_of("DoubleMLPLR"))
for t in ("DoubleMLDID", "DoubleMLDIDBinary", "DoubleMLDIDCSBinary",
          "DoubleMLDIDCrossSection"):
    check("%s's default is observational" % t,
          default_of(t) == "observational", default_of(t))
check("DoubleMLLPLR defaults to nuisance_space",
      default_of("DoubleMLLPLR") == "nuisance_space", default_of("DoubleMLLPLR"))
check("DoubleMLPLPR defaults to 'partialling out'",
      default_of("DoubleMLPLPR") == "partialling out", default_of("DoubleMLPLPR"))

# ==============================================================================
print()
print("=" * 78)
print("2. the cache-kind tags -- internal, and never score values")
print("=" * 78)

TAGS = set()
for f, lines in SRC.items():
    blob = re.sub(r"\s+", " ", "\n".join(lines))
    for m in re.finditer(r"(?:hash_hyperparams|estimator_kind)\(\s*\"([^\"]*)\"", blob):
        TAGS.add(m.group(1))
    for m in re.finditer(r"\"(policy_tree[^\"]*)\"\s*\+", blob):
        TAGS.add(m.group(1))
    # `let estimator_kind : String = if ... { "policy_tree_honest:" + ... }
    #                            else { "policy_tree" }` -- the tag is a
    # BINDING, not a call argument, so the call-site scan cannot see it.
    for i, ln in enumerate(lines):
        if re.search(r"let\s+estimator_kind\b", ln):
            for bl in lines[i:i + 10]:
                TAGS |= set(re.findall(r'"([^"]*)"', bl))
TAGS = {t for t in TAGS if t and "<" not in t and ":" not in t}
check("the cache-kind tags include the seven the documents name",
      {"apo", "apos", "pq", "qte", "lpq", "cvar", "policy_tree"} <= TAGS,
      str(sorted(TAGS)))
check("NO cache-kind tag is accepted as a score value",
      not (TAGS & PORT_UNION),
      "overlap: %s" % sorted(TAGS & PORT_UNION))

# ==============================================================================
print()
print("=" * 78)
print("3. the upstream vocabulary -- 0.11.4 (vendored) and 0.11.3 (installed)")
print("=" * 78)


def upstream_union(pkgdir):
    """The spellings upstream accepts, read from its production sources."""
    acc = set()
    for root, dirs, files in os.walk(pkgdir):
        parts = os.path.relpath(root, pkgdir).replace("\\", "/").split("/")
        if "tests" in parts:
            continue
        for fn in files:
            if not fn.endswith(".py"):
                continue
            s = read(os.path.join(root, fn))
            for m in re.finditer(r"valid_scores?\s*=\s*\[([^\]]*)\]", s):
                acc |= set(re.findall(r"[\"']([^\"']+)[\"']", m.group(1)))
            for m in re.finditer(r"_check_score\([^,]+,\s*\[([^\]]*)\]", s):
                acc |= set(re.findall(r"[\"']([^\"']+)[\"']", m.group(1)))
            for m in re.finditer(r"score\s+in\s+\(([^)]*)\)", s):
                acc |= set(re.findall(r"[\"']([^\"']+)[\"']", m.group(1)))
    return acc


VEND = os.path.join(ROOT, "_verify", "_upstream_ps", "doubleml-0.11.4", "doubleml")
UP14 = upstream_union(VEND) if os.path.isdir(VEND) else set()
check("the vendored 0.11.4 tree is present", bool(UP14), "%d spellings" % len(UP14))
check("upstream 0.11.4 uses 15 spellings", len(UP14) == 15, "got %d" % len(UP14))

UP13 = set()
UPVER = "missing"
try:
    import doubleml
    UP13 = upstream_union(os.path.dirname(doubleml.__file__))
    UPVER = doubleml.__version__
except Exception as e:                                   # pragma: no cover
    print("  (installed doubleml unavailable: %s)" % e)
check("the installed wheel is 0.11.3", UPVER == "0.11.3", UPVER)
check("the two upstream versions agree on the vocabulary", UP13 == UP14,
      "13-only=%s 14-only=%s" % (sorted(UP13 - UP14), sorted(UP14 - UP13)))
check("upstream's 15 are the documented ones",
      UP14 == {"APO", "ATE", "ATTE", "CVaR", "IV-type", "LATE", "LPQ", "PQ",
               "experimental", "instrument", "missing-at-random", "nonignorable",
               "nuisance_space", "observational", "partialling out"},
      str(sorted(UP14)))

try:
    from doubleml.rdd import RDFlex
    from doubleml.utils.blp import DoubleMLBLP
    from doubleml.utils.policytree import DoubleMLPolicyTree
    import inspect
    noscore = []
    for cls in (RDFlex, DoubleMLBLP, DoubleMLPolicyTree):
        sig = inspect.signature(cls.__init__)
        if "score" not in sig.parameters:
            noscore.append(cls.__name__)
    check("upstream's RDFlex, DoubleMLBLP and DoubleMLPolicyTree take no score",
          len(noscore) == 3, str(noscore))
except Exception as e:                                   # pragma: no cover
    check("upstream's RDFlex, DoubleMLBLP and DoubleMLPolicyTree take no score",
          False, "import failed: %s" % e)

# ==============================================================================
print()
print("=" * 78)
print("4. doc/004_estimators -- the catalogue table and the new section")
print("=" * 78)

D4PATH = os.path.join(ROOT, "doc", "004_estimators", "readme.mbt.md")
D4 = flat(D4PATH)
D4RAW = read(D4PATH)

rows = []
rlines = D4RAW.split("\n")
for i, l in enumerate(rlines):
    if l.startswith("|") and "Score argument" in l:
        for l2 in rlines[i + 1:]:
            if not l2.startswith("|"):
                break
            m = re.match(r"^\|\s*`DoubleML(\w+)`\s*\|([^|]*)\|([^|]*)\|([^|]*)\|$", l2)
            if m:
                rows.append(m.groups())
        break
check("doc/004's catalogue still lists 22 rows", len(rows) == 22, "got %d" % len(rows))
check("doc/004's catalogue lists exactly the derived estimator set",
      sorted("DoubleML" + r[0] for r in rows) == sorted(ESTIMATORS), "")

for r in rows:
    name = "DoubleML" + r[0]
    cell = r[1].strip()
    if name in ACCEPTED:
        want = "`%s(score=...)`" % method_of(name)
        check("doc/004's %s row names the %s() argument" % (name, method_of(name)),
              want in cell, "cell=%r want=%r" % (cell, want))
    else:
        check("doc/004's %s row says the score is fixed" % name,
              cell.startswith("— (fixed"), "cell=%r" % cell)

check("doc/004 states that only 7 of the 22 take a score argument",
      "**Only 7 of the 22 estimators take a `score` argument**" in D4)
check("doc/004 states that 15 take none", "**15 take no `score` argument at all**" in D4)
check("doc/004 states the 9 parameters at 7 estimators",
      "**9 `score` parameters, at 7 estimators**" in D4)
check("doc/004 says upstream uses 15 spellings", "set of **15** spellings" in D4)

# the COUNTS the document states must be the DERIVED ones -- a document that
# says "7" while the source has 6 is wrong even though "7" is present.
check("doc/004's stated score-taking count is the derived one",
      "**Only %d of the %d estimators take a `score` argument**"
      % (len(ACCEPTED), len(ESTIMATORS)) in D4,
      "derived %d of %d" % (len(ACCEPTED), len(ESTIMATORS)))
check("doc/004's stated no-score count is the derived one",
      "**%d take no `score` argument at all**" % len(NO_SCORE) in D4,
      "derived %d" % len(NO_SCORE))
check("doc/004's stated parameter count is the derived one",
      "**%d `score` parameters, at %d estimators**"
      % (len(SITES), len(ACCEPTED)) in D4,
      "derived %d at %d" % (len(SITES), len(ACCEPTED)))

site_rows = re.findall(
    r"^\|\s*`DoubleML(\w+)`\s*\|\s*`(\w+)\(score=\.\.\.\)`\s*\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|$",
    D4RAW, re.M)
check("doc/004's score-argument table has 7 rows", len(site_rows) == 7,
      "got %d" % len(site_rows))
for r in site_rows:
    name = "DoubleML" + r[0]
    meth, dflt, accs = r[1], r[2], r[3]
    check("doc/004's site row for %s names the right method" % name,
          method_of(name) == meth, "doc=%s derived=%s" % (meth, method_of(name)))
    check("doc/004's site row for %s states the real default" % name,
          default_of(name) == dflt, "doc=%s derived=%s" % (dflt, default_of(name)))
    want = set(re.findall(r"`([^`]+)`", accs))
    check("doc/004's site row for %s states the real accepted set" % name,
          want == accepts_of(name),
          "doc=%s derived=%s" % (sorted(want), sorted(accepts_of(name))))
check("doc/004's site table covers exactly the 7 estimators with a score",
      sorted("DoubleML" + r[0] for r in site_rows) == sorted(ACCEPTED), "")

for tag in ("apo", "apos", "pq", "qte", "lpq", "cvar", "policy_tree"):
    check("doc/004 names the cache-kind tag %r" % tag, "`%s`" % tag in D4)
check("doc/004 says the cache-kind tags are not score values",
      "are not score values" in D4)
check("doc/004 says they are cache-kind tags",
      "cache-kind tags" in D4 and "hash_hyperparams" in D4)
check("doc/004 no longer claims the column is what you pass to fit(score=...)",
      "the value you pass to `fit(score=...)`" not in D4)
check("doc/004 no longer calls the column 'Port `score` string'",
      "Port `score` string" not in D4)

# ==============================================================================
print()
print("=" * 78)
print("5. the README -- the score-vocabulary note and the constructor paragraph")
print("=" * 78)

RM = flat(os.path.join(ROOT, "README.mbt.md"))
check("the README keeps the pinned phrase 'three vocabularies are in play'",
      "three vocabularies are in play" in RM)
check("the README keeps the pinned upstream prefix",
      re.search(r"upstream\s+`doubleml-for-py` 0\.11\.4 uses `APO`, `ATE`, `PQ`, `LPQ`", RM)
      is not None)
check("the README keeps the pinned pointer to the tutorial",
      "`doc/004_estimators` tutorial lists the port's own strings" in RM)

note = re.search(r"three vocabularies are in play\.(.*?)(?:`doc/004_estimators` tutorial)",
                 RM, re.S)
check("the README's score note is findable", note is not None)
if note:
    body = note.group(1)
    # the port's list: the spellings between "spellings -- " and " -- and only"
    port_span = re.search(r"spellings -- (.*?) -- and only", body, re.S)
    check("the README's port list is findable", port_span is not None)
    if port_span:
        port_listed = set(re.findall(r"`([^`]+)`", port_span.group(1)))
        check("the README lists exactly the port's accepted spellings",
              port_listed == PORT_UNION,
              "extra=%s missing=%s" % (sorted(port_listed - PORT_UNION),
                                       sorted(PORT_UNION - port_listed)))
        pm = re.search(r"\*\*(\d+)\*\* spellings -- ", body)
        check("the README's stated port count is the derived one",
              pm is not None and int(pm.group(1)) == len(PORT_UNION),
              "doc=%s derived=%d" % (pm.group(1) if pm else "?",
                                     len(PORT_UNION)))
    # the upstream list: the spellings between "0.11.4 uses " and ";"
    up_span = re.search(r"0\.11\.4 uses (.*?);", body, re.S)
    check("the README's upstream list is findable", up_span is not None)
    if up_span:
        up_listed = set(re.findall(r"`([^`]+)`", up_span.group(1)))
        check("the README lists exactly upstream's spellings",
              up_listed == UP14,
              "extra=%s missing=%s" % (sorted(up_listed - UP14),
                                       sorted(UP14 - up_listed)))
        um = re.search(r"set of \*\*(\d+)\*\* spellings", body)
        check("the README's stated upstream count is the derived one",
              um is not None and int(um.group(1)) == len(UP14),
              "doc=%s derived=%d" % (um.group(1) if um else "?", len(UP14)))
    check("the README says 7 of the 22 take a score argument",
          "**7 of the 22 estimators take a `score` argument at all**" in RM)
    check("the README's stated score-taking count is the derived one",
          "**%d of the %d estimators take a `score` argument at all**"
          % (len(ACCEPTED), len(ESTIMATORS)) in RM,
          "derived %d of %d" % (len(ACCEPTED), len(ESTIMATORS)))
    check("the README says upstream's vocabulary is 15 spellings",
          "**15** spellings" in RM)
    check("the README says DoubleMLPLR takes the score on fit() and six on new()",
          "`DoubleMLPLR` on `fit()`, six others on `new()`" in RM)

check("the README no longer calls apo / pq / lpq / cvar / policy_tree score values",
      "`apo`" not in RM and "`policy_tree`" not in RM and "`lpq`" not in RM
      and "`cvar`" not in RM)

ctor = re.search(r"Constructor arguments also differ in ways a table cannot show:(.*?)"
                  r"(?=\*\*Learner injection)", RM, re.S)
check("the README's constructor-differences paragraph is findable", ctor is not None)
if ctor:
    cb = ctor.group(1)
    check("the README names the six that take the score on new()",
          all("`%s`" % n in cb for n in ON_NEW),
          str([n for n in ON_NEW if "`%s`" % n not in cb]))
    check("the README says DoubleMLPLR takes the score on fit()",
          "`DoubleMLPLR` takes it on `fit()`" in cb)

# ==============================================================================
print()
print("=" * 78)
print("6. skills/moonbit_doubleML.md -- the classifier set and the validators")
print("=" * 78)

SK = flat(os.path.join(ROOT, "skills", "moonbit_doubleML.md"))

# the estimators whose ml_m default is the classifier, derived from source
LOGISTIC = set()
for f, lines in SRC.items():
    for i, ln in enumerate(lines):
        if re.search(r"ml_m~\s*:\s*LearnerDispatch\s*=\s*LearnerDispatch::logistic_regression",
                     ln):
            t, m = owner_of(lines, i)
            if t:
                LOGISTIC.add(t)
check("7 estimators default ml_m to the classifier", len(LOGISTIC) == 7,
      "got %d: %s" % (len(LOGISTIC), sorted(LOGISTIC)))
check("DoubleMLLPLR is one of them", "DoubleMLLPLR" in LOGISTIC)
check("DoubleMLDID is not one of them", "DoubleMLDID" not in LOGISTIC)

six = ["DoubleMLIRM", "DoubleMLAPO", "DoubleMLAPOS", "DoubleMLSSM",
       "DoubleMLPQ", "DoubleMLQTE"]
check("the skills document names the six 1/m_hat estimators",
      all("`%s`" % n in SK for n in six),
      str([n for n in six if "`%s`" % n not in SK]))
check("the skills document accounts for the seventh (LPLR) as an exception",
      "DoubleMLLPLR" in SK and "d - m_hat" in SK)
check("the skills document says the 1/m_hat set is SIX",
      re.search(r"for the six estimators whose propensity enters the score", SK) is not None)
check("the skills document does not call the 1/m_hat set seven",
      not re.search(r"for the seven estimators whose propensity", SK))

# the 15 / 9 split of the validate_* family, by CODE.  The family is the 24
# `validate_*_with_python.py` scripts -- the three repo-level harnesses
# (`validate_plotting_scope.py` and friends) are NOT in it.
val = [f for f in sorted(os.listdir(ROOT))
       if f.startswith("validate_") and f.endswith("_with_python.py")]
wheel, own = [], []
for f in val:
    p = os.path.join(ROOT, f)
    try:
        with open(p, "rb") as fh:
            raw = fh.read()
        tree = ast.parse(raw)
    except (OSError, SyntaxError):
        continue
    docpos = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                             ast.ClassDef)):
            b = getattr(node, "body", None)
            if b and isinstance(b[0], ast.Expr) and \
                    isinstance(b[0].value, ast.Constant) and \
                    isinstance(b[0].value.value, str):
                docpos.add((b[0].value.lineno, b[0].value.col_offset))
    imported = False
    for tok in tokenize.tokenize(io.BytesIO(raw).readline):
        if tok.type == tokenize.COMMENT:
            continue
        if tok.type == tokenize.STRING and (tok.start[0], tok.start[1]) in docpos:
            continue
        if tok.type == tokenize.NAME and tok.string == "doubleml":
            imported = True
        if tok.type == tokenize.STRING and "doubleml" in tok.string:
            imported = True
    (wheel if imported else own).append(f)
check("9 of the 24 validate_* scripts import the upstream wheel in code",
      len(wheel) == 9, "got %d: %s" % (len(wheel), wheel))
check("15 re-derive the hand-rolled reference", len(own) == 15, "got %d" % len(own))
check("the skills document states the 15 / 9 split",
      "Fifteen of the 24 re-derive the hand-rolled reference" in SK
      and "the other nine import upstream's `doubleml` wheel" in SK)

# ==============================================================================
print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
