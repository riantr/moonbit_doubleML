"""Round 17 -- pin the LPLR record's promises, claim by claim.

`_verify/LPLR_GATE_BLINDNESS_1680.md` is the ONLY `_verify/`
record the shipped README cites, so a promise this record makes is a promise
the README inherits.  This round found that the record had never been
re-audited, and it had accumulated four kinds of rot:

  1. FOUR TEST COUNTS that were true when written and are now stale
     (`1115/1115` twice, `1122/1122` twice).  A historical count rewritten as
     a current one is a different claim, so the fix is to RE-ANCHOR each one
     to the commit that wrote it, not to overwrite it with today's number.
  2. SIXTEEN `moonbit_doubleML/lplr.mbt:NNN` line pointers.  That file moved
     by 624 lines, so eight of them no longer land on the line they claim.
  3. TEN METHOD SCRIPTS the record names, none of which was tracked -- and
     every one of them hard-coded one machine's absolute path, so a clone
     could not run any of them.
  4. A WITNESS THAT WAS THE WRONG FILE: section 27a named
     `_fuzz_dump_1680.log`, which is byte-identical to `_fuzz_run_1680.log`
     and holds the harness transcript, not rows.

WHAT THIS PINS
--------------
1. The record is TRACKED and carries a dated banner and an explicit
   "what is NOT verified" statement.
2. Every `file:line` pointer in it resolves to a real file and a real line,
   and the CONTENT there is the thing the record claims.  A pointer that
   resolves to the wrong line is still wrong.
3. Every script it names exists AND is tracked, and is path-portable.
4. The stale test counts do not appear UNANCHORED in the body.  The banner is
   excluded from that check: a correct "was -> now" banner legitimately
   quotes the old value, and a check that cannot tell the two apart will
   either fail on a good banner or pass on a bad body.
5. The current counts the record quotes are DERIVED from the tree, not
   literals.
6. The withdrawn witness is not cited in the body as a witness.
7. The README's inherited numbers agree with the record's.

DRY-RUN
-------
`ROUND17_ROOT` points the verifier at another checkout, so the same checks
can be run against the PREVIOUS release.  The dry-run counts the failures
exactly, so a verifier that has stopped biting is visible.
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.environ.get("ROUND17_ROOT") or \
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

REC = "_verify/LPLR_GATE_BLINDNESS_1680.md"
checks = 0
fails = []


def check(name, ok):
    global checks
    checks += 1
    if not ok:
        fails.append(name)
    print("  [%s] %s" % ("ok  " if ok else "FAIL", name))


def read(p):
    if not os.path.isfile(p):
        return b""
    with io.open(p, "rb") as fh:
        return fh.read()


def git(*a):
    r = subprocess.run(["git"] + list(a), cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.stdout


TRACKED = set(x.strip() for x in git("ls-files").splitlines() if x.strip())


def body(text):
    """The record's BODY: the leading blockquote banner is dropped.

    A correct banner legitimately quotes the value being corrected, so a
    stale-claim check that reads the whole file cannot tell a good banner
    from a bad body.
    """
    lines = text.split("\n")
    i = 0
    while i < len(lines) and not lines[i].startswith(">"):
        i += 1
    if i == len(lines):
        return text
    j = i
    while j < len(lines) and (lines[j].startswith(">") or lines[j].strip() == ""):
        j += 1
    return "\n".join(lines[:i] + lines[j:])


def test_blocks(subdir):
    """The `test "..."` declarations under a directory, by NAME.

    The SAME rule `_verify/_verify_testcounts_1610.py` uses, and the rule the
    README's generator uses: a WORKING-TREE walk, de-duplicated by name.

    It used to count the COMMITTED tree, and that made the check true at
    exactly ONE point in the release cycle -- before the commit it read the
    previous release's count and after the commit it read the new one, so
    the same record could not satisfy it at both ends of the release.  A
    check that is only true half the time is not a check.
    """
    acc = set()
    for base, dirs, files in os.walk(os.path.join(ROOT, subdir)):
        dirs[:] = [x for x in dirs if x not in ("_build", "_verify", "target", ".git")]
        for f in files:
            if f.endswith(".mbt"):
                src = io.open(os.path.join(base, f), encoding="utf-8",
                              errors="replace").read()
                acc.update(re.findall(r'\btest\s+"([^"]+)"', src))
    return len(acc)


print("=" * 78)
print("ROUND 17 -- LPLR record promises")
print("root: %s" % ROOT)
print("=" * 78)

raw = read(REC)
check("the record exists", bool(raw))
if not raw:
    print("checks: %d   failed: %d" % (checks, len(fails)))
    sys.exit(1)
text = raw.decode("utf-8", "replace")
bd = body(text)

print()
print("-- 1. the record is tracked, dated, and honest about its limits --")
check("the record is TRACKED", REC in TRACKED)
check("the record has a dated re-audit banner",
      re.search(r"^> \*\*Re-audited \d{4}-\d{2}-\d{2}", text, re.M) is not None)
check("the banner names the commit that added the record", "`d3ac364`" in text)
check("the banner has a 'what has changed since' table",
      "What was re-measured live" in text and "|" in text)
check("the record states what is NOT verified",
      "What is NOT verified here." in text)
check("the record says it is the only record the README cites",
      "only" in text and "README" in text)

print()
print("-- 2. the stale test counts are RE-ANCHORED, not overwritten --")
# The banner legitimately quotes the old value, so the BODY is what is
# checked.  The anchor may sit on a LATER line than the count (the count is
# in a sentence and the anchor is in the parenthetical under it), so the
# window is a plain slice -- it crosses newlines.
# `1117/1117` joined the list when the counts moved: it was TRUE when it
# was written and it is stale now, so it is anchored like the two before it.
STALE = re.compile(r"(1115/1115|1122/1122|1117/1117)")
ANCHOR = re.compile(r"`[0-9a-f]{7}`|\btoday\b")
for m in STALE.finditer(bd):
    after = bd[m.end():m.end() + 400]
    before = bd[max(0, m.start() - 200):m.start()]
    check("the body anchors %s to the commit that wrote it" % m.group(1),
          ANCHOR.search(after) is not None or ANCHOR.search(before) is not None)
native = test_blocks("moonbit_doubleML")
doc = test_blocks("doc")
# The counts are DERIVED, so this check holds no literal of its own to go
# stale: the record must state whatever the tree says today.
check("the body states the CURRENT count",
      ("**%d**" % native) in bd and ("**%d**" % (native + doc)) in bd)
check("the derived native count matches what the record claims",
      ("**%d**" % native) in text)
check("the derived wasm-gc count matches what the record claims",
      ("**%d**" % (native + doc)) in text)
# A PRESENCE check cannot see a record that states the current count AND a
# wrong one: it asks whether the number appears, not whether the CLAIM is
# true.  The record says which counts are CURRENT by the word "today" -- "it
# is **1118** today" -- so those claims are read out and held against the
# tree, and a count the record calls current must BE the current count.
TODAY = re.compile(r"\*\*(\d+)\*\*\s+today")
CLAIMS = set(int(m.group(1)) for m in TODAY.finditer(bd))
check("the record calls at least one count current, so the claim below is "
      "readable",
      len(CLAIMS) > 0)
check("every count the record calls current IS the current count",
      CLAIMS <= set([native, native + doc]))
check("the wasm-gc count is native + the doc tutorials, not a literal",
      doc == 6)

print()
print("-- 3. every pointer resolves, and resolves to the right CONTENT --")
import doubleml  # noqa: E402
UP = os.path.dirname(doubleml.__file__)
PKG = os.path.join(ROOT, "moonbit_doubleML")
UPSTREAM_ALIASES = {
    "lplr.py": os.path.join("plm", "lplr.py"),
    "_estimation.py": os.path.join("utils", "_estimation.py"),
    "double_ml_score_mixins.py": "double_ml_score_mixins.py",
    "resampling.py": os.path.join("utils", "resampling.py"),
    "utils/_estimation.py": os.path.join("utils", "_estimation.py"),
    "utils/resampling.py": os.path.join("utils", "resampling.py"),
    "plm/lplr.py": os.path.join("plm", "lplr.py"),
    "doubleml/plm/lplr.py": os.path.join("plm", "lplr.py"),
    "doubleml/utils/_estimation.py": os.path.join("utils", "_estimation.py"),
}


def resolve(path):
    base = os.path.basename(path)
    cands = []
    if path.startswith("doubleml/"):
        cands.append(os.path.join(UP, path[len("doubleml/"):]))
    if path in UPSTREAM_ALIASES:
        cands.append(os.path.join(UP, UPSTREAM_ALIASES[path]))
    if path == "check.yml":
        cands.append(os.path.join(ROOT, ".github", "workflows", "check.yml"))
    if path.endswith(".mbt"):
        cands.append(os.path.join(PKG, base))
    cands += [os.path.join(ROOT, path), os.path.join(PKG, path),
              os.path.join(ROOT, base), os.path.join(UP, path),
              os.path.join(UP, base)]
    for c in cands:
        if os.path.isfile(c):
            return os.path.normpath(c)
    return None


PTR = re.compile(r"`?([A-Za-z0-9_./\\-]+\.(?:py|mbt|md|ps1|yml|yaml|json|txt)):(\d+)(?:-(\d+))?`?")
pointers = {}
for m in PTR.finditer(text):
    a = int(m.group(2))
    b = int(m.group(3)) if m.group(3) else None
    pointers.setdefault((m.group(1), a, b), 0)
    pointers[(m.group(1), a, b)] += 1

unresolved, outof = [], []
for (path, a, b) in sorted(pointers, key=lambda k: (k[0], k[1], k[2] or 0)):
    real = resolve(path)
    if real is None:
        unresolved.append("%s:%s" % (path, a))
        continue
    n = len(open(real, encoding="utf-8", errors="replace").read().split("\n"))
    if (b or a) > n:
        outof.append("%s:%s (file has %d lines)" % (path, a, n))
check("every pointer in the record resolves to a real file (%d pointers)"
      % len(pointers), not unresolved)
for u in unresolved:
    print("        unresolved: %s" % u)
check("every pointer's line is inside the file", not outof)
for u in outof:
    print("        out of range: %s" % u)

CONTENT = [
    ("lplr.mbt", 199, 199, "r_hat = t_pred"),
    ("lplr.mbt", 203, 204, "expit(-r_hat)"),
    ("lplr.mbt", 362, 364, "LogisticRegression::new()"),
    ("lplr.mbt", 667, 667, "route `ml_g` to the `ml_t` slot"),
    ("lplr.mbt", 783, 783, "kfold(n, self.n_folds, self.seed + r)"),
    ("lplr.mbt", 777, 784, "set_sample_splitting"),
    ("lplr.mbt", 838, 838, "cross_fit_predict_dispatch"),
    ("lplr.mbt", 856, 878, "reverted twice"),
    ("lplr.mbt", 870, 870, "0.007307 -> 0.021078"),
    ("lplr.mbt", 872, 872, "1.03e11"),
    ("lplr.mbt", 930, 930, "m_pred = a_pred"),
    ("lplr.mbt", 1238, 1244, "One real divergence"),
    ("lplr.mbt", 1262, 1262, "theta_new.abs() > 5.0"),
    ("lplr.mbt", 1263, 1263, "raw_delta.abs() < 0.25"),
    ("lplr.mbt", 1266, 1266, "(theta_new - theta).abs() < 1.0e-9"),
    ("lplr.mbt", 1618, 1636, "cross_fit_predict_inner"),
    ("var_est.mbt", 79, 79, "jacobian.abs() > 0.0"),
    ("logistic.mbt", 218, 218, "pub fn LogisticRegression::predict("),
    ("logistic.mbt", 251, 251, "pub fn LogisticRegression::predict_class("),
    ("kfold.mbt", 758, 758, "Array::make(m, 0.0)"),
    ("kfold.mbt", 752, 758, "kfold(m, n_inner, rng_state)"),
    ("learner.mbt", 162, 162, "P(y = 1 | x)"),
    ("learner.mbt", 383, 428, "cross_fit_predict_conditional_dispatch"),
    ("expand_v145_test.mbt", 38, 136, "lplr_warnings_report_the_degenerate_design"),
    ("examples/fuzz/main.mbt", 412, 412, "rng.int(limit=100) + 60"),
    ("examples/fuzz/main.mbt", 412, 459, "chacha8_rng(seed)"),
    ("examples/fuzz/main.mbt", 478, 478, "se < 1.0e10"),
    # The pin is the LINE that runs the validators, and the workflow grows
    # above it from time to time: it was 114, then 125, and it is 155 now --
    # round 43 added a CI step above it and round 86 added the generator-sync
    # job, which carries the README-compile step with it.
    ("check.yml", 155, 155, "validate_*_with_python.py"),
]
for path, a, b, tok in CONTENT:
    real = resolve(path)
    ok = False
    if real:
        lines = open(real, encoding="utf-8", errors="replace").read().split("\n")
        ok = tok in "\n".join(lines[a - 1:min(b, len(lines))])
    check("`%s:%s` holds %r" % (path, a if a == b else "%d-%d" % (a, b), tok), ok)

UPSTREAM_CONTENT = [
    ("plm/lplr.py", 150, 150, "predict_proba"),
    ("plm/lplr.py", 166, 166, "predict_proba"),
    ("plm/lplr.py", 244, 252, 'M_hat["preds"] * (1 - M_hat["preds"])'),
    ("plm/lplr.py", 247, 252, "y[train] == 0"),
    ("plm/lplr.py", 250, 250, "train[y[train] == 0]"),
    ("plm/lplr.py", 268, 269, "_check_is_propensity"),
    ("plm/lplr.py", 302, 312, "_double_dml_cv_predict"),
    ("plm/lplr.py", 315, 323, "d_tilde"),
    ("plm/lplr.py", 326, 326, "np.average(beta)"),
    ("plm/lplr.py", 345, 345, "beta * a_hat"),
    ("plm/lplr.py", 401, 415, "_score_elements"),
    ("plm/lplr.py", 403, 403, "d_tilde = d - m_hat"),
    ("plm/lplr.py", 405, 405, "score_const"),
    ("double_ml_score_mixins.py", 143, 150, "_coef_bounds"),
    ("double_ml_score_mixins.py", 149, 149, 'method="newton"'),
    ("utils/_estimation.py", 65, 65, "fold_specific_target"),
    ("utils/_estimation.py", 207, 229, "preds_inner"),
    ("utils/_estimation.py", 225, 226, "predict_proba"),
    ("utils/resampling.py", 52, 65, "split_samples"),
]
for path, a, b, tok in UPSTREAM_CONTENT:
    real = resolve(path)
    ok = False
    if real:
        lines = open(real, encoding="utf-8", errors="replace").read().split("\n")
        ok = tok in "\n".join(lines[a - 1:min(b, len(lines))])
    check("upstream `%s:%s` holds %r" % (path, a if a == b else "%d-%d" % (a, b), tok), ok)

print()
print("-- 4. every script the record names is TRACKED and portable --")
# A script name in the record is a name that stands ALONE: the lookbehind
# rejects a match whose first character continues an earlier word, so the
# tail of a glob like `validate_*_with_python.py` is not read as a file
# named `with_python.py`.
SCRIPT = re.compile(r"(?<![A-Za-z0-9_*])(_verify/)?([A-Za-z0-9_]+\.py)\b")
UP_NAMES = set()
for r, d, f in os.walk(UP):
    for n in f:
        if n.endswith(".py"):
            UP_NAMES.add(n)
named = {}
for m in SCRIPT.finditer(text):
    if m.group(2) in UP_NAMES:
        continue
    named.setdefault(m.group(1) or "", []).append(m.group(2))
for prefix, names in sorted(named.items()):
    for n in sorted(set(names)):
        rel = prefix + n
        cands = [rel, "_verify/" + n]
        found = next((c for c in cands
                      if os.path.isfile(os.path.join(ROOT, c))), None)
        check("`%s` exists" % rel, found is not None)
        if found:
            check("`%s` is TRACKED" % rel, found.replace("\\", "/") in TRACKED)
            src = open(os.path.join(ROOT, found), encoding="utf-8",
                       errors="replace").read()
            check("`%s` has no hard-coded absolute path" % rel,
                  not re.search(r"[A-Za-z]:[\\/]{1,2}src", src))

print()
print("-- 5. the withdrawn witness is withdrawn in the BODY --")
# the CORRECTION legitimately names the wrong file; what must be gone is the
# record citing it AS the witness.
check("the body no longer cites _fuzz_dump_1680.log AS the witness",
      "against `_verify/_lplr_r17_1680/_fuzz_dump_1680.log`" not in bd)
check("the body names the real witness _port_dump_1680.log",
      "_port_dump_1680.log" in bd)
check("the record explains the wrong-witness correction",
      "WRONG FILE" in text)
check("the wrong-witness finding is stated as REPRODUCIBLE",
      "reproducible" in text.lower() and "re-running" in text.lower())
check("the real witness is TRACKED",
      "_verify/_lplr_r17_1680/_port_dump_1680.log" in TRACKED)
dump = read("_verify/_lplr_r17_1680/_port_dump_1680.log").decode("utf-8", "replace")
check("the real witness holds 2 PORTMETA blocks for n=66",
      len(re.findall(r"^PORTMETA .*n=66 ", dump, re.M)) == 2)
check("the fuzz transcript is TRACKED",
      "_verify/_lplr_r17_1680/_fuzz_run_1680.log" in TRACKED)
transcript = read("_verify/_lplr_r17_1680/_fuzz_run_1680.log")
check("the transcript holds the harness verdict, not rows",
      b"FZZMETA" not in transcript and b"PORTMETA" not in transcript
      and b"ALL FUZZ SURFACES PASSED" in transcript)
check("the misleading _fuzz_dump_1680.log is NOT tracked",
      "_verify/_lplr_r17_1680/_fuzz_dump_1680.log" not in TRACKED)

print()
print("-- 6. the method scripts announce which upstream they used --")
for n in ("_verify/_lplr_env_1680.py",):
    check("`%s` is TRACKED" % n, n in TRACKED)
env = read("_verify/_lplr_env_1680.py").decode("utf-8", "replace")
check("the env helper names the vendored upstream version", "0.11.4" in env)
check("the env helper warns when the vendored tree is absent",
      "NOT present" in env and "INSTALLED" in env)
for n in ("_verify/_lplr_upstream_fragility_control_1680.py",
          "_verify/_lplr_startval_bias_1680.py",
          "_verify/_lplr_nuisance_causal_1680.py",
          "_verify/_lplr_basin_scan_1680.py"):
    check("`%s` is TRACKED" % n, n in TRACKED)
    src = read(n).decode("utf-8", "replace")
    check("`%s` announces its upstream" % os.path.basename(n),
          "use_vendored_upstream" in src)

print()
print("-- 7. the README agrees with the record --")
readme = read("README.mbt.md").decode("utf-8", "replace")
# The README is GENERATED and its paragraphs are hard-wrapped in the builder,
# so a phrase anchored with LITERAL SPACES breaks the day the wrap moves.
# Every multi-word claim below is matched against the collapsed copy.
readme_flat = re.sub(r"\s+", " ", readme)
check("the README cites the record", "_verify/LPLR_GATE_BLINDNESS_1680.md" in readme)
check("the README's 17 of 40 (42%) agrees with the record's",
      "17 of 40 (42%)" in readme_flat and "17/40 (42%)" in text)
check("the README's derivative factor agrees with the record's",
      "344" in readme and "344" in text)
check("the README's overshoot agrees with the record's",
      "-1381" in readme and "-1381" in text)
# The README writes its counts with SPACES around the slash, so the
# unspaced shape this check used to test never appeared in it -- in any
# commit -- and the check could not fail.
check("the README does not quote the stale counts",
      not any(s in readme for s in ("1115/1115", "1115 / 1115",
                                    "1122/1122", "1122 / 1122",
                                    "1117/1117", "1117 / 1117")))
check("the README's mean(beta) figures agree with the record's",
      "2.56" in readme_flat and "sd 3.39" in readme_flat
      and "2.5554" in text and "3.3939" in text)
shipped = read("moonbit_doubleML/README.mbt.md")
check("the shipped README is byte-identical to the edited one",
      bool(shipped) and shipped == read("README.mbt.md"))

print()
print("checks: %d   failed: %d" % (checks, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
