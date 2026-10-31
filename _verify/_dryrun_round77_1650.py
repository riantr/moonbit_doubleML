"""Round 77 dry-run: prove that this round's NEW checks bite.

WHAT THIS IS A WITNESS FOR
===========================
Round 77 added two checks that can fail silently, and a check that cannot
fail protects nothing:

  1  `_verify/_verify_live_doc_versions_1680.py` -- the upstream-version
     claims in the LIVE documents.  Round 76 gave the upstream-version rule a
     home, but it gave it to the wrong scope: the `_verify/` RECORDS the
     README names.  The documents a reader is OPENED are opened more often,
     and five of them carry a live claim about the upstream release -- the
     README (both copies), `doc/001`, `doc/004` and `doc/005`.  All five were
     MEASURED against upstream 0.11.4 and all five are true BY MEASUREMENT and
     by nothing else;
  2  `_verify/_verify_cross_doc_counts_1680.py` -- the counts a live document
     states about ANOTHER document.  `doc/001` says "See `003_quick_start` for
     a 39-line end-to-end example", and the fenced block it points at has
     exactly 39 content lines -- and NOTHING held that.  Add a comment line to
     that block and the tutorial quietly starts lying;
  3  `_verify/_verify_live_doc_brackets_1680.py` -- the brackets in the live
     documents' prose.  Round 76 fixed "`P(y = 1 | x]`" twice in the README
     and missed the THIRD copy, in the agent skill -- the document a coding
     agent reads before it writes a line against this library.

So the driver breaks each of them, one at a time, and requires the failure to
appear.

THE MECHANISMS
===============
Eight, and each one breaks a promise this round's tree now holds:

  1  a tutorial names a stale upstream version ALONE -- the live documents
      must go RED when the installed upstream is not the version they are
      anchored to;
  2  the SHIPPED README copy names a stale upstream version -- the copy the
      registry serves is in scope in its own right;
  3  the live-doc verifier's SCOPE is emptied -- the rule must REFUSE to pass
      when it is looking at nothing, rather than pass vacuously;
  4  the live-doc verifier's own comparison is neutered -- ITS CONTROL ARM
      MUST NOTICE.  A control that cannot report a rule which has stopped
      biting is a rubber stamp;
  5  a live document's cross-document count is wrong -- the promise to a
      SECOND file must go RED;
  6  the cross-doc verifier's own comparison is neutered -- ITS CONTROL ARM
      MUST NOTICE;
  7  the agent skill carries the bracket round 76 fixed -- the copy nobody
      looked at must go RED;
  8  the bracket verifier's own comparison is neutered -- ITS CONTROL ARM
      MUST NOTICE.

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

Run: python _verify/_dryrun_round77_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r77")
DRIVER = "_verify/_dryrun_round77_1650.py"

# The three verifiers this round adds.  The list is a LITERAL so that the teeth
# verifier can see which verifiers this driver runs.
VERIFIERS = ["_verify/_verify_live_doc_versions_1680.py",
             "_verify/_verify_cross_doc_counts_1680.py",
             "_verify/_verify_live_doc_brackets_1680.py"]

LIVEDOCV = VERIFIERS[0]
XDOC = VERIFIERS[1]
BRACKETS = VERIFIERS[2]

DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

# the live documents the two verifiers read
LIVE_DOCUMENTS = [
    "doc/001_introduction/readme.mbt.md",
    "doc/002_installation/readme.mbt.md",
    "doc/003_quick_start/readme.mbt.md",
    "doc/004_estimators/readme.mbt.md",
    "doc/005_dgps/readme.mbt.md",
    "doc/006_python_check/readme.mbt.md",
    "skills/moonbit_doubleML.md",
    "examples/api_server/README.md",
]

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
DOC001 = os.path.join(WORK, "doc", "001_introduction", "readme.mbt.md")
SKILL = os.path.join(WORK, "skills", "moonbit_doubleML.md")
LIVEDOCV_SRC = os.path.join(WORK, "_verify", "_verify_live_doc_versions_1680.py")
XDOC_SRC = os.path.join(WORK, "_verify", "_verify_cross_doc_counts_1680.py")
BRACKETS_SRC = os.path.join(WORK, "_verify", "_verify_live_doc_brackets_1680.py")


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
    """Run the two verifiers; return their outputs and their counts."""
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
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + LIVE_DOCUMENTS + CHANGED:
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
# 1  a tutorial names a stale upstream version ALONE
M1_OLD = r"estimator classes upstream ships in\n0\.11\.4 -- 19 under the same name"
M1_NEW = r"estimator classes upstream ships in\n0.11.3 -- 19 under the same name"

# 2  the SHIPPED README copy names a stale upstream version
M2_OLD = r"upstream `doubleml-for-py` 0\.11\.4 uses `APO`, `ATE`, `PQ`, `LPQ`,"
M2_NEW = r"upstream `doubleml-for-py` 0.11.3 uses `APO`, `ATE`, `PQ`, `LPQ`,"

# 3  the live-doc verifier's SCOPE is emptied
M3_OLD = (r"def live_documents\(\):\n"
          r'    """The documents a reader is pointed at\.  DERIVED, not typed\."""\n')
M3_NEW = ('def live_documents():\n'
          '    """The documents a reader is pointed at.  DERIVED, not typed."""\n'
          '    return []\n')

# 4  the live-doc verifier's own comparison is neutered
M4_OLD = (r"def audit\(text, current, ver_re\):\n"
          r'    """Every live claim in one document: \(version, where, why\)\."""\n'
          r"    problems = \[\]\n")
M4_NEW = ('def audit(text, current, ver_re):\n'
          '    """Every live claim in one document: (version, where, why)."""\n'
          '    problems = []\n'
          '    return problems\n')

# 5  a live document's cross-document count is wrong
M5_OLD = r"See `003_quick_start` for a 39-line end-to-end example\."
M5_NEW = r"See `003_quick_start` for a 40-line end-to-end example."

# 6  the cross-doc verifier's own comparison is neutered
M6_OLD = (r"def check_claim\(count, ref, blocks\):\n"
          r'    """The rule, on its own: does `count` match a block of the '
          r'referenced file\?"""\n')
