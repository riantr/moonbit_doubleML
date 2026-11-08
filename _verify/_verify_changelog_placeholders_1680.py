#!/usr/bin/env python3
"""Round 86 verifier: the CHANGELOG must not carry an UNFILLED PLACEHOLDER.

THE GAP
=======
v0.164.63 shipped a CHANGELOG whose "Verified" block read

    - local gate: __GATESTEPS__ steps, 0 failed
    - tracked verifier suite: __SUITE__ passed / 0 failed / 0 unknown
    - the tracked contract in a FRESH CLONE: **0** of **__SUITE__** fail

The placeholders are what the release WRITES before the numbers are known,
and the release is supposed to replace them with the measured ones before
it commits.  For v0.164.63 that step never happened: the committed file
carried the literal tokens, and the registry never saw the package, so
nothing noticed.

The tokens are a TEMPLATE.  A template that reaches a reader is a document
that states nothing: "the gate ran __GATESTEPS__ steps" asserts nothing at
all, and it LOOKS like a measurement.

THE RULES
=========
  P1  the live CHANGELOG carries no unfilled `__PLACEHOLDER__` token.  Every
      section -- the newest and every historical one -- states DIGITS.
  P2  the NEWEST section states a gate-steps count, a suite count and a
      fresh-clone count, and all three are digits.
  P3  the newest section's suite count is the TRACKED CONTRACT count -- the
      number the suite itself derives -- so the published number is the
      number the suite ran.
  P4  the newest section's fresh-clone count is the same number: the clone
      runs the same contract.
  P5  the newest section's gate-steps count is the gate's OWN result count,
      read from `_verify/_gate_1651.json`.  That artifact is only usable when
      it is NEWER than the gate's source; an old one is a reported SKIP, never
      a pass.  And a RED gate publishes no count at all.
  P6  the newest section's FINDING COUNT is DERIVED: it is the number of
      `### Fixed --` entries in the section.  The section states the count it
      has, and the stated count is that number -- so the count cannot
      disagree with the enumeration it counts.

WHY P6 EXISTS
=============
This round published its own finding count in three documents, and the three
numbers did not agree: the CHANGELOG's newest section carried twenty-one
`### Fixed` entries, the commit message said "Sixteen defects", and the goal
summary said "FIFTEEN findings".  Nothing derived any of them and no check
could see any of them -- so the count was a claim about the round that no
reader could check, which is the same class of defect as the stale shift-map
number this round found in the same section.

The count is derived from the one construct in the tree that can be counted:
the section's own `### Fixed` entries.  The section states it, this rule
reads the entries and compares, and the release's commit message and goal
summary state the same number -- derived from the same source, and checked
against it before the commit.

THE DERIVATION
==============
  * the tracked contract is derived the way `_r18_run_suite_1650.py` derives
    it: the tracked `_verify` scripts whose basename contains "verify",
    minus the same SKIP filter;
  * the gate's step count comes from the gate's OWN result list, because three
    of the gate's steps live inside loops and counting its source would be a
    guess;
  * the three counts are read from the CLAIMS BLOCK -- the bullet list that
    states all three -- and not from the first mention of a claim shape
    anywhere in the section.  A section can PROSE about a past release's
    counts, and a first-match search would take the prose's number for the
    claim.  This verifier did exactly that: its P3 and P5 rules read a
    sentence about v0.164.63 and agreed with the real block only by luck;
  * every rule is a PURE function of a text, so the control arms can call it
    with a document nobody publishes.

THE CONTROL ARM
===============
  C1  a CHANGELOG carrying a placeholder is REJECTED by P1;
  C1b a CHANGELOG with every number filled is ACCEPTED by P1;
  C2  a newest section with all three counts filled is ACCEPTED by P2;
  C2b a newest section with a token where a count belongs is REJECTED by P2;
  C3  a newest section whose suite count IS the contract count is ACCEPTED
      by P3, and one whose suite count differs is REJECTED by P3;
  C4  a newest section whose clone count EQUALS its suite count is ACCEPTED
      by P4, and one whose clone count differs is REJECTED by P4;
  C5  the fixture carries a DECOY -- a paragraph stating all three claim
      shapes about another release, before the claims block.  A rule that
      read the first mention would take the decoy's numbers, and the arms
      above would then FAIL on the fixture itself.  So the fixture proves
      the block is what is read.
  C6  a section whose stated finding count EQUALS its `### Fixed` count is
      ACCEPTED by P6; one whose count differs is REJECTED; and one that
      states no count at all is REJECTED -- a section that states no count
      states nothing about how many findings it closed.

Run: python _verify/_verify_changelog_placeholders_1680.py
"""
import io
import json
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
GATE_JSON = os.path.join(ROOT, "_verify", "_gate_1651.json")
GATE_SRC = os.path.join(ROOT, "_verify", "_gate_1651.py")

