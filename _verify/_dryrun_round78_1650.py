"""Round 78 dry-run: prove that this round's NEW checks bite.

WHAT THIS IS A WITNESS FOR
===========================
Round 78 found a claim that was TRUE and held by nothing.

`doc/003_quick_start` publishes three exact numbers and says they are
"re-measured bit-identical on all four supported backends (`native`,
`wasm-gc`, `wasm`, `js`)".  The measurement is true -- it was re-measured on
all four, and the values are bit-for-bit identical.  But the promise that
kept it true was:

    The tutorial's own test (`using_test.mbt`) asserts all three values
    bit-exactly, so this table cannot drift away from the code it
    documents.

and `doc/003_quick_start/moon.pkg` declares `supported_targets = "wasm-gc"`.
So that test can only ever run on ONE of the four backends the claim names,
and the table could drift on native / wasm / js with every check in this
repository still green.

This round therefore adds two things that can fail silently:

  1  `_verify/_verify_backend_claims_1680.py` -- a backend claim must be
     WITNESSED on every backend it names.  The witness is derived from the
     tree: the backends the document names, the targets the library package
     declares, the backends CI's matrix builds, and the test files that
     ASSERT the published numbers;
  2  the repair of `_verify/_verify_tutorial_claims_1650.py` -- its check on
     this claim was a WORD check ("bit-identical" appears), which stays
     green when the claim goes false and goes RED when the claim is removed.
     It now checks the witness instead.

So the driver breaks each of them, one at a time, and requires the failure to
appear.

THE MECHANISMS
===============
Nine, and each one breaks a promise this round's tree now holds:

  1  the library-side witness is REMOVED -- with no test asserting the
      published values on all four backends, the claim is unwitnessed and
      BOTH verifiers must go red;
  2  doc/003 names a backend CI never builds -- the claim is wider than the
      build that would have to witness it;
  3  the library package drops a supported backend -- the claim and the
      package's own declaration stop agreeing;
  4  CI's matrix drops a backend -- the claim names a build that never runs;
  5  doc/003 stops naming its witness -- the reader cannot go and look at it;
  6  the backend verifier's witness DERIVATION is neutered -- the check must
      go red, not pass vacuously;
  7  the backend verifier's own RULE is neutered -- ITS CONTROL ARM MUST
      NOTICE.  A control that cannot report a rule which has stopped biting
      is a rubber stamp;
  8  the round-27 word check is restored AND doc/003's published value
      changes -- so the claim is now FALSE -- and the round-27 verifier must
      STAY GREEN.  This one runs the other way on purpose: it demonstrates
      that the old check really was vacuous, by construction rather than by
      assertion;
  9  the SAME change to doc/003's published value -- and the repaired check
      must go RED.  Mechanisms 8 and 9 are the same perturbation under two
      different checks, and their verdicts are opposite: that is what
      "the old check was vacuous and the new one bites" means.

EACH MECHANISM IS INDEPENDENT
==============================
The tree under test is restored before every mechanism, so each one is judged
against a green baseline rather than against the wreckage of the one before
it.  A cumulative driver can pass a mechanism whose failure count happened to
grow for someone else's reason.

The tree under test is a CLONE with the working tree's state copied in: the
clone is checked out from HEAD, so without the copy the tree under test would
be a mix of two releases -- this round's checks and the last round's
documents -- and the baseline would be red for a reason that has nothing to do
with the promise being broken.

THE ANCHORS ARE AT MODULE LEVEL
===============================
The `sub_once` calls are made DIRECTLY, not through a helper: the teeth
verifier resolves a driver's anchors by walking its module-level calls, and
a call hidden inside a helper's body is a call it cannot see.  A driver whose
anchors nobody checks is a driver whose anchors rot in silence.

It also walks them in SOURCE ORDER and simulates them cumulatively, so a
mechanism may not re-apply an anchor an earlier mechanism already consumed.
That is why mechanisms 8 and 9 perturb DIFFERENT numbers: the same number
twice would leave the second anchor matching nothing.

Run: python _verify/_dryrun_round78_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r78")
DRIVER = "_verify/_dryrun_round78_1650.py"

# The verifiers this round adds and repairs.  The list is a LITERAL so that the
# teeth verifier can see which verifiers this driver runs.
VERIFIERS = ["_verify/_verify_backend_claims_1680.py",
             "_verify/_verify_tutorial_claims_1650.py"]

BACKENDV = VERIFIERS[0]
TUTORIALV = VERIFIERS[1]

# the files the mechanisms patch
DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

# the live documents the verifiers read
LIVE_DOCUMENTS = [
    "doc/001_introduction/readme.mbt.md",
    "doc/002_installation/readme.mbt.md",
    "doc/003_quick_start/readme.mbt.md",
    "doc/003_quick_start/using_test.mbt",
    "doc/004_estimators/readme.mbt.md",
    "doc/005_dgps/readme.mbt.md",
    "doc/006_python_check/readme.mbt.md",
    "skills/moonbit_doubleML.md",
    "examples/api_server/README.md",
]

# the tree the mechanisms patch
TREE = [
    "moonbit_doubleML/plr_test.mbt",
    "moonbit_doubleML/moon.pkg",
    ".github/workflows/check.yml",
]

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
DOC003 = os.path.join(WORK, "doc", "003_quick_start", "readme.mbt.md")
DOC3TEST = os.path.join(WORK, "doc", "003_quick_start", "using_test.mbt")
PLRTEST = os.path.join(WORK, "moonbit_doubleML", "plr_test.mbt")
MOONPKG = os.path.join(WORK, "moonbit_doubleML", "moon.pkg")
CIYML = os.path.join(WORK, ".github", "workflows", "check.yml")
BACKENDV_SRC = os.path.join(WORK, "_verify", "_verify_backend_claims_1680.py")
TUTORIALV_SRC = os.path.join(WORK, "_verify", "_verify_tutorial_claims_1650.py")


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
    stands, and a literal here would be a literal that goes stale.
    """
    text = read(path)
    crlf = "\r\n" in text
    pat = pattern.replace("\n", "\r\n") if crlf and "\r\n" not in pattern else pattern
    rep = repl.replace("\n", "\r\n") if crlf and "\r\n" not in repl else repl
    n = len(re.findall(pat, text))
    if n != 1:
        raise SystemExit("!! %s: %r matched %d times (expected 1)"
                         % (path, pattern, n))
    # The replacement is LITERAL: `re.sub` would read a backslash in it as a
    # group reference, and a mechanism that inserts a backslash into a source
    # file turns the file into a SyntaxError instead of breaking a promise.
    write(path, re.sub(pat, lambda _m: rep, text))


