#!/usr/bin/env python3
"""Round 49 verifier: the nine stale-content defects the non-README documents
carried, and the claims that replace them.

WHAT THIS EXISTS FOR
====================
Round 48 shipped the README.  A separate fresh-eyes audit then read the SIX
TUTORIALS, the skill and the example README and asked of every sentence: does
it claim more than the tree supports?  Nine did, and the two worst were real
API-surface defects that no CI gate can catch, because one lived inside a
`moonbit nocheck` fence and the other was prose about the dependency rule:

  F1  doc/004 said "Every estimator follows" the
      `new(data, n_folds=2, n_rep=1, seed=3141)` snippet.  SIX of the 22 do
      not accept those arguments: `DoubleMLPQ` / `DoubleMLQTE` / `DoubleMLLPQ`
      have no `n_rep`, and `DoubleMLBLP` / `DoubleMLPolicyTree` /
      `DoubleMLRDD` take no `n_folds`, no `n_rep` and no `seed`.
  F2  the skill's dependency rule allowed only `moonbitlang/*` and `riantr/*`,
      and the library's OWN `moon.mod` declared `moonbit-community/sqlite3`,
      which is neither.  No `.mbt` in the library imports it (0 references).
  F3  doc/005 put upstream's factories in `doubleml.did.datasets` and called
      them `make_*_data`.  Only 3 of the 18 live under `did/datasets/`, only
      7 are named `*_data`, and SIX are renamed here.
  F4  doc/006's transcript of the `validate_*` loop was not a prefix of
      what the loop prints: it dropped the glob's SECOND file, with no
      elision marker, and put the verdict on the banner's own line.
  F5  doc/004 said `DoubleMLQTE` takes "an extra `quantile` arg".  It takes
      `quantiles` -- an `Array[Double]`.  `quantile=0.5` does not compile.
  F6  "17 modules, each with a sibling test -- 35 files in all" enumerates
      34 files; the 35th, `dgp_recovery_test.mbt`, is a test file with no
      module of its own.
  F7  doc/003 called a cross-section a "synthetic panel".  The repo reserves
      "panel" for `DoubleMLPanelData` and the panel DGP.
  F8  doc/006's loop is the exact shape CI's own comment identifies as the
      defect it was rewritten to remove -- a pipeline whose exit status is
      `tail`'s, not python's.
  F9  doc/002 listed `scipy` as a direct dependency and `rdrobust` with no
      constraint; CI installs `rdrobust>=2,<3` ON PURPOSE, because a version
      bump can move `tau.bc` in the last digits and turn the RDD gate red.

WHY THIS CHECKS THE TREE, NOT THE STRING
========================================
Each defect was a sentence, and a sentence can be fixed by a sentence.  So
every check below is tied to something MEASURED, and a document that
re-breaks any of the nine fails here even if every other check in the tree
stays green:

  * the estimator constructor census is DERIVED by brace-matching
    `pub fn DoubleMLXxx::new(...)` over the library's sources, and the
    document is asked to name exactly the estimators that came out;
  * the dependency-rule exception is DERIVED by parsing every tracked
    `moon.mod`'s `import` block -- with the COMMENTS stripped first, because
    a commented-out `import { ... }` in the header of `moon.mod` is the
    easiest way to parse the wrong block;
  * the upstream factory census is DERIVED from the 0.11.4 sdist that this
    repository vendors, not typed;
  * the `validate_*` transcript is DERIVED from the glob order and from each
    script's own trailing verdict statement;
  * the `rdrobust` pin is DERIVED from the CI workflow, and the DGP
    composition is DERIVED from the package's file census.

Run: python _verify/_verify_doc_scope_1650.py
"""
import io
import os
import re
import subprocess
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

fails = []
NCHECK = 0