# The same filter the suite runner uses.
SKIP = re.compile(r"_verify_published_readme_16\d\d\.py$"
                  r"|_verify_typos_pinned"
                  r"|^_final_1600_verify\.py$"
                  r"|^_release_verify_1590\.py$")

PLACEHOLDER = re.compile(r"__[A-Z][A-Z0-9_]{2,}__")

N = 0
FAILS = []
SKIPS = []


def check(label, ok, detail=""):
    global N
    N += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "FAIL", label, detail))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))


def skip(label, detail=""):
    global N
    N += 1
    print("  %-4s %-62s SKIP" % ("SKIP", label))
    print("      %s" % detail)
    SKIPS.append("%s -- %s" % (label, detail))


# ---------------------------------------------------------------------------
# the rules, as PURE functions of a text
# ---------------------------------------------------------------------------
def placeholders(text):
    """Every unfilled placeholder token in a document."""
    return sorted(set(m.group(0) for m in PLACEHOLDER.finditer(text)))


def newest_section(text):
    """The newest release section -- the first `## [x.y.z]` heading."""
    m = re.search(r"(?m)^## \[(\d+\.\d+\.\d+)\]", text)
    if not m:
        return None, ""
    start = m.start()
    nxt = re.search(r"(?m)^## \[\d+\.\d+\.\d+\]", text[m.end():])
    end = m.end() + nxt.start() if nxt else len(text)
    return m.group(1), text[start:end]


def claims_block(section):
    """The bullet list that states the newest section's three counts.

    The counts are read from the BLOCK, never from the first mention of a
    claim shape anywhere in the section.  A section may PROSE about a past
    release's counts -- v0.164.64's entry quotes v0.164.63's -- and a
    first-match search takes the prose's number for the claim, so the rule
    measures the sentence instead of the claim.  That is not hypothetical:
    this verifier did it, and its P3 and P5 rules read a sentence about
    v0.164.63 and agreed with the real block only by luck.

    A block is a contiguous run of bullet lines.  The claims block is the one
    that states ALL THREE counts; if none does, the first bullet that states
    one is used, so a malformed block is still read rather than ignored.
    """
    lines = section.splitlines()
    blocks = []
    cur = []
    for ln in lines:
        if re.match(r"^\s*[-*]\s+", ln):
            cur.append(ln)
        else:
            if cur:
                blocks.append(cur)
            cur = []
    if cur:
        blocks.append(cur)
    shapes = ("local gate:", "tracked verifier suite:", "FRESH CLONE")
    full = [b for b in blocks
            if all(any(s in ln for ln in b) for s in shapes)]
    if full:
        return "\n".join(full[0])
    for b in blocks:
        if any("local gate:" in ln for ln in b):
            return "\n".join(b)
    return ""


def stated_counts(section):
    """The three numbers the newest section's Verified block states."""
    out = {}
    block = claims_block(section)
    m = re.search(r"local gate:\s*(\S+)\s+steps", block)
    out["gate"] = m.group(1) if m else None
    m = re.search(r"tracked verifier suite:\s*(\S+)\s+passed", block)
    out["suite"] = m.group(1) if m else None
    m = re.search(r"FRESH CLONE:\s*\*\*0\*\*\s+of\s+\*\*(\S+?)\*\*\s+fail", block)
    out["clone"] = m.group(1) if m else None
    return out


def is_digits(value):
    return value is not None and value.isdigit()


def suite_is_the_contract(section, contract):
    """P3: the stated suite count IS the tracked contract count."""
    return stated_counts(section)["suite"] == str(contract)


def clone_is_the_suite(section):
    """P4: the stated clone count EQUALS the stated suite count."""
    c = stated_counts(section)
    return c["clone"] == c["suite"]


def flat(text):
    """Whitespace-normalised: a phrase may span a line break."""
    return re.sub(r"\s+", " ", text)


