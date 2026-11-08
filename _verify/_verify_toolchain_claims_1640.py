"""Every toolchain-named claim in the tree must name a toolchain that is current.

The README audit's recurring failure mode this round: claims are pinned to a
toolchain and then the toolchain keeps moving, and the claim keeps being
asserted against a version nobody is running any more. Four claims were pinned
to `moon 0.1.20261012`; the local toolchain is `moon 0.1.20261016`.

Each of the four was re-measured (see the round-6 notes), and all four still
hold in substance -- so the fix is the label, not the claim:

  * "a bare `moon test` prints `Total tests: 0` for the non-preferred
    backends"          -> re-measured on 0.1.20261016: still true.
  * "MoonBit has no file I/O (@std/env, @std/fs, @std/io, @std/process do not
    resolve)"          -> re-measured on 0.1.20261016: still true
                            ("Package \"std\" not found in the loaded packages").
  * the operator bit-exactness table -> re-measured on 0.1.20261016 vs
    CPython 3.13.14: identical numbers.

ROUND 39: THE TOOLCHAIN MOVED AGAIN
------------------------------------
The local toolchain is now `moon 0.1.20261028`, and every claim above was
RE-DERIVED on it -- not assumed:

  * a bare `moon test` still prints `Total tests: 0` for `wasm` and `native`
    and reports "no test entry found" for `js`, and still runs `wasm-gc`;
  * `@std/env`, `@std/fs`, `@std/io` and `@std/process` still do not resolve
    ("Cannot find import '@std/env'") and the builtin `read_file` still does
    not exist (error 4021);
  * the operator bit-exactness table is unchanged -- `_verify_op_table_1640.py`
    re-measures it on whatever toolchain is installed NOW, and it still gives
    `sqrt` 6/6, `cos`/`sin` 6/6 and `ln` 5/6 with `ln(3.0)` off by 1 ULP.

One claim did NOT survive the move, and the label was not the whole of it:
`train` was a hard error on `moon 0.1.20261016` and is NOT reserved on
`moon 0.1.20261028` -- it compiles as a local and as a field. The agent
skill's anti-pattern list said "all are reserved in current MoonBit", which
stopped being true, so the skill now states which ones are reserved and
which one moved.

What this verifier forbids is the opposite mistake: rewriting history. A
STALE mention is only allowed where the text explicitly marks it as the
ORIGINAL measurement. CHANGELOG.md is a historical record and is exempt, but
its stale mentions are counted so that a well-meaning "fix" cannot quietly
rewrite the record.

ROUND 86: THE TOOLCHAIN MOVED TWICE MORE, AND THIS VERIFIER DID NOT NOTICE
==========================================================================
`moon` moved 0.1.20261028 -> 0.1.20261029 -> 0.1.20261102 while this file
kept the literal

    CURRENT = "0.1.20261028"

and every live claim kept the label `0.1.20261028`. The verifier stayed
GREEN the whole time, because a verifier that DEMANDS a literal version
cannot notice that the version moved: the tree kept the old label, the check
kept demanding it, and both agreed. Meanwhile CI installs the FLOATING
`latest` channel build -- 0.1.20261104 today -- so the release was being
verified against one compiler and published by another. Two channel builds of
drift, and the check designed to catch exactly that was the thing making it
invisible.

THE REFERENCE IS DERIVED NOW
----------------------------
`CURRENT` comes from the README's Status table, and the check below holds
that reference to the INSTALLED toolchain, so the two cannot drift apart
either. The README's row is itself derived by the builder from the
transcript the release was measured on -- the same chain of custody the house
uses for the dependency pin. A literal in a verifier is a claim about the
world that only its author can refresh; a derived one follows the tree.

WHAT ROUND 86 ALSO FOUND: A QUOTED MESSAGE WENT STALE
-------------------------------------------------------
The live claim in `examples/parity/pyexample_data.mbt` and `pyexample_did.py`
quotes the compiler's own error text:

    all fail to resolve (`Cannot find import '@std/env'`)

That is the message the compiler printed BEFORE the stdlib moved into
`moonbitlang/core/*` packages. On 0.1.20261102 the same probe says

    Cannot use `@std`: package std is not imported.        (error 4037)

The SUBSTANCE holds -- the four packages do not resolve, `read_file` is still
unbound (error 4021), and the installed core ships no `fs` and no `io`
module -- but the QUOTED TEXT belongs to a compiler that no longer ships.
`_verify/_verify_fileio_claim_1680.py` now ties that quote to the compiler
that is actually installed.

AND A COVERAGE RULE: A FILE CAN BE ADDED AND FORGOTTEN
--------------------------------------------------------
The list of live files was hand-maintained, and it had already missed two:
`doc/006_python_check/readme.mbt.md` and `moonbit_doubleML/plr_test.mbt` both
carried a live toolchain label and neither was in the list. A hand-kept list
is a list that rots. The census below DERIVES the set of tracked files that
name a toolchain at all, and requires each one either to name the current
toolchain or to be a record of a past measurement.
"""
import fnmatch
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The toolchain this release is verified on.  DERIVED -- see the docstring.
STALE = "0.1.20261012"