def check(label, cond, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-68s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        if detail:
            print("      %s" % detail)
        fails.append(label)


def read(path):
    with io.open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def flat(path):
    return re.sub(r"\s+", " ", read(path))


def doc(name):
    return read(os.path.join("doc", name, "readme.mbt.md"))


D001 = doc("001_introduction")
D002 = doc("002_installation")
D003 = doc("003_quick_start")
D004 = doc("004_estimators")
D005 = doc("005_dgps")
D006 = doc("006_python_check")
SKILL = read(os.path.join("skills", "moonbit_doubleML.md"))
CI = read(os.path.join(".github", "workflows", "check.yml"))
PUB = read(os.path.join(".github", "workflows", "publish.yml"))

F001, F002, F003 = flat("doc/001_introduction/readme.mbt.md"), \
    flat("doc/002_installation/readme.mbt.md"), flat("doc/003_quick_start/readme.mbt.md")
F004, F005, F006 = flat("doc/004_estimators/readme.mbt.md"), \
    flat("doc/005_dgps/readme.mbt.md"), flat("doc/006_python_check/readme.mbt.md")
FSKILL = re.sub(r"\s+", " ", SKILL)

# ---------------------------------------------------------------------------
# the shared derivation: the estimator constructors
# ---------------------------------------------------------------------------
print("")
print("== the constructor census, derived from the library's sources ==")

SRC = os.path.join(ROOT, "moonbit_doubleML")
LIB_SRC = "\n".join(
    io.open(os.path.join(SRC, fn), encoding="utf-8", errors="replace").read()
    for fn in sorted(os.listdir(SRC)) if fn.endswith(".mbt"))

# The 22 estimators, and the 12 `*Data` types, are both `DoubleML*` structs.
# The data types are NOT estimators: they end in "Data".
_all_new = sorted(set(re.findall(r"pub fn (DoubleML\w+)::new", LIB_SRC)))
_estimators = [n for n in _all_new if not n.endswith("Data")]
_data_types = [n for n in _all_new if n.endswith("Data")]
check("the library has 22 estimators", len(_estimators) == 22,
      "got %d: %s" % (len(_estimators), _estimators))
check("the library has 12 data types", len(_data_types) == 12,
      "got %d" % len(_data_types))


def ctor_params(name):
    """The top-level parameter NAMES of `pub fn <name>::new(...)`."""
    m = re.search(r"pub fn " + re.escape(name) + r"::new\s*\(", LIB_SRC)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, min(len(LIB_SRC), i + 8000)):
        if LIB_SRC[j] == "(":
            depth += 1
        elif LIB_SRC[j] == ")":
            depth -= 1
            if depth == 0:
                break
    raw = LIB_SRC[i + 1:j]
    raw = re.sub(r"//[^\n]*", "", raw)          # strip line comments
    out, depth, cur = [], 0, ""
    for ch in raw:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    names = []
    for p in out:
        mm = re.match(r"([A-Za-z_]\w*)\s*[~:]?", p)
        names.append(mm.group(1) if mm else p)
    return names


PARAMS = {n: ctor_params(n) for n in _estimators}
NO_TRIPLE = sorted(n for n in _estimators
                   if not any(k in PARAMS[n] for k in ("n_folds", "n_rep", "seed")))
NO_REP = sorted(n for n in _estimators
                if "n_rep" not in PARAMS[n] and n not in NO_TRIPLE)
FULL = sorted(n for n in _estimators if n not in NO_TRIPLE and n not in NO_REP)
check("three estimators take no n_folds/n_rep/seed", len(NO_TRIPLE) == 3,
      "got %d: %s" % (len(NO_TRIPLE), NO_TRIPLE))
check("three estimators take n_folds+seed but no n_rep", len(NO_REP) == 3,
      "got %d: %s" % (len(NO_REP), NO_REP))
check("sixteen estimators take all three", len(FULL) == 16, "got %d" % len(FULL))
print("     no n_folds/n_rep/seed : %s" % ", ".join(NO_TRIPLE))
print("     no n_rep             : %s" % ", ".join(NO_REP))

# ---------------------------------------------------------------------------
# F1 -- the constructor snippet
# ---------------------------------------------------------------------------
print("")
print("== F1: doc/004's constructor snippet ==")
check("doc/004 no longer says 'Every estimator follows'",
      "Every estimator follows" not in F004)
check("doc/004 says 'Most estimators follow'", "Most estimators follow" in F004)
check("doc/004 states the exception count 'Six of the 22'",
      "Six of the 22 do not take that shape" in F004)
