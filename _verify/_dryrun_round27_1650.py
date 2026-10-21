"""Dry-run the tutorial-claims verifier against a tree whose claims are broken.

WHAT THIS PROVES
=================
`_verify/_verify_tutorial_claims_1650.py` derives the four tutorial documents'
claims from the SOURCE -- the DGP factories' real parameter lists, their
accessor sets, the 22-estimator cross-check coverage map, the 9/15 upstream
wheel split -- and checks that a witness sits next to every published number.

Round 27 found five false statements across `doc/003_quick_start`,
`doc/005_dgps`, `doc/006_python_check` and the published README.  The point
of the dry-run is that each of them is a sentence that READS FINE: a wrong
signature in a table, a wrong accessor set, a published number with nothing
asserting it, a coverage claim that is true only because it counted a family
it never mentioned, and a clause that says the pyexample family is the only
one whose reference is upstream.  No spelling check and no number check sees
any of them.

EACH MECHANISM IS PROVEN ON ITS OWN
====================================
The mechanisms are applied ONE AT A TIME and the verifier is run after each,
and the failure count must GROW at every step.  A mechanism that contributes
nothing is visible as a flat step, and the driver fails.  (Round 24's dry-run
had exactly that defect: one mechanism contributed ZERO failures, the total
was still > 0, and the dead mechanism hid inside a passing run.)

MECHANISM 9 IS THE ONE THAT PROVES THE DERIVATION IS LIVE
===========================================================
It deletes `pyexample_pq.py` from the clone.  Nothing in the verifier is
hard-coded to "22 estimators are covered": the coverage map is re-derived from
the scripts that are actually there, so `DoubleMLQTE` falls out of the union
and the verifier notices that an estimator is uncovered and that the
pyexample-only set is no longer the one the document names.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the corrected documents, the
rebuilt README and the new verifier -- are copied in from the WORKING TREE,
and the claims are broken on top of that.

Run: python _verify/_dryrun_round27_1650.py
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r27_mut")
VERIFIER = "_verify/_verify_tutorial_claims_1650.py"

COPY_IN = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "doc/003_quick_start/readme.mbt.md",
    "doc/003_quick_start/using_test.mbt",
    "doc/005_dgps/readme.mbt.md",
    "doc/006_python_check/readme.mbt.md",
    VERIFIER,
]


def run(cmd, cwd=REPO, timeout=3600):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def patch(path, old, new, count=1):
    """Replace `old` with `new`, keeping the file's own line endings."""
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    crlf = "\r\n" in text
    old = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
    new = new.replace("\n", "\r\n") if crlf and "\r\n" not in new else new
    n = text.count(old)
    if n != count:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, old[:60], n, count))
    text = text.replace(old, new)
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def verify(work):
    """Run the verifier in `work`; return (exit code, output, failure count)."""
    rc, out = run([sys.executable, os.path.join(work, VERIFIER)],
                  cwd=work, timeout=3600)
    exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
    return rc, out, exact


if os.path.isdir(WORK):
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

for rel in COPY_IN:
    src = os.path.join(REPO, rel.replace("/", os.sep))
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    print("  copied in %s" % rel)

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
DOC3 = os.path.join(WORK, "doc", "003_quick_start", "readme.mbt.md")
TEST3 = os.path.join(WORK, "doc", "003_quick_start", "using_test.mbt")
DOC5 = os.path.join(WORK, "doc", "005_dgps", "readme.mbt.md")
DOC6 = os.path.join(WORK, "doc", "006_python_check", "readme.mbt.md")
PQ = os.path.join(WORK, "pyexample_pq.py")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0 = verify(WORK)
print("  exit=%d  failures=%d" % (rc0, n0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# ------------------------------------------------------------ the mechanisms
MECHANISMS = [
    ("the DGP catalogue gives make_irm_heterogeneous_data a theta parameter again",
     lambda: patch(
         DOC5,
         "| `make_irm_heterogeneous_data` | IRM, heterogeneous effects | "
         "`(n_obs, dim_x, seed)` |",
         "| `make_irm_heterogeneous_data` | IRM, heterogeneous effects | "
         "`(n_obs, theta, seed)` |")),

    ("the DGP catalogue claims the x_get/y_get/d_get trio for all 18 again",
     lambda: patch(
         DOC5,
         "with a `theta_get()` accessor for the true causal parameter, and 17",
         "with `x_get()` / `y_get()` / `d_get()` accessors, and 17")),

    ("the DGP catalogue stops naming the LPLR exception",
     lambda: patch(
         DOC5,
         "exception is `make_lplr_LZZ2020`, which returns an `LplrData`\n"
         "carrying `theta_get()` and `data_get()`",
         "exception is `make_lplr_LZZ2020`, which returns an `LplrData`\n"
         "carrying `theta_get()` and `other_get()`")),

    ("the quick start publishes a coef() value its test does not assert",
     lambda: patch(
         DOC3,
         "| `coef()` | `-8.782651064906958` |",
         "| `coef()` | `-8.782651064906959` |")),

    ("the quick start's test stops asserting confint()",
     lambda: patch(
         TEST3,
         "  let (lo, hi) = fitted.confint()\n"
         "  inspect(lo == -35.74634818655666, content=\"true\")\n"
         "  inspect(hi == 18.18104605674274, content=\"true\")\n",
         "  let (lo, hi) = fitted.confint()\n"
         "  ignore(lo)\n"
         "  ignore(hi)\n")),

    ("the cross-check document stops naming DoubleMLQTE",
     lambda: patch(
         DOC6,
         "| `pyexample_*` | `DoubleMLAPO`, `DoubleMLDIDMulti`, `DoubleMLQTE` |",
         "| `pyexample_*` | `DoubleMLAPO`, `DoubleMLDIDMulti` |")),

    ("the cross-check document claims 17 estimators are cross-checked",
     lambda: patch(
         DOC6,
         "cross-check all **22** estimators.",
         "cross-check all **17** estimators.")),

    ("the README's upstream-ownership paragraph is reverted",
     lambda: patch(
         README,
         "The `validate_*` family is not exclusively ours, though: **9** of its 24",
         "The `validate_*` family is exclusively ours, and none of its 24")),

    ("pyexample_pq.py disappears, so DoubleMLQTE is no longer cross-checked",
     lambda: os.remove(PQ)),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    grew = n > prev
    print("  %d. %-70s failures %d -> %d  %s"
          % (i, desc[:70], prev, n, "GROW" if grew else "*** FLAT ***"))
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n

# the counter must agree with the verifier's own summary
rc, out, n = verify(WORK)
m = re.search(r"(\d+) checks, (\d+) failed", out)
print()
print("=== the counter and the verifier's own summary ===")
print("  the driver counted %d failures" % n)
print("  the verifier says  %s checks, %s failed" % (m.group(1), m.group(2)))
if not m or int(m.group(2)) != n:
    print("!! the counter and the summary disagree -- ABORT")
    sys.exit(1)
if rc == 0:
    print("!! the broken tree still exits 0 -- ABORT")
    sys.exit(1)

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
