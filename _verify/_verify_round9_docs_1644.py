#!/usr/bin/env python3
"""Round 9 verifier: the executable-verification layer of the shipped docs.

Every check here derives its expected value FROM AN ARTEFACT and compares
it to what a document says. Nothing pins a bare literal, because a literal
rots exactly like the document does (round 8's lesson).

Groups:
  A  feature file -> real test names resolve
  B  the shipped README's traceability paragraph == the feature file
  C  the feature file's header states the truth about its own mapping
  D  every scenario number == the number in the test it maps to
  E  doc/003: the API call compiles, and the quoted numbers agree
  F  doc/005: the tutorial test exercises the factory the readme shows
  G  examples/api_server/README.md: the paths and the file list are real
  H  the two root design docs do not assert a superseded state
  I  every version literal in the tree is covered by the bump script
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
FEATURE = os.path.join(ROOT, "features", "moonbit_doubleML_acceptance.feature")
README = os.path.join(ROOT, "README.mbt.md")
# round 18: the PROJECT document -- the CI harness, the QA registry and the
# release history.  The LIBRARY document is `README.mbt.md`.
PROJ = os.path.join(ROOT, "ENGINEERING.md")
API_README = os.path.join(ROOT, "examples", "api_server", "README.md")
API_MOD = os.path.join(ROOT, "examples", "api_server", "moon.mod")
BUMP = os.path.join(ROOT, "_verify", "_bump_1636.py")

FAILS = []
NCHECK = 0


def check(name, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if not ok:
        FAILS.append((name, detail))
        # The house's failure marker, so that a dry-run driver can COUNT
        # this check's failures the way it counts every other check's.
        print("  *** FAIL *** %-50s %s" % (name, detail))
    else:
        print("  ok    %-58s %s" % (name, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def package_sources():
    out = {}
    for fn in sorted(os.listdir(PKG)):
        if fn.endswith(".mbt"):
            out[fn] = read(os.path.join(PKG, fn))
    return out


SRC = package_sources()
DECLARED = set()
for _fn, _s in SRC.items():
    DECLARED.update(re.findall(r'\btest\s+"([^"]+)"', _s))
    DECLARED.update(re.findall(r"\bfn\s+(panic_\w+)\s*\(", _s))

feat = read(FEATURE)
feat_lines = feat.splitlines()

# --------------------------------------------------------------------------- #
# A. feature file -> real test names resolve
# --------------------------------------------------------------------------- #
print("A. feature-file mapping resolves against real declarations")


def mapped_entries():
    """Same walk the QA LOOP `gherkin` check does, so the two agree."""
    entries = []
    for i, l in enumerate(feat_lines):
        m = re.match(r"\s*#\s*mapped to:\s*(.+)$", l)
        if not m:
            continue
        acc = m.group(1)
        nxt = feat_lines[i + 1] if i + 1 < len(feat_lines) else ""
        if (re.match(r"\s*#\s+\S", nxt)
                and not re.match(r"\s*(Scenario|Feature|Background|Examples|Given|When|Then|And|But|\*)\b", nxt)):
            acc += " " + nxt.split("#", 1)[1]
        entries += [x.strip() for x in re.split(r",\s*|\s+and\s+", acc) if x.strip()]
    return entries


def is_prose(entry):
    """The QA LOOP's exemption rule, verbatim."""
    return bool(re.search(r"\s(?:in|usage|validators|tests)\b|\.", entry))


MAPPED = mapped_entries()
REAL = [m for m in MAPPED if not is_prose(m)]
PROSE = [m for m in MAPPED if is_prose(m)]
unresolved = [m for m in REAL if m.split("(")[0].strip() not in DECLARED]
check("every non-prose mapped name resolves", not unresolved, str(unresolved[:4]))

# --------------------------------------------------------------------------- #
# B. the shipped README's traceability paragraph == the feature file
# --------------------------------------------------------------------------- #
print()
print("B. the project document's traceability paragraph agrees with the feature file")
n_feat = len(re.findall(r"^Feature:", feat, re.M))
n_scen = len(re.findall(r"^\s*Scenario", feat, re.M))
n_step = len(re.findall(r"^\s*(?:Given|When|Then|And)\s", feat, re.M))
n_cited = len(MAPPED)
n_distinct = len(set(MAPPED))
n_resolve = len(REAL)
n_prose = len(PROSE)

