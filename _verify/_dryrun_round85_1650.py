"""Round 85 dry-run: prove that the DESCRIPTION checks bite.

WHAT THIS IS A WITNESS FOR
===========================
A `moon.mod`'s `description` is the one line a registry reader sees BEFORE
they install anything.  Round 85 found two of them that had rotted:

  * the PUBLISHED manifest's description enumerated the model families and
    ended in "and policy-tree models", so it read as a COMPLETE list -- and
    it omitted LPLR and PLPR, which had shipped a MONTH before the
    description was written;
  * the LPLR example's manifest called LPLR "local potential quantile
    regression", which is LPQ's name.

The house had fixed this class once before -- two stale counts in two example
descriptions -- and it fixed it by EDITING the descriptions.  Nothing held it,
so it rotted again.  The new check `_verify/_verify_manifest_descriptions_1680.py`
holds it, with five rules:

  R1  the published list is CLOSED, so it must COVER every family the package
      ships;
  R2  every NAME the published list carries must resolve to a family that
      exists;
  R3  a description must not name a DIFFERENT estimator than the one it is
      about;
  R4  a description that names an estimator CLASS must name one that exists;
  R5  a count a description carries is measured, not trusted.

THE MECHANISMS
===============
Seven, and each one breaks a promise this round's tree now holds:

  1  the published description omits a family the package ships -- R1 must go
     RED;
  2  the published description names a family the package LACKS -- R2 must go
     RED;
  3  the LPLR example's manifest names LPQ's estimator -- R3 must go RED;
  4  the PLPR example's manifest names a class that does not exist -- R4 must
     go RED;
  5  the main example's description carries a wrong estimator count -- R5 must
     go RED;
  6  the API server's description names a route the server does not serve --
     R5 must go RED;
  7  the published description lists the SAME families in a DIFFERENT order --
     it must STAY GREEN.  This one runs the other way on purpose: it proves
     by construction that the check reads the LIST rather than comparing the
     string, so a re-worded description that still names every family is not
     punished.

Each mechanism perturbs a DIFFERENT string, because the teeth verifier
simulates the mechanisms cumulatively in source order and an anchor may be
consumed only once.

Run: python _verify/_dryrun_round85_1650.py
"""
import io
import os
import re
import shutil
import stat
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r85")
DRIVER = "_verify/_dryrun_round85_1650.py"

# The verifier this round adds.  The list is a LITERAL so that the teeth
# verifier can see which verifiers this driver runs.
VERIFIERS = ["_verify/_verify_manifest_descriptions_1680.py"]

# the manifests the mechanisms patch
PUB_MANIFEST = "moonbit_doubleML/moon.mod"
LPLR_MANIFEST = "examples/lplr/moon.mod"
MAIN_MANIFEST = "examples/main/moon.mod"
API_MANIFEST = "examples/api_server/moon.mod"

PLPR_MANIFEST = "examples/plpr/moon.mod"

MANIFESTS = [PUB_MANIFEST, LPLR_MANIFEST, PLPR_MANIFEST,
             MAIN_MANIFEST, API_MANIFEST]

# The paths the mechanisms patch, as module-level NAMES bound to
# os.path.join(WORK, ...).  The teeth verifier resolves a patch anchor's
# target STATICALLY, and a target it cannot resolve is an anchor it cannot
# check -- so the target is a name, not a function call.
PUB_MANIFEST_PATH = os.path.join(WORK, "moonbit_doubleML", "moon.mod")
LPLR_MANIFEST_PATH = os.path.join(WORK, "examples", "lplr", "moon.mod")
PLPR_MANIFEST_PATH = os.path.join(WORK, "examples", "plpr", "moon.mod")
MAIN_MANIFEST_PATH = os.path.join(WORK, "examples", "main", "moon.mod")
API_MANIFEST_PATH = os.path.join(WORK, "examples", "api_server", "moon.mod")


def run(cmd, cwd=REPO, timeout=3600):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def read(path):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def sub_once(path, pattern, repl):
    """Replace the regex `pattern` with `repl`, exactly once.

    A REGEX, not a literal: the mechanisms must patch the text as it NOW
    stands.  The replacement is LITERAL: `re.sub` would read a backslash in
    it as a group reference, and a mechanism that inserts a backslash into a
    manifest turns the file into something the registry cannot read.
    """
    text = read(path)
    crlf = "\r\n" in text
    pat = pattern.replace("\n", "\r\n") if crlf and "\r\n" not in pattern else pattern
    rep = repl.replace("\n", "\r\n") if crlf and "\r\n" not in repl else repl
    n = len(re.findall(pat, text))
    if n != 1:
        raise SystemExit("!! %s: %r matched %d times (expected 1)"
                         % (path, pattern, n))
    write(path, re.sub(pat, lambda _m: rep, text))


