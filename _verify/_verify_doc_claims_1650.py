#!/usr/bin/env python3
"""Round 40 verifier: the PROSE claims the fresh-eyes audit found false.

WHAT THIS EXISTS FOR
=====================
A fresh-eyes audit of the README, the agent skill and the six tutorials found
eight claims that were false, and none of them was a number that rotted --
they were PROSE that asserted something the tree does not do.  A number can
be re-derived; a sentence can only be rewritten, and nothing here could see
either:

  D1  the agent skill said all 16 CLI-style demos "print true-vs-estimated
      theta and a 95% CI".  **14** of the 16 print a true value and **11**
      print a CI -- `examples/pava` and `examples/splitting` print neither,
      and `examples/apos`, `examples/cluster` and `examples/ssm` print a
      true value but no CI.  The README already said so; the skill did not.
  D2  the estimators tutorial said the port has **9** `score` parameters and
      told the reader to pass one to `fit_cluster(...)`.  There are **8**,
      at 7 estimators -- and `fit_cluster` is a PRIVATE dispatch target, so
      a reader who followed the sentence got
      "Type DoubleMLPLR has no method fit_cluster".
  D3  the same tutorial said `DoubleMLDIDMulti` takes a panel-form
      `DoubleMLDIDData` (x, y, d, t, g, id).  It takes `DoubleMLDIDCSData`,
      and `DoubleMLDIDData` has no `t`, `g` or `id` at all.
  D4  the README pointed at "the full curl recipe" in
      `examples/api_server/README.md`.  That file has no curl recipe -- its
      recipe is the PowerShell one -- and it points the other way.
  D5  the README said the wasm service "runs under `moonrun --port 4000`".
      `moonrun` takes a PATH and then the program's arguments, so that
      command is REJECTED, and the port is hard-coded anyway: the service
      binds 4000 whatever it is told.
  D6  the estimators tutorial said the package README "notes the few that
      are importable but absent from upstream's `__all__`".  The package
      README does not mention `__all__` at all.
  D7  the DGP tutorial said the panel and DID DGPs "return their own data
      types (`DoubleMLPanelData`, `DoubleMLDIDCSData`, ...) and carry the
      extra `t` / `g` / `id` accessors".  They return `DidCsData`,
      `DidMultiData` and `PlprData`; the panel one has NO `t` / `g` / `id`
      accessors at all, and the types named are the estimator-side wrappers
      the caller builds.
  D8  the same tutorial pointed at `dgp_recovery_test.mbt` for "a worked
      example of each shape" -- that file holds three tests, none of them
      LPLR.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the demo split, from the record the measuring verifier writes
    (`_verify/_cli_demo_ci_1650.json`, refreshed by the verifier that RUNS
    the 16 drivers);
  * the `score` parameters, from the SOURCE -- their owner, their
    visibility and their type, with the parameter list read by balancing
    parentheses (a signature whose default value contains a paren is cut
    short by a `[^)]*` matcher, and one of the eight was);
  * `DoubleMLDIDMulti`'s data type, from its constructor;
  * the DGP factories' return types and their accessors, from the source;
  * the api_server's port, from its `main.mbt`;
  * the demo and DGP test names, from the test files.

Run: python _verify/_verify_doc_claims_1650.py
"""
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
EX = os.path.join(ROOT, "examples")
SKILL = os.path.join(ROOT, "skills", "moonbit_doubleML.md")
README = os.path.join(ROOT, "README.mbt.md")
DOC4 = os.path.join(ROOT, "doc", "004_estimators", "readme.mbt.md")
DOC5 = os.path.join(ROOT, "doc", "005_dgps", "readme.mbt.md")
API_README = os.path.join(EX, "api_server", "README.md")
API_MAIN = os.path.join(EX, "api_server", "main.mbt")
DEMOS = os.path.join(ROOT, "_verify", "_cli_demo_ci_1650.json")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "*** FAIL ***", label, detail))
    if not ok:
        FAILS.append(label)


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def flat(s):
    return re.sub(r"\s+", " ", s)


def src(name):
    return read(os.path.join(PKG, name))