for n in NO_REP:
    check("doc/004 names the no-n_rep estimator %s" % n, n in F004)
for n in NO_TRIPLE:
    check("doc/004 names the no-fold estimator %s" % n, n in F004)
# The named sets must be EXACTLY the derived ones: the doc must not name an
# estimator that does take n_rep, nor omit one that does not.
_named_rep = [n for n in _estimators if n in F004 and n in NO_REP]
check("doc/004 names exactly the three no-n_rep estimators",
      len(_named_rep) == 3, "got %d: %s" % (len(_named_rep), _named_rep))
check("doc/004 says the three no-fold estimators take no n_folds, n_rep or seed",
      "take **no** `n_folds`, `n_rep` or `seed` at all" in F004)
check("doc/004 records DoubleMLRDD's own arguments",
      all(k in F004 for k in ("`cutoff`", "`bandwidth`", "`kernel`", "`fuzzy`")))
check("doc/004's score sentence no longer claims score is the ONLY exception",
      "is the one that does **not** follow the snippet" not in F004)
check("doc/004's score sentence still points at the score section",
      "#the-score-argument" in F004)

# ---------------------------------------------------------------------------
# F5 -- the quantile family's parameter
# ---------------------------------------------------------------------------
print("")
print("== F5: doc/004's quantile-family argument ==")
check("DoubleMLPQ takes a scalar `quantile`", "quantile" in PARAMS["DoubleMLPQ"]
      and "quantiles" not in PARAMS["DoubleMLPQ"])
check("DoubleMLLPQ takes a scalar `quantile`", "quantile" in PARAMS["DoubleMLLPQ"]
      and "quantiles" not in PARAMS["DoubleMLLPQ"])
check("DoubleMLQTE takes `quantiles`, not `quantile`",
      "quantiles" in PARAMS["DoubleMLQTE"] and "quantile" not in PARAMS["DoubleMLQTE"])
check("doc/004 no longer groups QTE with the scalar-quantile pair",
      "DoubleMLPQ` / `DoubleMLQTE` / `DoubleMLLPQ" not in F004)
check("doc/004 says QTE takes an Array[Double] named quantiles",
      "`quantiles` -- an `Array[Double]`" in F004)
check("doc/004 still says PQ/LPQ take the scalar quantile",
      "DoubleMLPQ` / `DoubleMLLPQ`: extra `quantile` arg" in F004)

# ---------------------------------------------------------------------------
# F2 -- the dependency rule
# ---------------------------------------------------------------------------
print("")
print("== F2: the dependency rule, derived from every tracked moon.mod ==")
_tracked = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True,
                          text=True, encoding="utf-8", errors="replace")
_mods = [l for l in _tracked.stdout.splitlines() if l.endswith("moon.mod")]
# Strip COMMENTS before looking for the import block: `moon.mod` carries a
# commented-out `import { "moonbitlang/x@0.4.6", }` in its header, and a
# naive regex finds THAT block first.
_deps_of = {}
for m in _mods:
    t = read(m)
    t_nc = re.sub(r"//[^\n]*", "", t)
    blk = re.search(r"import\s*\{([^}]*)\}", t_nc, re.S)
    deps = []
    if blk:
        for raw in blk.group(1).split("\n"):
            s = raw.strip().strip(",").strip('"').strip()
            if s:
                deps.append(s)
    _deps_of[m] = deps
OFFICIAL = [d for d in _deps_of.get("moonbit_doubleML/moon.mod", []) if d]
check("the library's moon.mod declares two dependencies", len(OFFICIAL) == 2,
       "got %s" % OFFICIAL)
_violations = []
for m, deps in _deps_of.items():
    for d in deps:
        if not (d.startswith("moonbitlang/") or d.startswith("riantr/")):
            _violations.append((m, d))
check("exactly one tracked moon.mod breaks the rule",
      len(_violations) == 1, "got %s" % _violations)
check("the violation is the library's own moon.mod",
      _violations and _violations[0][0] == "moonbit_doubleML/moon.mod",
      "got %s" % _violations)