def fixed_entries(section):
    """The `### Fixed --` headings of a section -- the enumeration."""
    return re.findall(r"(?m)^### Fixed -- .+$", section)


def stated_findings(section):
    """The finding count the section states, if it states one."""
    m = re.search(r"closed \*\*(\d+)\*\* findings", flat(section))
    return int(m.group(1)) if m else None


def findings_are_derived(section):
    """P6: the stated finding count IS the number of `### Fixed` entries."""
    stated = stated_findings(section)
    return stated is not None and stated == len(fixed_entries(section))


# ---------------------------------------------------------------------------
# the tracked contract, derived the way the suite derives it
# ---------------------------------------------------------------------------
def tracked_contract():
    p = subprocess.run(["git", "-C", ROOT, "ls-files", "_verify"], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    tracked = set(l.split("/")[-1] for l in p.stdout.splitlines() if l.strip())
    vdir = os.path.join(ROOT, "_verify")
    scripts = [f for f in sorted(os.listdir(vdir))
               if f.endswith(".py") and re.search(r"verify", f) and not SKIP.search(f)]
    return sorted(f for f in scripts if f in tracked)


print("== the tracked contract ==")
contract = tracked_contract()
print("   the tracked contract: %d script(s)" % len(contract))

print()
print("== the live CHANGELOG ==")
text = io.open(CHANGELOG, encoding="utf-8", errors="replace").read()
toks = placeholders(text)
check("P1 the CHANGELOG carries no unfilled placeholder", not toks,
      "it carries: %s" % ", ".join(toks))

ver, section = newest_section(text)
check("the CHANGELOG has a newest release section", ver is not None,
      "no `## [x.y.z]` heading")
counts = stated_counts(section) if section else {"gate": None, "suite": None, "clone": None}
if ver:
    print("   the newest section: %s" % ver)
    for k in ("gate", "suite", "clone"):
        print("      %-6s %s" % (k, counts[k]))
    check("P2a the newest section states a gate-steps count", is_digits(counts["gate"]),
          "it states %r" % counts["gate"])
    check("P2b the newest section states a suite count", is_digits(counts["suite"]),
          "it states %r" % counts["suite"])
    check("P2c the newest section states a fresh-clone count", is_digits(counts["clone"]),
          "it states %r" % counts["clone"])
    check("P3 the newest section's suite count is the tracked contract count",
          suite_is_the_contract(section, len(contract)),
          "it states %s, the contract is %d" % (counts["suite"], len(contract)))
    check("P4 the newest section's clone count is its suite count",
          clone_is_the_suite(section),
          "clone=%s suite=%s" % (counts["clone"], counts["suite"]))
    n_fixed = len(fixed_entries(section))
    stated = stated_findings(section)
    check("P6a the newest section states its finding count", stated is not None,
          "it states %r; the section has %d `### Fixed` entries" % (stated, n_fixed))
    check("P6b the newest section's finding count is the number of its "
          "`### Fixed` entries",
          stated is not None and stated == n_fixed,
          "it states %r, the section has %d" % (stated, n_fixed))

print()
print("== the gate's own step count ==")
if not os.path.isfile(GATE_JSON):
    skip("P5 the newest section's gate count is the gate's own result count",
         "there is no %s" % os.path.basename(GATE_JSON))
else:
    fresh = (os.path.getmtime(GATE_JSON) > os.path.getmtime(GATE_SRC))
    if not fresh:
        skip("P5 the newest section's gate count is the gate's own result count",
             "the gate result is OLDER than the gate's source -- it is a "
             "previous round's")
    else:
        with io.open(GATE_JSON, encoding="utf-8") as fh:
            data = json.load(fh)
        results = data.get("results", [])
        failed = data.get("failed", sum(1 for r in results if r.get("exit") != 0))
        print("   the gate ran %d step(s), %d failed" % (len(results), failed))
        if failed:
            skip("P5 the newest section's gate count is the gate's own result count",
                 "the gate is RED (%d failed step(s)) -- a red gate publishes no "
                 "count" % failed)
        else:
            check("P5 the newest section's gate count is the gate's own result count",
                  counts["gate"] == str(len(results)),
                  "it states %s, the gate ran %d" % (counts["gate"], len(results)))

print()
print("== the control arm: synthetic documents, and what the rules do with them ==")
# The DECOY: a paragraph that states all three claim shapes about ANOTHER
# release, BEFORE the claims block.  A rule that read the first mention in
# the section would take the decoy's numbers -- and the arms below would then
# fail on their own fixture.  So the fixture proves the BLOCK is what is
# read, and the arms below bite on it.
#
# The three shapes are spelled on a line each, and each line is short enough
# not to be re-wrapped: a shape split across a line break is not the shape,
# and the decoy would not bite.
SYN = """## [9.9.9] -- a synthetic release

A past release's entry reads "local gate: 7 steps, 0 failed",
"tracked verifier suite: 7 passed" and "the tracked contract in a
FRESH CLONE: **0** of **7** fail".  It is PROSE about another release:
it is not this section's claim, and a rule that reads the first mention
of a shape takes the prose's number instead of the block's.

### Verified ---

- local gate: 41 steps, 0 failed
- tracked verifier suite: %d passed / 0 failed / 0 unknown
- the tracked contract in a FRESH CLONE: **0** of **%d** fail
"""
good = SYN % (len(contract), len(contract))
_, sec_good = newest_section(good)
wrong_suite = SYN % (len(contract) + 1, len(contract) + 1)
_, sec_wrong_suite = newest_section(wrong_suite)
wrong_clone = SYN % (len(contract), len(contract) + 1)
_, sec_wrong_clone = newest_section(wrong_clone)
tokened = SYN % (len(contract), len(contract))
tokened = tokened.replace("- local gate: 41 steps", "- local gate: __GATESTEPS__ steps")

check("C1 a CHANGELOG carrying a placeholder is REJECTED",
      bool(placeholders(tokened)), "the rule did not see the placeholder")
check("C1b a CHANGELOG with every number filled is ACCEPTED",
      not placeholders(good), "the rule invented a placeholder")
cg = stated_counts(sec_good)
check("C2 a newest section with all three counts filled is ACCEPTED",
      all(is_digits(cg[k]) for k in ("gate", "suite", "clone")),
      "it states %r" % cg)
ct = stated_counts(newest_section(tokened)[1])
check("C2b a newest section with a token where a count belongs is REJECTED",
      not is_digits(ct["gate"]), "the rule accepted a token as a count")
check("C3 a newest section whose suite count IS the contract count is ACCEPTED",
      suite_is_the_contract(sec_good, len(contract)), "the rule REJECTED a right count")
check("C3b a newest section whose suite count differs is REJECTED",
      not suite_is_the_contract(sec_wrong_suite, len(contract)),
      "the rule ACCEPTED a wrong count")
check("C4 a newest section whose clone count equals its suite count is ACCEPTED",
      clone_is_the_suite(sec_good), "the rule REJECTED a right count")
check("C4b a newest section whose clone count differs is REJECTED",
      not clone_is_the_suite(sec_wrong_clone), "the rule ACCEPTED a wrong count")

# C6 -- the FINDING COUNT, and the enumeration it counts.
#
# The count is stated in the canonical shape, and the rule compares it with
# the number of `### Fixed` entries the section carries.  The three arms
# below are the rule's own control: a right count is accepted, a wrong count
# is rejected, and a section that states no count at all is rejected -- a
# section that states no count states nothing about how many findings it
# closed.
SYN_FIX = """## [9.9.8] -- a synthetic release

### Fixed -- a thing that was broken

It was broken, and it is fixed.

### Fixed -- another thing that was broken

It was broken too.

This round closed **%d** findings.
"""
good_fix = SYN_FIX % 2
wrong_fix = SYN_FIX % 3
no_fix = SYN_FIX.replace("This round closed **2** findings.\n", "")
check("C6 a section whose finding count equals its entries is ACCEPTED",
      findings_are_derived(good_fix), "the rule REJECTED a right count")
check("C6b a section whose finding count differs is REJECTED",
      not findings_are_derived(wrong_fix), "the rule ACCEPTED a wrong count")
check("C6c a section that states no finding count is REJECTED",
      not findings_are_derived(no_fix), "the rule accepted a section with no count")

print()
print("=" * 78)
# The summary's SHAPE is part of the contract: `_verify_ledger_counts_1650.py`
# reads a check's count out of one of three shapes, and a shape it cannot read
# is a count it cannot check.  "16 checks, 0 failed, 1 skipped" is the second
# of the three.
print("%d checks, %d failed, %d skipped" % (N, len(FAILS), len(SKIPS)))
for f in FAILS:
    print("  FAIL %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))
sys.exit(1 if FAILS else 0)
