"""Full local gate suite for the v0.164.11 release, on the FINAL tree.

Mirrors .github/workflows/check.yml job by job, plus the publish.yml
`Check typos` step that no master run covers (done separately, after the
CHANGELOG entry exists, because it must see the committed tree).

Every step records its exit code and the tail of its output. The run is only
"green" if every step exited 0.

v0.164.6 keeps the ROOT-level `moon fmt --check` (the one CI actually runs --
check.yml has no working-directory, so it formats every workspace member) and
keeps the package-level one.
"""
import json
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
PKG = os.path.join(ROOT, "moonbit_doubleML")
OUT = os.path.join(ROOT, "_verify", "_gate_1651.json")

results = []


def run(name, cmd, cwd=ROOT, timeout=3600, env=None):
    t0 = time.time()
    e = dict(os.environ)
    e["PYTHONUNBUFFERED"] = "1"
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           timeout=timeout, encoding="utf-8", errors="replace",
                           env=e)
        code = p.returncode
        tail = (p.stdout or "")[-1200:] + (("\n[stderr]\n" + (p.stderr or "")[-800:]) if p.stderr else "")
    except subprocess.TimeoutExpired as ex:
        code = 124
        tail = "TIMEOUT after %ss\n%s" % (timeout, (ex.stdout or "")[-400:] if isinstance(ex.stdout, str) else "")
    dt = time.time() - t0
    results.append({"step": name, "exit": code, "secs": round(dt, 1), "tail": tail[-2000:]})
    print("[%s] %-46s exit=%s  %.1fs" % ("OK " if code == 0 else "FAIL", name, code, dt),
          flush=True)
    if code != 0:
        print("---- tail ----\n%s\n--------------" % tail[-1200:], flush=True)
    return code


# ---------------------------------------------------------------- job: readme-sync
run("readme-sync: check_readme_sync.py",
    [sys.executable, ".github/scripts/check_readme_sync.py"])

# ---------------------------------------------------------------- job: moon-test
for target in ("native", "wasm-gc", "wasm", "js"):
    run("moon build --target %s --deny-warn" % target,
        ["moon", "build", "--target", target, "--deny-warn"], cwd=PKG)
    run("moon test --target %s --deny-warn" % target,
        ["moon", "test", "--target", target, "--deny-warn"], cwd=PKG, timeout=5400)
run("moon fmt --check (package)", ["moon", "fmt", "--check"], cwd=PKG)
run("moon fmt --check (workspace root, as CI runs it)",
    ["moon", "fmt", "--check"], cwd=ROOT)

# ------------------------------------------------- job: python-cross-check (24)
# check.yml compiles the published README's code blocks BEFORE it runs the
# validators, and the gate says it mirrors check.yml job by job -- so the step
# belongs here.  It was missing: the gate did not compile the README a reader
# copies, and neither did the publish workflow.
#
# The check writes a probe file into the PACKAGE dir and removes it again, so
# it compiles in the tree it measures -- the one the gate is about.
run("the published README's code blocks compile",
    [sys.executable, "_verify/_verify_readme_snippets_1650.py"], timeout=1800)

validators = sorted(f for f in os.listdir(ROOT)
                     if f.startswith("validate_") and f.endswith("_with_python.py"))
print("validators on disk: %d" % len(validators), flush=True)
for v in validators:
    run("validator: %s" % v, [sys.executable, v], timeout=1800)

# ------------------------------------------------- job: python-cross-check (9)
for s in ("pyexample_did.py", "pyexample_did_cs2021.py", "pyexample_suite.py",
          "pyexample_did_cs_binary.py", "pyexample_did_binary.py",
          "pyexample_lplr.py", "pyexample_pq.py", "pyexample_policytree.py",
          "pyexample_rdd.py"):
    run("pyexample: %s" % s, [sys.executable, s, "--check"], timeout=3600)

# ---------------------------------------------------------------- job: qa-loop
run("qa selftest", [sys.executable, ".github/scripts/qa_loop/selftest.py"], timeout=1800)
run("qa loop (fast scope)",
    [sys.executable, ".github/scripts/qa_loop/run.py", "--allow-inert",
     "--json", "_verify/_qa_fast_1649.json"], timeout=5400)
run("qa loop (service checks)",
    [sys.executable, ".github/scripts/qa_loop/run.py", "--allow-inert", "--full",
     "--only", "api_test,security_dast", "--json", "_verify/_qa_services_1649.json"],
    timeout=3600)

# ------------------------------------------------- job: upstream provenance
# The README's 22 provenance rows against the upstream 0.11.4 sdist.  This
# gate had gone DEAD -- it reported fifteen UNLABELLED rows and two rows
# backwards, and nothing ran it -- so it is wired in here, where a broken
# parse or a moved upstream class fails the release.  It SKIPS when the
# sdist is not present, which is a reported skip and not a pass.
run("upstream provenance (0.11.4 sdist)",
    [sys.executable, "_verify/_gate_provenance_1160.py"], timeout=1800)

