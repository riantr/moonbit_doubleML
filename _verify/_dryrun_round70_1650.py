"""Round 70 dry-run: break ONE promise at a time and watch the count GROW.

This round added a check -- the dependency RULE's own example must name a
version the tree declares -- so this driver proves the new check BITES, and
that the two checks it sits beside still bite after the pin moved.

The mechanism is the same one the round-44 driver used: each step rewrites one
version in the README (and in the shipped copy, which must stay identical),
and the failure count has to GROW at every step.  A mechanism that does not
change the count is a mechanism that proves nothing.

The tree under test is a CLONE, with the working tree's state copied in: the
clone is checked out from HEAD, so without the copy the tree under test would
be a mix of two releases -- this round's checks and the last round's
documents -- and the baseline would be red for a reason that has nothing to
do with the promise being broken.
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r70")
DRIVER = "_verify/_dryrun_round70_1650.py"

DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
]

VERIFIERS = [
    "_verify/_verify_dep_pins_1680.py",
]


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
    STANDS, and the pin in these files moves with every release.  A literal
    here would be a literal that goes stale.
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


def failures_of(out):
    """How many checks failed, in the verifiers' own words."""
    n = len(re.findall(r"\*\*\* FAIL \*\*\*", out))
    return n


def verify(work):
    """Run the verifiers in `work`; return (exit, output, failures)."""
    total, chunks = 0, []
    for rel in VERIFIERS:
        rc, out = run([sys.executable, os.path.join(work, rel.replace("/", os.sep))],
                      cwd=work)
        chunks.append(out)
        total += failures_of(out)
    return 1 if total else 0, "\n".join(chunks), total


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

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0 = verify(WORK)
print("  exit=%d  failures=%d" % (rc0, n0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# -------------------------------------------------------------- the mechanisms
#
# CUMULATIVE: each mechanism is applied on top of the ones before it.
MECHANISMS = [
    ("the dependency RULE's example names a pin the tree does not declare",
     lambda: (sub_once(README,
                        r"Pin to the latest published version \(e\.g\. "
                        r"`moonbitlang/async@0\.22\.6`\)",
                        "Pin to the latest published version (e.g. "
                        "`moonbitlang/async@0.22.5`)"),
              sub_once(SHIPPED,
                       r"Pin to the latest published version \(e\.g\. "
                       r"`moonbitlang/async@0\.22\.6`\)",
                       "Pin to the latest published version (e.g. "
                       "`moonbitlang/async@0.22.5`)"))),

    ("the dependency table's ROW names a pin the tree does not declare",
     lambda: (sub_once(README,
                        r"\| `moonbitlang/async@0\.22\.6` \| no \|",
                        "| `moonbitlang/async@0.22.5` | no |"),
              sub_once(SHIPPED,
                       r"\| `moonbitlang/async@0\.22\.6` \| no \|",
                       "| `moonbitlang/async@0.22.5` | no |"))),

    ("the service sentence names a pin the example does not declare",
     lambda: (sub_once(README,
                        r"The service is built directly on "
                        r"`moonbitlang/async@0\.22\.6` --",
                        "The service is built directly on "
                        "`moonbitlang/async@0.22.5` --"),
              sub_once(SHIPPED,
                       r"The service is built directly on "
                       r"`moonbitlang/async@0\.22\.6` --",
                       "The service is built directly on "
                       "`moonbitlang/async@0.22.5` --"))),
]

prev = n0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n = verify(WORK)
    print()
    print("  %d. %s" % (i, desc))
    print("       failures: %d -> %d" % (prev, n))
    if n <= prev:
        print(out)
        print("!! the failure count did NOT grow -- this mechanism proves nothing")
        sys.exit(1)
    for l in out.splitlines():
        if "FAIL" in l:
            print("       %s" % l.strip()[:150])
    prev = n

print()
print("=" * 78)
ok = prev > n0
if ok:
    print("VERDICT PASS -- %d mechanisms, each one grew the failure count "
          "(%d -> %d)" % (len(MECHANISMS), n0, prev))
else:
    print("VERDICT FAIL -- the mechanisms did not each grow the count")
print("=" * 78)

# The capture is the cited raw log of the run, and it is TRACKED by
# convention: the round-59 driver publishes one, and the documents that
# describe the dry-run cite it.
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r70_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 70 dry-run: the dependency pin, broken %d ways\n"
             % len(MECHANISMS))
    fh.write("baseline %d failing checks; final %d\n" % (n0, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