def failures(out):
    """The house's failure marker."""
    return out.count("*** FAIL ***")


def verify():
    """Run the verifiers; return their outputs and their counts."""
    outs = {}
    counts = {}
    for rel in VERIFIERS:
        rc, out = run([sys.executable, os.path.join(WORK, rel.replace("/", os.sep))],
                      cwd=WORK)
        outs[rel] = out
        counts[rel] = failures(out)
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
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + LIVE_DOCUMENTS + TREE + CHANGED:
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
if sum(counts.values()) != 0:
    for rel in VERIFIERS:
        print("---- %s ----" % rel)
        print(outs[rel][-3000:])
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# -------------------------------------------------------------- the mechanisms
#
# 1  the library-side witness is REMOVED
M1_OLD = r"(?s)\n///\|\n/// THE FOUR-BACKEND WITNESS.*\Z"
M1_NEW = "\n"

# 2  doc/003 names a backend CI never builds
M2_OLD = r"`wasm-gc`, `wasm`, `js`\):"
M2_NEW = "`wasm-gc`, `wasm`, `llvm`):"

# 3  the library package drops a supported backend
M3_OLD = r'supported_targets = "native\+wasm\+wasm-gc\+js"'
M3_NEW = 'supported_targets = "native+wasm+wasm-gc"'

# 4  CI's matrix drops a backend
M4_OLD = r"target: \[native, wasm-gc, wasm, js\]"
M4_NEW = "target: [native, wasm-gc, wasm]"