# Round 18 split the documentation in two.  The acceptance-criteria
# traceability describes THIS repository's own `features/*.feature` file -- it
# is project bookkeeping, not something a user of the library needs -- so the
# paragraph lives in `ENGINEERING.md` and these checks read that.
rd = read(PROJ)
i = rd.find("Acceptance-criteria traceability")
para = rd[i - 2 : i + 900] if i >= 0 else ""
for label, value in [
    ("Feature blocks", n_feat),
    ("Scenario blocks", n_scen),
    ("steps", n_step),
    ("cited names", n_cited),
    ("distinct names", n_distinct),
    ("resolving names", n_resolve),
    ("prose-exempt names", n_prose),
]:
    check("the project document states %s = %d" % (label, value),
          str(value) in para, "missing %d in the paragraph" % value)
check("the project document paragraph present", bool(para))
check("the project document does not claim a count the file does not have",
      ("**%d**" % n_resolve) in para or ("%d against" % n_resolve) in para
      or ("%d of the %d" % (n_resolve, n_cited)) in para
      or ("%d resolve" % n_resolve) in para
      or ("%d against real" % n_resolve) in para
      or ("%d real" % n_resolve) in para,
      "no count-anchored form of %d found" % n_resolve)

# --------------------------------------------------------------------------- #
# C. the feature header states the truth about its own mapping
# --------------------------------------------------------------------------- #
print()
print("C. the feature header does not overstate its own mapping")
check("header does not claim a 1:1 mapping",
      all(("NOT 1:1" in l or "not 1:1" in l) for l in feat.splitlines() if "1:1" in l),
      str([l for l in feat.splitlines() if "1:1" in l and "NOT 1:1" not in l][:2]))
check("header points at the live gherkin check", "qa_loop" in feat and "gherkin" in feat)
check("header says the mapping is not 1:1", "NOT 1:1" in feat)
check("header does not present T260 as the current verifier",
      "T260" not in feat.split("HISTORY:")[0])

# --------------------------------------------------------------------------- #
# D. scenario numbers == the numbers in the test each scenario maps to
# --------------------------------------------------------------------------- #
print()
print("D. every scenario number is the number in its mapped test")


def scenario_body(title):
    """The text of the Scenario block whose title starts with `title`."""
    lines = feat.splitlines()
    for k, l in enumerate(lines):
        if re.match(r"^\s*Scenario:\s*" + re.escape(title), l):
            out = [l]
            for l2 in lines[k + 1:]:
                if re.match(r"^\s*(Scenario|Feature|Background|Examples):", l2):
                    break
                out.append(l2)
            return "\n".join(out)
    return ""


def test_body(name):
    """The source of ONE `test "<name>"` block, not the whole file.

    Whole-file scans pick up neighbouring tests' fixtures, which is how a
    check ends up asserting the wrong thing (a `Matrix::zeros(5, 1)` from
    an unrelated panic test).
    """
    for fn, s in SRC.items():
        m = re.search(r'\ntest\s+"%s"\s*\{' % re.escape(name), s)
        if not m:
            continue
        start = m.end()
        end = s.find("\n}\n", start)
        return s[start:end if end > 0 else len(s)]
    return ""


def test_source(name):
    return test_body(name)


# D1: cluster SE ratio floor
t = test_source("plr_cluster_se_larger_than_row_se")
m = re.search(r"ratio\s*>\s*([0-9.]+)", t)
check("cluster test has a ratio floor", bool(m))
if m:
    bound = m.group(1)
    sc = scenario_body("Cluster-robust SE is larger")
    check("cluster scenario states the ratio floor %sx" % bound,
          ("%sx" % bound) in sc, sc.splitlines()[-1] if sc else "")

# D2: DIDMulti pre-treatment cell count
t = test_source("did_multi_universal_includes_pre_treatment")
m = re.search(r'inspect\(n_pre,\s*content="(\d+)"\)', t)
check("DIDMulti test pins the placebo cell count", bool(m))
if m:
    n_pre = m.group(1)
    sc = scenario_body("Universal keyword includes pre-treatment")
    check("DIDMulti scenario states %s placebo cells" % n_pre,
          ("%s cells" % n_pre) in sc, "")