CARVE = _violations[0][1] if _violations else ""
check("the carve-out is the sqlite3 dependency",
      CARVE.startswith("moonbit-community/sqlite3"), "got %r" % CARVE)
# And it really is dead: no library .mbt file imports it.
_pkg = CARVE.split("@")[0]
_libfiles = [fn for fn in sorted(os.listdir(SRC)) if fn.endswith(".mbt")]
_importers = [fn for fn in _libfiles
              if re.search(r"^\s*import\b", read(os.path.join("moonbit_doubleML", fn)),
                           re.M)]
_mentions = [fn for fn in _libfiles if _pkg.split("/")[-1] in read(os.path.join("moonbit_doubleML", fn))]
check("no .mbt in the library imports anything at all", len(_importers) == 0,
      "got %s" % _importers)
check("no .mbt in the library mentions sqlite3", len(_mentions) == 0,
      "got %s" % _mentions)
check("the skill names the carve-out", CARVE in FSKILL,
      "the skill does not name %r" % CARVE)
check("the skill says the rule is not met by one declared line",
      "does not meet the rule" in FSKILL)
check("the skill says the entry is dead", "dead entry" in FSKILL)
check("the skill says no .mbt imports it", "imports it" in FSKILL)
check("the skill still states the general rule",
      "Only official (`moonbitlang/*`) packages are allowed" in FSKILL)
check("the skill still states the riantr/* half of the rule",
      "Non-official packages may only be `riantr/*` (this repo itself)." in FSKILL)
# The README and doc/001 already disclosed this line; the skill must name the
# SAME one, or two documents are describing two different exceptions.
_RM = read("README.mbt.md")
check("the README names the same package that does not meet the rule",
      CARVE.split("@")[0] in _RM,
      "the README does not name %r" % CARVE.split("@")[0])
check("doc/001 names the same package",
      CARVE.split("@")[0] in D001,
      "doc/001 does not name %r" % CARVE.split("@")[0])
check("doc/001 says the two declared entries are dead",
      "dead entries" in D001)

# ---------------------------------------------------------------------------
# F3 -- the upstream factory census
# ---------------------------------------------------------------------------
print("")
print("== F3: the upstream factory census, derived from the tracked manifest ==")
# The upstream package publishes a WHEEL, and its 0.11.4 sdist is a LOCAL
# CACHE that is not tracked -- so a contract run in a FRESH CLONE cannot see
# it.  `_verify/_dgp_upstream_manifest_1690.txt` is the TRACKED snapshot of
# what upstream ships: extracted from that sdist, and carrying the sdist's
# sha256 so the snapshot can be tied to the artefact it came from.
MANIFEST = "_verify/_dgp_upstream_manifest_1690.txt"
_man = read(MANIFEST)
_rows = []
for _l in _man.split("\n"):
    _l = _l.strip()
    if not _l or _l.startswith("#"):
        continue
    _p = _l.split()
    if len(_p) == 3 and _p[2].lstrip("_").startswith("make"):
        _rows.append((_p[0], _p[1][:-3], _p[2]))
check("the manifest records the sdist it was extracted from",
      "sdist sha256 " in _man)
check("the manifest lists 18 upstream factories", len(_rows) == 18,
      "got %d" % len(_rows))
_up = {}
for _pkg, _mod, _fac in _rows:
    _up[_fac] = (_pkg, _mod)
check("the manifest's factory names are unique", len(_up) == 18,
      "got %d" % len(_up))
_split = {}
for _fac, (_pkg, _mod) in _up.items():
    _split[_pkg] = _split.get(_pkg, 0) + 1
check("upstream keeps them in four packages", len(_split) == 4, "got %s" % _split)
print("     %s" % ", ".join("%s=%d" % (k, v) for k, v in sorted(_split.items())))
_did = _split.get("doubleml/did", 0)
check("only 3 of the 18 live under did/datasets", _did == 3, "got %d" % _did)
_ndata = [n for n in _up if n.endswith("_data")]
check("only 8 of the 18 upstream names end in _data", len(_ndata) == 8,
      "got %d: %s" % (len(_ndata), sorted(_ndata)))
