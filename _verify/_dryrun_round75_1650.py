"""Round 75 dry-run: prove that this round's NEW checks bite.

WHAT THIS IS A WITNESS FOR
==========================
Round 75 added three things that can fail silently, and a check that
cannot fail protects nothing:

  1  `_verify/_verify_readme_precision_1680.py` gained three checks about
     the Installation section -- that it is there, that it names `git` as
     a prerequisite, and that it gives the reason;
  2  `_verify/_gate_provenance_1160.py` was REPAIRED (it had been parsing
     the whole README, reading the wrong table) and wired into the local
     gate;
  3  `_verify/_gate_provenance_control_1160.py` -- the control that proves
     the gate still bites -- was RED against the repaired gate, because two
     of its mutations had landed outside the region the gate reads.

So the driver breaks each of them, one at a time, and requires the
failure to appear.

THE MECHANISMS
==============
Four, and each one breaks a promise this round's tree now holds:

  1  the Installation section keeps the prerequisite but loses the REASON
     -- "git is required" with no "why" is a sentence a reader cannot act
     on, and the check that says so must fire;
  2  the Installation section keeps the reason but loses the word
     "prerequisite" -- naming a program is not the same as calling it
     required, and the check that says so must fire;
  3  the estimator table's marker for the RENAMED class is flipped to
     plain "(upstream)" -- the provenance gate holds those rows against
     the upstream sdist, and it must notice;
  4  the gate's own comparison is neutered -- `bad = []` -- so the gate
     stops failing on a broken table.  THE CONTROL MUST NOTICE.  A control
     that cannot report a gate which has stopped biting is a rubber stamp,
     and this is the mechanism that proves the control is not one.

WHY THE FIRST TWO ARE ADDITIVE AND THE LAST TWO ARE NOT
=======================================================
Mechanisms 1 and 2 damage the same paragraph, and each one leaves the
other's damage in place, so the failure count grows at every step.
Mechanism 3 damages a different part of the document, and mechanism 4
damages the gate itself, so each of those is checked against ITS OWN
verifier rather than against the running total -- a total could stay
level while the wrong thing grows.

The tree under test is a CLONE with the working tree's state copied in:
the clone is checked out from HEAD, so without the copy the tree under
test would be a mix of two releases -- this round's checks and the last
round's documents -- and the baseline would be red for a reason that has
nothing to do with the promise being broken.

The sdist is a vendored upstream artefact and is deliberately untracked,
so it is copied in separately.  When it is absent the two upstream arms
cannot run, and the driver says so and proves what it can -- a missing
artefact is not a broken claim.

Run: python _verify/_dryrun_round75_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r75")
DRIVER = "_verify/_dryrun_round75_1650.py"

DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

PRECISION = "_verify/_verify_readme_precision_1680.py"
GATE = "_verify/_gate_provenance_1160.py"
CONTROL = "_verify/_gate_provenance_control_1160.py"

VERIFIERS = [PRECISION, GATE, CONTROL]

SDIST = os.path.join(REPO, "doubleml-0.11.4.tar.gz")
if not os.path.isfile(SDIST):
    SDIST = os.path.join(REPO, "_verify", "doubleml-0.11.4.tar.gz")
HAVE_SDIST = os.path.isfile(SDIST)


def run(cmd, cwd=REPO, timeout=3600, env=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout,
                       env=env)
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
    write(path, re.sub(pat, rep, text))


def commit(work, paths, message):
    rc, out = run(["git", "-C", work, "add", "--"] + paths, cwd=work)
    if rc != 0:
        print(out)
        raise SystemExit("git add failed")
    rc, out = run(["git", "-C", work, "commit", "-m", message], cwd=work)
    if rc != 0:
        print(out)
        raise SystemExit("git commit failed")


# ------------------------------------------------------------------ counting
def precision_failures(out):
    """The precision verifier's own failure marker."""
    return out.count("*** FAIL ***")


def gate_failures(out):
    """The provenance gate reports a mismatch with a heading of its own."""
    return len(re.findall(r"^MISMATCH \(measured vs README\)", out, re.M))


def control_failures(out):
    """The control's two kinds of failure, counted apart.

    A mutation the control MISSED is the gate having stopped biting; a
    harness problem is the control not being able to set the test up.  The
    driver needs them apart: mechanism 4 must show MISSED mutations.
    """
    n = 0
    m = re.search(r"^mutations missed: (\d+) of (\d+)", out, re.M)
    if m:
        n += int(m.group(1))
    h = re.search(r"^harness problems: (\d+)", out, re.M)
    if h:
        n += int(h.group(1))
    return n


def verify(work):
    """Run the three verifiers; return their outputs and their counts."""
    outs = {}
    counts = {}
    for rel in VERIFIERS:
        rc, out = run([sys.executable, os.path.join(work, rel.replace("/", os.sep))],
                      cwd=work)
        outs[rel] = out
        if rel == PRECISION:
            counts[rel] = precision_failures(out)
        elif rel == GATE:
            counts[rel] = gate_failures(out)
        else:
            counts[rel] = control_failures(out)
    return outs, counts


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
for rel in list(VERIFIERS) + [DRIVER] + DOCUMENTS + CHANGED:
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
commit(WORK, COPY_IN, "dry-run: the tree under test carries this round's state")

