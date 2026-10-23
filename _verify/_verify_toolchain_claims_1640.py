"""Every toolchain-named claim in the tree must name a toolchain that is current.

The README audit's recurring failure mode this round: claims are pinned to a
toolchain and then the toolchain moves on, and the claim keeps being asserted
against a version nobody is running any more. Four claims were pinned to
`moon 0.1.20261012`; the local toolchain is `moon 0.1.20261016`.

Each of the four was re-measured (see the round-6 notes), and all four still
hold in substance -- so the fix is the label, not the claim:

  * "a bare `moon test` prints `Total tests: 0` for the non-preferred
    backends"          -> re-measured on 0.1.20261016: still true.
  * "MoonBit has no file I/O (@std/env, @std/fs, @std/io, @std/process do not
    resolve)"          -> re-measured on 0.1.20261016: still true
                            ("Package \\"std\\" not found in the loaded packages").
  * the operator bit-exactness table -> re-measured on 0.1.20261016 vs
    CPython 3.13.14: identical numbers.

What this verifier forbids is the opposite mistake: rewriting history. A
STALE mention is only allowed where the text explicitly marks it as the
ORIGINAL measurement. CHANGELOG.md is a historical record and is exempt, but
its stale mentions are counted so that a well-meaning "fix" cannot quietly
rewrite the record.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CURRENT = "0.1.20261016"
STALE = "0.1.20261012"

# a STALE mention is legitimate only when the text marks it as the original
HISTORICAL = re.compile(
    r"first taken on|was first|the measurement was first|originally|"
    r"it was first", re.I)

# files that carry a live claim and therefore must name the current toolchain
MUST_NAME_CURRENT = [
    "README.mbt.md",
    os.path.join("moonbit_doubleML", "README.mbt.md"),
    os.path.join("examples", "bitexact", "main.mbt"),
    "validate_bitexact_with_python.py",
    os.path.join("examples", "parity", "pyexample_data.mbt"),
    "pyexample_did.py",
]

fails = []


def check(label, cond, detail=""):
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


print("=== files that must name the current toolchain ===")
for rel in MUST_NAME_CURRENT:
    path = os.path.join(ROOT, rel)
    raw = io.open(path, encoding="utf-8", errors="replace").read()
    flat = re.sub(r"\s+", " ", raw)
    n_cur = flat.count(CURRENT)
    n_stale = flat.count(STALE)
    print("  %-46s current=%d stale=%d" % (rel, n_cur, n_stale))
    check("%s names the current toolchain" % os.path.basename(rel),
          n_cur >= 1, "no %s anywhere in the file" % CURRENT)
    for m in re.finditer(re.escape(STALE), flat):
        ctx = flat[max(0, m.start() - 140):m.end() + 140]
        check("  its %s mention is marked historical" % STALE,
              bool(HISTORICAL.search(ctx)),
              "context: ...%s..." % ctx[:200])

print()
print("=== CHANGELOG.md is a historical record and must not be rewritten ===")
ch = io.open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8",
             errors="replace").read()
n_stale_ch = ch.count(STALE)
print("  CHANGELOG.md stale mentions: %d" % n_stale_ch)
# The count is NOT pinned to a literal. It was 3 until v0.164.1, whose entry
# legitimately quotes the ORIGINAL measurement ("the moon 0.1.20261012 vs
# CPython 3.14 pair it was first taken on") -- so the count grows as history
# is added. What must hold is that it never SHRINKS: a drop means a release
# rewrote the record.
import subprocess

rc = subprocess.run(["git", "show", "v0.164.1:CHANGELOG.md"], cwd=ROOT,
                    capture_output=True, text=True, encoding="utf-8",
                    errors="replace")
prev = rc.stdout or ""
n_prev = prev.count(STALE)
print("  v0.164.1's CHANGELOG had %d stale mentions" % n_prev)
check("CHANGELOG.md's stale mentions never shrink (history is append-only)",
      n_stale_ch >= n_prev, "now %d, was %d at v0.164.1" % (n_stale_ch, n_prev))
# The CHANGELOG records past releases, so a stale toolchain mention there is
# historical by construction -- but it must belong to a PAST entry. A stale
# mention in the NEWEST entry would be a live claim, which is the defect this
# whole check exists to catch.
entries = re.split(r"^## \[", ch, flags=re.M)
newest = entries[1] if len(entries) > 1 else ""
check("the newest CHANGELOG entry makes no live stale-toolchain claim",
      STALE not in newest,
      "the newest entry still names %s" % STALE)
check("the historical entries are where the stale mentions live",
      n_stale_ch == sum(e.count(STALE) for e in entries[1:]),
      "mismatch")

print()
print("=== the two file-I/O claims name the current toolchain outright ===")
for rel in (os.path.join("examples", "parity", "pyexample_data.mbt"),
            "pyexample_did.py"):
    raw = io.open(os.path.join(ROOT, rel), encoding="utf-8",
                  errors="replace").read()
    flat = re.sub(r"\s+", " ", raw)
    check("%s has no stale toolchain mention" % os.path.basename(rel),
          STALE not in flat, "still names %s" % STALE)

print()
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