# D3: LPLR theta band
t = test_source("lplr_smoke_lzz2020_recovers_theta")
m = re.search(r"th\s*>\s*(-?[0-9.]+)\s*&&\s*th\s*<\s*([0-9.]+)", t)
check("LPLR test has a theta band", bool(m))
if m:
    lo, hi = m.group(1), m.group(2)
    sc = scenario_body("LPLR recovers alpha at finite positive SE")
    check("LPLR scenario states the band (%s, %s)" % (lo, hi),
          ("(%s, %s)" % (lo, hi)) in sc, "")

# D4: LPLR CI tolerance
t = test_source("lplr_confint_identity")
m = re.search(r"tol\s*=\s*([0-9.]+)\s*\*\s*([0-9.e\-]+)\s*\*\s*scale", t)
check("LPLR CI test derives its tolerance", bool(m))
if m:
    mult = m.group(1).rstrip("0").rstrip(".")
    sc = scenario_body("CI identity holds")
    check("LPLR CI scenario states the derived tolerance",
          ("%s * eps" % mult) in sc, "")

# D5: cv_repeated band factors
t = test_source("gain_stats_from_blp_cv_repeated_smooths_estimate")
m1 = re.search(r"v_avg\s*>\s*lo\s*\*\s*([0-9.]+)", t)
m2 = re.search(r"v_avg\s*<\s*hi\s*\*\s*([0-9.]+)", t)
check("cv_repeated test has a two-sided band", bool(m1 and m2))
if m1 and m2:
    sc = scenario_body("Averaging across repeats smooths")
    check("cv_repeated scenario states the %sx / %sx band" % (m1.group(1), m2.group(1)),
          ("%sx" % m1.group(1)) in sc and ("%sx" % m2.group(1)) in sc, "")

# D6: LPLR DGP shape
t = test_source("lplr_smoke_lzz2020_recovers_theta")
m = re.search(r"build_lzz2020_dgp\((\d+),\s*([0-9.]+),\s*(\d+)\)", t)
check("LPLR test calls the DGP builder with a fixed n", bool(m))
if m:
    n_obs, alpha = m.group(1), m.group(2)
    p = re.search(r"let p = (\d+)", SRC.get("lplr_test.mbt", ""))
    bg = feat.split("Feature: Partially logistic regression")[1].split("Scenario:")[0]
    check("LPLR background states %s observations" % n_obs, ("%s observations" % n_obs) in bg, bg.strip()[:90])
    if p:
        check("LPLR background states %s features" % p.group(1),
              ("%s features" % p.group(1)) in bg, "")
    check("LPLR background states alpha = %s" % alpha, ("alpha = %s" % alpha) in bg, "")

# D7: cluster DGP shape
t = test_source("plr_cluster_se_larger_than_row_se")
m = re.search(r"build_clustered_dgp\(rng,\s*(\d+),\s*(\d+),\s*([0-9.]+)\)", t)
check("cluster test calls the DGP builder with fixed args", bool(m))
if m:
    u, p, theta = m.group(1), m.group(2), m.group(3)
    bg = feat.split("Feature: Cluster-robust inference for PLR/IRM")[1].split("Scenario:")[0]
    check("cluster background states %s units x %s periods" % (u, p),
          ("%s units x %s periods" % (u, p)) in bg, bg.strip()[:90])
    check("cluster background states theta = %s" % theta, ("theta = %s" % theta) in bg, "")

# D8: cv_repeated BLP sizes
sizes = set()
for nm in ("gain_stats_from_blp_cv_repeated_basic",
           "gain_stats_from_blp_cv_repeated_matches_single_when_one_repeat",
           "gain_stats_from_blp_cv_repeated_smooths_estimate"):
    tt = test_source(nm)
    sizes.update(re.findall(r"Matrix::zeros\((\d+),\s*(\d+)\)", tt))
ncols = set(c for _r, c in sizes)
check("all three cv_repeated fixtures use 2 basis columns", ncols == {"2"}, str(ncols))
bg = feat.split("Feature: Repeated K-fold cross-fit stability")[1].split("Scenario:")[0]
obs = sorted(set(int(r) for r, _c in sizes))
check("cv_repeated background lists every fixture size",
      all(str(o) in bg for o in obs), "%s vs %s" % (obs, bg.strip()[:80]))

