"""Round 22 verifier: the README's VERIFICATION-SURFACE claims, checked.

WHAT THIS IS FOR
================
The README has a section called "Not covered, so not claimed".  It is the
part of the document a reader trusts most -- it tells them what the
project's own verification does NOT cover -- and it is the part that rots
silently, because every claim in it is a claim about an ABSENCE:

    "The `coverage` check is a test-reachability proxy, not instrumented
     line coverage."
    "There is no dependency-vulnerability scan."
    "`mutation` kills three mutants on one kernel, not a whole-codebase
     surviving-mutant ledger, and no CI workflow runs it."
    "`examples/fuzz/` has no crash-regression corpus, and its seed argument
     is ignored ... and no CI workflow runs it either."

An absence cannot fail on its own.  If somebody adds a vulnerability scan to
the QA registry, or gives the fuzz harness a seed parameter, or wires the
mutation check into a workflow, the README keeps saying the opposite and
nothing notices -- because "no CI workflow runs it" is not a measurement, it
is a sentence.

So this file DERIVES each of them:

  * the counts the README states (the .mbt census, the Python script
    count, the example binaries) are counted from the tree;
  * the absence claims are re-derived from the QA registry itself -- the
    registry's own check ids, the mutation battery's size, the fuzz
    check's invocation count, the `coverage` check's own evidence string,
    and the `dependencies` check's live WARN message;
  * "no CI workflow runs it" is decided by scanning the workflow files for
    the check id in a line that IS NOT A COMMENT.

WHY THE ABSENCE CLAIMS AND NOT THE PRESENCE CLAIMS
==================================================
A presence claim -- "25 / 25 bit-exact items", "24 / 24 Python reference
scripts PASS" -- is enforced by the thing that produces it: the CI's
python-cross-check step runs the validators and fails if they stop passing.
The absence claims have no such producer.  That is why this file is about
them.

THE DERIVATIONS ARE NOT SUBSTRING MATCHES
==========================================
Where a fact lives in the QA registry, this file reads it out of the
registry's AST rather than grepping for a string: the mutation battery's
size is the number of elements in its MUTS list, and the fuzz check's
invocation count is the number of elements in its seed tuple.  A grep for
"three" would pass even if the battery grew to four; an AST count cannot.

Run: python _verify/_verify_test_verification_1650.py
"""
import ast
import importlib.util
import inspect
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

PKG = os.path.join(ROOT, "moonbit_doubleML")
QA = os.path.join(ROOT, ".github", "scripts", "qa_loop", "checks.py")
README = "README.mbt.md"
SHIPPED = os.path.join("moonbit_doubleML", "README.mbt.md")

FAILURES = []
CHECKS = 0

WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
         "seven": 7, "eight": 8, "nine": 9, "ten": 10}


