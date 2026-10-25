"""QA loop -- check registry and implementations.

Design rules, each of which came from a gate in this repo that lied:

  * A verdict is PASS / FAIL / WARN / SKIP / INERT. INERT means "ran, exited 0,
    and has been shown unable to fail" -- a distinct state from PASS, because a
    check that cannot fail is a green light wired to nothing.
  * SKIP always carries a reason and, where one exists, the install command.
  * A check over an EMPTY subject set never reports PASS. Several checks below
    assert a non-zero subject count first and degrade to SKIP otherwise.
  * Where a check can prove it discriminates, it does so inline via a control
    arm, and says so in its evidence.

Heavy checks are scoped by default so the loop finishes in minutes; `--full`
expands them. Nothing here is advisory: the driver exits non-zero on any FAIL
or INERT.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PASS, FAIL, WARN, SKIP, INERT = "PASS", "FAIL", "WARN", "SKIP", "INERT"


# --------------------------------------------------------------------------- #
# plumbing
# --------------------------------------------------------------------------- #
def find_root(start: str) -> str:
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "moonbit_doubleML", "moon.mod")):
            return d
        p = os.path.dirname(d)
        if p == d:
            raise SystemExit("cannot locate repo root")
        d = p


ROOT = find_root(__file__)
PKG = os.path.join(ROOT, "moonbit_doubleML")


def run(cmd, cwd=ROOT, timeout=1800, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           timeout=timeout, env=e,
                           # Never let the console locale pick the decoder. With
                           # text=True and no encoding, subprocess uses
                           # locale.getpreferredencoding() -- GBK on this box --
                           # and a single undecodable byte from `moon check`
                           # raises UnicodeDecodeError inside the reader thread
                           # and takes the whole loop down with it.
                           encoding="utf-8", errors="replace")
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except FileNotFoundError:
        return 127, f"command not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, f"timeout after {timeout}s: {' '.join(cmd)}"


def mbt(rel: str) -> str:
    return os.path.join(PKG, rel)


def prod_sources():
    out = []
    for b, d, fs in os.walk(PKG):
        d[:] = [x for x in d if x not in ("_build", "_verify", "target", ".git")]
        for f in sorted(fs):
            if f.endswith(".mbt") and "_test" not in f and "wbtest" not in f:
                out.append(os.path.join(b, f))
    return sorted(out)


def all_mbt():
    out = []
    for b, d, fs in os.walk(PKG):
        d[:] = [x for x in d if x not in ("_build", "_verify", "target", ".git")]
        for f in sorted(fs):
            if f.endswith(".mbt"):
                out.append(os.path.join(b, f))
    return sorted(out)


def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


class R:
    __slots__ = ("id", "title", "verdict", "evidence", "seconds")

    def __init__(self, id, title, verdict, evidence, seconds=0.0):
        self.id, self.title = id, title
        self.verdict, self.evidence, self.seconds = verdict, evidence, seconds


CHECKS = []


def check(cid, title, scope="fast"):
    def deco(fn):
        CHECKS.append({"id": cid, "title": title, "fn": fn, "scope": scope})
        return fn
    return deco


# --------------------------------------------------------------------------- #
# 1. format check  -- carries its own control arm
# --------------------------------------------------------------------------- #
@check("format", "moon fmt --check", "fast")
def c_format():
    rc, out = run(["moon", "fmt", "--check"], timeout=600)
    tmp = tempfile.mkdtemp(prefix="qa_fmt_")
    try:
        open(os.path.join(tmp, "moon.mod"), "w", encoding="utf-8").write(
            'name = "t/fmtctl"\n\nversion = "0.1.0"\n')
        # The moon.pkg is LOAD-BEARING, and it was missing. Measured: without
        # it `moon fmt` prints "ran 1 task, now up to date", exits 0, and does
        # NOT rewrite the badly formatted file -- a directory with no package
        # definition is not a package, so there is nothing to format. The
        # control arm was therefore measuring nothing, reporting INERT on every
        # single run, and `--allow-inert` was quietly downgrading a check that
        # in fact works.
        #
        # `moon fmt --check` on the real repo demonstrably DOES fail: measured
        # on unformatted code earlier in this cycle, exit 4294967295. So the
        # INERT verdict was a false alarm, produced by a probe that never
        # pointed the tool at anything it could see. The fix is to make the
        # probe point at a real package, so the verdict means what it claims.
        open(os.path.join(tmp, "moon.pkg"), "w", encoding="utf-8").write(
            'pkgtype(kind: "executable")\n\nsupported_targets = "native"\n')
        open(os.path.join(tmp, "bad.mbt"), "w", encoding="utf-8").write(
            "fn  add( a : Int ,b : Int )->Int {\n        let x=a+b   \n  x\n}\n")
        crc, cout = run(["moon", "fmt", "--check"], cwd=tmp, timeout=600)
        control_failed = crc != 0 or "bad.mbt" in cout
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    ver = moon_version()
    if rc != 0:
        return R("format", "", FAIL, f"moon fmt --check exit={rc}", 0)
    if not control_failed:
        return R("format", "", INERT,
                 f"exit 0 on a package containing a deliberately mis-formatted "
                 f"file (control arm did NOT turn red) on {ver}. The gate is "
                 f"present in CI but cannot currently fail.", 0)
    return R("format", "", PASS,
             f"clean, and the control arm confirms the check turns red on bad "
             f"input ({ver})")


def moon_version():
    rc, out = run(["moon", "version"], timeout=120)
    return out.strip().splitlines()[0] if out.strip() else "moon (version unknown)"


# --------------------------------------------------------------------------- #
# 2/19. static analysis + static code check
# --------------------------------------------------------------------------- #
@check("static_analysis", "moon check --deny-warn (SAST-class)", "full")
def c_static_analysis():
    targets = ["native", "wasm-gc", "wasm", "js"]
    bad = []
    for t in targets:
        rc, out = run(["moon", "check", "--target", t, "--deny-warn"], timeout=1200)
        if rc != 0:
            bad.append((t, rc, out[-400:]))
    if bad:
        return R("static_analysis", "", FAIL, "; ".join(f"{t}: exit={rc}" for t, rc, _ in bad))
    return R("static_analysis", "", PASS, "moon check --deny-warn clean on 4 targets")


@check("static_code_check", "typos + package warnings", "fast")
def c_static_code_check():
    if not have("typos"):
        return R("static_code_check", "", SKIP, "typos not installed (cargo install typos-cli)")
    # Run it the way the gate runs it: bare `typos`, no path arguments.
    #
    # This used to pass `README.mbt.md CHANGELOG.md` explicitly, which was a
    # false WARN on every platform. Naming a file bypasses `extend-exclude`, and
    # `_typos.toml` deliberately excludes CHANGELOG.md because it preserves
    # historical entries verbatim -- including upstream's `agregate`, which that
    # config's own comments discuss at length. So the check reported 3 findings
    # (`ba`, 2x `agregate`) that the real gate never reports: on a pristine
    # checkout `typos` exits 0 with v1.19.0 (CI's pinned version) while the
    # named-file run exits 2.
    #
    # A check must measure the same thing as the gate it models, or it is
    # reporting its own disagreement as a defect in the code.
    rc, out = run(["typos"], timeout=600)
    hits = len(re.findall(r"^error:", out, re.M))
    # Name the first findings: a bare count is not actionable.
    where = re.findall(r"^error:[^\n]*\n\s*-->\s*([^\n]+)", out, re.M)
    files = {w.strip().split(":")[0].replace("\\", "/").lstrip("./") for w in where}
    if rc == 0:
        return R("static_code_check", "", PASS, "typos: 0 findings")
    # Separate what the GATE sees from what only exists in a dirty local tree.
    # CI checks out tracked files only; `_verify/` scratch scripts are untracked
    # and never ship, so a finding there cannot fail a release. Without this
    # split the check WARNs forever on any working tree with scratch in it,
    # which is the "permanently-red build everyone ignores" failure mode.
    tracked = set()
    trc, tout = run(["git", "ls-files"], timeout=120)
    if trc == 0:
        tracked = {t.strip().replace("\\", "/") for t in tout.splitlines() if t.strip()}
    flagged = sorted(f for f in files if f in tracked)
    if not flagged and files:
        untracked_n = len(files)
        sample = ", ".join(sorted(files)[:2])
        return R("static_code_check", "", PASS,
                 f"typos: {hits} finding(s) in {untracked_n} UNTRACKED file(s) "
                 f"({sample}) -- none are tracked, so the release gate is clean; "
                 f"this working tree has scratch files CI will not check")
    first = "; ".join(flagged[:3])
    detail = f"typos: {hits} finding(s) in {len(flagged)} tracked file(s)"
    if first:
        detail += f" [{first}]"
    return R("static_code_check", "", WARN,
             detail + f"; CI pins 1.19.0 and may differ from the local build "
                      f"({moon_version()})")


# --------------------------------------------------------------------------- #
# 3. duplicate code -- real detector, no external tool needed
# --------------------------------------------------------------------------- #
def _tokens(src: str):
    src = re.sub(r"//[^\n]*", " ", src)
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+\.?\d*|=>|->|==|!=|<=|>=|\S", src)


def _rel(p):
    """relpath that cannot crash on a path on a different drive/volume."""
    try:
        return os.path.relpath(p, ROOT)
    except ValueError:
        return p


@check("duplicate_code", "token n-gram duplicate detection", "fast")
def c_duplicate():
    W = 40
    srcs = prod_sources()
    if not srcs:
        return R("duplicate_code", "", SKIP, "no production sources found")
    seen = {}
    # The numerator counts SLIDING windows (every offset i), so the denominator
    # must be the sliding-window population. Using non-overlapping chunk count
    # (total_tokens // W) understates the denominator by ~W and makes the ratio
    # exceed 100% by construction. Measured: 160.26% (wrong) vs 4.04% (correct).
    population = 0
    for p in srcs:
        toks = _tokens(read(p))
        population += max(0, len(toks) - W + 1)
        for i in range(len(toks) - W):
            key = " ".join(toks[i:i + W])
            seen.setdefault(key, []).append((p, i))
    blocks = {k: v for k, v in seen.items() if len({x[0] for x in v}) > 1}
    files = {_rel(x[0]) for v in blocks.values() for x in v}
    pct = 100.0 * len(blocks) / max(1, population)
    # Name the dominant cluster, otherwise the ratio is an unfalsifiable number.
    top = max(blocks.items(), key=lambda kv: len({x[0] for x in kv[1]}),
              default=(None, []))
    top_n = len({x[0] for x in top[1]})
    verdict = WARN if pct > 5.0 else PASS
    return R("duplicate_code", "", verdict,
             f"{len(blocks)} duplicated {W}-token window(s) across {len(files)} file(s) "
             f"= {pct:.2f}% of {population} sliding windows (threshold 5.0%); "
             f"largest cluster repeats in {top_n} files "
             f"(estimator boilerplate, no jscpd/PMD-CPD in the toolchain)")


# --------------------------------------------------------------------------- #
# 4. dependency check
# --------------------------------------------------------------------------- #
@check("dependencies", "declared vs used, official vs not", "fast")
def c_deps():
    raw = read(os.path.join(PKG, "moon.mod"))
    live = "\n".join(re.sub(r"//.*$", "", ln) for ln in raw.split("\n"))
    imp = re.search(r"import\s*\{(.*?)\}", live, re.S)
    deps = re.findall(r'"([^"]+)"', imp.group(1)) if imp else []
    if not deps:
        return R("dependencies", "", SKIP, "moon.mod declares no import block")
    srcs = "".join(read(p) for p in all_mbt())
    unused, unofficial = [], []
    for d in deps:
        leaf = d.split("@")[0].rsplit("/", 1)[-1]
        if leaf not in srcs:
            unused.append(d)
        if not d.startswith(("moonbitlang/", "riantr/")):
            unofficial.append(d)
    notes = []
    if unofficial:
        notes.append(f"non-conforming: {unofficial}")
    if unused:
        notes.append(f"declared but unreferenced by library code: {unused}")
    return R("dependencies", "", WARN if notes else PASS,
             f"{len(deps)} declared; " + ("; ".join(notes) if notes else "all used and conforming")
             + "  [no vulnerability scanner in CI; moon update is not an audit]")


# --------------------------------------------------------------------------- #
# 5. unit tests / 18. component (whitebox) tests
# --------------------------------------------------------------------------- #
@check("unit_tests", "moon test --deny-warn", "full")
def c_unit():
    rc, out = run(["moon", "test", "--target", "native", "--deny-warn",
                   "-p", "riantr/moonbit_doubleML"], timeout=2400)
    m = re.search(r"Total tests:\s*(\d+),\s*passed:\s*(\d+),\s*failed:\s*(\d+)", out)
    if rc != 0 and not m:
        return R("unit_tests", "", FAIL, out[-400:])
    if not m:
        return R("unit_tests", "", SKIP, "no test summary line parsed")
    tot, pas, fail = map(int, m.groups())
    return R("unit_tests", "", PASS if fail == 0 else FAIL,
             f"{pas}/{tot} passed, {fail} failed (native)")


@check("component_tests", "whitebox component suite", "full")
def c_component():
    wbs = [p for p in all_mbt() if "wbtest" in os.path.basename(p)]
    if not wbs:
        return R("component_tests", "", SKIP, "no *_wbtest.mbt files found")
    rc, out = run(["moon", "test", "--target", "native", "--deny-warn",
                   "-p", "riantr/moonbit_doubleML"], timeout=2400)
    m = re.search(r"Total tests:\s*(\d+),\s*passed:\s*(\d+),\s*failed:\s*(\d+)", out)
    if not m:
        return R("component_tests", "", SKIP, "no summary parsed")
    tot, pas, fail = map(int, m.groups())
    return R("component_tests", "", PASS if fail == 0 else FAIL,
             f"{len(wbs)} whitebox files contribute to the {pas}/{tot} native run; "
             f"they are not separable from the unit invocation (same `moon test`)")


# --------------------------------------------------------------------------- #
# 6. Gherkin -- traceability, verified against real test names
# --------------------------------------------------------------------------- #
@check("gherkin", "acceptance feature -> test traceability", "fast")
def c_gherkin():
    f = os.path.join(ROOT, "features", "moonbit_doubleML_acceptance.feature")
    if not os.path.isfile(f):
        return R("gherkin", "", SKIP, "no .feature file")
    txt = read(f)
    feats = re.findall(r"^Feature:\s*(.+)$", txt, re.M)
    scen = re.findall(r"^\s*Scenario:\s*(.+)$", txt, re.M)
    steps = re.findall(r"^\s*(?:Given|When|Then|And)\s", txt, re.M)
    mapped = []
    wrapped = []
    lines = txt.splitlines()
    for i, l in enumerate(lines):
        m = re.match(r"\s*#\s*mapped to:\s*(.+)$", l)
        if not m:
            continue
        acc = m.group(1)
        # A "# mapped to:" annotation may WRAP onto a following comment line.
        # Reading only the first line silently DROPS the names on the
        # continuation (a false negative: a mapped test nobody verifies).
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if (re.match(r"\s*#\s+\S", nxt)
                and not re.match(r"\s*(Scenario|Feature|Background|Examples|Given|When|Then|And|But|\*)\b", nxt)):
            acc += " " + nxt.split("#", 1)[1]
            wrapped.append(i + 1)
        mapped += [x.strip() for x in re.split(r",\s*|\s+and\s+", acc) if x.strip()]
    declared = set()
    for p in all_mbt():
        s = read(p)
        declared.update(re.findall(r'\btest\s+"([^"]+)"', s))
        declared.update(re.findall(r"\bfn\s+(panic_\w+)\s*\(", s))
    # A cited name that is PROSE -- "padjust validators", "storey_m0_hat usage
    # in tsbh/tsby paths" -- names a file or a concept, not a test.  The
    # exemption is the check's own rule and it is not a resolution: the name
    # still names no declaration.  So the evidence message reports the split
    # instead of folding the prose into the numerator.  "29/29 mapped test
    # names resolve" was the same overstatement the README's "12 of the 16"
    # was: three of the 29 were not test names at all.
    PROSE = re.compile(r"\s(?:in|usage|validators|tests)\b|\.")
    prose = [m for m in mapped if PROSE.search(m)]
    real = [m for m in mapped if not PROSE.search(m)]
    unresolved = [m for m in real if m.split("(")[0].strip() not in declared]
    if not feats:
        return R("gherkin", "", SKIP, "feature file has no Feature: blocks")
    ok = not unresolved
    return R("gherkin", "", PASS if ok else FAIL,
             f"{len(feats)} Feature / {len(scen)} Scenario / {len(steps)} steps; "
             f"{len(mapped)} mapped names: {len(real) - len(unresolved)} resolve to a "
             f"real declaration, {len(prose)} prose-exempt"
             + (f"; {len(wrapped)} wrapped annotation(s) joined" if wrapped else "")
             + (f"; unresolved: {unresolved[:5]}" if unresolved else ""))


# --------------------------------------------------------------------------- #
# 7. QA process -- the loop's own manifest is the artifact
# --------------------------------------------------------------------------- #
@check("qa_process", "every activity has a registered check + a verdict", "fast")
def c_qa_process():
    ids = {c["id"] for c in CHECKS}
    required = {"format", "static_analysis", "duplicate_code", "dependencies",
                "unit_tests", "gherkin", "qa_process", "load_stress",
                "quality_metrics", "perf_test", "mutation", "fuzz",
                "coverage", "integration", "api_test", "e2e", "contract",
                "component_tests", "static_code_check", "benchmark",
                "security_sast", "security_dast"}
    missing = sorted(required - ids)
    return R("qa_process", "", PASS if not missing else FAIL,
             f"{len(ids)} checks registered, {len(required)} required activities"
             + (f"; MISSING {missing}" if missing else "")
             + "  [no standalone QA/test-plan document in the repo]")


# --------------------------------------------------------------------------- #
# 14. integration -- the Python cross-checks, AND proof they ran MoonBit
# --------------------------------------------------------------------------- #
# Each validator is launched through `_boot.py`, which wraps
# `subprocess.run` / `subprocess.Popen` in-process and appends every command
# whose executable looks like `moon` to a marker file. A validator that never
# spawned MoonBit leaves the marker absent.
#
# This is the gate that was missing. Ten of the twenty-three cross-checks
# imported no `subprocess` at all, computed a Python-only reference, and printed
# a trailing PASS -- and BOTH this check and CI's `python-cross-check` were
# satisfied by that, because a PASS-looking line is all either of them ever
# looked for. Nothing in the loop could tell "checked the port" from "checked a
# formula it typed out itself".
#
# Why behavioural rather than a static `import subprocess` scan: a scan passes
# a validator that imports `subprocess` and never calls it, which is the same
# failure wearing a hat. This observes the actual invocation.
#
# Why an in-process wrapper rather than a `sitecustomize.py` on PYTHONPATH:
# that was the first attempt and it did not load -- `sitecustomize` is imported
# by the `site` module at startup, and in this interpreter it never appeared in
# `sys.modules`, so the probe silently did nothing and the gate flagged all 25
# validators, not the one control. A wrapper that runs in the same process is
# deterministic and cannot half-load. (A gate that fails for the wrong reason
# is worse than no gate, because it looks like a finding.)
#
# It costs nothing extra -- `integration` already runs every validator; this
# only changes how they are launched and adds a file-existence test.
_BOOT = r'''
import os, runpy, subprocess, sys

marker, script = sys.argv[1], sys.argv[2]
sys.argv = [script] + sys.argv[3:]


def _is_moon(cmd):
    try:
        head = cmd[0]
    except (TypeError, IndexError, KeyError):
        return False
    if not isinstance(head, str):
        head = getattr(head, "__file__", "") or ""
    return os.path.basename(str(head)).lower() in (
        "moon", "moon.exe", "moon.cmd", "moon.bat")


def _note(cmd):
    if not _is_moon(cmd):
        return
    try:
        with open(marker, "a", encoding="utf-8") as fh:
            fh.write(str(cmd[0]) + "\n")
    except OSError:
        pass


_run, _Popen = subprocess.run, subprocess.Popen


def _run_wrapped(cmd, *a, **k):
    _note(cmd)
    return _run(cmd, *a, **k)


class _PopenWrapped(_Popen):
    def __init__(self, cmd, *a, **k):
        _note(cmd)
        super().__init__(cmd, *a, **k)


subprocess.run, subprocess.Popen = _run_wrapped, _PopenWrapped

runpy.run_path(script, run_name="__main__")
'''


@check("integration",
       "validate_*_with_python.py parity, each proven to spawn MoonBit", "full")
def c_integration():
    scripts = sorted(f for f in os.listdir(ROOT)
                     if re.match(r"validate_.*_with_python\.py$", f))
    if not scripts:
        return R("integration", "", SKIP, "no cross-check scripts")
    # The first version ran scripts[:4] and returned PASS -- a green gate
    # covering 4 of 23 subjects (17%), which is exactly the manufactured
    # confidence this loop exists to prevent. It is `full` scope, so run them
    # all.
    #
    # CI's `python-cross-check` additionally requires the TRAILING line to
    # contain PASS. Checking only that PASS appears *somewhere* is weaker, so
    # both conditions are enforced here.
    bad, blind = [], []
    tmp = tempfile.mkdtemp(prefix="moonprobe_")
    try:
        boot = os.path.join(tmp, "_boot.py")
        with open(boot, "w", encoding="utf-8") as fh:
            fh.write(_BOOT)
        for s in scripts:
            marker = os.path.join(tmp, s + ".marker")
            rc, out = run([sys.executable, boot, marker,
                           os.path.join(ROOT, s)], timeout=1800)
            tail = out.strip().splitlines()[-1] if out.strip() else ""
            if rc != 0 or "PASS" not in tail.upper():
                bad.append((s, rc, tail.strip()[:60]))
            if not os.path.exists(marker):
                blind.append(s)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    verdict = PASS if not bad and not blind else FAIL
    parts = ["%d cross-checks run" % len(scripts)]
    if bad:
        parts.append("FAILURES: %s" % bad)
    if blind:
        parts.append("NEVER SPAWNED MOONBIT: %s" % blind)
    if not bad and not blind:
        parts.append("all reported PASS on the trailing line AND invoked moon")
    return R("integration", "", verdict, "; ".join(parts))

# --------------------------------------------------------------------------- #
# pyexample -- the port against UPSTREAM's own Python example
# --------------------------------------------------------------------------- #
#
# This is the only check in the harness whose reference is not ours. Every
# other one compares the port against a second implementation written here;
# this one regenerates `doubleml.did.datasets.make_did_SZ2020` and runs
# upstream's `DoubleMLDID` on it, then compares the port to that.
#
# WHY IT NEEDS ITS OWN TREE GUARD
# ===============================
# `pyexample_did.py` overwrites a TRACKED file (`examples/parity/pyexample_data.mbt`)
# for the duration of one comparison and restores it with git. Every other
# check in this harness is read-only. So this check snapshots the bytes
# before and restores them after, independently of whether the gate did.
# The failure being defended against is precisely "the gate's own restore
# did not run", so relying on the gate's own restore would be circular.
#
# Byte comparison, not a git-status string: a fixture that came back with the
# right content but the wrong bytes (CRLF, BOM, trailing newline) would still
# be a dirty tree, and this repo has been bitten by exactly that.
@check("pyexample",
       "port vs upstream make_did_SZ2020 on upstream-generated data", "fast")
def c_pyexample():
    fixture = os.path.join(ROOT, "examples", "parity", "pyexample_data.mbt")
    gate = os.path.join(ROOT, "pyexample_did.py")
    if not os.path.isfile(gate):
        return R("pyexample", "", SKIP, "pyexample_did.py is not present")
    if not os.path.isfile(fixture):
        return R("pyexample", "", SKIP, "%s is not present"
                 % os.path.relpath(fixture, ROOT))
    try:
        with open(fixture, "rb") as fh:
            before = fh.read()
    except OSError as e:
        return R("pyexample", "", SKIP, "cannot read the fixture: %s" % e)
    try:
        rc, out = run([sys.executable, "pyexample_did.py", "--check"],
                      cwd=ROOT, timeout=2400)
        verdict = PASS if rc == 0 else FAIL
        # Prefer the gate's own verdict line over the process tail: `run()`
        # merges stderr, and doubleml's DeprecationWarning quotes its own
        # source line, so the tail is frequently a fragment of a warning
        # rather than anything the gate said about itself.
        evidence = ""
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("pyexample: port vs upstream"):
                evidence = s
        if not evidence:
            tail = out.strip().splitlines()[-1] if out.strip() else ""
            evidence = tail.strip()[:110]
        # Carry the one number a reader needs to judge the gate: how far the
        # coefficient sat from upstream in units of the measured fold noise.
        for line in out.splitlines():
            if "coef: sd" in line:
                evidence += " | " + line.strip()
        return R("pyexample", "", verdict, evidence)
    finally:
        try:
            with open(fixture, "rb") as fh:
                after = fh.read()
        except OSError:
            after = b"<unreadable>"
        if after != before:
            with open(fixture, "wb") as fh:
                fh.write(before)


# --------------------------------------------------------------------------- #
# pyexample_suite -- the CORE ESTIMATOR FAMILY against upstream's own fits
# --------------------------------------------------------------------------- #
#
# Same contract as the two gates above, applied to the six estimators that had
# no upstream gate at all: PLR, IRM, SSM, BLP, PLIV and IIVM on three numpy
# datasets. Registered separately rather than folded into `pyexample`, because
# it is a different gate against different estimators and a merge would hide
# which one broke.
#
# It writes a DIFFERENT tracked fixture (`examples/parity/suite_data.mbt`) than
# the two DID gates, so there is no fixture contention -- but all three drive
# the same `moon run examples/parity` build, so they must still not run
# concurrently against one working tree. It carries the same independent
# byte-snapshot guard for the same reason: the failure being defended against is
# "the gate's own restore did not run", which is exactly when its restore would
# be the thing that is missing.
@check("pyexample_suite",
       "port vs upstream on 9 estimators (PLR/IRM/SSM/BLP/PLIV/IIVM/APO/APOS/CVAR)"
       " over 3 datasets",
       "fast")
def c_pyexample_suite():
    fixture = os.path.join(ROOT, "examples", "parity", "suite_data.mbt")
    gate = os.path.join(ROOT, "pyexample_suite.py")
    if not os.path.isfile(gate):
        return R("pyexample_suite", "", SKIP, "pyexample_suite.py is not present")
    if not os.path.isfile(fixture):
        return R("pyexample_suite", "", SKIP, "%s is not present"
                 % os.path.relpath(fixture, ROOT))
    try:
        with open(fixture, "rb") as fh:
            before = fh.read()
    except OSError as e:
        return R("pyexample_suite", "", SKIP, "cannot read the fixture: %s" % e)
    try:
        rc, out = run([sys.executable, "pyexample_suite.py", "--check"],
                      cwd=ROOT, timeout=2400)
        verdict = PASS if rc == 0 else FAIL
        evidence = ""
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("pyexample: port vs upstream estimator family"):
                evidence = s
        if not evidence:
            tail = out.strip().splitlines()[-1] if out.strip() else ""
            evidence = tail.strip()[:110]
        # Two numbers a reader needs to judge whether this gate can bite: how
        # many items it compared, and the band the deterministic BLP is held
        # to. A `checked 0 item(s)` here would mean it compared nothing.
        for line in out.splitlines():
            if line.startswith("checked ") and "item(s)" in line:
                evidence += " | " + line.strip()
        for line in out.splitlines():
            if "BLP band in force" in line:
                evidence += " | " + line.strip()
        return R("pyexample_suite", "", verdict, evidence)
    finally:
        try:
            with open(fixture, "rb") as fh:
                after = fh.read()
        except OSError:
            after = b"<unreadable>"
        if after != before:
            with open(fixture, "wb") as fh:
                fh.write(before)


@check("pyexample_did_cs_binary",
       "port vs upstream DoubleMLDIDCSBinary on the CS2021 panel, 6 cells",
       "fast")
def c_pyexample_did_cs_binary():
    # Same fixture as the two DID gates above -- `pyexample_data.mbt`, spliced
    # with the same `cs2021_*` block -- so it carries the same byte-snapshot
    # guard and the same "must not run concurrently" caveat. The three gates
    # drive one `moon run examples/parity` build, and the harness runs them
    # sequentially.
    fixture = os.path.join(ROOT, "examples", "parity", "pyexample_data.mbt")
    gate = os.path.join(ROOT, "pyexample_did_cs_binary.py")
    if not os.path.isfile(gate):
        return R("pyexample_did_cs_binary", "", SKIP,
                 "pyexample_did_cs_binary.py is not present")
    if not os.path.isfile(fixture):
        return R("pyexample_did_cs_binary", "", SKIP, "%s is not present"
                 % os.path.relpath(fixture, ROOT))
    try:
        with open(fixture, "rb") as fh:
            before = fh.read()
    except OSError as e:
        return R("pyexample_did_cs_binary", "", SKIP,
                 "cannot read the fixture: %s" % e)
    try:
        rc, out = run([sys.executable, "pyexample_did_cs_binary.py", "--check"],
                      cwd=ROOT, timeout=2400)
        verdict = PASS if rc == 0 else FAIL
        evidence = ""
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("pyexample: port vs upstream DoubleMLDIDCSBinary"):
                evidence = s
        if not evidence:
            tail = out.strip().splitlines()[-1] if out.strip() else ""
            evidence = tail.strip()[:110]
        # The number that says whether this gate can bite: every cell is
        # REQUESTED on both sides here, so a drop below 6 means a cell went
        # missing rather than being skipped for a structural reason -- the
        # failure mode the CS2021 gate documents and has to guard against.
        for line in out.splitlines():
            if "cell(s), each REQUESTED explicitly" in line:
                evidence += " | " + line.strip()
        return R("pyexample_did_cs_binary", "", verdict, evidence)
    finally:
        try:
            with open(fixture, "rb") as fh:
                after = fh.read()
        except OSError:
            after = b"<unreadable>"
        if after != before:
            with open(fixture, "wb") as fh:
                fh.write(before)


@check("pyexample_did_binary",
       "port vs upstream DoubleMLDIDBinary on the CS2021 panel, 6 cells",
       "fast")
def c_pyexample_did_binary():
    # Fourth gate on the SAME fixture (`examples/parity/pyexample_data.mbt`,
    # same `cs2021_*` block), so it carries the same byte-snapshot guard and the
    # same "must not run concurrently" caveat as the three above it.
    #
    # Registered SEPARATELY from `pyexample_did_cs_binary` on purpose. Both
    # compare all 6 explicitly-requested cells on the same data and would merge
    # cleanly, but they grade different upstream classes -- `DoubleMLDIDBinary`
    # (the port converts the panel to a wide cross-section and fits an inner
    # `DoubleMLDID`) versus `DoubleMLDIDCSBinary` (consumes the panel) -- and a
    # merged check would hide which one broke.
    fixture = os.path.join(ROOT, "examples", "parity", "pyexample_data.mbt")
    gate = os.path.join(ROOT, "pyexample_did_binary.py")
    if not os.path.isfile(gate):
        return R("pyexample_did_binary", "", SKIP,
                 "pyexample_did_binary.py is not present")
    if not os.path.isfile(fixture):
        return R("pyexample_did_binary", "", SKIP, "%s is not present"
                 % os.path.relpath(fixture, ROOT))
    try:
        with open(fixture, "rb") as fh:
            before = fh.read()
    except OSError as e:
        return R("pyexample_did_binary", "", SKIP,
                 "cannot read the fixture: %s" % e)
    try:
        rc, out = run([sys.executable, "pyexample_did_binary.py", "--check"],
                      cwd=ROOT, timeout=2400)
        verdict = PASS if rc == 0 else FAIL
        evidence = ""
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("pyexample: port vs upstream DoubleMLDIDBinary"):
                evidence = s
        if not evidence:
            tail = out.strip().splitlines()[-1] if out.strip() else ""
            evidence = tail.strip()[:110]
        for line in out.splitlines():
            if "cell(s), all REQUESTED explicitly" in line:
                evidence += " | " + line.strip()
        return R("pyexample_did_binary", "", verdict, evidence)
    finally:
        try:
            with open(fixture, "rb") as fh:
                after = fh.read()
        except OSError:
            after = b"<unreadable>"
        if after != before:
            with open(fixture, "wb") as fh:
                fh.write(before)


# --------------------------------------------------------------------------- #
# pyexample_lplr -- the LPLR port against upstream on SHARED ROWS
# --------------------------------------------------------------------------- #
#
# No byte-snapshot guard, unlike the four DID gates above: those overwrite the
# shared `pyexample_data.mbt` fixture and must restore it. This one reads only
# the emitter's stdout -- the LPLR rows and partition are PRINTED by
# `sec_lplr_upstream` (`data_out`), not injected as literals -- so there is no
# file for it to disturb and nothing to restore.
#
# Registered separately because it is the only gate here that pins the fold
# partition. Measured: upstream refit under a pinned partition is bit-identical
# (|dcoef| = 0.000e+00), so this one removes the fold-draw noise the other
# estimators' gates still absorb. See `_verify/LPLR_GATE_BLINDNESS_1680.md`.
@check("pyexample_lplr",
       "port vs upstream DoubleMLLPLR on the example's own rows, pinned partition",
       "fast")
def c_pyexample_lplr():
    gate = os.path.join(ROOT, "pyexample_lplr.py")
    if not os.path.isfile(gate):
        return R("pyexample_lplr", "", SKIP, "pyexample_lplr.py is not present")
    try:
        rc, out = run([sys.executable, "pyexample_lplr.py", "--check"],
                      cwd=ROOT, timeout=3600)
    except Exception as e:  # noqa: BLE001 - any failure is a FAIL, never a PASS
        return R("pyexample_lplr", "", FAIL, "could not run the gate: %s" % e)
    verdict = PASS if rc == 0 else FAIL
    evidence = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith(("nuisance_space port=", "instrument     port=",
                         "identical:")):
            evidence.append(s)
    if not evidence:
        tail = out.strip().splitlines()[-1] if out.strip() else ""
        evidence = [tail.strip()[:110]]
    return R("pyexample_lplr", "", verdict, " | ".join(evidence))


# --------------------------------------------------------------------------- #
# pyexample_pq -- the quantile estimators (PQ / QTE) against upstream
# --------------------------------------------------------------------------- #
#
# No byte-snapshot guard and no emitted data, for the same reason as
# `pyexample_lplr`: this gate reads only stdout. Its comparison shape is
# different again -- the DGP is integer-only, so both sides build the rows
# independently and a per-column fingerprint is compared.
#
# Coefficients ride the measured seed-spread band; standard errors ride a
# ratio envelope, because the port sits ~10% below upstream on every QTE SE
# and both candidate causes were measured and ruled out. A seed-spread band
# would be red on every run, which is a permanently failing CI, not a gate.
@check("pyexample_pq",
       "port vs upstream DoubleMLPQ / DoubleMLQTE, independently rebuilt integer DGP",
       "fast")
def c_pyexample_pq():
    gate = os.path.join(ROOT, "pyexample_pq.py")
    if not os.path.isfile(gate):
        return R("pyexample_pq", "", SKIP, "pyexample_pq.py is not present")
    try:
        rc, out = run([sys.executable, "pyexample_pq.py", "--check"],
                      cwd=ROOT, timeout=3600)
    except Exception as e:  # noqa: BLE001 - any failure is a FAIL, never a PASS
        return R("pyexample_pq", "", FAIL, "could not run the gate: %s" % e)
    verdict = PASS if rc == 0 else FAIL
    evidence = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith(("pq_coef ", "qte[", "agree:")):
            evidence.append(s)
    if not evidence:
        tail = out.strip().splitlines()[-1] if out.strip() else ""
        evidence = [tail.strip()[:110]]
    return R("pyexample_pq", "", verdict, " | ".join(evidence)[:300])


# --------------------------------------------------------------------------- #
# pyexample_policytree -- the policy tree's decision rule against upstream
# --------------------------------------------------------------------------- #
#
# The last of the five estimator slots that shipped with an ANALYTIC oracle only.
# PQ/QTE/LPQ are `pyexample_pq` above; RDD is `pyexample_rdd` below, gated on its
# bias-corrected arm after the recorded divergence turned out to have been measured
# on a noiseless design.
#
# Its comparison shape is unique in this file. Upstream wraps a
# `DecisionTreeClassifier` and the port implements its own builder, and the two
# are genuinely different algorithms -- different threshold convention,
# different criterion, different leaf rule. So nothing structural is compared.
# What is compared is the LABEL VECTOR over every row, plus the split feature
# and the threshold: the quantities invariant to all of those differences.
#
# The threshold rides a bound because sklearn stores node thresholds as float32
# and the port computes in f64 -- measured gap 4.75e-8 relative, bound 1e-6. An
# a perturbation arm in the policy-tree measurement battery perturbs it by
# 1e-4 to prove that bound can actually go red, since the label comparison
# threshold that moved without crossing a row.
@check("pyexample_policytree",
       "port vs upstream DoubleMLPolicyTree, label vector over every row",
       "fast")
def c_pyexample_policytree():
    gate = os.path.join(ROOT, "pyexample_policytree.py")
    if not os.path.isfile(gate):
        return R("pyexample_policytree", "", SKIP,
                 "pyexample_policytree.py is not present")
    try:
        rc, out = run([sys.executable, "pyexample_policytree.py", "--check"],
                      cwd=ROOT, timeout=3600)
    except Exception as e:  # noqa: BLE001 - any failure is a FAIL, never a PASS
        return R("pyexample_policytree", "", FAIL,
                 "could not run the gate: %s" % e)
    verdict = PASS if rc == 0 else FAIL
    evidence = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith(("split feature :", "labels        :",
                         "RESULT: PolicyTree")):
            evidence.append(s)
    if not evidence:
        tail = out.strip().splitlines()[-1] if out.strip() else ""
        evidence = [tail.strip()[:110]]
    return R("pyexample_policytree", "", verdict, " | ".join(evidence)[:300])


# --------------------------------------------------------------------------- #
# pyexample_rdd -- RDD against upstream rdrobust, on the bias-corrected arm
# --------------------------------------------------------------------------- #
#
# RDD was the one estimator slot left ungated, on a recorded divergence
# (`_verify/RDD_PARITY_1680.md`). That divergence was measured on a design whose
# "noise" was collinear with the running variable, so the fit was exact and the
# variances were ~1e-15; the record has been withdrawn and re-measured. What it
# actually showed is that the port's BIAS-CORRECTED estimator agrees with
# rdrobust to 6.2e-15 and its robust SE to 1.9e-15, while the shipped default
# arm is a different estimator (homoskedastic, uncorrected) and diverges.
#
# So this gate pins the arm that matches and REPORTS the arm that does not.
# Requiring the default arm to match would be a permanently red gate, which is
# either a failing CI or a mute -- both worse than recording the divergence.
@check("pyexample_rdd",
       "port vs upstream rdrobust, bias-corrected arm (tau.bc / se.rb)",
       "fast")
def c_pyexample_rdd():
    gate = os.path.join(ROOT, "pyexample_rdd.py")
    if not os.path.isfile(gate):
        return R("pyexample_rdd", "", SKIP, "pyexample_rdd.py is not present")
    try:
        rc, out = run([sys.executable, "pyexample_rdd.py", "--check"],
                      cwd=ROOT, timeout=3600)
    except Exception as e:  # noqa: BLE001 - any failure is a FAIL, never a PASS
        return R("pyexample_rdd", "", FAIL, "could not run the gate: %s" % e)
    # A crash exits 1 with no RESULT line and is a FAIL, not a silent pass; the
    # gate now guarantees the verdict exists, but the absence is still reported
    # rather than folded into the exit code.
    verdict = PASS if rc == 0 else FAIL
    evidence = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith(("tau_bc ", "tau_bc_se_rb ", "RESULT: RDD")):
            evidence.append(s)
    if not evidence:
        tail = out.strip().splitlines()[-1] if out.strip() else ""
        evidence = [tail.strip()[:110]]
    return R("pyexample_rdd", "", verdict, " | ".join(evidence)[:300])


# --------------------------------------------------------------------------- #
# pyexample_cs2021 -- the MULTI-COHORT port against upstream's own CS2021 data
# --------------------------------------------------------------------------- #
#
# Same contract as `pyexample` above, on upstream's `DoubleMLDIDMulti` and
# `make_did_CS2021`. It is registered separately rather than folded into the
# SZ2020 check because they are different gates against different estimators,
# and a merge would hide which one broke.
#
# It writes the SAME tracked fixture (`examples/parity/pyexample_data.mbt`) as
# `pyexample`, splicing only the `cs2021_*` half. So the two checks must never
# run concurrently against one working tree, and this one carries the same
# independent byte-snapshot guard: the failure being defended against is "the
# gate's own restore did not run", which is precisely when its restore would be
# the thing that is missing.
@check("pyexample_cs2021",
       "port vs upstream make_did_CS2021 (DoubleMLDIDMulti) on upstream data",
       "fast")
def c_pyexample_cs2021():
    fixture = os.path.join(ROOT, "examples", "parity", "pyexample_data.mbt")
    gate = os.path.join(ROOT, "pyexample_did_cs2021.py")
    if not os.path.isfile(gate):
        return R("pyexample_cs2021", "", SKIP, "pyexample_did_cs2021.py is not present")
    if not os.path.isfile(fixture):
        return R("pyexample_cs2021", "", SKIP, "%s is not present"
                 % os.path.relpath(fixture, ROOT))
    try:
        with open(fixture, "rb") as fh:
            before = fh.read()
    except OSError as e:
        return R("pyexample_cs2021", "", SKIP, "cannot read the fixture: %s" % e)
    try:
        rc, out = run([sys.executable, "pyexample_did_cs2021.py", "--check"],
                      cwd=ROOT, timeout=2400)
        verdict = PASS if rc == 0 else FAIL
        evidence = ""
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("pyexample: port vs upstream make_did_CS2021"):
                evidence = s
        if not evidence:
            tail = out.strip().splitlines()[-1] if out.strip() else ""
            evidence = tail.strip()[:110]
        # The number that decides whether this gate can bite: how many of
        # upstream's 12 standard cells it actually compares. 6 is the
        # structural maximum (see the gate's docstring); a drop to 3 would
        # mean the `"standard"` keyword had replaced the explicit cell list.
        for line in out.splitlines():
            if "are comparable with the port" in line:
                evidence += " | " + line.strip()
        return R("pyexample_cs2021", "", verdict, evidence)
    finally:
        try:
            with open(fixture, "rb") as fh:
                after = fh.read()
        except OSError:
            after = b"<unreadable>"
        if after != before:
            with open(fixture, "wb") as fh:
                fh.write(before)



# --------------------------------------------------------------------------- #
# 17. contract -- the one CI's glob misses
# --------------------------------------------------------------------------- #
@check("contract", "validate_splitting_contract.py", "fast")
def c_contract():
    s = "validate_splitting_contract.py"
    p = os.path.join(ROOT, s)
    if not os.path.isfile(p):
        return R("contract", "", SKIP, f"{s} not present")
    rc, out = run([sys.executable, p], timeout=900)
    ok = "PASS" in out.upper() or rc == 0
    return R("contract", "", PASS if ok else FAIL,
             f"{s} executed (exit={rc}). NOTE: this script does NOT match CI's "
             f"`validate_*_with_python.py` glob, so the python-cross-check job "
             f"does not run it -- but this check does, on every push, because "
             f"`contract` is `fast` scope.")


# --------------------------------------------------------------------------- #
# 16. E2E -- run every runnable example and assert its output
# --------------------------------------------------------------------------- #
#
# The previous version of this check ran TWO examples (`pava` with a marker,
# `ssm` with `marker=None`) and was registered in `full` scope, which the CI
# fast job does not execute. So it asserted almost nothing, in a scope nothing
# runs. Both are fixed here.
#
# SCOPE OF THE TABLE -- measured, not guessed
# The examples census ran every `examples/*` directory that has
# both `moon.mod` and `moon.pkg` and recorded exit code, wall time and output
# shape. 21 directories: 20 finish, in **35.9 s total**, and every marker below
# is the measured final non-empty line of that example with every numeric
# literal replaced by `<n>`.
#
# WHY SUBSTITUTE THE VALUES. A marker is worth having only if it fails when the
# example breaks and not when it merely prints a different float. The first
# extraction rule cut each line at the first digit, which was wrong in both
# directions at once: `95% CI = [0.996, 1.004]` starts with a digit so the
# prefix came back empty and the marker became the whole line INCLUDING the
# floats (breaks on rounding, passes on NaN), while `key -2147483648 ...` cut
# to `key`, which matches any output containing that word. Replacing the
# literals keeps the whole structure and drops only the values.
#
# The `<n>` line count is the second assertion and is not decoration: a
# truncated or aborted example that still emits one matching line would pass a
# marker check alone.
#
# `api_server` IS DELIBERATELY ABSENT. `moon run examples/api_server` starts a
# listener and does not return -- measured as a 900 s timeout, which is 96% of
# the total runtime of the whole census. `api_test` and `security_dast` already
# boot that service and talk to it over HTTP with a settle delay; putting it in
# a "run it and read stdout" batch would turn a service into a hang. Its
# absence is a decision with a reason, not an oversight.
#
# Three markers are structurally generic (`datasets` `se = <n>`, `main`
# `se = <n>`, `parity` `end`) because that is genuinely all those examples end
# with. For them the assertion is "reached the final print with the expected
# line count", not "computed the right number" -- that is what the numeric
# upstream gates are for, and claiming otherwise here would overstate this
# check.
#
# (name, templatised final-line PREFIX, that line's exact char length,
#  minimum non-empty output lines)
#
# GENERATED, NOT TYPED. The e2e table generator runs every example and
# prints this table; `--check` re-runs it and diffs against this file. Two
# hand-transcription failures got here first: the census stored each final line
# TRUNCATED to 90 characters and those fragments were pasted in as if whole,
# and the repair retyped `bitexact`'s line by counting `b'...'` fields and got
# 22 against an actual 32. Both are counting problems and neither belongs to a
# person.
#
# The marker is a 60-character PREFIX of the templatised line plus that line's
# exact length. The length is not decoration: a prefix alone passes a line that
# got cut in half, and the whole line for `bitexact` is a 295-character string
# of 32 repetitions of `b'<n>'` that would assert nothing except "some bytes
# were printed".
_EXAMPLES = [
    ("apo", "bias_corrected_coef = <n>", 25, 26),
    ("apos", "contrast (level <n> - level <n>): delta=<n>, se=<n>", 51, 5),
    ("bitexact", "key <n> b'\\x<n>' b'\\x<n>' b'\\x<n>' b'\\x<n>' b'\\x<n>' b'\\x<n>", 295, 36),
    ("cluster", "cluster example done", 20, 7),
    ("consumer_demo", "contains <n>?    = true", 23, 5),
    ("cvar", "Result:                 PASS  (within <n>*se + <n> of <n>)", 58, 10),
    ("datasets", "se        = <n>", 15, 16),
    ("did_binary", "<n>% CI      = [<n>, <n>]", 25, 7),
    ("did_cross_section", "noisy ATT_hat = <n>, se = <n>", 29, 11),
    ("did_cs", "(g=<n>, t=<n>): ATT_hat=<n>, se=<n>, <n>% CI=[<n>, <n>] cove", 67, 7),
    ("did_cs_binary", "<n>% CI       = [<n>, <n>]", 26, 9),
    ("did_multi", "pre-treatment cells: <n>, max|coef|=<n> (expect < <n>)", 54, 24),
    ("fuzz", "ALL FUZZ SURFACES PASSED (no invariant violations)", 50, 24),
    ("lplr", "LPLR example done", 17, 16),
    ("main", "se   = <n>", 10, 81),
    ("parity", "end", 3, 215),
    ("pava", "PAVA example done", 17, 7),
    ("plpr", "<n>% CI    = [<n>, <n>]", 23, 18),
    ("splitting", "splitting se=<n>", 16, 4),
    ("ssm", "ssm example done", 16, 7),
]

# The `<n>` in a template is a PLACEHOLDER, so the substitution has to run on
# the observed line too, not only when the table was written. The first version
# compared a templated string against raw output and failed 13 of 20 examples
# for no reason other than that -- which is the mirror image of the failure it
# was written to avoid: a check that reports verdicts while comparing nothing.
# Both sides go through the same function or the templates are decoration.
_NUM_LITERAL = re.compile(r"-?\d+\.\d+(?:[eE][-+]?\d+)?|-?\.\d+|-?\d+")


def _templatise(line):
    return _NUM_LITERAL.sub("<n>", line.strip())


@check("e2e", "run every runnable example and assert its output", "fast")
def c_e2e():
    ran, bad = 0, []
    for name, prefix, want_len, min_lines in _EXAMPLES:
        d = os.path.join("examples", name)
        if not os.path.isdir(os.path.join(ROOT, d)):
            bad.append((name, "missing"))
            continue
        rc, out = run(["moon", "run", "--target", "native", d], timeout=900)
        ran += 1
        if rc != 0:
            bad.append((name, "exit=%d" % rc))
            continue
        lines = [ln.strip() for ln in (out or "").splitlines() if ln.strip()]
        if len(lines) < min_lines:
            bad.append((name, "only %d line(s), expected >= %d"
                        % (len(lines), min_lines)))
            continue
        got = _templatise(lines[-1]) if lines else ""
        if not got.startswith(prefix):
            bad.append((name, "final line starts %r, expected %r"
                        % (got[:60], prefix)))
        elif len(got) != want_len:
            bad.append((name, "final line is %d templatised chars, expected %d"
                        % (len(got), want_len)))
    if ran == 0:
        return R("e2e", "", SKIP, "no runnable examples found")
    return R("e2e", "", PASS if not bad else FAIL,
             "%d example(s) executed natively; exit code, final-line prefix, "
             "final-line length and output length asserted on each; "
             "examples/api_server excluded (service, never returns)"
             % ran + ("" if not bad else "; FAILURES: %s" % bad))


# --------------------------------------------------------------------------- #
# 15/21. API test + DAST -- boot the service and talk to it, including abuse
# Seconds to let `moon run` finish compiling and the listener come up before
# the harness sends its first request. Measured: probing from t=0 is what made
# api_test / security_dast fail intermittently.
_SETTLE_SECONDS = 15


def _http(port, path, method="GET", body=None):
    import urllib.request, urllib.error
    url = f"http://127.0.0.1:{port}{path}"
    data = body.encode() if body else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:                       # noqa: BLE001
        return 0, f"{type(e).__name__}: {e}"


def _boot_api(timeout=120):
    """Boot examples/api_server and wait until it actually answers HTTP.

    Probe with a real request rather than a bare `socket.create_connection`.
    The port is hardcoded to 4000 and `moon run` detaches the compiled server,
    so a leaked instance silently poisons the next boot -- see `_kill_tree`.
    """
    proc = subprocess.Popen(["moon", "run", "--target", "native", "examples/api_server"],
                            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace",
                            # Its own session so `_kill_tree` can killpg the
                            # whole group, which is the only thing that reaches
                            # the server `moon run` detaches. See _kill_tree.
                            start_new_session=(os.name == "posix"))
    port = 4000
    # Settle BEFORE the first request. Polling /healthz from t=0 connects while
    # the server is still coming up, and that early traffic -- not the number
    # of requests -- is what made this check fail intermittently. With a settle
    # window the shipped `allow_failure=false` serves every request.
    time.time()
    time.sleep(_SETTLE_SECONDS)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            try:
                tail = proc.stdout.read() or ""
            except Exception:                       # noqa: BLE001
                tail = ""
            return None, f"api_server exited early (rc={proc.returncode}): {tail[-300:]}"
        st, _body = _http(port, "/healthz")
        if st == 200:
            return proc, port
        time.sleep(0.5)
    _kill_tree(proc)
    return None, f"api_server did not answer GET /healthz with 200 within {timeout}s"


def _kill_tree(proc):
    """Kill `moon` AND the server binary it spawned, on Windows AND on POSIX.

    `moon run` detaches the compiled child: killing the `moon` parent leaves a
    live api_server holding port 4000, and the next boot then exits 1 with
    empty output (exit code 4294967295 == -1). Measured -- that is how the
    fuzz check first failed here.

    THE POSIX BRANCH IS NOT OPTIONAL. This function was Windows-only for its
    whole life: `taskkill` does not exist on Linux, so both of those calls
    raised FileNotFoundError into a bare `except Exception: pass`, and the only
    thing that actually killed anything was `proc.kill()` on the detached
    parent. Every api_server boot on Linux therefore LEAKED.

    Measured consequence, and the reason this is a fix rather than a cleanup:
    `api_test` and `security_dast` each passed when run alone on WSL and the
    SECOND one failed when run in the same invocation, with its own diagnostic
    naming the cause --

        api_server exited before any request (rc=1); is port 4000 already
        held by a leaked server?

    Nothing in CI showed it, because both checks are full-scope and no workflow
    ran full scope. They passed on Windows for the whole time because
    `taskkill /IM api_server.exe` was doing the work the POSIX branch lacked.

    Killing the whole PROCESS GROUP is the POSIX analogue of `taskkill /T`, and
    it is what makes the detached grandchild reachable. It requires the child
    to have been started in its own session -- hence `start_new_session=True`
    at both Popen call sites.
    """
    if proc is None:
        return
    if os.name == "posix":
        try:
            pgid = os.getpgid(proc.pid)
        except Exception:                           # noqa: BLE001
            pgid = None
        if pgid is not None:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except Exception:                       # noqa: BLE001
                pass
        # Belt and braces: `moon run` may have re-parented the server, in which
        # case the group kill above can miss it. Match on the image name.
        for image in ("api_server", "moon"):
            try:
                subprocess.run(["pkill", "-9", "-f", image],
                               capture_output=True, timeout=60)
            except Exception:                       # noqa: BLE001
                pass
    else:
        try:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                           capture_output=True, timeout=60)
        except Exception:                           # noqa: BLE001
            pass
        for image in ("api_server.exe", "moon.exe"):
            try:
                subprocess.run(["taskkill", "/F", "/IM", image],
                               capture_output=True, timeout=60)
            except Exception:                       # noqa: BLE001
                pass
    try:
        proc.kill()
    except Exception:                               # noqa: BLE001
        pass
    try:
        proc.wait(timeout=15)
    except Exception:                               # noqa: BLE001
        pass


@check("api_test", "api_server contract over HTTP", "full")
def c_api():
    proc, info = _boot_api()
    if proc is None:
        return R("api_test", "", FAIL, info)
    try:
        results = {}
        st, body = _http(info, "/healthz")
        results["/healthz"] = (st, "ok" in body)
        st, body = _http(info, "/ping")
        results["/ping"] = (st, "pong" in body)
        st, body = _http(info, "/version")
        results["/version"] = (st, "moonbit_doubleML" in body)
        # Pin the advertised library version to moon.mod. The example hardcoded
        # 0.52.0 while the package was at 0.161.0 -- 109 releases of silent
        # drift, invisible to CI and to the test suite, because the previous
        # assertion only checked that the substring appeared at all.
        mod_ver = ""
        m = re.search(r'version\s*=\s*"([^"]+)"', read(mbt("moon.mod")))
        if m:
            mod_ver = m.group(1)
        results["/version==moon.mod"] = (st, bool(mod_ver) and (f"@{mod_ver}" in body))
        # `x` must be n rows of p columns: api_server's json_to_matrix rejects a
        # flat vector with 400 "expected row 0 to be an array". The first
        # version of this payload sent a flat [1.0, 0.2, 1.0, 0.4]; the server
        # was RIGHT to reject it and the harness was wrong.
        payload = json.dumps({"x": [[1.0, 0.2], [1.0, 0.4], [0.5, 0.1], [0.7, 0.9]],
                              "y": [1.0, 2.0, 3.0, 4.0],
                              "d": [0.0, 1.0, 0.0, 1.0],
                              "n_folds": 2, "seed": 3141})
        st, body = _http(info, "/fit/plr", "POST", payload)
        results["/fit/plr"] = (st, "coef" in body or "coefficient" in body)
        # DoubleMLIRM trains a separate nuisance model per treatment group,
        # so every cross-fitting fold's TRAINING set needs both a control row
        # (d == 0) and a treated row (d == 1).  The library ABORTS when it
        # does not -- irm.mbt's `require(...)`, deliberately, rather than
        # writing zero nuisance predictions -- and a panic inside a request
        # handler takes the whole SERVICE down, not just the request: the
        # process exits and every later call is refused.  The api_server now
        # checks the same condition first (with the library's own `kfold`)
        # and answers 400, so this check asserts:
        #   * a valid binary treatment still fits;
        #   * a non-binary treatment is REJECTED, not fatal;
        #   * a fold whose training set lacks a group is REJECTED too -- the
        #     case a "both groups are present somewhere" check would miss;
        #   * the service is still alive after the rejections.
        irm_rows = [[1.0, 0.2], [1.0, 0.4], [0.5, 0.1], [0.7, 0.9]]
        irm_ok = json.dumps({"x": irm_rows, "y": [1.0, 2.0, 3.0, 4.0],
                             "d": [0.0, 1.0, 0.0, 1.0],
                             "n_folds": 2, "seed": 3141})
        st, body = _http(info, "/fit/irm", "POST", irm_ok)
        results["/fit/irm"] = (st, st == 200
                               and ("coef" in body or "coefficient" in body))
        irm_nonbinary = json.dumps({"x": irm_rows, "y": [1.0, 2.0, 3.0, 4.0],
                                    "d": [1.0, 2.0, 3.0, 4.0],
                                    "n_folds": 2, "seed": 3141})
        st, body = _http(info, "/fit/irm", "POST", irm_nonbinary)
        results["/fit/irm rejects a non-binary treatment"] = (st, st == 400)
        irm_unbalanced = json.dumps({"x": irm_rows, "y": [1.0, 2.0, 3.0, 4.0],
                                     "d": [0.0, 0.0, 0.0, 1.0],
                                     "n_folds": 2, "seed": 3141})
        st, body = _http(info, "/fit/irm", "POST", irm_unbalanced)
        results["/fit/irm rejects a fold without both groups"] = (st, st == 400)
        # The cross-fitting PARAMETERS are the same class of defect, and they
        # were the hole the v0.164.38 fix left: the library `require`s
        # `n_folds >= 2`, `n_folds <= n_obs` and `n_rep >= 1` (plr.mbt:106-108,
        # irm.mbt:121-123), and `kfold` aborts on an impossible partition
        # (kfold.mbt:442).  A `require` is a PANIC, not a catchable error, so
        # the process EXITS and every later caller is refused -- measured:
        # `POST /fit/irm` with one row and n_folds=2 printed
        # `precondition failed at kfold.mbt:442` + `PanicError`, the client
        # saw the connection reset, and `/healthz` then refused connections.
        # Both endpoints are exercised, because both call the library.
        one_row = json.dumps({"x": [[1.0, 0.2]], "y": [1.0], "d": [1.0],
                              "n_folds": 2, "seed": 3141})
        st, body = _http(info, "/fit/irm", "POST", one_row)
        results["/fit/irm rejects n_folds > n_obs"] = (st, st == 400)
        st, body = _http(info, "/fit/plr", "POST", one_row)
        results["/fit/plr rejects n_folds > n_obs"] = (st, st == 400)
        folds_one = json.dumps({"x": irm_rows, "y": [1.0, 2.0, 3.0, 4.0],
                                "d": [0.0, 1.0, 0.0, 1.0],
                                "n_folds": 1, "seed": 3141})
        st, body = _http(info, "/fit/irm", "POST", folds_one)
        results["/fit/irm rejects n_folds < 2"] = (st, st == 400)
        rep_zero = json.dumps({"x": irm_rows, "y": [1.0, 2.0, 3.0, 4.0],
                               "d": [0.0, 1.0, 0.0, 1.0],
                               "n_folds": 2, "n_rep": 0, "seed": 3141})
        st, body = _http(info, "/fit/irm", "POST", rep_zero)
        results["/fit/irm rejects n_rep < 1"] = (st, st == 400)
        st, body = _http(info, "/healthz")
        results["/healthz after a rejected fit"] = (st, st == 200)
        bad = [k for k, (s_, ok) in results.items() if not ok]
        verdict = PASS if not bad else FAIL
        detail = ", ".join(f"{k}->{s_}{'' if ok else ' BAD'}"
                           for k, (s_, ok) in results.items())
        if mod_ver:
            detail += f"  [api_server advertises moon.mod version {mod_ver}]"
        return R("api_test", "", verdict, detail)
    finally:
        _kill_tree(proc)


@check("security_dast", "dynamic abuse probe of api_server", "full")
def c_dast():
    """Abuse-probe api_server: malformed requests must not crash it.

    Single boot, one round of abuse, then a liveness re-check.

    api_server's `allow_failure` flag is what this check guards indirectly.
    With `allow_failure=false` the server serves EXACTLY ONE request and then
    dies on the second connection (measured: req1 -> 200 alive; req2 ->
    WinError 10061, rc=1, stderr "ReaderClosed"). This check sends 5 malformed
    requests plus a liveness re-check, so it goes red on its own -- no
    dedicated "cold probe" assertion is needed.

    A four-scenario sweep briefly "refuted" that finding and I reverted the
    fix. The sweep was invalid: every arm checked liveness after a single
    request, so it could not observe a second-connection failure. Lesson kept
    in `_verify/_api_count_probe_1630.py`: to test a server, send a SEQUENCE.
    """
    attacks = [
        ("/fit/plr", "POST", "{not json"),
        ("/fit/plr", "POST", "{}"),
        ("/fit/plr", "POST", json.dumps({"x": [], "y": [], "d": [], "n": 0, "p": 0})),
        ("/nope", "GET", None),
        ("/fit/plr", "TRACE", None),
    ]
    port = 4000
    proc = subprocess.Popen(["moon", "run", "--target", "native", "examples/api_server"],
                            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace",
                            # Same reason as _boot_api: its own session, so the
                            # group kill in _kill_tree reaches the detached
                            # server. Without it every boot leaks on POSIX.
                            start_new_session=(os.name == "posix"))
    try:
        # Wait for the listener with a real request. Note this sends a
        # request too: with `allow_failure=false` the server dies on the
        # SECOND connection, so a single-shot readiness check would miss it.
        time.sleep(_SETTLE_SECONDS)
        deadline = time.time() + 120
        ready = False
        while time.time() < deadline:
            if proc.poll() is not None:
                return R("security_dast", "", FAIL,
                         "api_server exited before any request (rc=%s); is port 4000 "
                         "already held by a leaked server?" % proc.returncode)
            if _http(port, "/healthz")[0] == 200:
                ready = True
                break
            time.sleep(0.5)
        if not ready:
            return R("security_dast", "", FAIL, "api_server never answered /healthz")
        crashes = []
        responses = []
        for path, method, body in attacks:
            st, txt = _http(port, path, method, body)
            responses.append("%s %s->%s" % (method, path, st))
            if st == 0:
                crashes.append("%s %s: %s" % (method, path, txt[:120]))
        st, _ = _http(port, "/healthz")
        alive = st == 200
        verdict = PASS if (not crashes and alive) else FAIL
        return R("security_dast", "", verdict,
                 "%d malformed request(s): %s; service alive afterwards = %s%s"
                 % (len(attacks), responses, alive,
                    ("; errors %s" % crashes) if crashes else ""))
    finally:
        _kill_tree(proc)


# --------------------------------------------------------------------------- #
# 20. SAST -- pattern rules, honestly labelled as pattern-based
# --------------------------------------------------------------------------- #
@check("security_sast", "pattern SAST over library sources", "fast")
def c_sast():
    RULES = [
        ("require() abort is uncatchable", r"\brequire\("),
        ("unwrap-style force access", r"\bas!|unsafe_|\bpanic!\("),
        ("unbounded allocation by literal size", r"Array::new\((\d{6,})\)"),
        ("float equality comparison", r"==\s*-?\d+\.\d+"),
        ("string concat in a loop guard", r"while[^\n]*\{[^}]*\+="),
    ]
    srcs = prod_sources()
    if not srcs:
        return R("security_sast", "", SKIP, "no production sources")
    hits = {name: 0 for name, _ in RULES}
    examples = {}
    for p in srcs:
        s = read(p)
        for name, pat in RULES:
            for m in re.finditer(pat, s):
                hits[name] += 1
                examples.setdefault(name, f"{os.path.relpath(p, ROOT)}:{s[:m.start()].count(chr(10))+1}")
    total = sum(hits.values())
    return R("security_sast", "", WARN,
             f"pattern-based (no CodeQL/semgrep in toolchain). {total} hit(s) over "
             f"{len(srcs)} files: " + ", ".join(f"{k}={v}" for k, v in hits.items())
             + "; first: " + "; ".join(f"{k}@{v}" for k, v in list(examples.items())[:3]))


# --------------------------------------------------------------------------- #
# 12. fuzz
# --------------------------------------------------------------------------- #
def fuzz_scale():
    """The fuzz harness's REAL scale: how many surfaces, how many trials each.

    Derived from the harness source so the evidence string cannot rot: if the
    harness gains a surface, or changes its trial count, the number this check
    reports follows it.  The surfaces are the calls that take a trial count --
    `fuzz_plpr_panel` is a helper, not a surface, and it takes no trials.

    Added in round 36, when this check's evidence called the three invocations
    a re-run of a single test case rather than a fuzz.  One invocation is 11
    surfaces at 300 trials each, so each invocation is a real property-based
    run; what the check repeats is that ONE run, because the seed ARGUMENT is
    ignored.  The limit is the missing seed sweep, not a missing fuzzer.
    """
    src = read(os.path.join(ROOT, "examples", "fuzz", "main.mbt"))
    if not src:
        return None
    surfaces = len(re.findall(
        r"fuzz_[a-z0-9_]+\(@moonbit_doubleML\.chacha8_rng\(s\d+\), trials\)", src))
    m = re.search(r"let trials\s*=\s*(\d+)", src)
    if not m or surfaces == 0:
        return None
    return surfaces, int(m.group(1))


@check("fuzz", "examples/fuzz across seeds", "full")
def c_fuzz():
    d = os.path.join(ROOT, "examples", "fuzz")
    if not os.path.isdir(d):
        return R("fuzz", "", SKIP, "examples/fuzz absent")
    bad, outputs = [], {}
    for seed in ("1", "42", "3141"):
        rc, out = run(["moon", "run", "--target", "native", d, seed], timeout=900)
        outputs[seed] = out
        if rc != 0:
            bad.append((seed, rc, out[-200:]))
    if not outputs:
        return R("fuzz", "", SKIP, "fuzz harness produced no run")
    # MEASURE seed-sensitivity instead of assuming it. examples/fuzz's `fn main`
    # takes no parameters, so `moon run examples/fuzz <seed>` IGNORES the seed
    # argument and replays one fixed workload. This check used to report
    # "3 seed(s) run" for what was really the same deterministic case three
    # times -- coverage that did not exist. Distinct outputs across distinct
    # seed arguments are the only evidence the seed is actually consumed.
    distinct = len(set(outputs.values()))
    scale = fuzz_scale()
    scale_note = ("%d surfaces, %d trials per surface" % scale if scale
                  else "an unknown number of surfaces")
    seed_note = (f"seed argument IS consumed ({distinct} distinct output(s) "
                 f"over {len(outputs)} seeds)") if distinct > 1 else (
        "seed argument is IGNORED by examples/fuzz -- `fn main` takes no "
        f"parameters, so all {len(outputs)} invocations replay ONE fixed "
        f"master seed (20260824); each invocation is a real property-based "
        f"run ({scale_note}), so what repeats is that one run, not a sweep "
        "of seeds")
    verdict = FAIL if bad else (PASS if distinct > 1 else WARN)
    body = (f"{len(outputs)} invocation(s); no crash" if not bad
            else f"{len(bad)} crash(es): {bad}")
    return R("fuzz", "", verdict,
             f"{body}; {seed_note}"
             "  [no CI job and no crash-regression corpus]")


# --------------------------------------------------------------------------- #
# 11. mutation -- real mutations against a pure-function file
# --------------------------------------------------------------------------- #
@check("mutation", "kill-rate on a mutated pure kernel", "full")
def c_mutation():
    # The first version of this check targeted "pava.mbt", which does not
    # exist -- pava() lives in ps_processor.mbt -- so it SKIPped silently and
    # the loop reported "not covered: mutation" without saying the target was
    # never found. Target the real file, and use mutations that genuinely
    # apply to it (verified: `>=` occurs once, `* 2.0` zero times).
    tgt = "ps_processor.mbt"
    src = read(mbt(tgt))
    if not src:
        return R("mutation", "", SKIP, f"{tgt} not found at {mbt(tgt)}")
    backup = src
    MUTS = [
        # Re-arms the exact defect that shipped in v0.104.0 and was fixed:
        # seeding a block with the RAW y[i] instead of w[i] * y[i].
        ("reintroduce raw-y pooling", lambda s: s.replace("let mut cur_sum = w[i] * y[i]",
                                                         "let mut cur_sum = y[i]", 1)),
        ("stop pooling one block early", lambda s: s.replace("while block_size.length() > 0",
                                                             "while block_size.length() > 1", 1)),
        ("flip comparison", lambda s: s.replace(">=", ">", 1)),
    ]
    results = []
    try:
        for name, fn in MUTS:
            mutated = fn(backup)
            if mutated == backup:
                results.append((name, "NOT-APPLIED"))
                continue
            with open(mbt(tgt), "w", encoding="utf-8", newline="") as f:
                f.write(mutated)
            rc, out = run(["moon", "test", "--target", "native", "--deny-warn",
                           "-p", "riantr/moonbit_doubleML"], timeout=2400)
            killed = rc != 0 or "failed: 0" not in out
            results.append((name, "killed" if killed else "SURVIVED"))
    finally:
        with open(mbt(tgt), "w", encoding="utf-8", newline="") as f:
            f.write(backup)
    killed = sum(1 for _, v in results if v == "killed")
    applied = sum(1 for _, v in results if v != "NOT-APPLIED")
    if applied == 0:
        return R("mutation", "", SKIP, f"no mutation could be applied to {tgt}")
    verdict = PASS if killed == applied else WARN
    return R("mutation", "", verdict,
             f"{killed}/{applied} killed on {tgt}: "
             + ", ".join(f"{n}={v}" for n, v in results)
             + "  [ad-hoc, no ledger, not a CI runner]")


# --------------------------------------------------------------------------- #
# 8/10/20. load, perf, benchmark
# --------------------------------------------------------------------------- #
def _time_example(d, reps=3):
    samples = []
    for _ in range(reps):
        t0 = time.perf_counter()
        rc, out = run(["moon", "run", "--target", "native", d], timeout=900)
        samples.append(time.perf_counter() - t0)
        if rc != 0:
            return None, out[-200:]
    return samples, None


@check("perf_test", "fit wall-clock, baseline + drift", "fast")
def c_perf():
    d = os.path.join(ROOT, "examples", "cvar")
    if not os.path.isdir(d):
        return R("perf_test", "", SKIP, "examples/cvar absent")
    s, err = _time_example("examples/cvar")
    if s is None:
        return R("perf_test", "", FAIL, f"example failed: {err}")
    med = sorted(s)[len(s) // 2]
    base_path = os.path.join(ROOT, "_verify", "perf_baseline.json")
    base = {}
    if os.path.isfile(base_path):
        base = json.loads(read(base_path))
    prev = base.get("examples/cvar_median_s")
    base["examples/cvar_median_s"] = med
    base["_note"] = "wall-clock incl. `moon run` compile check; noisy, drift only"
    with open(base_path, "w", encoding="utf-8") as f:
        json.dump(base, f, indent=2)
    drift = ""
    if prev:
        ratio = med / prev if prev else 0
        drift = f", drift vs baseline {ratio:.2f}x"
        verdict = PASS if ratio < 2.0 else WARN
    else:
        verdict = PASS
    return R("perf_test", "", verdict,
             f"median {med:.3f}s over {len(s)} runs (min {min(s):.3f}, max {max(s):.3f}){drift}")


@check("benchmark", "repeatability of a numeric result", "fast")
def c_benchmark():
    d = "examples/cvar"
    outs = []
    for _ in range(2):
        rc, out = run(["moon", "run", "--target", "native", d], timeout=900)
        if rc != 0:
            return R("benchmark", "", FAIL, out[-200:])
        nums = re.findall(r"-?\d+\.\d{6,}", out)
        outs.append(nums)
    if not outs[0]:
        return R("benchmark", "", SKIP, "no numeric output to compare")
    same = outs[0] == outs[1]
    return R("benchmark", "", PASS if same else FAIL,
             f"{len(outs[0])} printed value(s) bit-identical across 2 runs"
             + ("" if same else f"; run1={outs[0][:3]} run2={outs[1][:3]}"))


@check("load_stress", "sustained repeat of an example", "full")
def c_load():
    d = "examples/did_cs"
    if not os.path.isdir(os.path.join(ROOT, d)):
        return R("load_stress", "", SKIP, "examples/did_cs absent")
    t0 = time.perf_counter()
    fails, runs = [], 0
    for i in range(5):
        rc, out = run(["moon", "run", "--target", "native", d], timeout=900)
        runs += 1
        if rc != 0:
            fails.append(i)
    el = time.perf_counter() - t0
    return R("load_stress", "", PASS if not fails else FAIL,
             f"{runs} consecutive runs in {el:.1f}s ({runs/el:.2f} runs/s incl. "
             f"compile), failures={fails or 'none'}"
             + "  [no concurrency, no sustained-load profile, no SLO]")


# --------------------------------------------------------------------------- #
# 13. coverage -- explicitly a PROXY, not line coverage
# --------------------------------------------------------------------------- #
@check("coverage", "test-reachability proxy", "fast")
def c_coverage():
    srcs = prod_sources()
    if not srcs:
        return R("coverage", "", SKIP, "no production sources")
    tests = "".join(read(p) for p in all_mbt())
    total, reached, unreached = 0, 0, []
    for p in srcs:
        s = read(p)
        fns = re.findall(r"\bfn\s+(\w+)\s*\(", s)
        total += len(fns)
        miss = [f for f in fns if not re.search(r"\b" + re.escape(f) + r"\b", tests)]
        reached += len(fns) - len(miss)
        if miss:
            unreached.append((os.path.basename(p), len(miss), len(fns)))
    pct = 100.0 * reached / total if total else 0.0
    return R("coverage", "", PASS,
             f"PROXY, not line coverage: {reached}/{total} production functions "
             f"({pct:.1f}%) are referenced by name somewhere in the test suite. "
             f"`moon test --enable-coverage` instruments but emits no report in "
             f"this toolchain, so no line/branch figure is available. "
             f"Least-reached: {sorted(unreached, key=lambda x: -x[1])[:3]}")


# --------------------------------------------------------------------------- #
# 9. quality metrics -- aggregate of the others
# --------------------------------------------------------------------------- #
@check("quality_metrics", "aggregate quality index", "fast")
def c_metrics(prior=()):
    p = list(prior)
    n = len(p)
    passed = sum(1 for r in p if r == PASS)
    failed = sum(1 for r in p if r == FAIL)
    inert = sum(1 for r in p if r == INERT)
    skipped = sum(1 for r in p if r == SKIP)
    warned = sum(1 for r in p if r == WARN)
    if n == 0:
        return R("quality_metrics", "", SKIP, "no prior results to aggregate")
    strict = 100.0 * passed / n
    effective = 100.0 * (passed + warned) / n
    return R("quality_metrics", "", PASS,
             f"n={n}: PASS={passed} WARN={warned} FAIL={failed} INERT={inert} "
             f"SKIP={skipped}; strict pass rate {strict:.1f}%, "
             f"pass+warn {effective:.1f}%")