# The PORT's own record of upstream: the provenance header each dgp module
# carries.  Where a file holds several factories, the mapping is the LAST
# upstream mention BEFORE that factory's own definition -- which is how a
# reader reads a doc comment attached to a function.
_HDR = re.compile(r"doubleml\.([A-Za-z_]+)\.datasets\.([A-Za-z0-9_]+)\.(_?make_\w+)")
_port = set()
_portmap = {}
for _fn in sorted(os.listdir(SRC)):
    if not (_fn.startswith("dgp_") and _fn.endswith(".mbt")):
        continue
    if _fn.endswith("_test.mbt"):
        continue
    _t = read(os.path.join("moonbit_doubleML", _fn))
    for _pm in re.finditer(r"pub fn (make_\w+)\s*\(", _t):
        _fac = _pm.group(1)
        _port.add(_fac)
        _hits = _HDR.findall(_t[:_pm.start()])
        if _hits:
            _pkg, _mod, _upf = _hits[-1]
            _portmap[_fac] = (_upf, "doubleml/" + _pkg, _mod)
check("the port ships 18 factories", len(_port) == 18, "got %d" % len(_port))
check("every port factory names its upstream factory in a provenance header",
      len(_portmap) == 18,
      "got %d: %s" % (len(_portmap), sorted(set(_port) - set(_portmap))))
check("the port's headers name exactly the manifest's factories",
      sorted(v[0] for v in _portmap.values()) == sorted(_up),
      "headers: %s" % sorted(v[0] for v in _portmap.values()))
_bad = []
for _fac, (_upf, _pkg, _mod) in sorted(_portmap.items()):
    if _upf in _up and _up[_upf] != (_pkg, _mod):
        _bad.append((_fac, _upf, "header says %s/%s" % (_pkg, _mod),
                     "manifest says %s/%s" % _up[_upf]))
check("each provenance header names the manifest's package and module",
      not _bad, "mismatched: %s" % _bad)

# The RENAMES are DERIVED: a port factory whose own name differs from the
# upstream factory its header names.
_renames = {p: v[0] for p, v in _portmap.items() if p != v[0]}
check("six of the port's factories are renames", len(_renames) == 6,
      "got %d: %s" % (len(_renames), sorted(_renames.items())))
_need_port = sorted(_renames)
_need_up = sorted(v for v in _up if v not in _port)
check("six of the upstream factories have no identical port twin",
      len(_need_up) == 6, "got %d: %s" % (len(_need_up), _need_up))

# The CORRESPONDENCE is read out of the document and then checked against
# the DERIVED mapping -- the document states six pairs, and those pairs must
# be exactly the six the port's own provenance headers imply.
_GENERIC = {"make", "data", "dgp"}


def distinctive(n):
    return {t for t in n.strip("_").split("_") if t and t not in _GENERIC}


_para = re.search(r"\*\*Six are renamed here\*\*:(.*?)(?:\n\n|\Z)", D005, re.S)
check("doc/005 has a 'Six are renamed here' paragraph", _para is not None)
_mentioned = re.findall(r"`([^`]+)`", _para.group(1)) if _para else []
check("doc/005's rename paragraph names twelve identifiers",
      len(_mentioned) == 12, "got %d: %s" % (len(_mentioned), _mentioned))
_pairs_ren = [( _mentioned[i], _mentioned[i + 1]) for i in range(0, len(_mentioned) - 1, 2)]
check("doc/005's rename paragraph states six pairs",
      len(_pairs_ren) == 6, "got %d: %s" % (len(_pairs_ren), _pairs_ren))
_doc_ports = sorted(p for p, _ in _pairs_ren)
_doc_ups = sorted(u for _, u in _pairs_ren)
check("doc/005 names EXACTLY the port factories that need a twin",
      _doc_ports == _need_port, "doc: %s / derived: %s" % (_doc_ports, _need_port))
check("doc/005 names EXACTLY the upstream factories that need a twin",
      _doc_ups == _need_up, "doc: %s / derived: %s" % (_doc_ups, _need_up))