def failures(out, rc=0):
    """How many checks the verifier that printed this output FAILED.

    THE MARKER ALONE IS NOT ENOUGH
    ==============================
    The tree has more than one failure convention.  Most verifiers print
    the house's "*** FAIL ***"; the round-17 verifier prints "[FAIL]".
    A counter that counts one convention sees ZERO failures in a verifier
    that is failing loudly -- and the driver then reports "this mechanism
    proves nothing" while the verifier has just failed three checks.
    That is the round-43 lesson, and it is the reason the count comes
    from the verifier's OWN summary line.

    FOUR summary shapes are in the tree:

        "checks: 149   failed: 0"          the common form
        "N checks, M failed"                the same, with a comma
        "checks failed: M"                  the form without the word "checks"
        "checks run: N, checks failed: M"   the form with both

    The marker count is a second opinion and the two are combined with a
    MAXIMUM, so neither convention can hide a failure.  A verifier that
    exits non-zero without saying how many checks it failed is counted as
    ONE failure rather than none.
    """
    found = []
    # group(1) is the TOTAL and group(2) is the FAILED.  Reading group(1)
    # here made the counter report "149 failures" for a verifier that makes
    # 149 checks and fails NONE of them.
    found += [int(m.group(2)) for m in
              re.finditer(r"checks:\s*(\d+)\s+failed:\s*(\d+)", out)]
    found += [int(m.group(2)) for m in
              re.finditer(r"(\d+) checks,\s*(\d+) failed", out)]
    found += [int(m.group(1)) for m in
              re.finditer(r"checks run:\s*\d+,\s*checks failed:\s*(\d+)", out)]
    found += [int(m.group(1)) for m in
              re.finditer(r"checks failed:\s*(\d+)", out)]
    summary = max(found) if found else 0

    marker = 0
    for l in out.splitlines():
        if "*** FAIL ***" in l and l.strip() != "*** FAIL ***":
            marker += 1
        elif l.lstrip().startswith("[FAIL]"):
            marker += 1

    n = max(summary, marker)
    if n == 0 and rc not in (0, 2):
        # it failed and said nothing about how much: ONE failure, not none
        n = 1
    return n


def verify():
    """Run the verifiers; return their outputs and their counts."""
    outs = {}
    counts = {}
    for rel in VERIFIERS:
        rc, out = run([sys.executable, os.path.join(WORK, rel.replace("/", os.sep))],
                      cwd=WORK)
        outs[rel] = out
        counts[rel] = failures(out, rc)
    return outs, counts


def restore():
    """Put the tree under test back to the committed state."""
    rc, out = run(["git", "-C", WORK, "checkout", "--", "."], cwd=WORK)
    if rc != 0:
        print(out)
        raise SystemExit("git checkout failed")


# ------------------------------------------------------------------ the clone
if os.path.isdir(WORK):
    try:
        shutil.rmtree(WORK)
    except PermissionError:
        for _root, _dirs, _files in os.walk(WORK):
            for _f in _files:
                try:
                    os.chmod(os.path.join(_root, _f), stat.S_IWRITE)
                except OSError:
                    pass
        shutil.rmtree(WORK)
os.makedirs(WORK, exist_ok=True)

print("=== cloning locally and checking out %s ===" % COMMIT)
rc, out = run(["git", "clone", "--local", "--shared", "--no-checkout", ".", WORK])
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "checkout", "--detach", COMMIT], cwd=WORK)
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "rev-parse", "HEAD"], cwd=WORK)
print("  %s -> %s" % (COMMIT, out.strip()))

rc, out = run(["git", "diff", "--name-only", "HEAD"], cwd=REPO)
CHANGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
COPY_IN = []
for rel in list(VERIFIERS) + [DRIVER] + MANIFESTS + CHANGED:
    rel = rel.replace("\\", "/")
    if rel in COPY_IN:
        continue
    src = os.path.join(REPO, rel.replace("/", os.sep))
    if not os.path.isfile(src):
        continue
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    COPY_IN.append(rel)
print("  copied in %d files from the working tree" % len(COPY_IN))
rc, out = run(["git", "-C", WORK, "add", "--"] + COPY_IN, cwd=WORK)
if rc != 0:
    print(out)
    raise SystemExit("git add failed")
rc, out = run(["git", "-C", WORK, "commit", "-m",
               "dry-run: the tree under test carries this round's state"], cwd=WORK)
if rc != 0:
    print(out)
    raise SystemExit("git commit failed")


# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
outs, counts = verify()
for rel in VERIFIERS:
    print("  %-46s failures=%d" % (rel, counts[rel]))

# ---------------------------------------------------------------------------
# the counter, proved
# ---------------------------------------------------------------------------
# The counter must SEE a failure in every convention the tree uses.  So it is
# run against each convention here, and the driver refuses to start without it.
print()
print("=== the counter, proved against every convention ===")
for _label, _sample in (
        ("*** FAIL ***", "  *** FAIL ***  the check\n"
                         "  *** FAIL ***  the check\n"
                         "  *** FAIL ***  the check\n"),
        ("[FAIL]", "  [FAIL] the check\n"
                   "  [FAIL] the check\n"
                   "  [FAIL] the check\n"),
        ("checks: N failed: M", "checks: 7   failed: 3\n"),
        ("N checks, M failed", "7 checks, 3 failed\n"),
        ("checks failed: M", "checks failed: 3\n"),
        ("checks run: N, checks failed: M", "checks run: 7, checks failed: 3\n")):
    _n = failures(_sample)
    print("  %-34s -> %d" % (_label, _n))
    if _n != 3:
        print("!! the counter cannot see the %r convention -- ABORT" % _label)
        sys.exit(1)

