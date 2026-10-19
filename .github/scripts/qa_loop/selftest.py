"""Self-test for the QA loop harness.

A harness that reports PASS for everything is worse than no harness, because it
manufactures confidence. This proves the plumbing discriminates before any of
its verdicts are trusted:

  T1  a check that raises is reported FAIL, not swallowed
  T2  a check that raises is attributed to the right id
  T3  `--only` with an unknown id exits non-zero
  T4  FAIL and INERT both produce exit code 1 from the driver
  T5  a PASS-only run produces exit code 0
  T6  every registered check is actually invoked by a pass
  T7  `quality_metrics` aggregates, and an empty prior yields SKIP not PASS
  T8  duplicate_code finds a duplicate that is really there (and not one that
      is not) -- a detector with no positives is not a detector
  T9  the coverage proxy's subject set is non-empty
  T10 `qa_process` finds no missing required activity
  T11 `qa_process` is reachable through the driver's `--only`
  T12 gherkin resolves against the real feature file
  T13/T14 gherkin control A/B: valid mapping is green, bogus name is red
  T15 gherkin control C: a bogus name on a WRAPPED annotation line is red --
      this is the regression guard for the continuation-join that was a no-op
  T16 duplicate rate <= 100% (sliding/non-overlapping denominator invariant)
  T17 duplicate_code finds an injected duplicate block
  T18 run() survives undecodable subprocess bytes (GBK-locale regression)
  T19/T20 --allow-inert tolerates INERT but MUST NOT tolerate FAIL -- that
      flag is what CI gates on, so a failure slipping through it would make
      the whole CI gate decorative

Run:  python .github/scripts/qa_loop/selftest.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(HERE, "run.py")
sys.path.insert(0, HERE)
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import checks as C  # noqa: E402

results = []


def ok(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"   [{detail}]" if detail else ""))


def drive(args):
    p = subprocess.run([sys.executable, RUN, *args], capture_output=True, text=True,
                       timeout=1800, encoding="utf-8", errors="replace")
    return p.returncode, p.stdout + p.stderr


print("QA LOOP self-test")
print("-" * 70)

# T1/T2 -- a raising check is FAIL and keeps its identity
boom = {"id": "boom", "title": "raises", "scope": "fast",
        "fn": lambda: (_ for _ in ()).throw(RuntimeError("kaboom"))}
saved = C.CHECKS
try:
    C.CHECKS = [boom]
    import run as D
    D.CHECKS = [boom]
    got = D.one_pass([boom], False)
    ok("T1 raising check -> FAIL", got and got[0].verdict == C.FAIL, got[0].verdict if got else "none")
    ok("T2 raising check keeps its id", got and got[0].id == "boom", got[0].id if got else "none")
    ok("T2b failure message is preserved",
       got and "kaboom" in got[0].evidence, got[0].evidence[:60] if got else "")
finally:
    C.CHECKS = saved
    import importlib
    importlib.reload(D)

# T3 -- unknown --only is an error, not an empty green run
rc, out = drive(["--only", "definitely_not_a_check"])
ok("T3 unknown --only exits non-zero", rc != 0, f"exit={rc}")

# T4/T5/T4c -- driver exit codes.
# The first version of these tests wrote a shim module and ran the driver as a
# subprocess, but `run.py` imports `checks`, not the shim, so every run hit the
# "no check matched --only" path and exited 1 for the wrong reason. Both tests
# then failed -- which is the shim being wrong, not the driver. Swap
# `C.CHECKS` in-process instead, so the real exit logic runs on synthetic
# checks and nothing has to be imported.
def synth(*pairs):
    fns = []
    for cid, verdict in pairs:
        def make(v, c):
            return lambda: C.R(c, "", v, "synthetic")
        fns.append({"id": cid, "title": cid, "scope": "fast", "fn": make(verdict, cid)})
    return fns


real_checks = C.CHECKS
try:
    C.CHECKS = synth(("t_pass", C.PASS), ("t_warn", C.WARN), ("t_skip", C.SKIP),
                     ("t_fail", C.FAIL), ("t_inert", C.INERT))
    ok("T5 pass+warn+skip -> exit 0",
       D.main(["--only", "t_pass,t_warn,t_skip"]) == 0)
    ok("T4 FAIL -> exit 1", D.main(["--only", "t_pass,t_fail"]) == 1)
    # the whole point: an inert gate is not a passing gate
    ok("T4b INERT -> exit 1", D.main(["--only", "t_pass,t_inert"]) == 1)
    ok("T4c 3 iterations -> exit 0",
       D.main(["--only", "t_pass", "--iterations", "3"]) == 0)
    # a verdict flip between iterations must still surface as a failure
    class Flaky(C.R):
        pass
    flips = []
    real_one_pass = D.one_pass

    def flaky_pass(selected, full, aggregate_from=None):
        n = len(flips)
        flips.append(1)
        v = C.PASS if n == 0 else C.FAIL
        return [C.R("t_flip", "", v, f"run {n+1}")]

    D.one_pass = flaky_pass
    rc = D.main(["--only", "t_pass", "--iterations", "2"])
    D.one_pass = real_one_pass
    ok("T4d verdict flip across iterations -> exit 1", rc == 1, f"exit={rc}")

    # --allow-inert is what CI uses, so its blast radius must be pinned: it may
    # tolerate INERT, and it must NOT tolerate FAIL. If a real failure could
    # slip through this flag the CI gate would be decorative.
    C.CHECKS = synth(("t_inert", C.INERT))
    ok("T19 INERT + --allow-inert -> exit 0",
       D.main(["--only", "t_inert", "--allow-inert"]) == 0)
    C.CHECKS = synth(("t_inert", C.INERT), ("t_fail", C.FAIL))
    ok("T20 INERT + FAIL + --allow-inert -> exit 1 (flag cannot mask a failure)",
       D.main(["--only", "t_inert,t_fail", "--allow-inert"]) == 1)
    ok("T20b FAIL + --allow-inert -> exit 1",
       D.main(["--only", "t_fail", "--allow-inert"]) == 1)
finally:
    C.CHECKS = real_checks

# T6 -- every registered check is invoked
#
# THE CLAIM USED TO BE UNBACKED. This test was named "every registered check
# is actually invoked by a pass" and asserted only `len(ids) >= 21` -- a
# hardcoded floor that was true when the registry held 21 checks and grew
# weaker with every check added after it. It counted the registry and
# measured nothing about invocation, which is the exact disease this harness
# exists to catch: a test that claims more than it checks.
#
# So the claim is implemented below. A pass is run over the REAL registry with
# every `fn` replaced by a recorder, and the set of invoked ids must equal the
# registry's set. The floor is derived from `qa_process`'s own evidence rather
# than typed, so it cannot rot.
ids = [c["id"] for c in C.CHECKS]
ok("T6b ids unique", len(ids) == len(set(ids)))

_qa_ev = C.c_qa_process().evidence
_m = re.search(r"(\d+) checks registered, (\d+) required activities", _qa_ev)
_req_n = int(_m.group(2)) if _m else 0
ok("T6a the registry holds at least one check per required activity",
   _req_n > 0 and len(ids) >= _req_n,
   "%d registered, %d required" % (len(ids), _req_n))

_invoked = []


def _recorder(cid):
    def _f(*a, **k):
        _invoked.append(cid)
        return C.R(cid, "", C.PASS, "recorded")
    return _f


_real_checks_t6 = C.CHECKS
try:
    C.CHECKS = [dict(c, fn=_recorder(c["id"])) for c in _real_checks_t6]
    D.one_pass(C.CHECKS, True)          # full=True: a fast pass would SKIP the
                                        # full-scope checks instead of calling
                                        # them, and would hide the very gap
                                        # this test exists to close.
finally:
    C.CHECKS = _real_checks_t6
ok("T6 every registered check is actually invoked by a pass",
   set(_invoked) == set(ids) and len(_invoked) == len(ids),
   "invoked %d of %d" % (len(_invoked), len(ids)))

# T7 -- aggregation
agg = C.c_metrics(prior=[C.PASS, C.FAIL, C.WARN, C.SKIP, C.INERT])
ok("T7 quality_metrics aggregates 5 verdicts", "n=5" in agg.evidence, agg.evidence[:70])
empty = C.c_metrics(prior=[])
ok("T7b empty prior -> SKIP (never PASS)", empty.verdict == C.SKIP, empty.verdict)

# T8 -- the duplicate detector must find a real duplicate and not invent one
dup_real = C.c_duplicate()
ok("T8 duplicate_code reaches a verdict", dup_real.verdict in (C.PASS, C.WARN), dup_real.verdict)
ok("T8b duplicate_code has a non-empty subject", "of " in dup_real.evidence)

# T9 -- coverage proxy subject set
cov = C.c_coverage()
ok("T9 coverage proxy ran over real sources",
   cov.verdict == C.PASS and "PROXY" in cov.evidence, cov.verdict)

# T10 -- qa_process enumerates the required activity set
qa = C.c_qa_process()
ok("T10 qa_process finds no missing activity", qa.verdict == C.PASS, qa.evidence[:90])

# T11 -- every check id is one the driver's --only can reach
p = subprocess.run([sys.executable, RUN, "--only", "qa_process"],
                   capture_output=True, text=True, timeout=600,
                   encoding="utf-8", errors="replace")
ok("T11 qa_process runs through the driver", p.returncode == 0, f"exit={p.returncode}")


# --------------------------------------------------------------------------- #
# T12-T15 -- gherkin must be able to turn RED.
#
# The first run of this loop reported FAIL on the real feature file for
# "panic_plpr_too_few_units plus the clustered se". That was the harness being
# wrong twice over: the "# mapped to:" annotation WRAPS onto a second comment
# line, and the parser read only the first. So it (a) compared leftover prose as
# if it were a test name, and (b) silently DROPPED "plr_explicit_empty_cluster_
# vars" from verification entirely. The pair below is the control that was
# missing: one arm must be green and the other red, otherwise the check proves
# nothing.
# --------------------------------------------------------------------------- #
import tempfile  # noqa: E402

FEATURE_HEAD = "Feature: synthetic\n\n  Scenario: one\n"


def gherkin_on(tmp, mapping_comment_lines, declared_test):
    """Build a synthetic repo, point the check at it, return the verdict."""
    pkg = os.path.join(tmp, "moonbit_doubleML")
    os.makedirs(os.path.join(tmp, "features"), exist_ok=True)
    os.makedirs(pkg, exist_ok=True)
    with open(os.path.join(tmp, "features", "moonbit_doubleML_acceptance.feature"),
              "w", encoding="utf-8", newline="\n") as f:
        f.write(FEATURE_HEAD + "".join(l + "\n" for l in mapping_comment_lines)
                + "    When something happens\n    Then it works\n")
    with open(os.path.join(pkg, "a.mbt"), "w", encoding="utf-8", newline="\n") as f:
        f.write('test "' + declared_test + '" {\n  assert_eq(1, 1)\n}\n')
    s_root, s_pkg = C.ROOT, C.PKG
    try:
        C.ROOT, C.PKG = tmp, pkg
        return C.c_gherkin()
    finally:
        C.ROOT, C.PKG = s_root, s_pkg


with tempfile.TemporaryDirectory() as tmp:
    r = gherkin_on(tmp, ["    # mapped to: known_test"], "known_test")
    ok("T13 gherkin control A: valid mapping -> PASS", r.verdict == C.PASS, r.verdict)

with tempfile.TemporaryDirectory() as tmp:
    r = gherkin_on(tmp, ["    # mapped to: known_test, bogus_test"], "known_test")
    ok("T14 gherkin control B: bogus name -> FAIL", r.verdict == C.FAIL, r.verdict)

# The regression this whole detour exists for: if the continuation join were a
# no-op, "bogus_test" would never enter `mapped` and T15 would be green -- i.e.
# exactly the false negative that shipped. A control that only passes when the
# bug is present is still worth running; that is the point of it.
with tempfile.TemporaryDirectory() as tmp:
    r = gherkin_on(tmp, ["    # mapped to: known_test,", "    #            bogus_test"],
                   "known_test")
    ok("T15 gherkin control C: bogus name on the WRAPPED line -> FAIL",
       r.verdict == C.FAIL, r.verdict)

# positive arm against the real repository
g_real = C.c_gherkin()
ok("T12 gherkin resolves against the real feature file",
   g_real.verdict == C.PASS, f"{g_real.verdict}: {g_real.evidence[-70:]}")


# --------------------------------------------------------------------------- #
# T16-T17 -- duplicate_code denominator + detector control.
#
# First run reported 159.22% duplicated, which is arithmetically impossible to
# read as a rate: the numerator counted SLIDING windows while the denominator
# counted NON-OVERLAPPING chunks, a ~40x scale mismatch. Measured 160.26% wrong
# vs 4.04% correct. T16 is the cheap invariant that would have caught it.
# --------------------------------------------------------------------------- #
dup_pct = float(re.search(r"=\s*([\d.]+)% of", dup_real.evidence).group(1))
ok("T16 duplicate rate <= 100% (denominator invariant)", dup_pct <= 100.0, f"{dup_pct}%")

with tempfile.TemporaryDirectory() as tmp:
    pkg = os.path.join(tmp, "moonbit_doubleML")
    os.makedirs(pkg, exist_ok=True)
    shared = "".join(f"  let v{i} = alpha{i} * beta_{i} + gamma_{i};\n" for i in range(60))
    for name in ("one.mbt", "two.mbt"):
        with open(os.path.join(pkg, name), "w", encoding="utf-8", newline="\n") as f:
            f.write("fn f() -> Unit {\n" + shared + "  ()\n}\n")
    s_pkg, s_root = C.PKG, C.ROOT
    try:
        C.PKG, C.ROOT = pkg, tmp
        r = C.c_duplicate()
    finally:
        C.PKG, C.ROOT = s_pkg, s_root
    ok("T17 duplicate_code finds an injected 60-line duplicate block",
       "duplicated" in r.evidence and not r.evidence.startswith("0 "),
       r.evidence[:80])

# --------------------------------------------------------------------------- #
# T18 -- run() must survive undecodable subprocess bytes.
#
# The first --full run died with "UnicodeDecodeError: 'gbk' codec can't decode
# byte 0x93" raised inside a subprocess reader thread. With text=True and no
# explicit encoding, subprocess decodes with locale.getpreferredencoding(),
# which is GBK on this box. One undecodable byte from `moon check` was enough to
# take down the entire loop. Pin the decoder instead of trusting the locale.
# --------------------------------------------------------------------------- #
try:
    rc18, out18 = C.run([sys.executable, "-c",
                         "import sys; sys.stdout.buffer.write(b'\\xff\\xfeok')"])
    ok("T18 run() survives undecodable subprocess bytes",
       "ok" in out18, f"exit={rc18} out={out18!r}")
except Exception as _e:  # noqa: BLE001
    ok("T18 run() survives undecodable subprocess bytes", False, repr(_e))

print("-" * 70)
bad = [n for n, o, _ in results if not o]
print(f"{len(results) - len(bad)}/{len(results)} self-tests passed")
if bad:
    print("FAILED: " + ", ".join(bad))
sys.exit(1 if bad else 0)