# a STALE mention is legitimate only when the text marks it as the original
HISTORICAL = re.compile(
    r"first taken on|was first|the measurement was first|originally|"
    r"it was first", re.I)

# any `moon` channel version
TOKEN = re.compile(r"0\.1\.2026\d{4}")

# files that carry a LIVE claim and therefore must name the current toolchain
MUST_NAME_CURRENT = [
    "README.mbt.md",
    os.path.join("moonbit_doubleML", "README.mbt.md"),
    os.path.join("examples", "bitexact", "main.mbt"),
    "validate_bitexact_with_python.py",
    os.path.join("examples", "parity", "pyexample_data.mbt"),
    "pyexample_did.py",
    os.path.join("doc", "006_python_check", "readme.mbt.md"),
    os.path.join("moonbit_doubleML", "plr_test.mbt"),
    os.path.join(".github", "workflows", "check.yml"),
    os.path.join(".github", "workflows", "publish.yml"),
]

# Files that name a toolchain and are RECORDS rather than live claims.
#
#   * the two append-only documents: the CHANGELOG is a release record and
#     ENGINEERING.md is the v0.164.11 snapshot plus the ascending ledger;
#   * the dated verdict / handoff records, which name the toolchain the
#     verdict was reached on -- that IS the record;
#   * the house's own scripts under `_verify/`, whose toolchain mentions are
#     narratives about which toolchain a PAST measurement was taken on, and
#     whose live assertions about the tree each have their own check;
#   * the QA harness's own narrative about the 2026-10-29 stderr warning;
#   * the recorded measurement artifacts (the JSON verdicts, the probe
#     transcripts and the probe sources).
HISTORICAL_FILES = (
    "CHANGELOG.md",
    "ENGINEERING.md",
    "_probe/*.md",
    "_prove_pilot/*.md",
    "_verify/*-verdict.md",
    "_verify/TODO-*.md",
    "_verify/UPSTREAM_*.md",
    "_verify/CLUSTER_*.md",
    "_verify/DID_BINARY_PANIC_*.md",
    "_verify/upstream_prove_1649/*",
    "_verify/_*.json",
    "_verify/_*.txt",
    "_verify/_*.mbt",
    "_verify/_*.py",
    os.path.join(".github", "scripts", "qa_loop", "*.py"),
)

TEXTY = (".md", ".mbt", ".py", ".yml", ".yaml", ".toml", ".txt", ".mbti", ".json")

fails = []
N = 0


def check(label, cond, detail=""):
    global N
    N += 1
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def read(rel):
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def is_historical(rel):
    for pat in HISTORICAL_FILES:
        if fnmatch.fnmatch(rel.replace("\\", "/"), pat.replace("\\", "/")):
            return True
    return False


def classify(rel, text, current):
    """Is this file's toolchain mention a live claim, or a record of a past one?

    (ok, why) -- the rule itself, so a control arm can feed it a case.
    """
    if current and current in text:
        return True, "names the current toolchain"
    if is_historical(rel):
        return True, "a record of a past measurement"
    return False, "names a toolchain that is not the current one"


print("=== the reference: the toolchain this release is verified on ===")
txt = read("README.mbt.md")
m = re.search(r"^\|\s*Toolchain\s*\|\s*`moon ([0-9.]+)`", txt, re.M)
CURRENT = m.group(1) if m else ""
check("the README's Status table has a Toolchain row", bool(CURRENT),
      "no '| Toolchain | `moon X.Y.Z`' row")

inst_out = subprocess.run(["moon", "version"], cwd=ROOT, capture_output=True,
                           text=True, encoding="utf-8", errors="replace")