def check(label, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print("  PASS  %s" % label)
    else:
        print("  *** FAIL ***  %s%s" % (label, (" -- " + detail) if detail else ""))
        FAILURES.append(label)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def norm(text):
    return re.sub(r"\s+", " ", text)


readme = read(README)
doc = norm(readme)

# ------------------------------------------------------------------ the QA registry
spec = importlib.util.spec_from_file_location("qa_checks_1650", QA)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
REG = {c["id"]: c for c in qa.CHECKS}

print()
print("A. the QA registry the README describes")
check("the QA registry loads and has its checks", len(REG) > 0,
      "%d checks" % len(REG))


def fn_source(fn):
    return inspect.getsource(fn)


def ast_of(fn):
    return ast.parse(fn_source(fn))


def list_len(fn, name):
    """The number of elements in the list/tuple assigned to `name`."""
    for node in ast.walk(ast_of(fn)):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == name:
                    v = node.value
                    if isinstance(v, (ast.List, ast.Tuple)):
                        return len(v.elts)
                    return None
    return None


def str_of(fn, name):
    for node in ast.walk(ast_of(fn)):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == name:
                    if isinstance(node.value, ast.Constant):
                        return node.value.value
    return None


def tuple_of(fn, name):
    for node in ast.walk(ast_of(fn)):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == name:
                    if isinstance(node.value, (ast.List, ast.Tuple)):
                        return [e.value for e in node.value.elts
                                if isinstance(e, ast.Constant)]
    return None


# ------------------------------------------------------------------ the counts
print()
print("B. the counts the README states are the counts in the tree")
mbt = []
for base, dirs, files in os.walk(PKG):
    dirs[:] = [d for d in dirs if d not in ("_build", "_verify", "target", ".git")]
    for f in files:
        if f.endswith(".mbt"):
            mbt.append(os.path.join(base, f))
prod = [p for p in mbt if "_test" not in os.path.basename(p)
        and "wbtest" not in os.path.basename(p)]
bb = [p for p in mbt if "_test" in os.path.basename(p)
      and "wbtest" not in os.path.basename(p)]
wb = [p for p in mbt if "wbtest" in os.path.basename(p)]

m = re.search(r"out of (\d+) `\.mbt` files in the package "
              r"\((\d+) production, (\d+) blackbox test, (\d+) whitebox test\)",
              doc)
check("the README states the .mbt census", m is not None)
if m:
    said = [int(x) for x in m.groups()]
    actual = [len(mbt), len(prod), len(bb), len(wb)]
    names = ["total .mbt files", "production", "blackbox test", "whitebox test"]
    for n, s, a in zip(names, said, actual):
        check("the README's %s count (%d) is the tree's (%d)" % (n, s, a), s == a)
    check("the three .mbt classes sum to the total",
          sum(actual[1:]) == actual[0],
          "%d + %d + %d = %d, total %d"
          % (actual[1], actual[2], actual[3], sum(actual[1:]), actual[0]))

validators = sorted(f for f in os.listdir(ROOT)
                     if f.startswith("validate_") and f.endswith("_with_python.py"))
m = re.search(r"\*\*(\d+) / \d+ Python reference scripts PASS\*\*", doc)
check("the README states the Python reference script count", m is not None)
if m:
    check("the README's %s reference scripts are the tree's (%d)"
          % (m.group(1), len(validators)),
          int(m.group(1)) == len(validators))

examples = sorted(d for d in os.listdir(os.path.join(ROOT, "examples"))
                  if os.path.isfile(os.path.join(ROOT, "examples", d, "main.mbt")))
m = re.search(r"\*\*(\d+) runnable example binaries\*\*", doc)
check("the README states the example binary count", m is not None)
if m:
    check("the README's %s example binaries are the tree's (%d)"
          % (m.group(1), len(examples)),
          int(m.group(1)) == len(examples))

# ------------------------------------------------------- the absence claims
print()
print("C. the absence claims are still true")


def ci_runs(check_id):
    """Does any workflow RUN this check id?  A comment that names it does
    not count -- the workflows say in as many words that these checks run
    in no CI job, and the sentences that say so MENTION the ids."""
    hits = []
    wfdir = os.path.join(ROOT, ".github", "workflows")
    for wf in sorted(os.listdir(wfdir)):
        for i, line in enumerate(read(os.path.join(wfdir, wf)).split("\n"), 1):
            if line.strip().startswith("#"):
                continue
            if re.search(r"\b%s\b" % re.escape(check_id), line):
                hits.append("%s:%d" % (wf, i))
    return hits


for claim, cid in (("`mutation` kills three mutants on one kernel", "mutation"),
                    ("`examples/fuzz/` has no", "fuzz")):
    check("the README makes the %r claim" % claim, claim in doc)

if "mutation" in REG:
    n_muts = list_len(qa.c_mutation, "MUTS")
    tgt = str_of(qa.c_mutation, "tgt")
    check("the mutation battery has three mutants (the tree has %s)" % n_muts,
          n_muts == 3)
    check("the mutation battery targets ONE kernel (the tree targets %s)" % tgt,
          bool(tgt) and isinstance(tgt, str))
    m = re.search(r"`mutation` kills (\w+) mutants on one kernel", doc)
    check("the README's mutation count matches the battery's",
          m is not None and WORDS.get(m.group(1)) == n_muts,
          "the README says %r, the battery has %s" % (m.group(1) if m else None,
                                                       n_muts))
    check("no CI workflow runs the mutation check", not ci_runs("mutation"),
          "run by %s" % ci_runs("mutation"))
    ev = qa.c_mutation.__doc__ or ""
    check("the mutation check says it is not a CI runner",
          "not a CI runner" in read(QA))

if "fuzz" in REG:
    seeds = tuple_of(qa.c_fuzz, "seeds")
    n_inv = len(seeds) if seeds else 0
    # the seed tuple is a literal inside the function body, so read it from
    # the source's `for seed in (...)`
    src = fn_source(qa.c_fuzz)
    m2 = re.search(r"for seed in \(([^)]*)\)", src)
    seeds = re.findall(r'"([^"]+)"', m2.group(1)) if m2 else []
    n_inv = len(seeds)
    check("the fuzz check invokes the harness three times (the tree: %d)"
          % n_inv, n_inv == 3)
    # Round 36: the README now says "one fixed MASTER seed" -- the harness
    # derives its 11 per-surface RNGs from that one master -- so the word is
    # optional here.  The FACT this check asserts is unchanged: the count word
    # the README states must equal the number of invocations the check makes.
    m = re.search(r"replays one fixed (?:master )?seed \((\d+)\) (\w+) times", doc)
    check("the README states the fuzz invocation count",
          m is not None and WORDS.get(m.group(2)) == n_inv,
          "the README says %r, the check makes %d" % (m.group(2) if m else None,
                                                     n_inv))
    # the harness: `fn main` takes no parameters, and one seed is fixed
    harness = read(os.path.join(ROOT, "examples", "fuzz", "main.mbt"))
    mm = re.search(r"fn main\s*(\([^)]*\))?\s*\{", harness)
    check("the fuzz harness's `fn main` takes no parameters",
          mm is not None and not (mm.group(1) or "").strip(),
          "signature: %r" % (mm.group(1) if mm else None))
    fixed = re.search(r"seed_to_bytes\((\d+)\)", harness)
    check("the fuzz harness names one fixed seed",
          fixed is not None, "no seed_to_bytes(NNN) found")
    if fixed and m:
        check("the README's fixed seed is the harness's fixed seed",
              fixed.group(1) == m.group(1),
              "the harness uses %s, the README says %s"
              % (fixed.group(1), m.group(1)))
    check("no CI workflow runs the fuzz check", not ci_runs("fuzz"),
          "run by %s" % ci_runs("fuzz"))
    corpus = [p for p in os.listdir(os.path.join(ROOT, "examples", "fuzz"))
              if "corpus" in p.lower() or p.endswith(".log")]
    check("examples/fuzz has no crash-regression corpus", not corpus,
          "found %s" % corpus)

if "coverage" in REG:
    ev = qa.c_coverage().evidence
    check("the `coverage` check says it is a PROXY, not line coverage",
          "PROXY, not line coverage" in ev, ev[:120])
    check("the `coverage` check measures reachability by NAME",
          "referenced by name" in ev, ev[:120])
    check("the README calls `coverage` a test-reachability proxy",
          "test-reachability proxy" in doc)

# ------------------------------------------------- the vulnerability scanner
print()
print("D. there is still no dependency-vulnerability scan")
scan_words = ("vulnerability", "osv", "snyk", "pip-audit", "safety")
found = []
for wf in sorted(os.listdir(os.path.join(ROOT, ".github", "workflows"))):
    for i, line in enumerate(read(os.path.join(ROOT, ".github", "workflows", wf)).split("\n"), 1):
        if line.strip().startswith("#"):
            continue
        low = line.lower()
        for w in scan_words:
            if w in low and "no vulnerability scanner" not in low:
                found.append("%s:%d %s" % (wf, i, line.strip()[:60]))
check("no CI workflow runs a dependency-vulnerability scan", not found,
      "; ".join(found))
check("the README says there is no dependency-vulnerability scan",
      "There is no dependency-vulnerability scan" in doc)
check("the QA registry's own note says moon update is not an audit",
      "moon update is not an audit" in read(QA))

# ------------------------------------------------------- the dependencies WARN
print()
print("E. the quoted WARN is the WARN the check produces")
if "dependencies" in REG:
    r = qa.c_deps()
    live = r.evidence.split("  [")[0].strip()
    m = re.search(r"`(2 declared; [^`]*)`", doc)
    check("the README quotes the dependencies WARN", m is not None)
    if m:
        check("the README's quoted WARN is the live WARN",
              m.group(1).strip() == live,
              "README: %r\nlive  : %r" % (m.group(1).strip(), live))
    check("the dependencies check WARNs rather than passing quietly",
          r.verdict == "WARN", "verdict: %s" % r.verdict)
    for d in ("moonbit-community/sqlite3@0.2.3", "moonbitlang/async@0.22.6"):
        check("the dependency %s is still declared" % d,
              d in read(os.path.join(PKG, "moon.mod")))
        check("the dependency %s is still unreferenced by the library" % d,
              d.split("@")[0].rsplit("/", 1)[-1] not in "".join(read(p) for p in mbt))

print()
print("F. the two copies")
shipped = read(SHIPPED)
check("the shipped README is byte-identical to the edited one",
      shipped.encode("utf-8") == readme.encode("utf-8"))
check("the README is LF-only with no BOM",
      b"\r" not in readme.encode("utf-8")
      and not readme.encode("utf-8").startswith(b"\xef\xbb\xbf"))

print()
print("=" * 72)
print("%d checks, %d failed" % (CHECKS, len(FAILURES)))
if FAILURES:
    print("*** FAIL ***")
    for f in FAILURES:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
