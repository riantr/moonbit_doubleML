"""Check the README's NEGATIVE claims -- the "Not covered, so not claimed" section.

A LIMIT that is no longer a limit is a false claim, and a false claim in a
document that promises honesty is worse than no claim at all.  The README's
`### Not covered, so not claimed` section states seven such limits, and until
this round NOTHING checked any of them: the section was trusted, and the whole
point of the section is that it is not to be trusted.

Every check here DERIVES its expectation from the tree:

  N1/N2  the `mutation` and `fuzz` checks run in NO CI workflow.  The QA
         runner's selection rule is read out of the registry: a check runs
         when it is selected AND (its scope is not "full" OR --full was
         passed).  The workflows' invocations are read out of the YAML, so the
         set of checks CI actually runs is DERIVED, not asserted.
  N3     `examples/fuzz`'s `fn main` takes no parameters -- the seed argument
         is ignored.
  N4     the harness's fixed master seed is the one the README names.
  N5     the fuzz check invokes the harness three times, with three different
         seed arguments -- which is why the seed argument being ignored makes
         it a RE-RUN of one run rather than a sweep.
  N6     the `coverage` check is a reachability proxy, not instrumented line
         coverage -- the registry's own message says so.
  N7     the `mutation` check applies three mutants, all to ONE file.
  N8/N9  the two declared `moon.mod` dependencies are unreferenced by the
         library's code, and the `dependencies` check's OWN verdict is WARN.
  N10    the README quotes the message that check actually emits.
  N11    no CI run step invokes a dependency-vulnerability scanner.
  N12    `examples/fuzz/` has no crash-regression corpus.
  N13    the README actually STATES each of these, so this verifier cannot
         rot into checking nothing.
  N14    the limit is not OVERSTATED: the README names the harness's scale,
         and neither the README nor the QA check's evidence calls one
         invocation "one case".

TWO METHOD POINTS, both paid for in this round:

  * A document is HARD-WRAPPED.  The README's claims are broken across lines,
    so every claim is matched against a WHITESPACE-NORMALISED copy of the
    document.  The first version of this file compared raw substrings and
    reported five failures that were all its own line-wrapping, not the
    README's -- it flagged as "NOT FOUND" five claims the README states.
  * The `dependencies` message is taken from the check's OWN output --
    `c_deps()` is CALLED -- not from a second implementation of its logic
    living in the verifier.  A verifier that re-implements the thing it
    verifies is a second opinion, not a witness.

Run: python _verify/_verify_not_covered_1650.py
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
READMEs = [os.path.join(ROOT, "README.mbt.md"),
           os.path.join(PKG, "README.mbt.md")]
CHECKS_PY = os.path.join(ROOT, ".github", "scripts", "qa_loop", "checks.py")
FUZZ_MAIN = os.path.join(ROOT, "examples", "fuzz", "main.mbt")
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")

# The declared size of the claim set.  A change to it is a change to the SET.
EXPECTED_CLAIMS = 11

fails = []
NCHECK = 0


def check(label, cond, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


def read(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


def norm(text):
    """Collapse every whitespace run to one space.

    The document under test is hard-wrapped, so a claim written on one line
    appears in it across several.  Comparing normalised forms is what makes
    "the README states this" a question about the TEXT rather than about the
    typesetter.
    """
    return " ".join(text.split())


readme = read(READMEs[0])
readme_n = norm(readme)
for p in READMEs[1:]:
    check("the two README copies are byte-identical", read(p) == readme, p)

# ---------------------------------------------------------------------------
# the QA registry: every check's id and scope
# ---------------------------------------------------------------------------

checks_src = read(CHECKS_PY)
tree = ast.parse(checks_src)
SCOPE = {}
FUNCS = {}
for node in tree.body:
    if isinstance(node, ast.FunctionDef):
        FUNCS[node.name] = node
        for dec in node.decorator_list:
            if isinstance(dec, ast.Call) and getattr(dec.func, "id", "") == "check":
                args = [ast.literal_eval(a) for a in dec.args]
                SCOPE[args[0]] = args[2]

print("== the registry ==")
print("   the registry holds %d checks; %d are full scope: %s"
      % (len(SCOPE), sum(1 for v in SCOPE.values() if v == "full"),
         ", ".join(sorted(k for k, v in SCOPE.items() if v == "full"))))
check("the registry's checks and scopes are findable", len(SCOPE) > 20, str(len(SCOPE)))

# ---------------------------------------------------------------------------
# the workflows: which checks does CI actually RUN?
# ---------------------------------------------------------------------------


def qa_invocations(path):
    """Every `qa_loop/run.py` invocation in a workflow, with its flags.

    A `run: |` block continues while the following lines are indented deeper
    than the `run:` key that opened it, so the command is gathered with the
    step it belongs to rather than with the file.
    """
    lines = read(path).split("\n")
    out = []
    for i, line in enumerate(lines):
        if "qa_loop/run.py" not in line:
            continue
        base = 0
        for j in range(i, -1, -1):
            m = re.match(r"^(\s*)run:", lines[j])
            if m:
                base = len(m.group(1))
                break
        block = [line]
        k = i + 1
        while k < len(lines):
            nxt = lines[k]
            if not nxt.strip():
                break
            if len(nxt) - len(nxt.lstrip()) <= base:
                break
            block.append(nxt)
            k += 1
        text = "\n".join(block)
        only = ""
        m = re.search(r"--only\s+(\S+)", text)
        if m:
            only = m.group(1)
        out.append({"file": os.path.basename(path), "line": i + 1,
                    "only": [x.strip() for x in only.split(",") if x.strip()],
                    "full": "--full" in text})
    return out


INVOCATIONS = []
for f in sorted(os.listdir(WORKFLOWS)):
    if f.endswith((".yml", ".yaml")):
        INVOCATIONS += qa_invocations(os.path.join(WORKFLOWS, f))

print("   the workflows make %d QA invocation(s):" % len(INVOCATIONS))
for inv in INVOCATIONS:
    print("      %-14s line %-4d --only=%-24s --full=%s"
          % (inv["file"], inv["line"], ",".join(inv["only"]) or "(none)", inv["full"]))

# The set of checks that actually RUN, derived from the runner's own rule:
# a selected check runs when its scope is not "full", or --full was passed.
RUNNING = set()
for inv in INVOCATIONS:
    selected = inv["only"] if inv["only"] else list(SCOPE)
    for cid in selected:
        if cid not in SCOPE:
            continue
        if SCOPE[cid] != "full" or inv["full"]:
            RUNNING.add(cid)

print("   the checks CI actually runs: %d of %d" % (len(RUNNING), len(SCOPE)))
print("   the full-scope checks CI does NOT run: %s"
      % ", ".join(sorted(k for k, v in SCOPE.items()
                         if v == "full" and k not in RUNNING)))

# ---------------------------------------------------------------------------
# N1 / N2 -- the mutation and fuzz checks run nowhere
# ---------------------------------------------------------------------------

print("")
print("== the checks that run in no CI workflow ==")
for cid in ("mutation", "fuzz"):
    check("the %r check runs in no CI workflow" % cid,
          cid not in RUNNING,
          "it is selected by %s" % [i["file"] for i in INVOCATIONS
                                    if not i["only"] or cid in i["only"]])

# ---------------------------------------------------------------------------
# the QA module itself -- the checks are CALLED, not re-implemented
# ---------------------------------------------------------------------------

spec = importlib.util.spec_from_file_location("qa_checks", CHECKS_PY)
QA = importlib.util.module_from_spec(spec)
spec.loader.exec_module(QA)
check("the QA module is importable", QA is not None)

# ---------------------------------------------------------------------------
# N3 / N4 / N5 -- the fuzz harness and its check
# ---------------------------------------------------------------------------

print("")
print("== the fuzz harness ==")
fuzz_src = read(FUZZ_MAIN)
m = re.search(r"^fn main\b\s*(\(([^)]*)\))?", fuzz_src, re.M)
check("examples/fuzz's `fn main` is findable", m is not None)
if m:
    params = (m.group(2) or "").strip()
    check("examples/fuzz's `fn main` takes no parameters",
          params == "", "it takes %r" % params)

m = re.search(r"seed_to_bytes\((\d+)\)", fuzz_src)
check("the harness's fixed master seed is findable", m is not None)
MASTER_SEED = m.group(1) if m else None
if MASTER_SEED:
    check("the harness's fixed master seed is the one the README names",
          "(%s)" % MASTER_SEED in readme_n,
          "the source says %s" % MASTER_SEED)

# the harness's SCALE: how many surfaces, how many trials each.  Derived two
# ways -- the calls that take a trial count, and the [k/N] markers the harness
# prints -- and the two must agree.
SURFACES = len(re.findall(
    r"fuzz_[a-z0-9_]+\(@moonbit_doubleML\.chacha8_rng\(s\d+\), trials\)", fuzz_src))
DENOMS = set(d for _k, d in re.findall(r"\[(\d+)/(\d+)\]", fuzz_src))
TRIALS = re.findall(r"let trials\s*=\s*(\d+)", fuzz_src)
check("the harness's surface count is derivable", SURFACES > 0, str(SURFACES))
check("the harness's printed surface count agrees with the call count",
      DENOMS == {str(SURFACES)},
      "the calls give %d, the markers give %s" % (SURFACES, sorted(DENOMS)))
check("the harness's trial count is findable", len(TRIALS) == 1, str(TRIALS))
N_TRIALS = int(TRIALS[0]) if TRIALS else 0
check("the harness's trial count is positive", N_TRIALS > 0, str(N_TRIALS))
print("   the harness's scale: %d surfaces, %d trials per surface"
      % (SURFACES, N_TRIALS))

# the QA check's own scale derivation must agree with ours
qa_scale = QA.fuzz_scale() if hasattr(QA, "fuzz_scale") else None
check("the QA check derives the harness's scale", qa_scale is not None)
if qa_scale:
    check("the QA check's scale agrees with the source",
          tuple(qa_scale) == (SURFACES, N_TRIALS),
          "the check says %s, the source says %s"
          % (tuple(qa_scale), (SURFACES, N_TRIALS)))

# the fuzz check's seed arguments
seeds = None
fn = FUNCS.get("c_fuzz")
if fn is not None:
    for node in ast.walk(fn):
        if isinstance(node, ast.For) and isinstance(node.iter, ast.Tuple):
            vals = [e.value for e in node.iter.elts
                    if isinstance(e, ast.Constant) and isinstance(e.value, str)]
            if vals:
                seeds = vals
check("the fuzz check's seed arguments are findable", seeds is not None)
if seeds:
    check("the fuzz check invokes the harness three times",
          len(seeds) == 3, str(seeds))
    check("the fuzz check's three seed arguments are DIFFERENT",
          len(set(seeds)) == len(seeds), str(seeds))

# ---------------------------------------------------------------------------
# N6 -- the coverage check is a proxy
# ---------------------------------------------------------------------------

print("")
print("== the coverage check ==")
fn = FUNCS.get("c_coverage")
cover_src = ast.get_source_segment(checks_src, fn) if fn else ""
check("the coverage check's body is findable", bool(cover_src))
check("the coverage check says it is a PROXY, not line coverage",
      "PROXY, not line coverage" in cover_src,
      "the registry's own message does not say so")
check("the coverage check is a fast-scope check", SCOPE.get("coverage") == "fast",
      str(SCOPE.get("coverage")))

# ---------------------------------------------------------------------------
# N7 -- the mutation battery: three mutants, one file
# ---------------------------------------------------------------------------

print("")
print("== the mutation battery ==")
fn = FUNCS.get("c_mutation")
muts = None
target = None
if fn is not None:
    for node in ast.walk(fn):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "MUTS" \
                        and isinstance(node.value, (ast.List, ast.Tuple)):
                    muts = len(node.value.elts)
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "tgt" \
                        and isinstance(node.value, ast.Constant):
                    target = node.value.value
check("the mutation battery's size is findable", muts is not None)
if muts is not None:
    check("the mutation battery applies three mutants", muts == 3, str(muts))
    check("the mutation battery targets one file", bool(target),
          "the target is %r" % target)
    if target:
        check("the mutation battery's target exists",
              os.path.isfile(os.path.join(PKG, target)), target)

# ---------------------------------------------------------------------------
# N8 / N9 / N10 -- the declared dependencies are dead, and the quote is right
# ---------------------------------------------------------------------------

print("")
print("== the declared dependencies ==")
raw = read(os.path.join(PKG, "moon.mod"))
live = "\n".join(re.sub(r"//.*$", "", ln) for ln in raw.split("\n"))
m = re.search(r"import\s*\{(.*?)\}", live, re.S)
deps = re.findall(r'"([^"]+)"', m.group(1)) if m else []
check("the package's import block is findable", bool(deps))
srcs = ""
for b, _d, fs in os.walk(PKG):
    for fn2 in fs:
        if fn2.endswith(".mbt"):
            srcs += read(os.path.join(b, fn2))
unused = [d for d in deps
          if d.split("@")[0].rsplit("/", 1)[-1] not in srcs]
check("the declared dependencies are unreferenced by the library code",
      len(unused) == len(deps), str(unused))

# the check's OWN output -- CALLED, not re-implemented here
deps_result = QA.c_deps()
check("the `dependencies` check reports WARN", deps_result.verdict == "WARN",
      deps_result.verdict)
for d in unused:
    check("the `dependencies` check names %r as unreferenced" % d,
          d in deps_result.evidence, deps_result.evidence)

# The message the check EMITS, minus the bracketed note it appends: that is
# the part the README quotes.  It is taken from the check's own output, so
# the claim set below is not the README agreeing with itself.
DEPS_MSG = norm(re.sub(r"\s*\[[^\]]*\]\s*$", "", deps_result.evidence)).strip()
check("the `dependencies` check emits a message", bool(DEPS_MSG),
      repr(deps_result.evidence))

# the README's quote must be a PREFIX of what the check actually emits
QUOTED = ""
mq = re.search(r"WARNs about exactly that \((.*?)\)", readme_n)
if mq:
    QUOTED = mq.group(1).strip().strip("`")
check("the README quotes the `dependencies` message", bool(QUOTED),
      "the README does not quote it")
if QUOTED:
    check("the quoted `dependencies` message is what the check emits",
          norm(deps_result.evidence).startswith(norm(QUOTED)),
          "the check emits: %s" % deps_result.evidence)

# ---------------------------------------------------------------------------
# N11 -- no dependency-vulnerability scan in CI
# ---------------------------------------------------------------------------

print("")
print("== the CI's dependency audit ==")
# a KNOWN-SCANNER list: the check is "no known scanner is invoked", which is
# narrower than "no scan exists" and is stated as such.
SCANNERS = ("pip-audit", "safety", "osv-scanner", "osv_scanner", "npm audit",
            "cargo audit", "govulncheck", "trivy", "snyk", "grype", "audit-ci")
run_lines = []
for f in sorted(os.listdir(WORKFLOWS)):
    if not f.endswith((".yml", ".yaml")):
        continue
    for line in read(os.path.join(WORKFLOWS, f)).split("\n"):
        st = line.strip()
        if st.startswith("run:"):
            run_lines.append((f, st))
        elif st.startswith("python3 ") or st.startswith("moon ") or st.startswith("typos"):
            run_lines.append((f, st))
found = [(f, s) for f, s in run_lines
         if any(sc in s.lower() for sc in SCANNERS)]
check("no CI run step invokes a dependency-vulnerability scanner",
      not found, str(found[:3]))
print("   the CI's run commands: %d" % len(run_lines))

# ---------------------------------------------------------------------------
# N12 -- no crash-regression corpus
# ---------------------------------------------------------------------------

print("")
print("== the crash-regression corpus ==")
fuzz_dir = os.path.join(ROOT, "examples", "fuzz")
corpus = []
for b, _d, fs in os.walk(fuzz_dir):
    for f in fs:
        low = f.lower()
        if any(k in low for k in ("corpus", "regression", "crash")):
            corpus.append(os.path.join(b, f))
check("examples/fuzz has no crash-regression corpus", not corpus, str(corpus[:3]))

# ---------------------------------------------------------------------------
# N13 -- the README STATES these claims
# ---------------------------------------------------------------------------

print("")
print("== the README states the claims this file checks ==")
CLAIMS = [
    "no CI workflow runs it",
    "no CI workflow runs it either",
    "its seed argument is **ignored** -- `fn main` takes no parameters",
    "replays one fixed master seed (%s) three times rather than sweeping seeds"
    % MASTER_SEED,
    "Each invocation is a real property-based run -- %d surfaces, %d trials per surface"
    % (SURFACES, N_TRIALS),
    "The `coverage` check is a test-reachability proxy, not instrumented line coverage",
    "There is no dependency-vulnerability scan",
    "`mutation` kills three mutants on one kernel",
    "are dead: nothing imports them",
    "`examples/fuzz/` has no crash-regression corpus",
    DEPS_MSG,
]
check("the claim set is the declared size", len(CLAIMS) == EXPECTED_CLAIMS,
      "found %d, declared %d" % (len(CLAIMS), EXPECTED_CLAIMS))
for c in CLAIMS:
    check("the README states %r" % c[:44], norm(c) in readme_n, "NOT FOUND")

# ---------------------------------------------------------------------------
# N14 -- the limit is not OVERSTATED
# ---------------------------------------------------------------------------
#
# A limit that is exaggerated is as false as one that is understated.  The
# README used to call one fuzz invocation "one case, not a fuzz"; one
# invocation is 11 surfaces at 300 trials each, so the claim must name the
# scale, and neither the README nor the check's evidence may call it a case.

print("")
print("== the limit is not overstated ==")
check("the README names the harness's scale",
      "%d surfaces, %d trials per surface" % (SURFACES, N_TRIALS) in readme_n)
check("the README does not call a fuzz run 'one case'",
      "one case" not in readme_n)

# The QA check's EVIDENCE is what a developer reads, so the scan is over the
# string literals the check builds -- not over the whole file, where a comment
# may legitimately quote the old wording to say what changed.
FUZZ_LITERALS = " ".join(
    n.value for n in ast.walk(FUNCS["c_fuzz"])
    if isinstance(n, ast.Constant) and isinstance(n.value, str)) \
    if "c_fuzz" in FUNCS else ""
check("the QA check's evidence does not call a fuzz run 'one case'",
      "one case" not in FUZZ_LITERALS, FUZZ_LITERALS[:120])
check("the QA check's evidence does not deny that the harness fuzzes",
      "not fuzzing" not in FUZZ_LITERALS and "not a fuzz" not in FUZZ_LITERALS,
      FUZZ_LITERALS[:120])
check("the QA check names the harness's scale",
      "trials per surface" in FUZZ_LITERALS)

print("")
print("%d checks, %d failed" % (NCHECK, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
