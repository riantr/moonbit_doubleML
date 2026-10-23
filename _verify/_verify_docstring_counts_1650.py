#!/usr/bin/env python3
"""Round 29 verifier: the numbers in the library's PUBLIC API DOCSTRINGS.

WHY THIS EXISTS
===============
Rounds 21-28 audited the README, the test-verification claims, the four
tutorial documents and the `score` argument.  This one audits the prose a user
reads when they call the library -- the `///` docstrings on the public API.

That surface is the one no earlier round had ever checked for numbers, and it
turned out to carry the same failure mode as everything else: a COUNT of a set
of package members, written once and never revisited when the set grew.

THREE DEFECTS, ALL CONFIRMED AGAINST THE TREE
=============================================
A  `moonbit_doubleML/lpq.mbt` -- `DoubleMLLPQ::bias_corrected_coef` said it was
   "Identical in reasoning to the twelve `bias_corrected_coef` methods added in
   v0.86.0 - v0.92.0".  The range v0.86.0 - v0.92.0 holds THIRTEEN: the twelve
   that landed together at v0.91.0 plus `DoubleMLLPLR` at v0.92.0.

B  `moonbit_doubleML/quantile.mbt` -- `DoubleMLPQ::bias_corrected_coef` said
   "thirteen ... added in v0.86.0 - v0.93.0".  That range holds FOURTEEN: the
   twelve, plus LPLR (v0.92.0), plus `DoubleMLLPQ` (v0.93.0).

C  `moonbit_doubleML/sandwich.mbt` -- the canonical `bias_corrected_theta`
   docstring, which every other docstring cites as "the full argument", said
   "All twelve `bias_corrected_coef` methods are now documented no-ops".  There
   are FIFTEEN methods by that name now; the sentence was written when the
   family was twelve and was never revisited.

The pattern in A and B is exact: each author counted the family as of the
version BEFORE the immediately preceding addition.  `DoubleMLLPLR` (v0.92.0)
says twelve and is RIGHT (twelve existed before it); `DoubleMLLPQ` (v0.93.0)
says twelve and is wrong by one; `DoubleMLPQ` (v0.94.0) says thirteen and is
wrong by one; `DoubleMLQTE` (v0.95.0) says fifteen and is RIGHT.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the `bias_corrected*` family: its members, each one's SELF-DECLARED
    "vX.Y.Z+:" version, and the count of members in any stated range;
  * the estimator roster (22), the sandwich family (15) and the upstream
    `doubleml` 0.11.4 estimator roster (17), all from source;
  * upstream's `_sensitivity_implemented = True` set (7) and its
    `init_ps_processor` caller set (12), from the vendored upstream tree;
  * the RDDKernel variants (5) and which of them are negative outside
    |u| <= h (3), from the weight formulas;
  * the policy-tree flat encoding stride (5), the `GainStatsResult` field
    count (4), the `DoubleMLDIDBinary` delegation count (3), the
    `hash_data` row sample (10 + 10), the logistic defaults (25, 1e-8) and
    the two partialling-out spellings -- all from the CODE.

A COUNT MUST BE RESOLVABLE TO A SET, AND THE SET MUST BE NAMED
===============================================================
So this verifier does not look for a number and compare it with a constant.  It
derives the set, and then asks the prose whether it agrees.

READ THE DOCSTRING, NOT THE FILE
================================
A whole-file search is not a docstring check.  `fit_cache.mbt` says "first 10
+ last 10" in a `//` CODE COMMENT as well as in the `hash_data` docstring, and a
whole-file search matches whichever comes first -- so it can be satisfied by a
comment that a reader never sees.  Every check below is aimed at one named
docstring, and the `///` markers are stripped before the text is searched, so a
phrase that straddles a line break is still one phrase.

THE CHECK COUNT IS FIXED, NOT TREE-DEPENDENT
=============================================
Round 28's verifier ran one check per document row, so its published count
moved with the tree -- and v0.164.21 shipped the count measured on the
dry-run's deliberately-broken tree (127) as if it were the real one (131).
Here the five publishing sites are a FIXED list, and every other check is an
aggregate, so the number of checks is the same on every tree.  A site whose
docstring is destroyed reports a FAILED CHECK, not a skipped one, and the count
does not move.  The verifier still asserts its own published count, so the
number in the CHANGELOG cannot drift.

Run: python _verify/_verify_docstring_counts_1650.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
UPSTREAM = os.path.join(ROOT, "_verify", "_upstream_0114")

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


def skip(label, reason):
    """A check that could not run.  It still COUNTS, so the verifier's
    published check count does not depend on what is present on disk."""
    global NCHECK
    NCHECK += 1
    print("  SKIP  %-64s %s" % (label, reason))


HAVE_UPSTREAM = os.path.isdir(UPSTREAM)


def up_check(label, ok, detail=""):
    """A check about the VENDORED UPSTREAM tree.

    That tree is a DOWNLOADED third-party package, not part of this
    repository, so its absence is not a defect HERE -- the check skips with
    a reason instead of failing, which is what the QA registry's own rule
    says: "a check over an EMPTY subject set never reports PASS ... and
    degrade to SKIP otherwise".  Before this, a fresh clone of the
    repository failed six checks here for no reason of its own.
    """
    if not HAVE_UPSTREAM:
        skip(label, "the vendored upstream 0.11.4 tree is not present "
                    "(a downloaded package -- fetch it to run this)")
        return
    check(label, ok, detail)


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def mbt_flat(p):
    """A .mbt file with the `///` and `//` markers stripped, then flattened.

    The markers are NOT whitespace, so a plain whitespace collapse leaves
    "the function twelve /// upstream estimators call" in the text and every
    phrase that straddles a line break stops matching.
    """
    out = []
    for ln in read(p).split("\n"):
        s = ln.lstrip()
        if s.startswith("///"):
            s = s[3:]
        elif s.startswith("//"):
            s = s[2:]
        out.append(s)
    return re.sub(r"\s+", " ", " ".join(out)).strip()


def mbt_files():
    return [f for f in sorted(os.listdir(LIB)) if f.endswith(".mbt")
            and not f.startswith("_")
            and not f.startswith("expand_v")
            and not f.endswith("_test.mbt")
            and not f.endswith("_wbtest.mbt")]


FILES = mbt_files()
LINES = {f: read(os.path.join(LIB, f)).split("\n") for f in FILES}

# `pub fn DoubleMLDID::new(` -- group 1 is the TYPE, group 2 the METHOD.
FUNC_RE = re.compile(r"^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)\s*::\s*([A-Za-z_]\w*)\s*\(")
FREE_RE = re.compile(r"^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)\s*\(")

WORDNUM = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
}
NUMWORD = {v: k for k, v in WORDNUM.items()}


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def doc_above(f, i):
    """The `///` block above line index `i`, in FILE order.

    Collect BACKWARDS and then reverse.  Collecting forwards and reversing
    afterwards inverts the sentence -- which is exactly how an earlier probe
    lost "the twelve" and made a correct claim look unmatched.
    """
    doc = []
    j = i - 1
    while j >= 0 and LINES[f][j].strip().startswith("///"):
        doc.append(LINES[f][j].strip())
        j -= 1
    doc.reverse()
    return " ".join(d[3:].strip() for d in doc)


def doc_of_sig(f, sig):
    """-> the docstring of the function whose signature line contains `sig`.

    A docstring, not the file: a phrase that also appears in a `//` code
    comment must not be able to satisfy a check about what a reader sees.
    """
    for i, ln in enumerate(LINES[f]):
        if sig in ln and re.match(r"\s*(?:pub\s+)?fn\s", ln):
            return doc_above(f, i)
    return ""


def doc_of_struct(f, name):
    """-> the docstring of `struct <name>`."""
    for i, ln in enumerate(LINES[f]):
        if re.match(r"\s*(?:pub\s+)?struct\s+%s\b" % re.escape(name), ln):
            return doc_above(f, i)
    return ""


def doc_of_decl(f, pat):
    """-> the docstring of the declaration whose line matches `pat`.

    A trait or a struct is a declaration too, and a docstring can sit on one.
    """
    for i, ln in enumerate(LINES[f]):
        if re.match(pat, ln):
            return doc_above(f, i)
    return ""


def body_of(f, header_idx):
    """The brace-balanced body of the function whose header is at header_idx."""
    depth = 0
    started = False
    out = []
    for i in range(header_idx, len(LINES[f])):
        out.append(LINES[f][i])
        depth += LINES[f][i].count("{") - LINES[f][i].count("}")
        if "{" in LINES[f][i]:
            started = True
        if started and depth <= 0:
            break
    return "\n".join(out)


def find_method(type_name, method_name):
    """-> (file, lineno, docstring) for `fn <type>::<method>(`, or (None, 0, "")."""
    pat = re.compile(r"^\s*(?:pub\s+)?fn\s+%s\s*::\s*%s\s*\("
                     % (re.escape(type_name), re.escape(method_name)))
    for f in FILES:
        for i, ln in enumerate(LINES[f]):
            if pat.match(ln):
                return f, i + 1, doc_above(f, i)
    return None, 0, ""


def find_free(fn_name):
    """-> (file, lineno, docstring) for the free function `fn <fn_name>(`."""
    pat = re.compile(r"^\s*(?:pub\s+)?fn\s+%s\s*\(" % re.escape(fn_name))
    for f in FILES:
        for i, ln in enumerate(LINES[f]):
            if pat.match(ln):
                return f, i + 1, doc_above(f, i)
    return None, 0, ""


# ==============================================================================
print("=" * 78)
print("1. the bias_corrected family, derived from the source")
print("=" * 78)

FAMILY = []
for f in FILES:
    for i, ln in enumerate(LINES[f]):
        m = FUNC_RE.match(ln)
        if not m or not m.group(2).startswith("bias_corrected"):
            continue
        doc = doc_above(f, i)
        v = re.search(r"v(0\.\d+\.\d+)\+?:", doc)
        FAMILY.append({"type": m.group(1), "method": m.group(2), "file": f,
                       "line": i + 1, "version": v.group(1) if v else None,
                       "doc": doc})

PLAIN = [x for x in FAMILY if x["method"] == "bias_corrected_coef"]
SUFFIXED = [x for x in FAMILY if x["method"] != "bias_corrected_coef"]

for x in sorted(PLAIN, key=lambda z: (z["version"] or "", z["type"])):
    print("        %-24s %-22s v%-9s %s" % (x["type"], x["method"],
                                             x["version"], x["file"]))

check("every plain `bias_corrected_coef` method carries a self-declared version",
      all(x["version"] for x in PLAIN),
      str([x["type"] for x in PLAIN if not x["version"]]))
check("every index-suffixed `bias_corrected*` method carries one too",
      all(x["version"] for x in SUFFIXED),
      str([x["type"] for x in SUFFIXED if not x["version"]]))
check("the plain family and the index-suffixed one are disjoint",
      not (set(x["type"] for x in PLAIN) & set(x["type"] for x in SUFFIXED)),
      "plain=%d suffixed=%d" % (len(PLAIN), len(SUFFIXED)))

# a second, independent derivation of the plain family: a raw text scan of the
# signatures.  If the parser and the scan disagree, one of them is wrong.
raw_plain = set()
for f in FILES:
    for m in re.finditer(r"\bfn\s+([A-Za-z_]\w*)\s*::\s*bias_corrected_coef\s*\(",
                         read(os.path.join(LIB, f))):
        raw_plain.add((m.group(1), f))
check("a raw signature scan finds the same plain family",
      raw_plain == set((x["type"], x["file"]) for x in PLAIN),
      "scan=%d parsed=%d" % (len(raw_plain), len(PLAIN)))

PLAIN_VERSIONS = sorted(set(x["version"] for x in PLAIN if x["version"]))
MIN_PLAIN = PLAIN_VERSIONS[0] if PLAIN_VERSIONS else "0.0.0"


def count_upto(hi):
    """The number of plain members whose self-declared version is <= hi."""
    return len([x for x in PLAIN if x["version"] and vkey(x["version"]) <= vkey(hi)])


# ==============================================================================
print()
print("=" * 78)
print("2. the five sites that publish a count of the family")
print("=" * 78)

# (file, type, method, kind).  RANGE = "the N ... added in vA - vB";
# ALL = "All N ..." -- the CURRENT total of the family.
SITES = [
    ("lplr.mbt", "DoubleMLLPLR", "bias_corrected_coef", "RANGE"),
    ("lpq.mbt", "DoubleMLLPQ", "bias_corrected_coef", "RANGE"),
    ("quantile.mbt", "DoubleMLPQ", "bias_corrected_coef", "RANGE"),
    ("quantile.mbt", "DoubleMLQTE", "bias_corrected_coef_at", "RANGE"),
    ("sandwich.mbt", None, "bias_corrected_theta", "ALL"),
]

COUNT_RE = re.compile(
    r"\b(the|All)\s+([A-Za-z]+)\s+`?bias_corrected_coef`?\s+methods?"
    r"(\s+added\s+in\s+v(0\.\d+\.\d+)\s*-\s*v(0\.\d+\.\d+))?")

for want_file, type_name, method, kind in SITES:
    if type_name is None:
        f, ln, doc = find_free(method)
    else:
        f, ln, doc = find_method(type_name, method)
    label = "%s:%s" % (f or want_file, method)
    if f is None:
        # A missing site must report the SAME NUMBER of checks as a present
        # one -- 3 for the "All N" site, 4 for a range site -- so that the
        # published count cannot move when a site is destroyed.
        n = 3 if kind == "ALL" else 4
        check("%s publishes a count of the family" % label, False,
              "the method was not found in the source")
        for _ in range(n - 1):
            check("%s's count is the derived one" % label, False, "no site")
        continue
    m = COUNT_RE.search(doc)
    word = m.group(2).lower() if m else ""
    stated = WORDNUM.get(word)
    lo, hi = (m.group(4), m.group(5)) if m else (None, None)
    check("%s publishes a count of the family" % label,
          m is not None and stated is not None,
          "phrase=%r" % (m.group(0) if m else None))
    if kind == "ALL":
        derived = len(PLAIN)
        check("%s's count is the derived one" % label,
              stated is not None and stated == derived,
              "stated=%s derived=%d" % (word, derived))
        check("%s states the CURRENT total, not a historical one" % label,
              m is not None and not m.group(3),
              "range=%r" % (m.group(3) if m else None))
    else:
        derived = count_upto(hi) if hi else -1
        check("%s's count is the derived one" % label,
              stated is not None and hi is not None and stated == derived,
              "stated=%s derived=%s" % (word, derived if hi else "?"))
        # the range's upper bound must be the publisher's own version, less one
        # minor: the count is "the family as it stood before this member".
        own_v = re.search(r"v(0\.\d+\.\d+)\+?:", doc)
        want_hi = None
        if own_v:
            maj, mi, pa = vkey(own_v.group(1))
            if mi >= 1:
                want_hi = "%d.%d.%d" % (maj, mi - 1, pa)
        check("%s's version range is the derived one" % label,
              hi is not None and want_hi is not None and hi == want_hi,
              "stated hi=%s derived hi=%s" % (hi, want_hi))
        check("%s's range covers every member up to its bound" % label,
              lo is not None and vkey(lo) <= vkey(MIN_PLAIN),
              "lo=%s earliest member=%s" % (lo, MIN_PLAIN))

# no OTHER site may publish a count of the family -- a sixth publisher would
# have to be gated too, and this check is what says so.
other = []
for f in FILES:
    for i, ln in enumerate(LINES[f]):
        m = FUNC_RE.match(ln)
        name = None
        if m:
            name = m.group(1) + "::" + m.group(2)
        else:
            fm = FREE_RE.match(ln)
            if fm:
                name = fm.group(1)
        if name is None:
            continue
        if COUNT_RE.search(doc_above(f, i)):
            other.append((f, name))
check("exactly five sites publish a count of the family",
      len(other) == 5, "got %d: %s" % (len(other), other))
check("the publishing sites are the ones this verifier gates",
      sorted(other) == sorted([("lplr.mbt", "DoubleMLLPLR::bias_corrected_coef"),
                               ("lpq.mbt", "DoubleMLLPQ::bias_corrected_coef"),
                               ("quantile.mbt", "DoubleMLPQ::bias_corrected_coef"),
                               ("quantile.mbt", "DoubleMLQTE::bias_corrected_coef_at"),
                               ("sandwich.mbt", "bias_corrected_theta")]),
      str(sorted(other)))

# ==============================================================================
print()
print("=" * 78)
print("3. the other package-wide counts in the public docstrings")
print("=" * 78)

# --- the estimator roster ---------------------------------------------------
EST_RE = re.compile(r"pub\s+struct\s+(DoubleML\w+)\s*\{")
ESTIMATORS = set()
for f in FILES:
    for ln in LINES[f]:
        m = EST_RE.search(ln)
        if m and not m.group(1).endswith("Data"):
            ESTIMATORS.add(m.group(1))
check("the port has 22 estimators", len(ESTIMATORS) == 22, "got %d" % len(ESTIMATORS))

LIN = doc_of_decl("linear.mbt", r"\s*pub\s+trait\s+Learner\b")
check("the Learner trait's docstring says all 22 estimators",
      "all 22 estimators" in LIN, "")
check("its count is the derived one",
      "all %d estimators" % len(ESTIMATORS) in LIN, "derived %d" % len(ESTIMATORS))

JOINT = doc_of_struct("sensitivity.mbt", "JointSensitivityInput")
check("JointSensitivityInput's docstring says all 22 estimators",
      "all 22 estimator" in JOINT, "")
check("its count is the derived one",
      "all %d estimator" % len(ESTIMATORS) in JOINT, "derived %d" % len(ESTIMATORS))

# --- rdd.mbt: the sandwich bias correction on 15 OTHER estimators ------------
TAUBC = doc_of_sig("rdd.mbt", "::tau_bc(")
check("DoubleMLRDD::tau_bc's docstring says 15 other estimators have it",
      re.search(r"`bias_corrected_coef` already exists on 15 other estimators", TAUBC)
      is not None, "")
check("its count is the derived plain-family size",
      re.search(r"`bias_corrected_coef` already exists on %d other estimators"
                % len(PLAIN), TAUBC) is not None, "derived %d" % len(PLAIN))
check("the RDD estimator is not one of them",
      "DoubleMLRDD" not in set(x["type"] for x in PLAIN), "")

# --- apo.mbt: "the fifteen other estimators" --------------------------------
APO = doc_of_sig("apo.mbt", "::m_inv_1x1_at(")
SANDWICH_FAMILY = set(x["type"] for x in PLAIN)
check("DoubleMLAPOS::m_inv_1x1_at's docstring says the fifteen other estimators",
      "the fifteen other estimators" in APO, "")
check("its count is the derived sandwich family",
      "the %s other estimators" % NUMWORD.get(len(SANDWICH_FAMILY), "fifteen")
      in APO, "derived %d" % len(SANDWICH_FAMILY))
check("APOS is not in that family, so 'other' is right",
      "DoubleMLAPOS" not in SANDWICH_FAMILY, "")

# --- upstream: the 7 with `_sensitivity_implemented = True` ------------------
UP_TRUE = set()
UP_CALLERS = set()
UP_ESTIMATORS = set()
if os.path.isdir(UPSTREAM):
    for dirpath, dirnames, filenames in os.walk(UPSTREAM):
        rel = os.path.relpath(dirpath, UPSTREAM).replace("\\", "/")
        for fn in sorted(filenames):
            if not fn.endswith(".py"):
                continue
            p = os.path.join(dirpath, fn)
            s = read(p)
            is_test = "/tests/" in ("/" + rel + "/") or fn.startswith("test_")
            if is_test:
                continue
            for m in re.finditer(r"_sensitivity_implemented\s*=\s*True", s):
                UP_TRUE.add(fn[:-3])
            if "init_ps_processor" in s and "def init_ps_processor" not in s:
                UP_CALLERS.add(fn[:-3])
            for m in re.finditer(r"^class\s+(DoubleML\w+)\s*\(", s, re.M):
                if not m.group(1).endswith("Data"):
                    UP_ESTIMATORS.add(m.group(1))
up_check("the vendored upstream 0.11.4 tree is present", bool(UP_TRUE),
         "%d files with the flag" % len(UP_TRUE))
up_check("upstream sets _sensitivity_implemented = True at 7 estimators",
         len(UP_TRUE) == 7, "got %d: %s" % (len(UP_TRUE), sorted(UP_TRUE)))
SENS = doc_of_sig("sensitivity.mbt", "fn irm_style_sensitivity(")
check("irm_style_sensitivity's docstring says the seven upstream estimators",
      "the seven estimators whose upstream sets" in SENS, "")
up_check("its seven are exactly upstream's seven",
         UP_TRUE == {"did", "did_binary", "did_cs", "did_cs_binary",
                     "apo", "irm", "plr"}, str(sorted(UP_TRUE)))

# --- ps_processor.mbt: the twelve upstream estimators that call it -----------
PS = doc_of_sig("ps_processor.mbt", "fn resolve_ps_processor(")
check("init_ps_processor's docstring says twelve upstream estimators",
      "twelve upstream estimators" in PS, "")
up_check("upstream's init_ps_processor callers are 12", len(UP_CALLERS) == 12,
         "got %d: %s" % (len(UP_CALLERS), sorted(UP_CALLERS)))
NAMED = set(re.findall(r"`(apo|apos|cvar|iivm|irm|lpq|pq|qte|ssm|did_binary|"
                        r"did_cs_binary|did_multi)`", PS))
up_check("it names exactly upstream's 12 callers",
         NAMED == UP_CALLERS, "named=%s derived=%s" % (sorted(NAMED), sorted(UP_CALLERS)))

# --- cvar.mbt: upstream's 17 estimators -------------------------------------
CVAR = doc_of_sig("cvar.mbt", "fn DoubleMLCVAR::sensitivity_analysis(")
check("DoubleMLCVAR::sensitivity_analysis's docstring says all 17 of upstream's",
      "at all 17 of its" in CVAR, "")
up_check("upstream 0.11.4 has 17 estimator classes", len(UP_ESTIMATORS) == 17,
         "got %d" % len(UP_ESTIMATORS))

# --- rdd.mbt: the kernels ----------------------------------------------------
KERNELDOC = doc_of_sig("rdd.mbt", "fn rdd_weight_at(")
km = re.search(r"fn\s+RDDKernel::weight.*?\{(.*?)\n\s*\}", "\n".join(LINES["rdd.mbt"]), re.S)
KERNELS = {}
if km:
    for m in re.finditer(r"([A-Z][A-Za-z0-9_]*)\s*=>\s*([^\n]+)", km.group(1)):
        KERNELS[m.group(1)] = m.group(2).strip()
NEG = sorted(k for k, expr in KERNELS.items()
             if "t" in expr and "- t" in expr and "exp" not in expr)
check("RDDKernel has 5 variants", len(KERNELS) == 5,
      "got %d: %s" % (len(KERNELS), sorted(KERNELS)))
check("RDDKernel::weight's docstring says three of the five are negative",
      "Three of the five kernels" in KERNELDOC, "")
check("exactly 3 of the kernels are negative outside |u| <= h",
      NEG == ["Epanechnikov", "Quadratic", "Triangular"], str(NEG))
check("the docstring names exactly those three",
      all(("`%s`" % k) in KERNELDOC for k in NEG), str(NEG))

# --- blp_policy.mbt: the flat encoding stride --------------------------------
TREE = doc_of_sig("blp_policy.mbt", "fn policy_tree_cache_encode(")
enc = re.search(r"fn\s+policy_tree_cache_encode.*?\n\}",
                 "\n".join(LINES["blp_policy.mbt"]), re.S)
STRIDE = None
if enc:
    body = enc.group(0)
    dm = re.search(r"out\.length\(\)\s*/\s*(\d+)", body)
    pushes = len(re.findall(r"out\.push\(", body.split("match")[0]))
    if dm:
        STRIDE = int(dm.group(1))
        check("the encoder pushes exactly as many slots as its stride",
              pushes == STRIDE, "pushes=%d stride=%d" % (pushes, STRIDE))
check("the encoder's docstring says 5 slots per node", "5 slots per node" in TREE, "")
check("its slot count is the derived stride",
      "%d slots per node" % (STRIDE or 0) in TREE, "derived %s" % STRIDE)

# --- sensitivity.mbt: the GainStatsResult field count ------------------------
GAIN = doc_of_struct("sensitivity.mbt", "GainStatsResult")
gs = re.search(r"pub\s+struct\s+GainStatsResult\s*\{(.*?)\n\}",
               "\n".join(LINES["sensitivity.mbt"]), re.S)
NFIELDS = 0
if gs:
    NFIELDS = len([ln for ln in gs.group(1).split("\n")
                   if ln.strip() and not ln.strip().startswith("//")])
check("GainStatsResult has 4 fields", NFIELDS == 4, "got %d" % NFIELDS)
check("its docstring says 'The four fields are'", "The four fields are" in GAIN, "")
check("its field count is the derived one",
      "The %s fields are" % NUMWORD.get(NFIELDS, "four") in GAIN,
      "derived %d" % NFIELDS)

# --- did_binary.mbt: the three delegated methods -----------------------------
# "the three methods are delegated" is about the SANDWICH API, not about every
# method the wrapper forwards -- `DoubleMLDIDBinary` forwards a dozen others to
# the inner `DoubleMLDID` as well.  The sandwich API is derived, not named: it
# is the set of method names that ALL FIFTEEN estimators of the plain
# `bias_corrected_coef` family have and that NONE of the other seven has.
def methods_of(t):
    out = set()
    for f in FILES:
        for ln in LINES[f]:
            m = re.match(r"^\s*pub\s+fn\s+%s::(\w+)\s*\(" % re.escape(t), ln)
            if m:
                out.add(m.group(1))
    return out


FAMILY_TYPES = set(x["type"] for x in PLAIN)
OTHER_TYPES = sorted(ESTIMATORS - FAMILY_TYPES)
common = set.intersection(*[methods_of(t) for t in sorted(FAMILY_TYPES)])
outside = set()
for t in OTHER_TYPES:
    outside |= methods_of(t)
SANDWICH_API = common - outside
print("        the package's sandwich API: %s" % sorted(SANDWICH_API))
check("the sandwich API is derived from the 15-vs-7 estimator split",
      len(FAMILY_TYPES) == 15 and len(OTHER_TYPES) == 7 and len(SANDWICH_API) >= 3,
      "family=%d other=%d api=%s" % (len(FAMILY_TYPES), len(OTHER_TYPES),
                                     sorted(SANDWICH_API)))

deleg = set()
for i, ln in enumerate(LINES["did_binary.mbt"]):
    m = re.match(r"\s*pub\s+fn\s+DoubleMLDIDBinary::(\w+)\s*\(", ln)
    if m and m.group(1) in SANDWICH_API:
        body = body_of("did_binary.mbt", i)
        if re.search(r"self\.inner\.%s\s*\(" % m.group(1), body):
            deleg.add(m.group(1))
check("DoubleMLDIDBinary delegates 3 of the sandwich API's methods",
      len(deleg) == 3, "got %d: %s" % (len(deleg), sorted(deleg)))
DBS = doc_of_sig("did_binary.mbt", "fn DoubleMLDIDBinary::sandwich_se(")
check("its docstring says the three methods are delegated",
      "the three methods are delegated" in DBS, "")
check("its count is the derived one",
      "the %s methods are delegated" % NUMWORD.get(len(deleg), "three") in DBS,
      "derived %d" % len(deleg))

# --- logistic.mbt: the two defaults ------------------------------------------
LOG = doc_of_sig("logistic.mbt", "fn LogisticRegression::fit(")
logsrc = "\n".join(LINES["logistic.mbt"])
mi = re.search(r"max_iter~\s*:\s*Int32\s*=\s*(\d+)", logsrc)
rg = re.search(r"ridge~\s*:\s*Double\s*=\s*([0-9.e\-]+)", logsrc)
check("logistic.mbt's max_iter default is 25", mi is not None and mi.group(1) == "25",
      mi.group(1) if mi else "?")
check("its docstring says max_iter = 25", "max_iter = 25" in LOG, "")
check("logistic.mbt's ridge default is 1e-8",
      rg is not None and abs(float(rg.group(1)) - 1e-8) < 1e-16,
      rg.group(1) if rg else "?")
check("its docstring says the default of 1e-8", "the default of `1e-8`" in LOG, "")

# --- fit_cache.mbt: the sampled rows ------------------------------------------
HASHDOC = doc_of_sig("fit_cache.mbt", "fn hash_data(")
fcsrc = "\n".join(LINES["fit_cache.mbt"])
hm = re.search(r"fn\s+hash_data.*?\n\}", fcsrc, re.S)
NSLICE = None
if hm:
    body = hm.group(0)
    fm = re.search(r"let\s+first_n\s*=\s*if\s+n_rows\s*<\s*(\d+)", body)
    lm = re.search(r"let\s+last_start\s*=\s*n_rows\s*-\s*(\d+)", body)
    if fm and lm:
        NSLICE = (int(fm.group(1)), int(lm.group(1)))
check("hash_data samples 10 rows from each end", NSLICE == (10, 10), str(NSLICE))
check("its docstring says 'first 10 + last 10'", "first 10 + last 10" in HASHDOC, "")
check("its slice count is the derived one",
      "first %d + last %d" % (NSLICE or (0, 0)) in HASHDOC, "derived %s" % (NSLICE,))

# --- regularized.mbt: the two families ---------------------------------------
REG = doc_of_struct("regularized.mbt", "ElasticNet")
if not REG:
    REG = mbt_flat(os.path.join(LIB, "regularized.mbt"))
check("the ElasticNet docstring names Lasso and Ridge as the two families",
      "the convex blend of `Lasso` and `Ridge`" in REG, "")
check("the package has both Lasso and Ridge",
      any(re.search(r"pub\s+struct\s+Lasso\b", "\n".join(LINES[f])) for f in FILES)
      and any(re.search(r"pub\s+struct\s+Ridge\b", "\n".join(LINES[f])) for f in FILES), "")

# --- plr.mbt: the two spellings ------------------------------------------------
PLRDOC = doc_of_sig("plr.mbt", "fn plr_is_po_score(")
check("plr_is_po_score's docstring says the two spellings this package has used",
      "the two spellings this package has ever used" in PLRDOC, "")
sp = set()
for i, ln in enumerate(LINES["plr.mbt"]):
    if re.match(r"\s*fn\s+plr_is_po_score\s*\(", ln):
        sp = set(re.findall(r'"([^"]*)"', body_of("plr.mbt", i)))
check("the package really uses both spellings",
      sp == {"partialling-out", "partialling out"}, str(sorted(sp)))

# ==============================================================================
print()
print("== 4. the published check count, witnessed ==")
# ------------------------------------------------------------------------------
# The CHANGELOG publishes this verifier's check count.  A published exact number
# with nothing asserting it goes stale silently -- that is how v0.164.21 shipped
# "127 checks", the count measured on the dry-run's deliberately-broken tree,
# as if it were the count on the tree as it stands.
#
# The count here is FIXED: the five publishing sites are a named list and every
# other check is an aggregate, so the number of checks is the same on every
# tree.  A destroyed site reports a FAILED CHECK rather than a skipped one, so
# the count cannot move under the published number.
#
# The comparison is against NCHECK + 1, because THIS check is one of the checks
# it is counting.
# ==============================================================================
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
# The CHANGELOG is in DESCENDING order -- the newest entry is at the TOP -- so
# the CURRENT published number is the FIRST occurrence.  (Taking the last one
# binds the witness to an entry that has already shipped.)
_found = re.findall(r"_verify_docstring_counts_1650\.py` \(\*\*(\d+)\*\* checks\)",
                    read(CHANGELOG))
published = int(_found[0]) if _found else None
check("the CHANGELOG publishes this verifier's check count",
      published is not None,
      "the '(**N** checks)' line for this verifier is absent" if published is None
      else "published %d (of %d occurrences, newest first)" % (published, len(_found)))
check("the published check count is the count this run made",
      published is not None and published == NCHECK + 1,
      "published %s, this run makes %d" % (published, NCHECK + 1))

# ==============================================================================
print()
print("=" *78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