if sum(counts.values()) != 0:
    for rel in VERIFIERS:
        if counts[rel]:
            print("---- %s ----" % rel)
            print(outs[rel][-3000:])
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# -------------------------------------------------------------- the mechanisms
#
# 1  the published description omits a family the package ships (LPLR).
M1_OLD = r"LPQ, LPLR, CVaR"
M1_NEW = "LPQ, CVaR"

# 2  the published description names a family the package LACKS.
M2_OLD = r"and policy-tree models"
M2_NEW = "XYZ, and policy-tree models"

# 3  the LPLR example's manifest names LPQ's estimator.
M3_OLD = r"LPLR \(partially logistic regression\) demo driver"
M3_NEW = "LPLR (local potential quantile regression) demo driver"

# 4  the PLPR example's manifest names a class that does not exist.  It is
#    a DIFFERENT manifest from mechanism 3 on purpose: mechanism 3 replaces
#    the text this one anchored on, and an anchor the previous mechanism
#    consumed is an anchor the teeth verifier cannot resolve.
M4_OLD = r"PLPR demo driver"
M4_NEW = "DoubleMLNoSuchThing demo driver"

# 5  the main example's description carries a wrong estimator count.
M5_OLD = r"\(12 estimators on synthetic PLR\)"
M5_NEW = "(11 estimators on synthetic PLR)"

# 6  the API server's description names a route the server does not serve.
M6_OLD = r"plus /healthz, /ping, /version"
M6_NEW = "plus /healthz, /ping, /version, /delete"

# 7  the published description lists the SAME families in a DIFFERENT order --
#    it must STAY GREEN.
M7_OLD = r"PQ, QTE, LPQ"
M7_NEW = "QTE, PQ, LPQ"

V = VERIFIERS[0]

MECHANISMS = [
    ("the published description omits a family the package ships",
     lambda: sub_once(PUB_MANIFEST_PATH, M1_OLD, M1_NEW), [V], []),
    ("the published description names a family the package LACKS",
     lambda: sub_once(PUB_MANIFEST_PATH, M2_OLD, M2_NEW), [V], []),
    ("the LPLR example's manifest names LPQ's estimator",
     lambda: sub_once(LPLR_MANIFEST_PATH, M3_OLD, M3_NEW), [V], []),
    ("the PLPR example's manifest names a class that does not exist",
     lambda: sub_once(PLPR_MANIFEST_PATH, M4_OLD, M4_NEW), [V], []),
    ("the main example's description carries a wrong estimator count",
     lambda: sub_once(MAIN_MANIFEST_PATH, M5_OLD, M5_NEW), [V], []),
    ("the API server's description names a route it does not serve",
     lambda: sub_once(API_MANIFEST_PATH, M6_OLD, M6_NEW), [V], []),
    ("the published description lists the same families in a different order "
     "-- it must STAY GREEN",
     lambda: sub_once(PUB_MANIFEST_PATH, M7_OLD, M7_NEW), [], [V]),
]

print()
print("=== the mechanisms, one at a time, each from a green tree ===")
ok = True
for i, (desc, apply_it, must_fail, must_green) in enumerate(MECHANISMS, 1):
    restore()
    apply_it()
    outs, counts = verify()
    print()
    print("  %d. %s" % (i, desc))
    for r in VERIFIERS:
        print("       %-46s failures=%d" % (r, counts[r]))
    bad = False
    for rel in must_fail:
        if counts[rel] <= 0:
            print("---- %s ----" % rel)
            print(outs[rel][-3000:])
            print("!! %s did NOT fail -- this mechanism proves nothing" % rel)
            bad = True
    for rel in must_green:
        if counts[rel] != 0:
            print("---- %s ----" % rel)
            print(outs[rel][-3000:])
            print("!! %s went RED -- the check was not reading the LIST" % rel)
            bad = True
    for rel in must_fail:
        if counts[rel] > 0:
            for l in outs[rel].splitlines():
                if "*** FAIL ***" in l:
                    print("       %s" % l.strip()[:150])
    if bad:
        ok = False

print()
print("=" * 78)
print("VERDICT %s -- every mechanism made the check it breaks fail"
      % ("PASS" if ok else "FAIL"))
print("=" * 78)

# The capture is the cited raw log of the run, and it is TRACKED by
# convention: the round-59 driver publishes one, and the documents that
# describe the dry-run cite it.
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r85_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 85 dry-run: the manifest description checks, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline 0 failing checks; every mechanism made the check it "
             "breaks fail\n")
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn, rels, green) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s -- %s\n"
                 % (i, name, ", ".join(rels) if rels
                    else ("must stay green: " + ", ".join(green))))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