# ...and the CONTROL that proves the gate above still bites.  A gate nobody
# exercises is a gate that can rot in silence -- which is exactly what
# happened to the provenance gate: it had been reporting fifteen UNLABELLED
# rows, and nothing ran it, so nobody noticed.  The control mutates a COPY
# of the README eleven ways -- the table's markers in all three directions,
# the flat prose assertions, both of the parser's guards, and the derived
# exception -- and requires the gate to fail for the RIGHT reason each time.
# It was RED when it was written against the repaired gate (two of its
# mutations had landed outside the region the gate reads), so it is wired in
# here rather than left as a document.
run("upstream provenance CONTROL (0.11.4 sdist)",
    [sys.executable, "_verify/_gate_provenance_control_1160.py"], timeout=1800)

# -------------------------------------------- job: the records the README names
# A document the README points AT is a document a reader opens, and the two
# records it names still said 0.11.3 in live claims after the upstream moved.
# The provenance gate above reads the README's 22 estimator ROWS; it does not
# read a record's prose.  This step reads the prose, and it SKIPS loudly when
# the upstream package is not installed here.
run("upstream version claims in the cited records",
    [sys.executable, "_verify/_verify_upstream_version_claims_1680.py"], timeout=1800)

# ...and WHERE each validator's SECOND IMPLEMENTATION comes from.  The README
# claimed all 24 were written in this repository; two of them take their
# reference from a third-party library.  The split is derived from the
# validators themselves and compared with what the README declares.
run("validator reference split (third-party vs ours)",
    [sys.executable, "_verify/_verify_validator_references_1680.py"], timeout=1800)

# ...and the `mutation` check's verdict.  The README says it kills three
# mutants on one kernel; the check is scope=full, no workflow runs it, and its
# verdict had no witness anywhere in the tree.
run("mutation verdict (the README's three mutants)",
    [sys.executable, "_verify/_verify_mutation_verdict_1680.py"], timeout=1800)

# ...and the UPSTREAM `file:line` pointers, resolved.  The house file:line
# verifier counts them and refuses to resolve them ("they are counted and
# reported, but they are not resolved against this tree"), and the records the
# README names are outside its scope altogether.  37 pointers, none of them
# ever resolved -- and upstream's line numbers move with its releases.
run("upstream line pointers in the reader's documents",
    [sys.executable, "_verify/_verify_upstream_line_refs_1680.py"], timeout=1800)

# ...and the claims a record makes ABOUT the README.  One record called itself
# the only `_verify/` record the README cites, at the README's lines 1162 and
# 1217 -- and the README is 896 lines long and cites two records.
run("the records' claims about the README",
    [sys.executable, "_verify/_verify_record_readme_refs_1680.py"], timeout=1800)

# ------------------------------------------------ job: the LIVE documents
# The records the README NAMES are not the documents a reader OPENS.  The live
# ones -- both README copies, the six tutorials, the agent skill and the
# example service's own README -- carry their own upstream-version claims, and
# the rule that covers the records does not reach them.
run("upstream version claims in the live documents",
    [sys.executable, "_verify/_verify_live_doc_versions_1680.py"], timeout=1800)

# ...and the counts a live document states about ANOTHER document.  A count
# about this tree is held; a count about a second FILE is a promise to it, and
# "See `003_quick_start` for a 39-line end-to-end example" was held by nobody.
run("cross-document counts in the live documents",
    [sys.executable, "_verify/_verify_cross_doc_counts_1680.py"], timeout=1800)

# ...and the brackets in those documents' prose.  Round 76 fixed the bracket
# that does not close TWICE in the README and missed the third copy, in the
# agent skill -- the document a coding agent reads before it writes a line
# against this library.
run("brackets in the live documents",
    [sys.executable, "_verify/_verify_live_doc_brackets_1680.py"], timeout=1800)

# ...and the BACKEND claims.  A document that says its published numbers are
# the same on all four backends needs a witness that RUNS on all four -- and
# round 78 found `doc/003` promising exactly that with a test that could only
# ever run on one of them.
run("backend claims and their witnesses",
    [sys.executable, "_verify/_verify_backend_claims_1680.py"], timeout=1800)

# ------------------------------------------------------------ meta-gate (local)
run("validator meta-gate", [sys.executable, "validate_suite_meta.py"])

# ------------------------------------------------------------------------ summary
fails = [r for r in results if r["exit"] != 0]
print("=" * 78)
print("steps: %d   failed: %d" % (len(results), len(fails)))
for r in fails:
    print("  FAIL %s (exit %s)" % (r["step"], r["exit"]))
print("=" * 78)

with open(OUT, "w", encoding="utf-8") as fh:
    json.dump({"results": results, "failed": len(fails)}, fh, indent=2)
sys.exit(1 if fails else 0)
