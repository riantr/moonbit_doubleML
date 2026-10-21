"""Dry-run the README structure verifier against a tree whose SHAPE is broken.

WHAT THIS PROVES
=================
`_verify/_verify_readme_structure_1650.py` checks the README's shape rather
than its claims: heading levels, code fences, table columns, paragraphs that
open mid-sentence, relative links, and pointers that resolve to nothing.

Round 22 found two shape defects BY READING -- a section that opened with
half a sentence, and a heading that skipped a level -- and no claim
verifier can see either, because a well-formed claim about nothing is still
a well-formed claim.  So the check has to be proven against a tree where
the shape is broken.

Six defects, six different mechanisms:

  1. a heading skips a level            -> the heading-level check
  2. a paragraph opens mid-sentence     -> the prose-shape check
  3. a relative markdown link           -> the link check
  4. a table row loses a column         -> the table-column check
  5. a code fence is left open          -> the fence check
  6. a 'see below' pointer at the end   -> the pointer check

The counter is checked against the verifier's own summary, because a count
that can drift from the output proves nothing.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round has not committed yet -- the rebuilt README and the new
verifier -- are copied in from the WORKING TREE, and the shape is broken on
top of that.

Run: python _verify/_dryrun_round23_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r23_mut")

COPY_IN = [
    "README.mbt.md",
    "moonbit_doubleML/README.mbt.md",
    "_verify/_verify_readme_structure_1650.py",
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

print()
print("=== breaking the shape in six places ===")

README = os.path.join(WORK, "README.mbt.md")
SHIPPED = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")

# 1. a heading skips a level
patch(README, "### Differences from upstream `doubleml-for-py`",
      "#### Differences from upstream `doubleml-for-py`")
print("  1. a heading skips a level")

# 2. a paragraph opens mid-sentence
patch(README,
      "**Bit-exact parity is a second, stronger tier.** A tolerance cannot tell",
      "patterns instead, against `examples/bitexact/`. A tolerance cannot tell")
print("  2. a paragraph opens mid-sentence")

# 3. a relative markdown link -- on the published page this is a link to nowhere
patch(README,
      "documented in `ENGINEERING.md`, together with",
      "documented in [ENGINEERING.md](ENGINEERING.md), together with")
print("  3. a relative markdown link")

# 4. a table row loses a cell
patch(README,
      "| `DoubleMLBLP` | IV | best linear predictor of treatment effect *(upstream)* |",
      "| `DoubleMLBLP` | IV |")
print("  4. a table row loses a column")

# 5 and 6 are appended at the END, so that neither can swallow the other:
# an unclosed fence would hide everything after it from the prose checks,
# and the pointer has to sit BELOW the last heading and table.
tail = io.open(README, encoding="utf-8", newline="").read().rstrip("\n")
with io.open(README, "w", encoding="utf-8", errors="replace", newline="") as fh:
    fh.write(tail
             + "\n\nA final note: see below for the details.\n\n"
             + "```moonbit\nlet x = 1\n")
print("  5. a code fence is left open at the end of the document")
print("  6. a 'see below' pointer with nothing below it")

# the shipped copy must stay byte-identical, so it gets the same damage
shutil.copy2(README, SHIPPED)
print("  (the shipped copy was given the same damage, so the byte-identity "
      "check still holds and does not mask the other five)")

print()
print("=== running the structure verifier ===")
rc, out = run([sys.executable,
               os.path.join(WORK, "_verify", "_verify_readme_structure_1650.py")],
              cwd=WORK, timeout=3600)
print(out)
print("=== verifier exit code: %d ===" % rc)
print()

fail_lines = [l for l in out.splitlines() if "*** FAIL ***" in l]
print("FAIL lines: %d" % len(fail_lines))
for l in fail_lines:
    print("   " + l.strip()[:170])

exact = len([l for l in out.splitlines()
             if l.startswith("  *** FAIL ***")])
print()
print("EXACT failure count (check lines carrying the marker): %d" % exact)

m = re.search(r"(\d+) checks, (\d+) failed", out)
if m:
    print("verifier summary: checks=%s failed=%s" % (m.group(1), m.group(2)))
    agree = int(m.group(2)) == exact
    print("the counter agrees with the summary: %s" % agree)
else:
    print("verifier summary: NOT FOUND (the verifier probably crashed)")
    agree = False

print()
if rc == 0:
    print("VERDICT: *** the dry-run did NOT bite -- the verifier PASSED against "
          "a tree whose README shape was broken ***")
    sys.exit(1)
print("VERDICT: PASS -- the dry-run bites (%d failures)" % exact)

LOG = os.path.join(REPO, "_verify", "_dryrun1650", "r23_dryrun.out")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
    fh.write("\nEXACT failure count: %d\n" % exact)
print("wrote %s" % LOG)
sys.exit(0 if agree else 1)