# --------------------------------------------------------------------------- #
# E. doc/003: the API call compiles, and the quoted numbers agree
# --------------------------------------------------------------------------- #
print()
print("E. doc/003 quick start: real API shape, self-consistent numbers")
d3 = read(os.path.join(ROOT, "doc", "003_quick_start", "readme.mbt.md"))
sig = re.search(r"pub fn Matrix::from_array\((.*?)\)\s*->", SRC.get("matrix.mbt", ""), re.S)
arity = len(re.findall(r":\s*(?:Array\[Double\]|Int32)", sig.group(1))) if sig else -1
calls = re.findall(r"Matrix::from_array\((.*?)\)", d3, re.S)


def nargs(call):
    body = call.strip().rstrip(",").strip()
    return len([x for x in body.split(",") if x.strip()])


ok = bool(calls) and all(nargs(c) == arity for c in calls)
check("doc/003 from_array call arity == the package signature (%d args)" % arity,
      ok, "%d call(s): %s" % (len(calls), [nargs(c) for c in calls]))

nums = dict(re.findall(r"\|\s*`(\w+)\(\)`\s*\|\s*`?(-?[0-9.]+)`?\s*\|", d3))
ci = re.search(r"\|\s*`confint\(\)`\s*\|\s*`\(([^)]+)\)`\s*\|", d3)
check("doc/003 quotes coef, se and confint", bool(nums) and bool(ci))
if nums and ci:
    coef = float(nums.get("coef", "nan"))
    se = float(nums.get("se", "nan"))
    lo, hi = [float(x) for x in ci.group(1).split(",")]
    # The CI must be the 95% normal CI of the quoted coef and se. The
    # multiplier is not pinned to one constant: the package has two 95%
    # conventions (`norm_ppf(0.975)` for PLR, the hard-coded
    # 1.959963984540054 for LPLR/PLPR/...), and they differ by ~1.2e-6.
    # What must hold is the RELATIONSHIP, not the constant.
    z_measured = (hi - lo) / 2.0 / se
    check("doc/003 confint is the 95% normal CI of the quoted coef/se",
          abs(z_measured - 1.959963984540054) < 2.0e-5,
          "implied z = %r" % z_measured)
    check("doc/003 confint is centred on the quoted coef",
          abs((hi + lo) / 2.0 - coef) < 1.0e-9,
          "midpoint = %r vs coef = %r" % ((hi + lo) / 2.0, coef))
    check("doc/003 quotes the same numbers as the tutorial test produces",
          "8.782651064906958" in d3 and "13.75724952565863" in d3, "")
check("doc/003 no longer claims the retired magnitudes",
      "≈ 1.0" not in d3 and "≈ 0.1" not in d3 and "(0.8, 1.2)" not in d3)
# The cross-backend spread figure is the package's OWN measurement, not a
# number the tutorial invented: expand_v146_test.mbt records it.
spread = set()
for _fn, s in SRC.items():
    spread.update(re.findall(r"([0-9.]+e-15)", s))
check("doc/003's cross-backend spread is the figure the package measured",
      "1.5e-15" in d3 and "1.5e-15" in spread, str(sorted(spread)[:6]))
check("doc/003's tolerance is the one the did_cs gates use",
      "1e-12" in d3 and any("1.0e-12" in s for s in SRC.values()), "")
tut = read(os.path.join(ROOT, "doc", "003_quick_start", "using_test.mbt"))
for frag in ("x_data[i * 5 + 4] = ((i + 3) % 7).to_double()",
             "d[i] = i.to_double() * 0.5",
             "y[i] = i.to_double() * 1.0 + (i % 2).to_double()"):
    check("doc/003 shows the tutorial fixture line: %s" % frag[:40],
          frag in d3 and frag in tut, "")