mi = re.search(r"moon\s+([0-9.]+)", inst_out.stdout or "")
INSTALLED = mi.group(1) if mi else ""
print("   the README names moon %s ; the installed toolchain is moon %s"
      % (CURRENT or "?", INSTALLED or "?"))
check("the reference is the INSTALLED toolchain",
      bool(CURRENT) and bool(INSTALLED) and CURRENT == INSTALLED,
      "README=%s installed=%s" % (CURRENT, INSTALLED or "?"))
print()

print("=== files that must name the current toolchain ===")
for rel in MUST_NAME_CURRENT:
    raw = read(rel)
    flat = re.sub(r"\s+", " ", raw)
    n_cur = flat.count(CURRENT)
    n_stale = flat.count(STALE)
    print("  %-46s current=%d stale=%d" % (rel, n_cur, n_stale))
    check("%s names the current toolchain" % rel,
          n_cur >= 1, "no %s anywhere in the file" % CURRENT)
    for m2 in re.finditer(re.escape(STALE), flat):
        ctx = flat[max(0, m2.start() - 140):m2.end() + 140]
        check("  its %s mention is marked historical" % STALE,
              bool(HISTORICAL.search(ctx)),
              "context: ...%s..." % ctx[:200])

print()
print("=== CHANGELOG.md is a historical record and must not be rewritten ===")
ch = read("CHANGELOG.md")
n_stale_ch = ch.count(STALE)
print("  CHANGELOG.md stale mentions: %d" % n_stale_ch)
# The count is NOT pinned to a literal. It was 3 until v0.164.1, whose entry
# legitimately quotes the ORIGINAL measurement ("the moon 0.1.20261012 vs
# CPython 3.14 pair it was first taken on") -- so the count grows as history
# is added. What must hold is that it never SHRINKS: a drop means a release
# rewrote the record.
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
    raw = read(rel)
    flat = re.sub(r"\s+", " ", raw)
    check("%s has no stale toolchain mention" % os.path.basename(rel),
          STALE not in flat, "still names %s" % STALE)

print()
print("=== census: every tracked file that names a toolchain is accounted for ===")
# The hand-kept list above had already missed two live files.  This derives
# the set instead: EVERY tracked file that names a toolchain must either name
# the current one or be a record.
ls = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                     text=True, encoding="utf-8", errors="replace")
tracked = [r.strip() for r in (ls.stdout or "").splitlines() if r.strip()]
candidates = []
for rel in tracked:
    if not rel.lower().endswith(TEXTY):
        continue
    body = read(rel)
    if TOKEN.search(body):
        candidates.append(rel)
print("  tracked files naming a toolchain: %d" % len(candidates))
unclassified = []
for rel in candidates:
    ok, why = classify(rel, read(rel), CURRENT)
    if not ok:
        unclassified.append((rel, why))
for rel, why in unclassified:
    print("    unclassified: %s -- %s" % (rel, why))
check("every tracked file that names a toolchain names the current one "
      "or is a record",
      not unclassified,
      "%d unclassified: %s" % (len(unclassified),
                               ", ".join(r for r, _ in unclassified)))

print()
print("=== control arms: the census rule can bite ===")
ok_now, _ = classify("examples/new_claim.mbt",
                      "measured on moon %s" % CURRENT, CURRENT)
check("C1 a new file naming the current toolchain is ACCEPTED", ok_now)
ok_old, _ = classify("examples/new_claim.mbt",
                     "measured on moon 0.1.20261028", CURRENT)
check("C1b a new file naming an old toolchain is REJECTED", not ok_old)
ok_rec, _ = classify(os.path.join("_verify", "TODO-99-verdict.md"),
                      "**Toolchain**: `moon 0.1.20260713 (75c7e1f 2026-07-13)`",
                      CURRENT)
check("C2 a dated verdict record is ACCEPTED", ok_rec)
ok_stale, _ = classify("examples/new_claim.mbt",
                        "measured on moon %s vs CPython 3.14" % STALE, CURRENT)
check("C2b a new file naming the ORIGINAL measurement is REJECTED", not ok_stale)

print()
print("=" * 78)
# The summary's SHAPE is part of the contract: `_verify_ledger_counts_1650.py`
# reads a check's count out of one of three shapes, and a shape it cannot read
# is a count it cannot check.  "N checks, M failed" is the first of them.
print("%d checks, %d failed" % (N, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