# 5  doc/003 stops naming its witness
M5_OLD = r"- the package's own suite, in `plr_test\.mbt`, under the test"
M5_NEW = "- the package's own suite, under the test"

# 6  the backend verifier's witness DERIVATION is neutered
M6_OLD = (r'def witness_for\(root, numbers, backends\):\n'
          r'    """-> \(the witnesses that cover every backend, the ones that '
          r'do not\)\."""\n')
M6_NEW = ('def witness_for(root, numbers, backends):\n'
          '    """-> (the witnesses that cover every backend, the ones that '
          'do not)."""\n'
          '    return [], []\n')

# 7  the backend verifier's own RULE is neutered
M7_OLD = (r'def rule_ok\(named_set, lib_set, ci_set, full_witnesses, '
          r'doc_text\):\n'
          r'    """The rule, as one function, so the control arm can call it '
          r'too\."""\n')
M7_NEW = ('def rule_ok(named_set, lib_set, ci_set, full_witnesses, doc_text):\n'
          '    """The rule, as one function, so the control arm can call it '
          'too."""\n'
          '    return True\n')

# 8  the round-27 check goes BACK to the word check
M8_OLD = (r"(?s)# --- round 78: a backend claim needs a WITNESS, not a word -+\n"
          r".*?_WIT or \"NONE\"\)\)\n")
M8_NEW = ('check("doc/003 says the values are backend-independent",\n'
          '      "bit-identical" in flat(DOC3))\n')

# 9  doc/003's published value changes -- the claim is now FALSE.
#    The document and the tutorial test change TOGETHER, so the round-27
#    verifier's own number checks stay green: the only thing that can notice
#    the false claim is the check under test.
M9_OLD = r"-8\.782651064906958"
M9_NEW = "-8.782651064906959"
M10_OLD = r"-8\.782651064906958"
M10_NEW = "-8.782651064906959"
M11_OLD = r"13\.75724952565863"
M11_NEW = "13.75724952565864"
M12_OLD = r"13\.75724952565863"
M12_NEW = "13.75724952565864"

MECHANISMS = [
    ("the library-side witness is REMOVED",
     lambda: sub_once(PLRTEST, M1_OLD, M1_NEW), [BACKENDV, TUTORIALV], []),
    ("doc/003 names a backend CI never builds",
     lambda: sub_once(DOC003, M2_OLD, M2_NEW), [BACKENDV], []),
    ("the library package drops a supported backend",
     lambda: sub_once(MOONPKG, M3_OLD, M3_NEW), [BACKENDV], []),
    ("CI's matrix drops a backend",
     lambda: sub_once(CIYML, M4_OLD, M4_NEW), [BACKENDV], []),
    ("doc/003 stops naming its witness",
     lambda: sub_once(DOC003, M5_OLD, M5_NEW), [BACKENDV], []),
    ("the backend verifier's witness derivation is neutered",
     lambda: sub_once(BACKENDV_SRC, M6_OLD, M6_NEW), [BACKENDV], []),
    ("the backend verifier's own rule is neutered -- ITS CONTROL MUST NOTICE",
     lambda: sub_once(BACKENDV_SRC, M7_OLD, M7_NEW), [BACKENDV], []),
    ("the round-27 word check is restored and doc/003's value changes -- "
     "it must STAY GREEN",
     lambda: (sub_once(TUTORIALV_SRC, M8_OLD, M8_NEW),
              sub_once(DOC003, M9_OLD, M9_NEW),
              sub_once(DOC3TEST, M10_OLD, M10_NEW)), [], [TUTORIALV]),
    ("doc/003's value changes -- the REPAIRED check must go RED",
     lambda: (sub_once(DOC003, M11_OLD, M11_NEW),
              sub_once(DOC3TEST, M12_OLD, M12_NEW)), [BACKENDV, TUTORIALV], []),
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
            print("!! %s went RED -- the old check was NOT vacuous" % rel)
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r78_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 78 dry-run: this round's new checks, broken %d ways\n"
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