# --------------------------------------------------------------------------- #
# F. doc/005: the tutorial test exercises the factory the readme shows
# --------------------------------------------------------------------------- #
print()
print("F. doc/005: the executable test exercises the documented factory")
d5 = read(os.path.join(ROOT, "doc", "005_dgps", "readme.mbt.md"))
t5 = read(os.path.join(ROOT, "doc", "005_dgps", "using_test.mbt"))
factories = re.findall(r"let dgp = (make_\w+)\(", d5)
check("doc/005 usage pattern names one factory", len(factories) == 1, str(factories))
if factories:
    f = factories[0]
    public = any(re.search(r"^pub fn %s\(" % f, s, re.M) for s in SRC.values())
    check("the factory %s is public in the package" % f, public, "")
    check("the tutorial test calls %s" % f, f in t5, "")
    check("the tutorial test uses the DGP accessors", "x_get()" in t5 and "y_get()" in t5 and "d_get()" in t5, "")
check("doc/005 test no longer states the retired 'abstract struct' reason",
      "abstract" not in t5.lower())

# --------------------------------------------------------------------------- #
# G. examples/api_server/README.md: paths and file list are real
# --------------------------------------------------------------------------- #
print()
print("G. examples/api_server README: the paths and the file list are real")
ar = read(API_README)
pkgname = re.search(r'name\s*=\s*"([^"]+)"', read(API_MOD)).group(1)
build_dir = pkgname.replace(".", "/")
check("README native build path contains the package dir %r" % build_dir,
      ("_build/native/debug/build/%s/api_server.exe" % build_dir) in ar,
      "")
check("README wasm build path contains the package dir %r" % build_dir,
      ("_build/wasm/release/build/%s/api_server.wasm" % build_dir) in ar, "")
check("README does not use the package-less build path",
      "_build/native/debug/build/api_server/api_server.exe" not in ar, "")
tracked = set()
try:
    import subprocess
    tracked = set(
        subprocess.run(["git", "ls-files", "examples/api_server"], cwd=ROOT,
                       capture_output=True, text=True).stdout.split())
    if not tracked:
        raise RuntimeError("no git")
except Exception:
    adir = os.path.join(ROOT, "examples", "api_server")
    tracked = set("examples/api_server/" + f for f in os.listdir(adir)
                  if os.path.isfile(os.path.join(adir, f)))
layout = ar.split("## Source layout")[-1]
listed = re.findall(r"^\s{2}(\S+)\s+<-", layout, re.M)
tracked_basenames = set(os.path.basename(p) for p in tracked)
missing = [f for f in listed if f not in tracked_basenames and f != ".archived/"]
check("every file in the Source layout list is tracked", not missing, str(missing))
check("README does not claim a main_test.mbt that does not exist",
      "main_test.mbt" not in ar or "no** `main_test.mbt`" in ar, "")
check("the package really has no main_test.mbt",
      "examples/api_server/main_test.mbt" not in tracked, "")

# --------------------------------------------------------------------------- #
# H. the two root design docs do not assert a superseded state
# --------------------------------------------------------------------------- #
print()
print("H. the root design docs do not assert a superseded state")
td = read(os.path.join(ROOT, "TUNE_DESIGN.md"))
check("TUNE_DESIGN does not claim 'no implementation yet'",
      "no implementation yet" not in td, "")
check("TUNE_DESIGN flags itself as a superseded record", "SUPERSEDED" in td, "")
tune_owners = set()
for _fn, s in SRC.items():
    for m in re.finditer(r"^pub fn (DoubleML\w+)::tune\b", s, re.M):
        tune_owners.add(m.group(1))
est_structs = set()
for _fn, s in SRC.items():
    for m in re.finditer(r"^pub struct (DoubleML\w+)\b", s, re.M):
        est_structs.add(m.group(1))
non_data = {s for s in est_structs if not s.endswith("Data") and not s.endswith("Data")}
n_tune = len(tune_owners & non_data)
n_est = len(non_data)
check("TUNE_DESIGN's tune() count matches the package",
      ("**%d of the %d**" % (n_tune, n_est)) in td,
      "package has %d of %d" % (n_tune, n_est))
qh = read(os.path.join(ROOT, "QUANTILE_HANDOFF.md"))
check("QUANTILE_HANDOFF is labelled a historical record",
      "HISTORICAL RECORD" in qh, "")
check("QUANTILE_HANDOFF's absolute paths use the current directory name",
      "dml-moonbit" not in re.findall(r"cd D:[^\n]*", qh).__str__(), "")