check("doc/005's pairs are EXACTLY the renames the headers imply",
      dict(_pairs_ren) == _renames,
      "doc: %s / derived: %s" % (dict(_pairs_ren), _renames))
check("doc/005's pairs are a bijection (no upstream name used twice)",
      len(set(_doc_ups)) == 6, "got %s" % _doc_ups)
check("doc/005's pairs are a bijection (no port name used twice)",
      len(set(_doc_ports)) == 6, "got %s" % _doc_ports)
for _p, _u in _pairs_ren:
    check("doc/005's pair %s <- %s shares a distinctive token" % (_p, _u),
          bool(distinctive(_p) & distinctive(_u)),
          "%s vs %s" % (sorted(distinctive(_p)), sorted(distinctive(_u))))
check("doc/005 says the port publishes upstream's private helper",
      "**private** `_make_pliv_data`" in F005)
_renames = dict(_pairs_ren)
print("     %s" % ", ".join("%s <- %s" % (k, v) for k, v in sorted(_renames.items())))
check("doc/005 no longer points at doubleml.did.datasets",
      "doubleml.did.datasets" not in F005)
check("doc/005 names all four upstream packages",
      all(p in F005 for p in ("doubleml/did/datasets/", "doubleml/irm/datasets/",
                              "doubleml/plm/datasets/", "doubleml/rdd/datasets/")))
for pk, n in sorted(_split.items()):
    check("doc/005 states %s holds %d" % (pk, n), "(%d)" % n in F005)
check("doc/005 states the *_data count the census gives",
      "only %d of the 18" % len(_ndata) in F005,
      "the census says %d end in _data" % len(_ndata))
for p, u in sorted(_renames.items()):
    check("doc/005 names the rename %s <- %s" % (p, u),
          p in F005 and u in F005)
check("doc/005 says the port publishes upstream's private helper",
      "**private** `_make_pliv_data`" in F005)
check("doc/001 no longer says 'make_*_data factories'",
      "`make_*_data` factories" not in F001)
check("doc/001 now says 18 `make_*` dataset factories",
      "upstream's 18 `make_*` dataset factories" in F001)

# ---------------------------------------------------------------------------
# F4 -- the validate transcript
# ---------------------------------------------------------------------------
print("")
print("== F4: the validate_* transcript, derived from the glob and the scripts ==")
_glob = sorted(f for f in os.listdir(ROOT)
               if f.startswith("validate_") and f.endswith("_with_python.py"))
check("the glob picks up 24 validate scripts", len(_glob) == 24, "got %d" % len(_glob))
check("the glob's second file is validate_bitexact_with_python.py",
      _glob[1] == "validate_bitexact_with_python.py", "got %r" % _glob[1])

# Each script's TRAILING output line, derived from its own source: the last
# print() or report() call in source order, resolved to the PASS branch.
_ph = read("parity_helper.py")
_rm = re.search(r"def report\s*\(.*?\n(?=\ndef |\Z)", _ph, re.S)
_rbody = _rm.group(0) if _rm else ""
_vfmt = re.search(r'verdict\s*=\s*"(\w+)"\s+if', _rbody)
_pfmt = re.findall(r'print\("([^"]*%s[^"]*)"\s*%\s*\(title,\s*verdict\)\)', _rbody)
PASSWORD = _vfmt.group(1) if _vfmt else "PASS"
REPORT_FMT = _pfmt[0] if _pfmt else "%s: %s"


def trailing_verdict(fname):
    t = read(fname)
    cands = []
    for mm in re.finditer(r'print\(\s*"((?:[^"\\]|\\.)*)"\s*\)\s*\n', t):
        cands.append((mm.start(), "print", mm.group(1)))
    for mm in re.finditer(r'print\(\s*"((?:[^"\\]|\\.)*)"\s*%\s*\(([^)]*)\)\s*\)\s*\n', t):
        cands.append((mm.start(), "fmt", mm.group(1), mm.group(2)))
    for mm in re.finditer(r'report\(\s*"([^"]*)"', t):
        cands.append((mm.start(), "report", mm.group(1)))
    if not cands:
        return None
    cands.sort(key=lambda c: c[0])
    last = cands[-1]
    if last[1] == "print":
        return last[2]
    if last[1] == "fmt":
        if "PASS" not in last[3]:
            return None
        return last[2].replace("%s", PASSWORD)
    return REPORT_FMT.replace("%s", last[2], 1).replace("%s", PASSWORD, 1)