def signatures(text, want_public):
    """(owner, method, params) for every method definition in a source.

    The parameter list is read by BALANCING parentheses: a signature whose
    default value contains a paren -- `gt_combinations~ : Array[(Int32,
    Int32, Int32)]` -- is cut short by a `[^)]*` matcher, and the score
    parameter behind it is never seen.
    """
    out = []
    for m in re.finditer(r"(?m)^\s*(pub\s+)?fn\s+([A-Za-z_]\w*)::(\w+)\s*\(", text):
        if bool(m.group(1)) != want_public:
            continue
        i = m.end() - 1
        depth = 0
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        out.append((m.group(2), m.group(3), text[m.end():i]))
    return out


# ==============================================================================
print()
print("=" * 78)
print("A. the skill's CLI-demo split")
print("=" * 78)

rec = json.loads(read(DEMOS))
drivers = rec["drivers"]
no_true = set(rec["no_true"])
no_ci = set(rec["no_ci"])
true_count = drivers - len(no_true)
ci_count = drivers - len(no_ci)
print("  the record: %d drivers, %d without a true value, %d without a CI"
      % (drivers, len(no_true), len(no_ci)))

skill = read(SKILL)
sflat = flat(skill)
check("the record names %d drivers" % drivers, drivers == 16, "got %d" % drivers)
check("the record's per-driver flags agree with its two lists",
      {d for d, v in rec["per_driver"].items() if not v["true"]} == no_true
      and {d for d, v in rec["per_driver"].items() if not v["ci"]} == no_ci,
      "the lists and the flags disagree")
check("the skill states the true-value count the record gives",
      "**%d** of the %d print a true value" % (true_count, drivers) in sflat,
      "the record says %d" % true_count)
check("the skill states the CI count the record gives",
      "**%d** of the %d print a 95%% CI" % (ci_count, drivers) in sflat,
      "the record says %d" % ci_count)
check("the skill names the demos that print a true value but no CI",
      all(("examples/%s" % d) in skill for d in ("apos", "cluster", "ssm")),
      ", ".join(sorted(no_ci - no_true)))
check("the skill names the demos that print neither",
      all(("examples/%s" % d) in skill for d in ("pava", "splitting")),
      ", ".join(sorted(no_true)))
check("the skill no longer claims all 16 print a CI",
      "print true-vs-estimated" not in sflat,
      "the blanket claim is still there")

# ==============================================================================
print()
print("=" * 78)
print("B. the estimators tutorial's `score` parameters")
print("=" * 78)

public_score = []
private_score = []
# An optional parameter carries a TILDE in MoonBit -- `score~ : String` -- so
# the name in the source is `score~`, not `score`.
SCORE_P = re.compile(r"\s*score~?\s*:\s*String")
for fn in sorted(os.listdir(PKG)):
    if not fn.endswith(".mbt"):
        continue
    text = src(fn)
    for owner, meth, params in signatures(text, True):
        for p in params.split(","):
            if SCORE_P.match(p):
                public_score.append((owner, meth, fn))
    for owner, meth, params in signatures(text, False):
        for p in params.split(","):
            if SCORE_P.match(p):
                private_score.append((owner, meth, fn))

owners = sorted({o for o, _m, _f in public_score})
print("  public score parameters: %d, at %d estimators" % (len(public_score), len(owners)))
for o, m, f in sorted(public_score):
    print("    %-26s %-10s %s" % (o, m, f))
for o, m, f in sorted(private_score):
    print("    (private) %-20s %-10s %s" % (o, m, f))

doc4 = flat(read(DOC4))
check("the public score parameters are 8, at 7 estimators",
      len(public_score) == 8 and len(owners) == 7,
      "%d at %d" % (len(public_score), len(owners)))
# The tutorial's sentence is one bold phrase: "**N `score` parameters, at M
# estimators**".  Both numbers are read out of it, so the check is on the
# NUMBERS and not on the shape of the emphasis.
_st = re.search(r"\*\*(\d+)\s+`score`\s+parameters,\s+at\s+(\d+)\s+estimators\*\*",
                 doc4)
check("the tutorial states the count the source gives",
      _st is not None
      and int(_st.group(1)) == len(public_score)
      and int(_st.group(2)) == len(owners),
      "the source says %d at %d, the tutorial says %s"
      % (len(public_score), len(owners),
         ("%s at %s" % (_st.group(1), _st.group(2))) if _st else "nothing"))