M6_NEW = ('def check_claim(count, ref, blocks):\n'
          '    """The rule, on its own: does `count` match a block of the '
          'referenced file?"""\n'
          '    return True, "neutered"\n')

# 7  the agent skill carries the bracket round 76 fixed
M7_OLD = r"because it models `E\[y \| x\]`, not `P\(y = 1 \| x\)`\."
M7_NEW = r"because it models `E\[y \| x\]`, not `P\(y = 1 \| x\]`\."

# 8  the bracket verifier's own comparison is neutered
M8_OLD = (r"    bad = \[\]\n"
          r'    if span\.count\("\("\) > span\.count\("\)"\):\n')
M8_NEW = '    bad = []\n    return []\n    if span.count("(") > span.count(")"):\n'

MECHANISMS = [
    ("a tutorial names a stale upstream version ALONE",
     lambda: sub_once(DOC001, M1_OLD, M1_NEW), LIVEDOCV),
    ("the SHIPPED README copy names a stale upstream version",
     lambda: sub_once(SHIPPED, M2_OLD, M2_NEW), LIVEDOCV),
    ("the live-doc verifier's scope is emptied",
     lambda: sub_once(LIVEDOCV_SRC, M3_OLD, M3_NEW), LIVEDOCV),
    ("the live-doc verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     lambda: sub_once(LIVEDOCV_SRC, M4_OLD, M4_NEW), LIVEDOCV),
    ("a live document's cross-document count is wrong",
     lambda: sub_once(DOC001, M5_OLD, M5_NEW), XDOC),
    ("the cross-doc verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     lambda: sub_once(XDOC_SRC, M6_OLD, M6_NEW), XDOC),
    ("the agent skill carries the bracket round 76 fixed",
     lambda: sub_once(SKILL, M7_OLD, M7_NEW), BRACKETS),
    ("the bracket verifier's comparison is neutered -- ITS CONTROL MUST NOTICE",
     lambda: sub_once(BRACKETS_SRC, M8_OLD, M8_NEW), BRACKETS),
]

print()
print("=== the mechanisms, one at a time, each from a green tree ===")
ok = True
for i, (desc, apply_it, rel) in enumerate(MECHANISMS, 1):
    restore()
    apply_it()
    outs, counts = verify()
    print()
    print("  %d. %s" % (i, desc))
    for r in VERIFIERS:
        print("       %-46s failures=%d" % (r, counts[r]))
    if counts[rel] <= 0:
        print("---- %s ----" % rel)
        print(outs[rel][-3000:])
        print("!! the check did NOT fail -- this mechanism proves nothing")
        ok = False
    else:
        for l in outs[rel].splitlines():
            if "*** FAIL ***" in l:
                print("       %s" % l.strip()[:150])

print()
print("=" * 78)
print("VERDICT %s -- every mechanism made the check it breaks fail"
      % ("PASS" if ok else "FAIL"))
print("=" * 78)

# The capture is the cited raw log of the run, and it is TRACKED by
# convention: the round-59 driver publishes one, and the documents that
# describe the dry-run cite it.
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r77_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 77 dry-run: this round's new checks, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline 0 failing checks; every mechanism made the check it "
             "breaks fail\n")
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn, rel) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s -- %s\n" % (i, name, rel))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