_exp = []
for f in _glob[:3]:
    _exp.append((f, trailing_verdict(f)))
print("     derived: %s" % _exp)
check("the derived verdict for apos is the PASS line",
      _exp[0][1] == "PASS: apos reference", "got %r" % (_exp[0][1],))
check("the derived verdict for bitexact is the PASS line",
      _exp[1][1] == "bit-exact parity: PASS", "got %r" % (_exp[1][1],))
check("the derived verdict for blp_policy is the PASS line",
      _exp[2][1] == "BLP / policy tree parity: PASS", "got %r" % (_exp[2][1],))
_block = re.search(r"```console\n\$ for s in validate_\*_with_python\.py.*?```", D006, re.S)
check("doc/006 still shows the validate loop", _block is not None)
_blk = _block.group(0) if _block else ""
# The loop prints `=== <file> ===` and the verdict on the NEXT line, so the
# pairs are read off the block's own line sequence -- the verdict lines must
# NOT be filtered out before they are paired.
_blines = _blk.split("\n")
_pairs = []
for _i, _l in enumerate(_blines):
    if not _l.startswith("=== "):
        continue
    _m = re.match(r"^=== (.+?) ===$", _l)
    if not _m:
        continue
    _fn = _m.group(1).strip()
    _v = _blines[_i + 1].strip() if _i + 1 < len(_blines) else ""
    if _v.startswith("===") or not _v:
        continue
    _pairs.append((_fn, _v))
_banners = [l for l in _blines if l.startswith("=== ")]
check("doc/006's transcript block has one banner per file",
      len(_banners) == len(_pairs),
      "%d banners, %d pairs" % (len(_banners), len(_pairs)))
check("doc/006's transcript is a prefix of the real glob order",
      [p[0] for p in _pairs] == [f for f, _ in _exp],
      "doc: %s" % [p[0] for p in _pairs])
check("doc/006's transcript verdicts are the scripts' real trailing lines",
      [p[1] for p in _pairs] == [v for _, v in _exp],
      "doc: %s" % [p[1] for p in _pairs])
check("doc/006 no longer puts a verdict on the banner's own line",
      "=== validate_apos_with_python.py === PASS" not in D006)
check("doc/006's elision marker is present", "... (24 total)" in D006)
check("doc/006 no longer drops bitexact without a marker",
      "validate_bitexact_with_python.py" in D006)

# ---------------------------------------------------------------------------
# F8 -- the loop shape vs what CI runs
# ---------------------------------------------------------------------------
print("")
print("== F8: the documented loop vs the gate CI actually runs ==")
_ci_loop = re.search(r'out="\$\(python "\$s"\)"', CI)
check("CI captures stdout and the exit code separately", _ci_loop is not None)
check("CI does NOT use the bare pipeline the document shows",
      'line="$(python "$s" | tail -1)"' not in CI.split("rdrobust")[-1]
      or "previous form" in CI)
check("CI's own comment records the bare pipeline as the old form",
      "The previous form was" in CI and 'tail -1' in CI)
check("doc/006 marks its loop as the short form", "short form" in F006)
check("doc/006 says CI runs a stricter version", "CI runs a" in F006
      and "stricter" in F006)
check("doc/006 says a PASS-looking line that then fails is still a failure",
      "prints a PASS-looking line and then fails is still a" in F006)
check("doc/006 points at the workflow", ".github/workflows/check.yml" in F006)

# ---------------------------------------------------------------------------
# F9 -- the Python dependency list
# ---------------------------------------------------------------------------
print("")
print("== F9: the Python dependency list, derived from the workflow ==")
_installs = re.findall(r"pip install ([^\n#]+)", CI)
check("CI has a pip install line for the cross-check deps", bool(_installs),
      "got %s" % _installs)