# The RDD data type's own `score` is the SCORE VECTOR, not the oracle
# argument -- a `score : Array[Double]`.  A count that sweeps for the word
# "score" counts it, and gets 9.
rddscore = []
for owner, meth, params in signatures(src("rdd.mbt"), True):
    for p in params.split(","):
        if re.match(r"\s*score\s*\??\s*:", p):
            rddscore.append(p.strip())
check("the RDD data's `score` is the score VECTOR, not the oracle argument",
      rddscore and all("Array[Double]" in p for p in rddscore),
      "; ".join(rddscore) or "no score parameter found")

# Every method the tutorial offers as a place to PASS the score must be
# public API.  The scope is the score SITES -- the table's argument column
# and the sentence that follows it -- not every method the section mentions:
# the section also names `hash_hyperparams(...)`, which is the internal
# cache-kind tag the port passes, and that is a different claim.
section = read(DOC4).split("## The `score` argument", 1)[-1].split("\n## ", 1)[0]
sites = set(re.findall(r"`(\w+)\(score=\.\.\.\)`", section))
for sentence in re.split(r"(?<=\.)\s+", section):
    if "takes the argument on" in sentence:
        sites.update(re.findall(r"`(\w+)\(\.\.\.\)`", sentence))
public_methods = set()
for fn in sorted(os.listdir(PKG)):
    if fn.endswith(".mbt"):
        for _o, m, _p in signatures(src(fn), True):
            public_methods.add(m)
not_public = sorted(s for s in sites if s not in public_methods)
check("every score site the tutorial names is public API",
      not not_public,
      "not public: %s" % ", ".join(not_public))
check("the private `fit_cluster` is named as internal, not as a call site",
      ("fit_cluster" not in section) or ("not a public call site" in section),
      "the tutorial still offers it as a call site")

# ==============================================================================
print()
print("=" * 78)
print("C. DoubleMLDIDMulti's data type")
print("=" * 78)

m = re.search(r"pub fn DoubleMLDIDMulti::new\s*\(([^)]*)\)", src("did_multi.mbt"), re.S)
dtype = None
if m:
    mt = re.search(r"data\s*:\s*(\w+)", m.group(1))
    dtype = mt.group(1) if mt else None
print("  the constructor takes: %s" % dtype)
check("the constructor's data type is readable", dtype is not None, str(dtype))
check("the tutorial names the type the constructor takes",
      dtype is not None and ("`%s`" % dtype) in read(DOC4),
      "the constructor takes %s" % dtype)
check("the tutorial does not name a data type the constructor does not take",
      dtype is not None and ("`DoubleMLDIDData`" not in read(DOC4)
                             or "DoubleMLDIDMulti" not in
                             read(DOC4).split("DoubleMLDIDMulti", 1)[1][:120]),
      "the tutorial still pairs DoubleMLDIDMulti with DoubleMLDIDData")

# ==============================================================================
print()
print("=" * 78)
print("D. the README's api_server invocation")
print("=" * 78)

main = read(API_MAIN)
readme = read(README)
const = re.search(r"const DEFAULT_PORT\s*:\s*Int32\s*=\s*(\d+)", main)
port = const.group(1) if const else None
check("the api_server's listen port is a constant in its source",
      port is not None, "DEFAULT_PORT = %s" % port)
check("the api_server parses no argument for the port",
      "let port = DEFAULT_PORT" in main and "args" not in main.split("async fn main", 1)[-1][:400],
      "main.mbt reads no argument")
check("the README does not offer `moonrun --port`",
      "moonrun --port" not in readme,
      "the README still passes --port to moonrun")
check("the README's api_server README pointer names a recipe that is there",
      ("PowerShell" in readme) and ("```powershell" in read(API_README)),
      "the README promises a recipe the file does not have")
check("the api_server README does not pass --port to moonrun either",
      "--port" not in read(API_README),
      "the example README still passes --port")
check("the api_server README says the port is hard-coded",
      "hard-coded" in read(API_README) and (port is None or ("`%s`" % port) in read(API_README)),
      "the example README does not say so")

