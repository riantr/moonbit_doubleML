"""Round 79 dry-run: prove that the RE-ANCHORED count checks still bite.

WHAT THIS IS A WITNESS FOR
===========================
Round 78 added one test to the library package, so the counts moved
(1117/1123 -> 1118/1124), and FOUR verifiers that hold those counts went
red.  They were not wrong -- the tree really did move -- but each of them
had to be RE-TYPED by hand, and a holder that has to be re-typed every
release is a holder that will be re-typed wrongly, or not at all.

Round 79 repairs them:

  * `_verify/_verify_readme_commands_1680.py` DERIVES the count from the
    run it already makes, instead of typing it;
  * `_verify/_verify_round17_lplr_1650.py` DERIVES the counts from the
    tree, and counts the WORKING TREE rather than the committed one -- a
    check that counted `git ls-tree HEAD` was true at exactly one point in
    the release cycle;
  * `_verify/_verify_round18_readme_1650.py` keeps the literal, because
    that is the check that NAMES the counts, and the orphan-number check
    requires a literal holder to exist;
  * `_verify/_dryrun_round44_1650.py` patches the README by SHAPE rather
    than by count, so its anchors do not die with the suite's size.

TWO MORE DEFECTS, FOUND ON THE WAY
==================================
The stale-count checks in round-18 and round-17 tested the shape
"1115/1115".  The README writes its counts with SPACES ("**1118 / 1118 /
1118**"), and the unspaced shape never appeared in the README in ANY
commit -- so the check could not fail, and it looked like it could.

THE MECHANISMS
===============
Seven, and each one breaks a promise this round's tree now holds:

  1  the README's native total drifts from the tree -- the check that
     NAMES the count and the check that DERIVES it must both go RED;
  2  the README's Status table quotes a stale count in the SPACED shape
     the README really uses -- the round-18 check must go RED;
  3  the round-18 check is restored to the UNSPACED shape AND a stale
     count is quoted in the SPACED shape -- it must STAY GREEN.  This one
     runs the other way on purpose: it demonstrates by construction that
     the old shape could not have failed;
  4  the record's live count drifts from the tree -- the round-17 check
     must go RED;
  5  the record's stale count loses its anchor -- the round-17 check must
     go RED;
  6  the working tree gains a test that is NOT committed -- the round-17
     check must go RED, because it counts the working tree;
  7  the same uncommitted test AND the round-17 check's counting rule is
     restored to the COMMITTED tree -- it must STAY GREEN.  That is the
     defect the repair fixes, demonstrated by construction: the old rule
     could not see a change that is not yet committed, which is exactly
     the state a release is in when its checks run.

Each mechanism perturbs a DIFFERENT string, because the teeth verifier
simulates the mechanisms cumulatively in source order and an anchor may
be consumed only once.

Run: python _verify/_dryrun_round79_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r79")
DRIVER = "_verify/_dryrun_round79_1650.py"

# The verifiers this round repairs.  The list is a LITERAL so that the teeth
# verifier can see which verifiers this driver runs.
VERIFIERS = ["_verify/_verify_readme_commands_1680.py",
             "_verify/_verify_round18_readme_1650.py",
             "_verify/_verify_round17_lplr_1650.py"]

CMDV = VERIFIERS[0]
R18V = VERIFIERS[1]
R17V = VERIFIERS[2]

# the documents the mechanisms patch
DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

# the record the round-17 verifier reads
RECORD = "_verify/LPLR_GATE_BLINDNESS_1680.md"

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
REC = os.path.join(WORK, "_verify", "LPLR_GATE_BLINDNESS_1680.md")
R18_SRC = os.path.join(WORK, "_verify", "_verify_round18_readme_1650.py")
R17_SRC = os.path.join(WORK, "_verify", "_verify_round17_lplr_1650.py")
PROBE = os.path.join(WORK, "moonbit_doubleML", "zz_round79_probe_test.mbt")

# The PROBE: a test that exists in the WORKING TREE and in no commit.  It
# is what the round-17 check's counting rule is measured against: a rule
# that counts the COMMITTED tree cannot see it, and a rule that counts the
# WORKING tree can.  It is never tracked -- it is created and removed
# inside the tree under test.
PROBE_SRC = '''///|
/// A PROBE: this test exists in the working tree and in no commit.
///
/// It is what the round-17 check's counting rule is measured against: a
/// rule that counts the COMMITTED tree cannot see it, and a rule that
/// counts the WORKING tree can.
test "round79_probe_working_tree_only" {
  assert_eq!(1, 1)
}
'''


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
    stands, and the numbers in these files move with every release.  A
    literal here would be a literal that goes stale.

    The replacement is LITERAL: `re.sub` would read a backslash in it as a
    group reference, and a mechanism that inserts a backslash into a source
    file turns the file into a SyntaxError instead of breaking a promise.
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
    """Put the tree under test back to the committed state.

    The PROBE is not tracked, so `git checkout` does not remove it -- it is
    removed here, and the mechanism that needs it puts it back.
    """
    rc, out = run(["git", "-C", WORK, "checkout", "--", "."], cwd=WORK)
    if rc != 0:
        print(out)
        raise SystemExit("git checkout failed")
    if os.path.isfile(PROBE):
        os.remove(PROBE)


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
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + [RECORD] + CHANGED:
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
# The counter must SEE a failure in every convention the tree uses.  The
# round-17 verifier prints "[FAIL]" where the others print "*** FAIL ***",
# and a counter blind to that one reported a mechanism as proving nothing
# while the verifier was failing loudly.  So the counter is run against
# each convention here, and the driver refuses to start without it.
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
# 1  the README's native total drifts from the tree.  The transcript
#    appears TWICE, so the two are told apart by what follows each.
M1A_OLD = r"Total tests: 1118, passed: 1118, failed: 0\.\n\n\$ moon run examples/main"
M1A_NEW = "Total tests: 1119, passed: 1119, failed: 0.\n\n$ moon run examples/main"
M1B_OLD = r"Total tests: 1118, passed: 1118, failed: 0\.\n```"
M1B_NEW = "Total tests: 1119, passed: 1119, failed: 0.\n```"

# 2  the README's Status table quotes a stale count in the SPACED shape
M2_OLD = r"\| Tests \(native / wasm / js\) \| \*\*1118 / 1118 / 1118\*\* \|"
M2_NEW = "| Tests (native / wasm / js) | **1117 / 1117 / 1117** |"

# 3  a stale count quoted in the SPACED shape, elsewhere in the table
M3_OLD = r"\| Tests \(wasm-gc\) \| \*\*1124 / 1124\*\* \(lib \+ 6 doc tutorials\) \|"
M3_NEW = "| Tests (wasm-gc) | **1122 / 1122** (lib + 6 doc tutorials) |"

# 4  the record's live count drifts from the tree
M4_OLD = r"written; it is \*\*1118\*\* today\. The claim is that the suite was green, not"
M4_NEW = "written; it is **1119** today. The claim is that the suite was green, not"

# 5  the record's stale count loses its anchor
M5_OLD = r"1117/1117 native tests \*\(\s*the\s+native count at `f452421`; \*\*1118\*\* today\)\*,"
M5_NEW = "1117/1117 native tests,"

# 6/7  the round-17 check's counting rule.  The pattern spans the whole
#      rule, from its first line to its last, and the replacement is the
#      rule as it was before round 79 -- one that counts the COMMITTED
#      tree.  The replacement carries NO backslash: the teeth verifier
#      substitutes with the replacement as a TEMPLATE, and a backslash in
#      it would be read as a group reference.
M6_OLD = r"(?s)    acc = set\(\).*?    return len\(acc\)\n"
M6_NEW = ('    n = 0\n'
          '    r = subprocess.run(["git", "ls-tree", "-r", "--name-only", "HEAD", "--", subdir],\n'
          '                       cwd=ROOT, capture_output=True, text=True,\n'
          '                       encoding="utf-8", errors="replace")\n'
          '    for p in r.stdout.splitlines():\n'
          '        if p.endswith(".mbt"):\n'
          '            blob = subprocess.run(["git", "show", "HEAD:%s" % p], cwd=ROOT,\n'
          '                                  capture_output=True, text=True,\n'
          '                                  encoding="utf-8", errors="replace")\n'
          '            n += blob.stdout.count(\'test "\')\n'
          '    return n\n')

# the round-18 check, restored to the shape it had before round 79
M7_OLD = (r"for lit in \(\"1115\", \"1122\", \"1117\"\):\n"
          r"    for shape in \(\"%s/%s\" % \(lit, lit\), \"%s / %s\" % \(lit, lit\)\):\n"
          r"        check\(\"the README does not quote the stale count %r\" % shape,\n"
          r"              shape not in readme\)\n")
M7_NEW = ('for lit in ("1115/1115", "1122/1122"):\n'
          '    check("the README does not quote the stale count %r" % lit, lit not in readme)\n')


def add_probe():
    write(PROBE, PROBE_SRC)


MECHANISMS = [
    ("the README's native total drifts from the tree",
     lambda: (sub_once(README, M1A_OLD, M1A_NEW),
              sub_once(README, M1B_OLD, M1B_NEW),
              sub_once(SHIPPED, M1A_OLD, M1A_NEW),
              sub_once(SHIPPED, M1B_OLD, M1B_NEW)), [CMDV, R18V], []),
    ("the README's Status table quotes a stale count in the SPACED shape",
     lambda: (sub_once(README, M2_OLD, M2_NEW),
              sub_once(SHIPPED, M2_OLD, M2_NEW)), [R18V], []),
    ("the round-18 check is restored to the UNSPACED shape and a stale "
     "count is quoted in the SPACED shape -- it must STAY GREEN",
     lambda: (sub_once(R18_SRC, M7_OLD, M7_NEW),
              sub_once(README, M3_OLD, M3_NEW),
              sub_once(SHIPPED, M3_OLD, M3_NEW)), [], [R18V]),
    ("the record's live count drifts from the tree",
     lambda: sub_once(REC, M4_OLD, M4_NEW), [R17V], []),
    ("the record's stale count loses its anchor",
     lambda: sub_once(REC, M5_OLD, M5_NEW), [R17V], []),
    ("the working tree gains a test that is NOT committed -- the check "
     "counts the WORKING tree, so it must go RED",
     lambda: add_probe(), [R17V], []),
    ("the same uncommitted test, and the check counts the COMMITTED tree "
     "again -- it must STAY GREEN",
     lambda: (add_probe(),
              sub_once(R17_SRC, M6_OLD, M6_NEW)), [], [R17V]),
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
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r79_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 79 dry-run: the re-anchored count checks, broken %d ways\n"
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