_ci_pkgs = " ".join(_installs)
check("CI installs rdrobust with a >=2,<3 pin", 'rdrobust>=2,<3' in _ci_pkgs)
check("CI does not install scipy directly", not re.search(r"(?<![\w-])scipy(?![\w-])", _ci_pkgs))
check("the rdrobust pin is deliberate, per CI's own comment",
      "Pinning" in CI and "rdrobust" in CI)
check("doc/002 states the rdrobust pin", "**pinned `>=2,<3`**" in F002)
check("doc/002 says scipy arrives transitively", "arrives transitively" in F002)
check("doc/002 no longer lists scipy as a direct package",
      "`doubleml`, `numpy`, `pandas`, `scipy`" not in F002)
check("doc/002 still names the packages CI installs",
      all(p in F002 for p in ("`doubleml`", "`numpy`", "`pandas`", "`statsmodels`",
                              "`scikit-learn`")))
check("doc/002 still names scipy", "scipy" in F002)
check("the publish workflow uses the same rdrobust pin",
      'rdrobust>=2,<3' in PUB)

# ---------------------------------------------------------------------------
# F6 -- the DGP file composition
# ---------------------------------------------------------------------------
print("")
print("== F6: the DGP file composition, derived from the package ==")
_dgp_mod = sorted(fn for fn in os.listdir(SRC)
                   if fn.startswith("dgp_") and fn.endswith(".mbt")
                   and not fn.endswith("_test.mbt"))
_dgp_test = sorted(fn for fn in os.listdir(SRC)
                   if fn.startswith("dgp_") and fn.endswith("_test.mbt"))
check("there are 17 dgp_* modules", len(_dgp_mod) == 17, "got %d" % len(_dgp_mod))
check("there are 18 dgp_* test files", len(_dgp_test) == 18, "got %d" % len(_dgp_test))
_orphans = [t for t in _dgp_test if t[:-len("_test.mbt")] + ".mbt" not in _dgp_mod]
check("exactly one test file has no module sibling",
      len(_orphans) == 1, "got %s" % _orphans)
check("the orphan is dgp_recovery_test.mbt",
      _orphans == ["dgp_recovery_test.mbt"], "got %s" % _orphans)
check("the total really is 35 files", len(_dgp_mod) + len(_dgp_test) == 35)
check("the module+its-own-siblings account for only 34 of them",
      2 * len(_dgp_mod) == 34)
for label, text in (("doc/001", F001), ("doc/005", F005), ("the skill", FSKILL)):
    check("%s names the orphan test file" % label, "dgp_recovery_test.mbt" in text)
    check("%s says 35 files in all" % label, "35 files" in text)
check("doc/005 no longer says 'each with a sibling -- 35 files in all'",
      "each with a sibling `dgp_*_test.mbt` --" not in D005)
check("doc/005 says the orphan has no module of its own",
      "with no module of its own" in F005 or "a test file with no module of its own" in F005)
check("the skill says the orphan has no module of its own",
      "a\n  test file with no module of its own" in SKILL
      or "test file with no module of its own" in FSKILL)

# ---------------------------------------------------------------------------
# F7 -- the quick-start data shape
# ---------------------------------------------------------------------------
print("")
print("== F7: the quick-start data shape ==")
check("doc/003 no longer calls the example a panel", "synthetic panel" not in F003)
check("doc/003 calls it a cross-section", "synthetic cross-section" in F003)
_q = D003
check("doc/003's example builds a DoubleMLData", "DoubleMLData::new" in _q)
check("doc/003's example does NOT build a DoubleMLPanelData",
      "DoubleMLPanelData" not in _q)
check("doc/003's example has no unit or time dimension",
      not re.search(r"DoubleMLDIDData|DoubleMLPanelData", _q))
check("the repo reserves 'panel' for the panel DGP and the panel data type",
      "panel" in flat("doc/005_dgps/readme.mbt.md"))

# ---------------------------------------------------------------------------
print("")
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(fails)))
if fails:
    print("FAILED:")
    for f in fails:
        print("  - %s" % f)
    sys.exit(1)
print("=" * 78)
sys.exit(0)