# ==============================================================================
print()
print("=" * 78)
print("E. the DGP tutorial's return types")
print("=" * 78)

doc5raw = read(DOC5)
doc5 = flat(doc5raw)
factories = {}
for fn in sorted(os.listdir(PKG)):
    if not fn.startswith("dgp_") or not fn.endswith(".mbt"):
        continue
    text = src(fn)
    for m in re.finditer(r"pub fn (make_\w+)\s*\(([^)]*)\)\s*->\s*(\w+)", text, re.S):
        factories[m.group(1)] = m.group(3)
panel = factories.get("make_plpr_CP2025")
did = factories.get("make_did_SZ2020")
multi = factories.get("make_did_CS2021")
print("  the panel DGP returns %s; the DID ones %s and %s" % (panel, did, multi))

check("the panel DGP's return type is readable", panel is not None, str(panel))
check("the DID DGP return types are readable",
      did is not None and multi is not None, "%s, %s" % (did, multi))
check("the tutorial names the DGP-side types the factories return",
      all(("`%s`" % t) in doc5 for t in (panel, did, multi) if t),
      "the tutorial names the estimator-side wrappers instead")

panel_accessors = set()
if panel:
    for fn in sorted(os.listdir(PKG)):
        if fn.endswith(".mbt"):
            for m in re.finditer(r"pub fn %s::(\w+)\s*\(" % panel, src(fn)):
                panel_accessors.add(m.group(1))
extra = sorted(a for a in panel_accessors if a in ("t_get", "g_get", "id_get"))
check("the panel DGP's type carries no t/g/id accessor", not extra,
      "it carries %s" % ", ".join(extra))
check("the tutorial says the panel DGP has no t/g/id accessors",
      "no `t` / `g` / `id` accessors" in doc5 or "no `t` / `g` / `id`" in doc5,
      "the tutorial still claims they are there")

# ==============================================================================
print()
print("=" * 78)
print("F. the files the tutorials cite")
print("=" * 78)

cited = set()
for d in sorted(os.listdir(os.path.join(ROOT, "doc"))):
    path = os.path.join(ROOT, "doc", d, "readme.mbt.md")
    if not os.path.isfile(path):
        continue
    for m in re.finditer(r"`([A-Za-z0-9_]+\.mbt)`", read(path)):
        cited.add(m.group(1))


def _found_in_repo(name):
    """Is the file anywhere in the tracked tree?

    A tutorial cites files in the package AND in its own doc package
    (`using_test.mbt`), so the lookup is not the library's directory alone.
    """
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames
                       if d not in ("_build", "_verify", ".git", "target")]
        if name in filenames:
            return True
    return False
missing = sorted(c for c in cited
                  if not os.path.isfile(os.path.join(PKG, c))
                  and not _found_in_repo(c))
check("every `.mbt` file the tutorials cite exists", not missing,
      "missing: %s" % ", ".join(missing))

def tests_of(fname):
    path = os.path.join(PKG, fname)
    if not os.path.isfile(path):
        return []
    return re.findall(r'test\s+"([^"]+)"', read(path))

recovery = tests_of("dgp_recovery_test.mbt")
lplr_file = tests_of("dgp_lplr_test.mbt")
check("the file cited for the DID and PLPR shapes holds those tests",
      any("DID" in t for t in recovery) and any("PLPR" in t for t in recovery),
      "%d tests" % len(recovery))
check("the file cited for the LPLR shape holds an LPLR test",
      any("LPLR" in t for t in lplr_file),
      "%d tests" % len(lplr_file))
check("the tutorial cites the LPLR file it needs",
      "dgp_lplr_test.mbt" in doc5raw,
      "the tutorial still points only at dgp_recovery_test.mbt")

# ==============================================================================
print()
print("=" * 78)
print("G. the `__all__` cross-reference")
print("=" * 78)

check("no tutorial points at an `__all__` note the README does not carry",
      not ("__all__" in doc5raw) and not ("__all__" in doc4),
      "a tutorial still promises the note")
check("a tutorial may mention `__all__` only if the README does",
      ("__all__" not in doc5raw and "__all__" not in doc4) or ("__all__" in readme),
      "the README does not discuss it")

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
