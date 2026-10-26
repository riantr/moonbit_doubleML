"""Round 8: pin the SHIPPED documents (skills/, doc/, AGENTS.md, README) to
what the tree, the upstream sdist and the CI actually say.

Round 7 fixed a class of defect in the README alone: a count word that had
drifted from the list it introduced. Round 8 asked the next question -- what
else ships that was never audited? The answer was the package's other
shipped documents, and they carried the SAME defect class, plus a few of
their own:

  * `skills/moonbit_doubleML.md` told agents NOT to introduce classifier
    learners, and called `LinearRegression` "the single closed-form learner".
    The port ships 11 `LearnerDispatch` variants, 3 of them classifiers, and
    the logistic classifier is the DEFAULT `ml_m` for six estimators.
  * The same file listed 2 white-box test files as "current coverage" when
    there are 26 (169 test cases).
  * The same file said the api_server "uses `Map::of([])` ... where the
    deprecation caveat does not apply". It uses `Map::from_array([])`, and
    the deprecation is live: `Map::of` warns on the current toolchain, and
    CI builds with `--deny-warn`.
  * `AGENTS.md` said `moon.work` has 16 members and listed 14 examples.
    It has 23 members and 21 examples.
  * `doc/001` was frozen at v0.52.0: 17 estimators, 35 DGPs, 415 tests,
    and "Single learner -- the closed-form LinearRegression handles every
    nuisance function".
  * `doc/002` pinned the package at 0.52.0 and reported 415 tests.
  * `doc/003` called 17 estimators the total, said "35 DGP factories" (35
    is the FILE count; there are 18 factories), and used `coef_get()` /
    `se_get()` -- methods that do not exist.
  * `doc/004`'s Score column disagreed with the README's on 6 of 22 rows,
    and its "Upstream file" column listed the PORT's files.
  * `doc/005` named 13 factories that do not exist, passed an `rng` and
    labelled kwargs to factories that take positional args, and attributed
    the Python validators' tolerance to a MoonBit test file.
  * `doc/006` showed a fabricated transcript, and told the reader to append
    a new script to a loop that is a glob.
  * The README itself claimed `dgp_recovery_test.mbt` enforces
    `MAX(MODEL_TOL=0.1, 2.0 * handrolled_se)`. Neither identifier appears
    anywhere in the MoonBit sources, and no CI script mentions either.
  * The README called APO/APOS "average prescriptive effect". The word
    "prescriptive" appears ZERO times in the upstream 0.11.4 sdist; both
    upstream and the port say "average potential outcomes".

Design note (the round-7 lesson): almost every assertion here is DERIVED
from the artefact and compared as a SET, never pinned to a literal. A
literal pin rots exactly like the document does; an invariant does not.
"""
import io
import os
import re
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = (sys.argv[1] if len(sys.argv) > 1
        else os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if not os.path.isabs(ROOT):
    ROOT = os.path.abspath(ROOT)
LIB = os.path.join(ROOT, "moonbit_doubleML")
SDIST = os.path.join(ROOT, "_verify", "doubleml-0.11.4.tar.gz")

fails = []
checks = 0


def read(rel):
    with io.open(os.path.join(ROOT, rel.replace("/", os.sep)), encoding="utf-8") as f:
        return f.read()


def check(label, cond, detail=""):
    global checks
    checks += 1
    print("  %-64s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def must(label, needle, hay, kind="substring"):
    """`needle` must be PRESENT. The needle must be a str -- a compiled
    pattern passed here is a false-ABSENT generator, so it is rejected."""
    global checks
    checks += 1
    if not isinstance(needle, str):
        fails.append("%s -- needle is not a str (%r)" % (label, type(needle)))
        print("  %-64s *** FAIL *** (needle not str)" % label)
        return False
    ok = needle in hay
    print("  %-64s %s" % (label, "OK" if ok else "*** FAIL ***"))
    if not ok:
        fails.append("%s -- %r not found" % (label, needle[:70]))
    return ok


def must_re(label, pattern, hay, flags=0):
    """`pattern` must be PRESENT (regex)."""
    global checks
    checks += 1
    ok = re.search(pattern, hay, flags) is not None
    print("  %-64s %s" % (label, "OK" if ok else "*** FAIL ***"))
    if not ok:
        fails.append("%s -- /%s/ not found" % (label, pattern[:70]))
    return ok


def must_not(label, needle, hay):
    global checks
    checks += 1
    ok = needle not in hay
    print("  %-64s %s" % (label, "OK" if ok else "*** FAIL ***"))
    if not ok:
        fails.append("%s -- %r still present" % (label, needle[:70]))
    return ok


def skip(label, reason):
    """A check that could not run.  It still COUNTS, so the verifier's
    published check count does not depend on what is present on disk, and
    it is PRINTED, so a transcript never loses checks silently."""
    global checks
    checks += 1
    print("  SKIP  %-64s %s" % (label, reason))


# ------------------------------------------------------------------ artefacts
libfiles = sorted(f for f in os.listdir(LIB) if f.endswith(".mbt"))
libsrc = {f: read("moonbit_doubleML/" + f) for f in libfiles}
allsrc = "\n".join(libsrc.values())

mbt = read("moonbit_doubleML/moon.mod")
mod_version = re.search(r'version\s*=\s*"([^"]+)"', mbt).group(1)
readme = read("README.mbt.md")
skill = read("skills/moonbit_doubleML.md")
agents = read("AGENTS.md")
moonwork = read("moon.work")

docs = {}
for d in sorted(os.listdir(os.path.join(ROOT, "doc"))):
    p = os.path.join(ROOT, "doc", d, "readme.mbt.md")
    if os.path.exists(p):
        docs[d] = io.open(p, encoding="utf-8").read()

# estimator structs (the `DoubleML*Data` helpers are not estimators)
owners = {}
for f, t in libsrc.items():
    for m in re.finditer(r"pub struct (DoubleML\w+)", t):
        owners[m.group(1)] = f
EST = sorted(n for n in owners if not n.endswith("Data"))
DID = sorted(n for n in EST if "DID" in n)

# DGP factories
DGP_FILES = sorted(f for f in libfiles
                   if f.startswith("dgp_") and f.endswith(".mbt") and not f.endswith("_test.mbt"))
DGP_TEST_FILES = sorted(f for f in libfiles if f.startswith("dgp_") and f.endswith("_test.mbt"))
FACTORIES = set()
for f in DGP_FILES:
    FACTORIES |= set(re.findall(r"pub fn (make_\w+)", libsrc[f]))

# white-box tests
WB_FILES = sorted(f for f in libfiles if f.endswith("_wbtest.mbt"))
WB_CASES = sum(len(re.findall(r'^\s*(?:panic_)?test\s+"', libsrc[f], re.M)) for f in WB_FILES)

# learner dispatch
disp = re.search(r"pub enum LearnerDispatch\s*\{(.*?)\n\}", allsrc, re.S).group(1)
VARIANTS = re.findall(r"^\s*([A-Z]\w+)\s*\(", disp, re.M)
classifier_body = re.search(r"pub fn LearnerDispatch::is_classifier.*?\n\}", allsrc, re.S).group(0)
CLASSIFIERS = re.findall(r"^\s*([A-Z]\w+)\(_\)\s*=>\s*true", classifier_body, re.M)

# accessors
ALL4 = []
for n in EST:
    t = libsrc[owners[n]]
    if all(re.search(r"pub fn %s::%s\b" % (n, a), t)
           for a in ("coef", "se", "confint", "bootstrap")):
        ALL4.append(n)
EXC = [n for n in EST if n not in ALL4]

# python validators
VAL = sorted(f for f in os.listdir(ROOT)
             if re.match(r"validate_.*_with_python\.py$", f))
VAL_ALL = sorted(f for f in os.listdir(ROOT) if f.startswith("validate_") and f.endswith(".py"))

# recovery tests
REC = sorted(re.findall(r'^test\s+"([^"]+)"', libsrc["dgp_recovery_test.mbt"], re.M))

# moon.work
MEMBERS = re.findall(r'"([^"]+)"', moonwork)
EXAMPLES = sorted(m.split("/", 1)[1] for m in MEMBERS if m.startswith("examples/"))

# upstream sdist
UP = {}
if os.path.exists(SDIST):
    tf = tarfile.open(SDIST, "r:gz")
    for m in tf.getmembers():
        if m.isfile() and m.name.endswith(".py"):
            UP[m.name.split("0.11.4/")[-1]] = tf.extractfile(m).read().decode("utf-8", "replace")
UPSRC = "\n".join(UP.values())

print("=" * 78)
print("A. skill file -- learner surface, wbtests, Map, accessors")
print("=" * 78)
check("skill states the real LearnerDispatch variant count",
      ("**%d**" % len(VARIANTS)) in skill or ("exactly %d" % len(VARIANTS)) in skill,
      "derived %d variants" % len(VARIANTS))
for v in CLASSIFIERS:
    must("skill names the classifier %s" % v, v, skill)
must_not("skill no longer bans classifier learners outright",
         "do NOT introduce classifier learners", skill)
must_not("skill no longer calls LinearRegression the single learner",
         "single closed-form `LinearRegression` learner", skill)
must_re(r"skill records the wbtest file count \(derived %d\)" % len(WB_FILES),
        r"\*\*%d\*\* `\*_wbtest\.mbt` files" % len(WB_FILES), skill)
must_re(r"skill records the wbtest case count \(derived %d\)" % WB_CASES,
        r"\*\*%d\*\* test cases" % WB_CASES, skill)
must_not("skill no longer says the api_server uses Map::of",
         "uses `Map::of([])` for response headers", skill)
must("skill names the non-deprecated constructor",
     "Map::from_array([])", skill)
must_not("skill no longer attributes MODEL_TOL to a MoonBit file",
         "MAX(MODEL_TOL=0.1, 2.0 * handrolled_se)`", skill)
must_re(r"skill states the PASS token is case-sensitive", r"case-sensitive", skill)
must_re(r"skill states the accessor exception count \(derived %d\)" % len(EXC),
        r"%d of the 22 estimators" % len(ALL4), skill)

print()
print("=" * 78)
print("B. AGENTS.md -- moon.work members and the example set")
print("=" * 78)
must_re(r"AGENTS states the real member count \(derived %d\)" % len(MEMBERS),
        r"members \(%d total\)" % len(MEMBERS), agents)
must_re(r"AGENTS states the real example count \(derived %d\)" % len(EXAMPLES),
        r"× %d —" % len(EXAMPLES), agents)
# the enumerated example names must be the SET in moon.work
blk = re.search(r"examples/<bin>/.*?(?=\n\n|\n- )", agents, re.S)
named = set(re.findall(r"`([a-z_]+)`", blk.group(0))) if blk else set()
named = {n for n in named if n in set(EXAMPLES)}
missing = sorted(set(EXAMPLES) - named)
check("AGENTS enumerates every example in moon.work",
      not missing, "missing: %s" % missing)

print()
print("=" * 78)
print("C. doc/001 -- counts and version")
print("=" * 78)
d1 = docs["001_introduction"]
must_re(r"doc/001 states the real estimator count \(derived %d\)" % len(EST),
        r"\*\*%d estimators\*\*" % len(EST), d1)
must_re(r"doc/001 states the real DGP factory count \(derived %d\)" % len(FACTORIES),
        r"\*\*%d DGP factories\*\*" % len(FACTORIES), d1)
must_not("doc/001 no longer claims 17 estimators", "**17 estimators**", d1)
must_not("doc/001 no longer claims 35 DGPs", "**35 DGPs**", d1)
must_not("doc/001 no longer claims 415 tests", "415 / 415", d1)
must_not("doc/001 no longer calls RDD 'RDB'", "RDB", d1)
must_not("doc/001 no longer claims a single learner", "**Single learner**", d1)
must("doc/001 version matches moon.mod", "riantr/moonbit_doubleML@%s" % mod_version, d1)
must("doc/001 names the real learner vocabulary", "LearnerDispatch", d1)
must_not("doc/001 no longer names core/random and core/math as the deps",
         "moonbitlang/core/random", d1)

print()
print("=" * 78)
print("D. doc/002 -- version, toolchain, test count")
print("=" * 78)
d2 = docs["002_installation"]
must("doc/002 version matches moon.mod", "riantr/moonbit_doubleML@%s" % mod_version, d2)
must_not("doc/002 no longer pins 0.52.0", "@0.52.0", d2)
must_not("doc/002 no longer reports 415 tests", "Total tests: 415", d2)
readme_tests = re.search(r"Tests \(native / wasm / js\) \| \*\*(\d+) / (\d+) / (\d+)\*\*", readme)
if readme_tests:
    want = readme_tests.group(1)
    must("doc/002 native test count matches the README Status table", "Total tests: %s" % want, d2)
    must("doc/001 native test count matches the README Status table",
         "%s / %s tests pass" % (want, want), d1)
readme_moon = re.search(r"`(moon 0\.1\.\d+)`", readme)
if readme_moon:
    must("doc/002 names the same toolchain as the README", readme_moon.group(1), d2)
must("doc/002 lists scipy", "scipy", d2)

# The suite ships in the REPOSITORY, not in the published package: a project
# that installed the package gets the library and no tests of its own, and
# `moon test` there reports zero.  The guide used to tell an installed
# CONSUMER to "run the test suite" and quoted the repository's own count --
# so a consumer who followed the instruction read "Total tests: 1117" for a
# run that reports none.
_vsec = d2.split("## Verification", 1)[1] if "## Verification" in d2 else ""
check("doc/002 has a Verification section", bool(_vsec),
      "the '## Verification' heading is gone")
must("doc/002 says the suite is in the repository", "repository", _vsec)
must("doc/002 says an installed consumer runs no tests", "Total tests: 0", _vsec)
must_not("doc/002 no longer tells the reader to run the suite after install",
         "After install, run the test suite", d2)

print()
print("=" * 78)
print("E. doc/003 -- estimator count, DGP count, accessor names")
print("=" * 78)
d3 = docs["003_quick_start"]
must_re(r"doc/003 states the real estimator count \(derived %d\)" % len(EST),
        r"all %d estimators" % len(EST), d3)
must_re(r"doc/003 states the real DGP factory count \(derived %d\)" % len(FACTORIES),
        r"%d DGP factories" % len(FACTORIES), d3)
must_not("doc/003 no longer uses the non-existent coef_get()", "coef_get", d3)
must_not("doc/003 no longer uses the non-existent se_get()", "se_get", d3)
must_not("doc/003 no longer names the non-existent next_f64", "next_f64", d3)
must("doc/003 uses the real accessor", "fitted.coef()", d3)

print()
print("=" * 78)
print("F. doc/004 -- table SET, score strings, accessor exceptions")
print("=" * 78)
# only the ESTIMATOR table counts -- these documents have several other
# tables whose rows also start with a `DoubleML*` name.
def estimator_table_rows(text, header_key):
    lines = text.splitlines()
    for i, l in enumerate(lines):
        if not l.startswith("|"):
            continue
        if header_key not in l:
            continue
        if i + 1 >= len(lines) or not re.match(r"^\|[\s\-:|]+\|$", lines[i + 1]):
            continue
        rows = []
        for l2 in lines[i + 1:]:
            if not l2.startswith("|"):
                break
            m = re.match(r"^\|\s*`(DoubleML\w+)`\s*\|", l2)
            if m:
                rows.append(m.group(1))
        return rows
    return []


d4 = docs["004_estimators"]
rows = estimator_table_rows(d4, "Score argument")
check("doc/004 lists exactly the derived estimator set",
      sorted(set(rows)) == sorted(EST) and len(rows) == len(EST),
      "rows=%d est=%d" % (len(rows), len(EST)))
must_re(r"doc/004 names the right DID-variant count \(derived %d DID estimators\)" % len(DID),
        r"its %d variants" % (len(DID) - 1), d4)
must_not("doc/004 no longer mislabels the file column as upstream", "| Upstream file |", d4)
must("doc/004 labels the column as the port's file", "| Port file |", d4)
for n in EXC:
    must("doc/004 names the accessor exception %s" % n, n, d4)
must_re(r"doc/004 states the accessor count \(derived %d of %d\)" % (len(ALL4), len(EST)),
        r"%d of the %d estimators expose" % (len(ALL4), len(EST)), d4)
# the port's own ACCEPTED score strings must appear, and the cache-kind tags
# must appear TOO -- but as the things they are, not as score values.
# (Round 28: the column used to claim that `apo` / `pq` / `lpq` / `cvar` /
# `policy_tree` were score values the port accepts.  They are the internal
# `hash_hyperparams(...)` kind tags.)
for s in ("partialling-out", "partialling out", "iv-type", "IV-type",
          "observational", "experimental", "nuisance_space", "instrument"):
    must("doc/004 carries the port's accepted score string %r" % s, s, d4)
for s in ("apo", "apos", "pq", "qte", "lpq", "cvar", "policy_tree"):
    must("doc/004 names the cache-kind tag %r" % s, s, d4)
must_re("doc/004 says the cache-kind tags are NOT score values",
         r"are not\s+score values", d4)
must_not("doc/004 no longer uses the README's prose label for APO",
         "policy score |", d4)

print()
print("=" * 78)
print("G. doc/005 -- factory SET, signatures, recovery-test SET")
print("=" * 78)
d5 = docs["005_dgps"]
# doc/005 now names UPSTREAM's factories as well: six of them are renamed
# here, and the rename paragraph names each upstream name.  The set check is
# RE-TARGETED -- it must name every PORT factory and no other, and every
# extra name must be a real UPSTREAM factory, read from the tracked manifest
# (the sdist is a local cache and is not tracked, so it cannot be the anchor
# here: a check that reads a file a fresh clone does not have is a check that
# does not run).
_up_fac = set()
_man = os.path.join(ROOT, "_verify", "_dgp_upstream_manifest_1690.txt")
if os.path.isfile(_man):
    for _l in io.open(_man, encoding="utf-8").read().split("\n"):
        _p = _l.split()
        if len(_p) == 3 and _p[2].lstrip("_").startswith("make"):
            _up_fac.add(_p[2])
named_f = set(re.findall(r"`(make_\w+)`", d5))
_port_named = named_f & set(FACTORIES)
_extra = named_f - set(FACTORIES)
check("doc/005 names exactly the derived factory set",
      _port_named == set(FACTORIES) and _extra <= _up_fac,
      "extra=%s missing=%s unknown=%s" % (sorted(_extra - _up_fac),
                                          sorted(set(FACTORIES) - _port_named),
                                          sorted(_extra - _up_fac)))
must_re(r"doc/005 states the real factory count \(derived %d\)" % len(FACTORIES),
        r"^%d synthetic-data generators" % len(FACTORIES), d5, flags=re.M)
must_re(r"doc/005 states the real module count \(derived %d\)" % len(DGP_FILES),
        r"\*\*%d\*\* `dgp_\*\.mbt` modules" % len(DGP_FILES), d5)
must_re(r"doc/005 states the real file count \(derived %d\)"
        % (len(DGP_FILES) + len(DGP_TEST_FILES)),
        r"\*\*%d files\*\* in all" % (len(DGP_FILES) + len(DGP_TEST_FILES)), d5)
for f in FACTORIES:
    must("doc/005 names the real factory %s" % f, f, d5)
must_not("doc/005 no longer uses the non-existent coef_get()", "coef_get", d5)
must_not("doc/005 no longer passes an rng to a positional factory",
         "make_plr_CCDDHNR2018(rng", d5)
must_not("doc/005 no longer attributes MODEL_TOL to the MoonBit test file",
         "dgp_recovery_test.mbt` runs every estimator", d5)
named_t = set(re.findall(r"`(DIDCS_\w+|PLPR_\w+)`", d5))
check("doc/005 names exactly the derived recovery-test set",
      named_t == set(REC), "extra=%s missing=%s" % (sorted(named_t - set(REC)),
                                                    sorted(set(REC) - named_t)))
for t in REC:
    must("doc/005 names the recovery test %s" % t, t, d5)

print()
print("=" * 78)
print("H. doc/006 -- script count, transcript, glob, PASS token")
print("=" * 78)
d6 = docs["006_python_check"]
must_re(r"doc/006 states the real script count \(derived %d\)" % len(VAL),
        r"(^%d Python scripts)|(^\| `validate_\*_with_python\.py` \| %d \|)"
        % (len(VAL), len(VAL)), d6, flags=re.M)
for m in re.finditer(r"=== (validate_\w+\.py) === (.+)", d6):
    s, tail = m.group(1), m.group(2)
    check("doc/006 transcript names a real script: %s" % s, s in VAL, "not a validator")
    check("doc/006 transcript line for %s contains PASS" % s, "PASS" in tail, tail)
must_re(r"doc/006 states the PASS token is case-sensitive", r"case-sensitive", d6)
must_not("doc/006 no longer claims 'passed' or 'match' suffice",
         "or `passed` or `match`", d6)
must_not("doc/006 no longer uses the non-existent dml_xxx convention",
         "dml_xxx", d6)
must_not("doc/006 no longer tells you to append to a glob",
         "Append the new script to the loop", d6)
must_re(r"doc/006 says nothing needs registering", r"Nothing to register", d6)

print()
print("=" * 78)
print("I. README -- tolerance attribution, APO wording, estimator table")
print("=" * 78)
rrows = estimator_table_rows(readme, "| Model | Score | Description |")
check("README's estimator table lists exactly the derived set",
      sorted(set(rrows)) == sorted(EST) and len(rrows) == len(EST),
      "rows=%d est=%d" % (len(rrows), len(EST)))
must_not("README no longer attributes MODEL_TOL to dgp_recovery_test.mbt",
         "`dgp_recovery_test.mbt` enforces", readme)
must_not("README no longer says 'average prescriptive effect'", "prescriptive", readme)
must("README says 'average potential outcomes' for APO", "average potential outcomes", readme)
if UPSRC:
    check("upstream sdist never says 'prescriptive'",
          "prescriptive" not in UPSRC.lower(), "upstream uses another word")
    for s in ("APO", "PQ", "LPQ", "nuisance_space", "partialling out",
              "observational", "missing-at-random"):
        check("upstream sdist still declares the score string %r" % s, s in UPSRC, "")
else:
    # The upstream sdist is a DOWNLOADED artifact: it is not tracked, so a
    # checkout without it is not broken.  The checks below still COUNT --
    # otherwise the published check count would depend on what happens to be
    # on disk -- and they are PRINTED, so a transcript never loses them
    # silently.
    skip("upstream sdist never says 'prescriptive'",
         "the upstream sdist is not in this checkout")
    for s in ("APO", "PQ", "LPQ", "nuisance_space", "partialling out",
              "observational", "missing-at-random"):
        skip("upstream sdist still declares the score string %r" % s,
             "the upstream sdist is not in this checkout")
must_re(r"README reconciles the three score vocabularies",
        r"three vocabularies are in play", readme)

print()
print("=" * 78)
print("J. library sources -- identifiers the docs must not name")
print("=" * 78)
check("MODEL_TOL appears nowhere in the MoonBit sources",
      "MODEL_TOL" not in allsrc, "found")
check("handrolled_se appears nowhere in the MoonBit sources",
      "handrolled_se" not in allsrc, "found")
check("next_f64 appears nowhere in the MoonBit sources",
      "next_f64" not in allsrc, "found")
check("coef_get appears nowhere in the MoonBit sources",
      "coef_get" not in allsrc, "found")
check("se_get appears nowhere in the MoonBit sources",
      "se_get" not in allsrc, "found")
# no third-party import in the library
third = []
for f, t in libsrc.items():
    for m in re.finditer(r'@([a-z_]+/[a-z_0-9]+(?:/[a-z_0-9]+)?)', t):
        pkg = m.group(1)
        if pkg.startswith("moonbit_doubleML"):
            continue
        third.append((f, pkg))
third_pkgs = sorted(set(p for _, p in third))
check("the library imports no third-party package",
      not [p for p in third_pkgs if p.startswith("moonbitlang/async")
           or p.startswith("moonbit-community/")],
      "third-party: %s" % third_pkgs)

print()
print("=" * 78)
print("K. every shipped document, checked for the retracted identifiers")
print("=" * 78)
ALLDOCS = dict(docs)
ALLDOCS["skills/moonbit_doubleML.md"] = skill
ALLDOCS["AGENTS.md"] = agents
ALLDOCS["README.mbt.md"] = readme
for name, text in sorted(ALLDOCS.items()):
    for bad in ("coef_get", "se_get", "next_f64", "dml_xxx", "RDB, BLP"):
        must_not("%s does not name %s" % (name, bad), bad, text)

print()
print("=" * 78)
print("SUMMARY: %d checks, %d failures" % (checks, len(fails)))
print("=" * 78)
for f in fails:
    print("  FAIL:", f)
sys.exit(1 if fails else 0)