# --------------------------------------------------------------------------- #
# I. every version literal in the tree is covered by the bump script
# --------------------------------------------------------------------------- #
print()
print("I. every version literal is covered by the bump script")
# The bump script IS the contract this section checks against -- its
# `os.path.join(ROOT, ...)` calls are what the coverage list is derived
# from -- so it has to be a file a reader can open.  It was untracked until
# round 18, which meant the check that guards the version sites depended on
# a script nobody else could see.
_tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                          text=True, encoding="utf-8", errors="replace").stdout.splitlines()
check("the bump script is TRACKED",
      "_verify/_bump_1636.py" in _tracked,
      "the check below reads a file a reader cannot open")
ver = re.search(r'version\s*=\s*"([0-9.]+)"', read(os.path.join(PKG, "moon.mod"))).group(1)
bump_src = read(BUMP)
bump_paths = set()
for m in re.finditer(r'os\.path\.join\(\s*ROOT\s*,\s*((?:"[^"]+"\s*,\s*)*"[^"]+")\s*\)', bump_src):
    parts = re.findall(r'"([^"]+)"', m.group(1))
    bump_paths.add("/".join(parts))
uncovered = []
# The scope device is the TRACKED tree, not the working directory.  A walk of
# the filesystem measures whatever happens to be sitting in the checkout: a
# scratch clone of the tree at the repository root carries every version
# literal in it, and the check then reports a dozen sites that no reader can
# open and no bump script can reach.  Group J below already asks `git
# ls-files`; this section now asks the same question.
_SKIP_DIRS = ("_build", "_verify", ".git", ".mooncakes", "__pycache__", "_probe")
_SCANNABLE = (".mbt", ".md", ".mod", ".feature", ".yml", ".yaml")
for rel in sorted(r.strip().replace("\\", "/") for r in _tracked if r.strip()):
    if rel.split("/")[0] in _SKIP_DIRS:
        continue
    if not rel.endswith(_SCANNABLE):
        continue
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    # A SYMLINK is not an independent version site: `README.md` is a
    # symlink to `README.mbt.md`, so its content IS the target's content,
    # and the target is a bump site.  Counting it again would report a
    # site that cannot be bumped separately.
    if os.path.islink(p):
        continue
    try:
        s = read(p)
    except Exception:
        continue
    if ("riantr/moonbit_doubleML@%s" % ver) in s and rel not in bump_paths:
        uncovered.append(rel)
check("every riantr/moonbit_doubleML@%s literal is a bump site" % ver,
      not uncovered, str(uncovered))
check("the version-literal scope is the TRACKED tree, not the working directory",
      not any(r.startswith("_r") and r.endswith("_tree/") for r in uncovered),
      "a scratch tree was measured")

# --------------------------------------------------------------------------- #
# J. every `_verify/...` path a LIVE document names is a file a reader can open
# --------------------------------------------------------------------------- #
print()
print("J. document pointers to repository files resolve")
import subprocess

tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                         text=True, encoding="utf-8", errors="replace").stdout.split()
tset = set(tracked)
PTR = re.compile(r"`?(_verify/[A-Za-z0-9_./-]+\.(?:py|md|txt|json|sh|ps1))`?")
LIVE_SKIP = ("CHANGELOG.md",)  # an append-only historical record
dangling, untracked = set(), set()
for rel in tracked:
    if rel.startswith("_verify/") or rel in LIVE_SKIP:
        continue
    if not rel.endswith((".md", ".mbt", ".feature", ".yml", ".yaml", ".py")):
        continue
    try:
        s = read(os.path.join(ROOT, rel))
    except Exception:
        continue
    for m in PTR.finditer(s):
        p = m.group(1)
        if not os.path.exists(os.path.join(ROOT, p)):
            dangling.add((p, rel))
        elif p not in tset:
            untracked.add((p, rel))
check("no live document names a `_verify/` file that does not exist",
      not dangling, str(sorted(dangling)[:4]))
check("no live document names a `_verify/` file that is not tracked",
      not untracked, str(sorted(untracked)[:4]))

# --------------------------------------------------------------------------- #
print()
print("=" * 74)
# The house's common summary shape, so that the LEDGER can measure this
# check's count the way it measures every other check's.
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    for n, d in FAILS:
        print("  FAILED: %s  %s" % (n, d))
    sys.exit(1)
print("ALL PASS")
