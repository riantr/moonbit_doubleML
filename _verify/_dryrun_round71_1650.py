"""Round 71 dry-run: break ONE promise at a time and watch the count GROW.

This round published a FLOOR -- a requirement a reader must meet -- so this
driver proves the checks that hold it BIT, and that the two checks they sit
beside still bite.

THE MECHANISMS
===============
Four of them break a DOCUMENT promise, and the fifth breaks a MEASUREMENT.
That split is the point of the round, so it is worth stating:

  * a document promise can be broken by editing the document -- a pin that
    the tree does not declare, a floor that disagrees with the Status table,
    a floor that is NEWER than the toolchain the release was verified on, a
    "Not covered" section that stops saying what the dead pin costs, and an
    installation guide that goes back to saying the repository pins no
    minimum;
  * a MEASUREMENT cannot be broken by editing a document, because it does
    not read one.  "the installed core provides `moonbitlang/core/async`" is
    about the toolchain, so the way to break it is to point the verifier at a
    moon home that does not carry the subpackage.  `MOON_HOME` is the
    toolchain's own convention, so the verifier reads it -- and a check that
    cannot be pointed at a different world is a check that cannot fail.

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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r71")
DRIVER = "_verify/_dryrun_round71_1650.py"

DOCUMENTS = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "ENGINEERING.md",
    "CHANGELOG.md",
    os.path.join("doc", "002_installation", "readme.mbt.md").replace("\\", "/"),
]

VERIFIERS = [
    "_verify/_verify_toolchain_floor_1680.py",
    "_verify/_verify_dep_pins_1680.py",
]


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
    stands, and the pin and the toolchain in these files move with every
    release.  A literal here would be a literal that goes stale.
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
    return len(re.findall(r"\*\*\* FAIL \*\*\*", out))


def verify(work, env=None):
    """Run the verifiers in `work`; return (exit, output, failures)."""
    total, chunks = 0, []
    for rel in VERIFIERS:
        rc, out = run([sys.executable, os.path.join(work, rel.replace("/", os.sep))],
                      cwd=work, env=env)
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
GUIDE = os.path.join(WORK, "doc", "002_installation", "readme.mbt.md")

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
#
# The pin and the toolchain are matched as REGEXES, so a mechanism keeps
# working after the version has moved -- which is what happens at every
# release, and a literal would have gone stale on the first one.
def both_readmes(pattern, repl):
    sub_once(README, pattern, repl)
    sub_once(SHIPPED, pattern, repl)


MECHANISMS = [
    ("the Installation requirement names a pin the tree does not declare",
     lambda: both_readmes(
         r"`moonbitlang/async@0\.\d+\.\d+`, and that published version imports",
         "`moonbitlang/async@0.22.5`, and that published version imports")),

    ("the Installation requirement names a toolchain the Status table does not",
     lambda: both_readmes(
         r"\*\*Requires `moon 0\.1\.\d+` or newer\.\*\*",
         "**Requires `moon 0.1.20261023` or newer.**")),

    ("the floor is NEWER than the toolchain the release was verified on",
     lambda: both_readmes(
         r"\*\*Requires `moon 0\.1\.\d+` or newer\.\*\*",
         "**Requires `moon 0.1.20261105` or newer.**")),

    ("the 'Not covered' section stops saying what the dead pin costs",
     lambda: both_readmes(
         r", a core\nsubpackage that older cores do not carry, so the dead pin is what sets the\n"
         r"\*\*toolchain floor\*\* -- see \*\*Installation\*\*\.",
         ", a core\nsubpackage that older cores do not carry.")),

    ("the installation guide goes back to saying the repository pins no minimum",
     lambda: sub_once(
         GUIDE,
         r"- `moon` \*\*0\.1\.\d+ or newer\*\*\.",
         "- `moon` — CI installs the `latest` channel build and the\n"
         "  repository pins no minimum.")),
]

# The fifth mechanism is a MEASUREMENT, not a document: the verifier is
# pointed at a moon home that does not carry the subpackage.  It runs LAST,
# because it changes the environment the other mechanisms share.
EMPTY_HOME = os.path.join(WORK, "_dryrun_empty_moon_home")
os.makedirs(os.path.join(EMPTY_HOME, "lib", "core"), exist_ok=True)

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

# the sixth: break a MEASUREMENT
env = dict(os.environ)
env["MOON_HOME"] = EMPTY_HOME
rc, out, n = verify(WORK, env=env)
print()
print("  %d. the installed core does not carry the subpackage (a moon home "
      "that has none)" % (len(MECHANISMS) + 1))
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
          "(%d -> %d)" % (len(MECHANISMS) + 1, n0, prev))
else:
    print("VERDICT FAIL -- the mechanisms did not each grow the count")
print("=" * 78)

# The capture is the cited raw log of the run, and it is TRACKED by
# convention: the round-59 driver publishes one, and the documents that
# describe the dry-run cite it.
capture = os.path.join(REPO, "_verify", "_dryrun1650", "r71_dryrun.out")
os.makedirs(os.path.dirname(capture), exist_ok=True)
with io.open(capture, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("round 71 dry-run: the toolchain floor, broken %d ways\n"
             % (len(MECHANISMS) + 1))
    fh.write("baseline %d failing checks; final %d\n" % (n0, prev))
    fh.write("VERDICT %s\n" % ("PASS" if ok else "FAIL"))
    for i, (name, _fn) in enumerate(MECHANISMS, 1):
        fh.write("  %2d. %s\n" % (i, name))
    fh.write("  %2d. the installed core does not carry the subpackage "
             "(a moon home that has none)\n" % (len(MECHANISMS) + 1))
print("wrote %s" % capture)
sys.exit(0 if ok else 1)
