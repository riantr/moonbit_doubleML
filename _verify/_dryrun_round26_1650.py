"""Dry-run the provenance-grouping verifier against a tree whose GROUPING is broken.

WHAT THIS PROVES
=================
`_verify/_verify_provenance_grouping_1650.py` derives the upstream-provenance
grouping from the INSTALLED upstream package and the port's own source, and
then checks that every tracked document which states the grouping states THAT
one.

Round 26 found four false statements, all of the same kind: three tracked
documents (the introduction tutorial, the estimators tutorial, the agent skill)
predate `_verify/UPSTREAM_PROVENANCE.md` -- the record that was first tracked
in v0.164.11 -- and still carried the OLD grouping (20 name-matched, one
renamed, `DoubleMLDIDCrossSection` port-only).  The published README was
already right.

The point of the dry-run is that a document can be wrong in a way that no
number check sees: 19 and 20 are both plausible counts, and the sentence
"and `DoubleMLDIDCrossSection` has no upstream estimator" is a perfectly
well-formed English sentence.  Only a check that knows the RIGHT grouping can
tell.

EACH MECHANISM IS PROVEN ON ITS OWN
====================================
Round 24's dry-run had SIX mechanisms and one of them contributed ZERO
failures -- it patched the wrong slot, so the total was > 0 and the dead
mechanism hid inside a passing run.  So this one applies the mechanisms ONE
AT A TIME and runs the verifier after each, and requires the failure count to
GROW at every step.  A mechanism that contributes nothing is visible as a
flat step, and the driver fails.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the three corrected documents and
the new verifier -- are copied in from the WORKING TREE, and the grouping is
broken on top of that.

Run: python _verify/_dryrun_round26_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r26_mut")
VERIFIER = "_verify/_verify_provenance_grouping_1650.py"

COPY_IN = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "doc/001_introduction/readme.mbt.md",
    "doc/004_estimators/readme.mbt.md",
    "skills/moonbit_doubleML.md",
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
DOC001 = os.path.join(WORK, "doc", "001_introduction", "readme.mbt.md")
DOC004 = os.path.join(WORK, "doc", "004_estimators", "readme.mbt.md")
SKILLS = os.path.join(WORK, "skills", "moonbit_doubleML.md")

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
    ("the introduction tutorial names DIDCrossSection as the port-only one again",
     lambda: patch(
         DOC001,
         "one port-only estimator (`DoubleMLDIDCS`), for 22 in total.",
         "plus one port-only estimator (`DoubleMLDIDCrossSection`),\n"
         "for 22 in total.")),
    ("the introduction tutorial says 20 under the same name again",
     lambda: patch(
         DOC001,
         "0.11.4 -- 19 under the same name,",
         "0.11.4 -- 20 under the same name,")),
    ("the estimators tutorial's grouping goes back to 20 again",
     lambda: patch(
         DOC004,
         "Of the 22, **19** match a class of the same name upstream.",
         "Of the 22, **20** match a class of the same name upstream.")),
    ("the estimators tutorial says DIDCrossSection has no upstream estimator again",
     lambda: patch(
         DOC004,
         "and `DoubleMLDIDCrossSection` is upstream's `DoubleMLDIDCS` -- the",
         "and `DoubleMLDIDCrossSection` has no upstream estimator -- the")),
    ("the estimators tutorial calls the port's DIDCS repeated cross-sections again",
     lambda: patch(
         DOC004,
         "| `DoubleMLDIDCS` | `observational` | DID with staggered adoption "
         "(Callaway-Sant'Anna) | `did_cs.mbt` |",
         "| `DoubleMLDIDCS` | `observational` | DID with repeated cross-sections "
         "(Callaway-Sant'Anna) | `did_cs.mbt` |")),
    ("the agent skill says 20 mirror upstream and DIDCrossSection is port-only again",
     lambda: patch(
         SKILLS,
         "19 mirror upstream `doubleml-for-py`\n  by name; two are upstream's "
         "under another name -- `DoubleMLRDD` is\n  upstream's `RDFlex` and "
         "`DoubleMLDIDCrossSection` is upstream's\n  `DoubleMLDIDCS`; and "
         "`DoubleMLDIDCS` is the one with no 1:1 upstream\n  class",
         "20 mirror upstream `doubleml-for-py`\n  by name; `DoubleMLRDD` is "
         "upstream's `RDFlex` renamed; and\n  `DoubleMLDIDCrossSection` has no "
         "upstream counterpart (port-only).")),
    ("the published README's grouping goes back to 20 again",
     lambda: patch(
         README,
         "**19** match a\nclass of the same name in upstream",
         "**20** match a\nclass of the same name in upstream")),
]

print()
print("=== breaking the grouping, one mechanism at a time ===")
counts = [n0]
transcript = []
for i, (label, apply) in enumerate(MECHANISMS, start=1):
    apply()
    print("  %d. %s" % (i, label))
    rc, out, n = verify(WORK)
    print("     exit=%d  failures=%d  (was %d)" % (rc, n, counts[-1]))
    if n <= counts[-1]:
        print("     !! this mechanism contributed NO failure -- it is a dead control")
    counts.append(n)
    transcript.append((label, rc, out))

# the shipped copy must stay byte-identical, so it gets the same damage
shutil.copy2(README, SHIPPED)

print()
print("=== the fully broken tree ===")
rc, out, final = verify(WORK)
print(out)
print("=== verifier exit code: %d ===" % rc)
print()

exact = len([l for l in out.splitlines() if l.startswith("  *** FAIL ***")])
print("EXACT failure count (check lines carrying the marker): %d" % exact)

m = re.search(r"(\d+) checks, (\d+) failed", out)
if m:
    print("verifier summary: checks=%s failed=%s" % (m.group(1), m.group(2)))
    agree = int(m.group(2)) == exact
    print("the counter agrees with the summary: %s" % agree)
else:
    print("verifier summary: NOT FOUND (the verifier probably crashed)")
    agree = False

# every mechanism must have contributed
grew = all(counts[i + 1] > counts[i] for i in range(len(counts) - 1))
print()
print("failure count after each mechanism: %s" % counts)
print("every mechanism contributed a failure: %s" % grew)

print()
if rc == 0:
    print("VERDICT: *** the dry-run did NOT bite -- the verifier PASSED against "
          "a tree whose grouping was broken ***")
    sys.exit(1)
if not grew:
    print("VERDICT: *** a mechanism contributed no failure -- a dead control ***")
    sys.exit(1)
if not agree:
    print("VERDICT: *** the counter disagrees with the verifier's own summary ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures, every mechanism visible)"
      % exact)

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r26_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
    fh.write("failure count after each mechanism: %s\n" % counts)
print("wrote %s" % LOG)
sys.exit(0)