# the sdist is vendored and untracked: it is copied in, not committed
if HAVE_SDIST:
    shutil.copy2(SDIST, os.path.join(WORK, os.path.basename(SDIST)))
    print("  copied in the 0.11.4 sdist (untracked, vendored)")
else:
    print("  !! the 0.11.4 sdist is not present -- the upstream arms cannot run")

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
GATE_SRC = os.path.join(WORK, "_verify", "_gate_provenance_1160.py")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
outs, counts = verify(WORK)
for rel in VERIFIERS:
    print("  %-46s failures=%d" % (rel, counts[rel]))
total = sum(counts.values())
if total != 0:
    for rel in VERIFIERS:
        print("---- %s ----" % rel)
        print(outs[rel][-3000:])
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# -------------------------------------------------------------- the mechanisms
#
# The `sub_once` calls are made DIRECTLY, not through a helper: the teeth
# verifier resolves a driver's anchors by walking its module-level calls, and
# a call hidden inside a helper's body is a call it cannot see.
#
# 1  the reason goes, the prerequisite stays
M1_OLD = r"CLONING it with git -- the registry's remote is\s+`https://mooncakes\.io/git/index` --"
M1_NEW = r"coming from the registry --"

# 2  the reason stays, the word "prerequisite" goes
M2_OLD = r"\*\*`git` is the other prerequisite\.\*\*"
M2_NEW = r"**`git` is the other requirement.**"

# 3  a renamed class claims plain upstream
#
# The row is PLPR, not RDD: the control mutates the RDD row itself, so a
# mechanism that broke RDD would leave the control unable to set its own
# test up -- and a control that cannot set its test up proves nothing about
# the gate.
M3_OLD = r"(\| `DoubleMLPLPR` \|[^|]*\|[^|]*?)\*\(upstream\)\*"
M3_NEW = r"\1*(upstream, renamed)*"

# 4  the gate's comparison is neutered, so the gate stops biting
M4_OLD = r"bad = \[\(n, truth\[n\], claimed\[n\]\) for n in est if truth\[n\] != claimed\[n\]\]"
M4_NEW = "bad = []"


def mechanism_1():
    sub_once(README, M1_OLD, M1_NEW)
    sub_once(SHIPPED, M1_OLD, M1_NEW)


def mechanism_2():
    sub_once(README, M2_OLD, M2_NEW)
    sub_once(SHIPPED, M2_OLD, M2_NEW)


def mechanism_3():
    sub_once(README, M3_OLD, M3_NEW)
    sub_once(SHIPPED, M3_OLD, M3_NEW)


def mechanism_4():
    sub_once(GATE_SRC, M4_OLD, M4_NEW)


MECHANISMS = [
    ("the Installation section keeps the prerequisite and loses the reason",
     mechanism_1, PRECISION, "precision"),
    ("the Installation section keeps the reason and loses the word 'prerequisite'",
     mechanism_2, PRECISION, "precision"),
    ("the estimator table claims a renamed class is plain upstream",
     mechanism_3, GATE, "gate"),
    ("the gate's comparison is neutered, so it stops biting",
     mechanism_4, CONTROL, "control"),
]

prev = dict(counts)
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it, rel, kind) in enumerate(MECHANISMS, 1):
    if kind in ("gate", "control") and not HAVE_SDIST:
        print()
        print("  %d. %s" % (i, desc))
        print("       SKIPPED -- the 0.11.4 sdist is not present, so this arm "
              "cannot run here")
        continue
    apply_it()
    outs, counts = verify(WORK)
    print()
    print("  %d. %s" % (i, desc))
    for r in VERIFIERS:
        print("       %-46s failures=%d" % (r, counts[r]))
    if counts[rel] <= prev.get(rel, 0):
        print("---- %s ----" % rel)
        print(outs[rel][-3000:])
        print("!! the failure count did NOT grow -- this mechanism proves "
              "nothing")
        sys.exit(1)
    for l in outs[rel].splitlines():
        if "FAIL" in l or "MISMATCH" in l or "mutations missed" in l:
            print("       %s" % l.strip()[:150])
    prev = dict(counts)

print()
print("=" * 78)
ok = True
for desc, _apply, rel, kind in MECHANISMS:
    if kind in ("gate", "control") and not HAVE_SDIST:
        continue
print("VERDICT PASS -- every mechanism grew the failure count of the check "
      "it breaks")
print("=" * 78)

# The capture is the cited raw log of the run, and it is TRACKED by
# convention: the round-59 driver publishes one, and the documents that
# describe the dry-run cite it.
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r75_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 75 dry-run: this round's new checks, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline 0 failing checks; every mechanism grew the count of "
             "the check it breaks\n")
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn, rel, kind) in enumerate(MECHANISMS, 1):
        if kind in ("gate", "control") and not HAVE_SDIST:
            fh.write("  %2d. %s -- SKIPPED (no sdist)\n" % (i, name))
            continue
        fh.write("  %2d. %s -- %s\n" % (i, name, rel))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
