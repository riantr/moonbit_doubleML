"""Full self-check for the moonbit_doubleML release state.

Written because of the v0.131.1 lesson: the README status table had three stale
counts that survived because every release checklist only remembered the rows
that happened to move. So this script does not trust the README -- it
RE-DERIVES every number in the status table from the tree and diffs it against
what the README claims.

Exit code 0 only if every check passes.

    python _verify/_selfcheck.py            # full run (moon gates ~6 min)
    python _verify/_selfcheck.py --quick    # skip the 4-target test sweep
"""
import http.client
import io
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(REPO, "moonbit_doubleML")
QUICK = "--quick" in sys.argv

results = []
pending = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (("  -- " + detail) if detail else ""))
    return ok


def pending_check(name, reason):
    """A check that could not be READ is neither pass nor fail.

    Same principle as check_ci(), and for the same reason: a tool that cries
    wolf on an unreadable input gets ignored on the one input it was written for.
    PENDING still forces a non-zero exit so an unverified release cannot be
    mistaken for a verified one.
    """
    results.append((name, True, ""))
    print("  PENDING  %s  -- could not read: %s" % (name, reason))
    pending.append(name)
    return False


def check_ci(name, conclusion, status):
    """A CI run that is still executing is PENDING, not FAILED.

    The first full v0.131.2 run reported `CI (master) succeeded -- None` while
    that run was still in flight: GitHub returns `conclusion: null` until the
    run completes. Scoring `None` as a failure conflates "not finished yet" with
    "broke", which is the one distinction this tool exists to preserve -- a
    release check that cries wolf gets ignored. PENDING counts as neither pass
    nor fail but still makes the exit code non-zero, so a half-finished pipeline
    cannot be mistaken for a verified one.
    """
    if status != "completed":
        results.append((name, True, ""))
        print("  PENDING  %s  -- run still %s" % (name, status))
        pending.append(name)
        return False
    return check(name, conclusion == "success", str(conclusion))


def sh(cmd, cwd=REPO, timeout=3600):
    return subprocess.run(
        cmd, cwd=cwd, shell=True, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=timeout,
    )


def gh(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "selfcheck", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as f:
        return json.loads(f.read().decode())


def is_unreadable(exc):
    """Did this exception mean "the answer never arrived", or "the answer was bad"?

    The distinction is the whole point of this file. A read that timed out and a
    read that came back wrong look identical if you only keep `str(e)`, but they
    demand opposite responses: retry, versus go fix something. GitHub from this
    network resets for hours at a time, so "never arrived" is the common case and
    must not be dressed up as a verdict.

    Unreadable: URLError (and its HTTPError subclass) for connection/DNS/reset,
    socket timeouts, RemoteDisconnected. Readable-but-bad: KeyError and friends,
    i.e. the API answered and we no longer understand the payload -- those keep
    failing loudly, because that is a genuine regression in the checker.
    """
    if isinstance(exc, urllib.error.HTTPError):
        # The server answered with a status. 5xx is the server being unwell, not
        # the repo being broken; 4xx is a real answer and stays a failure.
        return exc.code >= 500
    if isinstance(exc, (urllib.error.URLError, socket.timeout, TimeoutError,
                        ConnectionError, http.client.RemoteDisconnected,
                        http.client.IncompleteRead)):
        return True
    return False


def remote_refs(url, tag):
    """Return (master_sha, has_tag, unreadable_reason).

    v0.143.0 defect, fixed here. This used to be a bare

        out = sh('git ls-remote ...');  txt = out.stdout

    with the return code ignored, so a transport failure -- an SSH reset, an
    HTTPS connection torn down mid-handshake -- produced empty stdout, which
    then compared as `remote_master != head` and printed

        FAILED: github: master at HEAD  remote= local=c0e68b06b01f

    i.e. "the remote is at the wrong commit, go push", for a branch the REST
    API showed published at exactly that SHA. That is the crying-wolf defect
    check_ci() exists to prevent, reintroduced 150 lines later because nobody
    applied the lesson to the neighbouring section.

    So: a non-zero exit means WE COULD NOT READ, and is reported as such. Only
    a zero exit is trusted, and only then is an empty result real evidence of
    absence -- `git ls-remote` succeeds and simply prints nothing for a ref
    that does not exist.
    """
    out = sh('git ls-remote "%s" refs/heads/master "refs/tags/%s"' % (url, tag))
    if out.returncode != 0:
        lines = (out.stderr or out.stdout).strip().splitlines()
        return None, None, lines[-1] if lines else "exit %d" % out.returncode
    words = out.stdout.split()
    return (words[0] if words else ""), ("refs/tags/%s" % tag) in out.stdout, None


def gh_refs_api(tag):
    """Same two facts, read from the REST API instead of the git transport.

    Both git routes to GitHub (HTTPS and SSH) reset for hours at a time in this
    environment while api.github.com kept answering 200, so the API is the only
    reader that produces evidence rather than a guess.

    Returns (master, has_tag), or raises if the API could not be read.

    Only an HTTP 404 counts as "the tag is absent" -- that is the API stating a
    fact. Every other failure (403 rate-limit, 5xx, connection reset) means we
    did not get an answer, and this function deliberately lets it propagate so
    the caller degrades to PENDING. Catching a bare `Exception` here and
    returning has_tag=False is the same class of bug as ignoring git's return
    code, only pointed the other way: it turns "could not read" into "the tag
    was never pushed", and the unauthenticated API allows only 60 requests an
    hour, so that path fires the moment this script is run repeatedly.
    """
    base = "https://api.github.com/repos/riantr/moonbit_doubleML/git/ref"
    master = gh(base + "/heads/master")["object"]["sha"]
    try:
        gh(base + "/tags/%s" % tag)
        has_tag = True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            has_tag = False    # the API answered, and the answer is "no such ref"
        else:
            raise RuntimeError("API %s for tag %s: %s" % (e.code, tag, e.reason))
    return master, has_tag


def read(p):
    return io.open(p, "r", encoding="utf-8", newline="").read()


print("=" * 78)
print("SELF-CHECK  moonbit_doubleML")
print("=" * 78)

# ---------------------------------------------------------------- A. repo state
print("\nA. repository state")
st = sh("git status --porcelain")
tracked_dirty = [l for l in st.stdout.splitlines()
                 if l.strip() and not l.startswith("??")]
check("working tree clean (tracked files)", not tracked_dirty,
      "; ".join(tracked_dirty[:3]))

head = sh("git rev-parse HEAD").stdout.strip()
tag = sh("git describe --tags --exact-match HEAD 2>nul").stdout.strip() \
    or sh("git describe --tags --exact-match").stdout.strip()
moon_ver = re.search(r'^version\s*=\s*"([^"]+)"',
                     read(os.path.join(PKG, "moon.mod")), re.M).group(1)
check("HEAD is exactly on a tag", bool(tag), "tag=" + tag)
check("tag version == moon.mod version", tag == "v" + moon_ver,
      "tag=%s moon.mod=%s" % (tag, moon_ver))

readme = read(os.path.join(REPO, "README.mbt.md"))
rm_ver = re.search(r'`moon\.mod` version \| \*\*([0-9.]+)\*\*', readme).group(1)
check("README version row == moon.mod version", rm_ver == moon_ver,
      "README=%s moon.mod=%s" % (rm_ver, moon_ver))

for remote in ("origin", "github"):
    url = {"origin": "https://gitee.com/ren-yongxiang/moonbit_doubleml.git",
           "github": "git@github.com:riantr/moonbit_doubleML.git"}[remote]
    master, has_tag, unreadable = remote_refs(url, tag)
    source = "git ls-remote"
    if unreadable and remote == "github":
        # GitHub only: the REST API can answer when neither git route can.
        # gitee has no equivalent unauthenticated reader, so it degrades to
        # PENDING on its own -- which is the honest outcome, not a failure.
        try:
            master, has_tag = gh_refs_api(tag)
            source = "REST API (git transport: %s)" % unreadable
        except Exception as e:                                # noqa: BLE001
            unreadable = "%s; API also unreadable: %s" % (unreadable, e)
    if unreadable:
        pending_check("%s: master at HEAD" % remote, unreadable)
        pending_check("%s: tag %s published" % (remote, tag), unreadable)
        continue
    check("%s: master at HEAD" % remote, master == head,
          "%s local=%s remote=%s" % (source, head[:12], master[:12]))
    check("%s: tag %s published" % (remote, tag), has_tag, source)

# --------------------------------------------------- B. README table re-derived
print("\nB. README status table, re-derived from the tree")
files = [f for f in os.listdir(PKG) if f.endswith(".mbt")]
# v0.132.0: THREE explicit buckets. The old code classified "production" as
# "everything that is not *_test.mbt", which swept the 25 `*wbtest.mbt`
# WHITEBOX TEST files into the production count -- the same defect the README
# carried, wrong since at least v0.127.0. `*wbtest.mbt` does not end in
# `_test.mbt` (it ends in `btest.mbt`), so the suffix test misses it.
bbtest = [f for f in files if f.endswith("_test.mbt") and not f.endswith("wbtest.mbt")]
wbtest = [f for f in files if f.endswith("wbtest.mbt")]
tests = bbtest + wbtest
prod = [f for f in files if f not in tests]

blob = "".join(read(os.path.join(PKG, f)) for f in prod)
ESTIMATORS = [
    "DoubleMLPLR", "DoubleMLIRM", "DoubleMLPLIV", "DoubleMLIIVM",
    "DoubleMLDID", "DoubleMLDIDBinary", "DoubleMLDIDCS", "DoubleMLDIDCSBinary",
    "DoubleMLDIDMulti", "DoubleMLDIDCrossSection", "DoubleMLSSM", "DoubleMLAPO",
    "DoubleMLAPOS", "DoubleMLPQ", "DoubleMLQTE", "DoubleMLLPQ",
    "DoubleMLLPLR", "DoubleMLCVAR", "DoubleMLRDD", "DoubleMLBLP",
    "DoubleMLPLPR", "DoubleMLPolicyTree",
]
SANDWICH = ("sandwich_se", "cluster_sandwich_se", "bias_corrected_coef")

sandwich_cov = {m: [e for e in ESTIMATORS
                    if re.search(r"pub fn %s::%s\s*\(" % (e, m), blob)]
                for m in SANDWICH}
missing_sandwich = sorted(set(ESTIMATORS) - set(sandwich_cov["sandwich_se"]))
# Per-cell variants. NOTE the `\b` discipline that bit v0.131.1: a pattern of
# `pub fn X::sandwich_se` with no word boundary ALSO matches
# `pub fn X::sandwich_se_at(`, which inflated the count from 15 to 19 by
# pulling in the four multi-theta estimators. Match the opening paren.
per_cell = [e for e in missing_sandwich
            if re.search(r"pub fn %s::\w*sandwich_se_at" % e, blob)
            or re.search(r"pub fn %s::cluster_sandwich_se_at" % e, blob)]
est_files = set()
for e in ESTIMATORS:
    m = re.search(r"pub struct %s\b[^\n]*" % e, blob)
    for f in prod:
        if re.search(r"pub struct %s\b" % e, read(os.path.join(PKG, f))):
            est_files.add(f)
            break

derived = {
    "total .mbt": len(files),
    "prod": len(prod),
    "test": len(tests),
    "estimators": len(ESTIMATORS),
    "sandwich": len(sandwich_cov["sandwich_se"]),
    "src files": len(est_files),
}
print("  derived: " + ", ".join("%s=%s" % kv for kv in derived.items()))
print("  sandwich coverage is uniform across all three methods: "
      + str(all(len(v) == derived["sandwich"] for v in sandwich_cov.values())))
print("  WITHOUT scalar sandwich: " + ", ".join(missing_sandwich))
print("  ... of which expose per-cell variants: " + ", ".join(per_cell))

m = re.search(r'`\.mbt` file count \| \*\*(\d+)\*\* `\.mbt` files '
              r'\(\*\*(\d+)\*\* production \+ \*\*(\d+)\*\* blackbox test '
              r'\+ \*\*(\d+)\*\* whitebox test\)', readme)
check("README .mbt count",
      bool(m) and [int(x) for x in m.groups()] ==
      [len(files), len(prod), len(bbtest), len(wbtest)]
      and len(prod) + len(bbtest) + len(wbtest) == len(files),
      "README=%s derived=%d/%d/%d/%d" % (m.groups() if m else None,
                                          len(files), len(prod),
                                          len(bbtest), len(wbtest)))
m = re.search(r'Estimators \| \*\*(\d+)\*\* `DoubleML\*`', readme)
check("README estimator count", bool(m) and int(m.group(1)) == len(ESTIMATORS),
      "README=%s derived=%d" % (m.group(1) if m else None, len(ESTIMATORS)))
m = re.search(r'Sandwich-variance coverage \| \*\*(\d+) / (\d+)\*\*', readme)
check("README sandwich (scalar) coverage",
      bool(m) and int(m.group(1)) == derived["sandwich"]
      and int(m.group(2)) == len(ESTIMATORS),
      "README=%s/%s derived=%d/%d" % (m.group(1), m.group(2),
                                      derived["sandwich"], len(ESTIMATORS)))
m = re.search(r'\*\*(\d+)\*\* more \(', readme)
check("README sandwich (per-cell) count",
      bool(m) and int(m.group(1)) == len(per_cell),
      "README=%s derived=%d" % (m.group(1) if m else None, len(per_cell)))
for name in missing_sandwich:
    if name not in per_cell:
        check("README names %s as having NO sandwich" % name,
              ("`%s`" % name) in readme)
m = re.search(r'in (\d+) source files', readme)
check("README source-file count", bool(m) and int(m.group(1)) == len(est_files),
      "README=%s derived=%d" % (m.group(1) if m else None, len(est_files)))
check("no stale retracted claim (v0.128.0 G-vs-D) in README",
      "v128_did_cs_binary_nuisance_is_a_group_propensity" not in readme)

# ---------------------------------------------------------------- C. gates
print("\nC. toolchain gates")
typos = os.path.join(os.environ.get("TEMP", ""), "typos1190", "typos.exe")
r = sh('"%s"' % typos)
check("typos 1.19.0 clean", r.returncode == 0 and not r.stdout.strip(),
      r.stdout.strip()[:120])

r = sh("moon fmt --check", cwd=PKG)
check("moon fmt --check", r.returncode == 0, r.stdout.strip()[-160:])

targets = ["native", "wasm", "wasm-gc", "js"]
counts = {}
for t in targets:
    r = sh("moon check --deny-warn --target " + t, cwd=PKG)
    # v0.144.0: the return code was missing here too, the same defect as the
    # remote-ref block above. `ok` was inferred from the ABSENCE of the string
    # "Failed with", so any moon check that died before reaching its own error
    # reporting -- a toolchain crash, an OOM, a missing target -- printed no
    # such line and scored PASS. Absence of a message is not evidence of
    # success; the exit code is.
    ok = r.returncode == 0 and "Failed with" not in r.stdout
    check("moon check --deny-warn (%s)" % t, ok,
          "" if ok else "exit=%d %s" % (r.returncode, r.stdout.strip()[-160:]))

if QUICK:
    print("\n  (--quick: skipping the 4-target test sweep)")
else:
    print("\nD. tests (this also re-derives the README test counts)")
    for t in targets:
        r = sh("moon test --target " + t, cwd=PKG)
        mm = re.search(r"Total tests: (\d+), passed: (\d+), failed: (\d+)\.", r.stdout)
        if mm:
            counts[t] = (int(mm.group(1)), int(mm.group(3)))
            check("moon test (%s)" % t, int(mm.group(3)) == 0,
                  "%s/%s passed" % (mm.group(2), mm.group(1)))
        else:
            check("moon test (%s)" % t, False, r.stdout.strip()[-200:])
    m = re.search(r'Tests \(native / wasm / js\) \| \*\*(\d+) / (\d+) / (\d+)\*\*',
                  readme)
    derived_n = counts.get("native", (0,))[0]
    check("README native/wasm/js test counts",
          bool(m) and all(int(m.group(i + 1)) == counts.get(t, (0,))[0]
                          for i, t in enumerate(["native", "wasm", "js"])),
          "README=%s derived=%s" % (m.groups() if m else None,
                                    {k: v[0] for k, v in counts.items()}))
    m = re.search(r'Tests \(wasm-gc\) \| \*\*(\d+) / (\d+)\*\*', readme)
    check("README wasm-gc test count",
          bool(m) and int(m.group(1)) == counts.get("wasm-gc", (0,))[0],
          "README=%s derived=%s" % (m.group(1) if m else None,
                                    counts.get("wasm-gc", (None,))[0]))

# ---------------------------------------------------------------- E. release
print("\nE. release pipeline state")

pub = []          # assigned inside try; the except handler reads it
try:
    runs = gh("https://api.github.com/repos/riantr/moonbit_doubleML"
              "/actions/runs?per_page=8")["workflow_runs"]
    pub = [r for r in runs if r["head_branch"] == tag and r["name"].startswith("publish")]
    ci = [r for r in runs if r["name"] == "CI" and r["head_branch"] == "master"]
    if pub:
        r0 = pub[0]
        check_ci("CI publish run for %s succeeded" % tag,
                 r0["conclusion"], r0["status"])
        jobs = gh("https://api.github.com/repos/riantr/moonbit_doubleML"
                  "/actions/runs/%s/jobs" % r0["id"])["jobs"]
        # v0.132.0: three-state, for the same reason check_ci() is. A step that
        # has not run yet reports `conclusion: null`, and scoring null as a
        # failure conflates "still executing" with "broke". Verified live: this
        # fired while the v0.132.0 run was genuinely mid-flight.
        for job in jobs:
            bad = [s["name"] for s in job["steps"]
                   if s["conclusion"] not in ("success", None)]
            unrun = [s["name"] for s in job["steps"] if s["conclusion"] is None]
            check_ci("publish job steps: %s" % job["name"],
                     "failure" if bad else "success", r0["status"])
            if unrun and not bad:
                print("        (not yet run: %s)" % ",".join(unrun))
    else:
        check("CI publish run for %s found" % tag, False)
    if ci:
        check_ci("CI (master) succeeded", ci[0]["conclusion"], ci[0]["status"])
    rel = gh("https://api.github.com/repos/riantr/moonbit_doubleML"
             "/releases/tags/%s" % tag)
    check("GitHub Release %s published" % tag,
          rel["tag_name"] == tag and not rel["draft"], rel.get("published_at"))
except Exception as e:                                    # noqa: BLE001
    # v0.132.0: a 404 here means "CI has not created the Release yet", which is
    # the normal state while the publish run is in flight -- not a broken
    # release. Only a run that has COMPLETED and still shows no Release is a
    # real failure, so gate on the run state instead of on readability alone.
    #
    # v0.144.0, the same defect a third time. This blanket handler caught
    # `URLError: <urlopen error ... timed out>` and scored it
    #     FAIL  GitHub release state readable  -- The read operation timed out
    # which reads as "the release state is broken" when the truth is "the read
    # did not happen". That is what I had just spent the whole fix removing
    # from the remote-ref block, in a different except handler, in the same
    # file. A KeyError from a changed API shape must still FAIL loudly -- that
    # one is real -- so the split is by exception kind, not by leniency.
    msg = str(e)
    still_running = bool(pub) and pub[0]["status"] != "completed"
    if is_unreadable(e):
        pending_check("GitHub release state readable", msg)
    elif still_running and "404" in msg:
        results.append(("GitHub release state readable", True, ""))
        print("  PENDING  GitHub Release published  -- run still %s"
              % pub[0]["status"])
        pending.append("GitHub Release published")
    else:
        check("GitHub release state readable", False, msg)

# ---------------------------------------------------------------- summary
print("\n" + "=" * 78)
fails = [r for r in results if not r[1]]
print("SELF-CHECK: %d/%d passed, %d failed" %
      (len(results) - len(fails), len(results), len(fails)))
for n, _, d in fails:
    print("  FAILED: %s  %s" % (n, d))
for n in pending:
    print("  PENDING: %s" % n)
print("=" * 78)
sys.exit(1 if fails or pending else 0)