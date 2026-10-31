#!/usr/bin/env python3
"""Round 76 verifier: the claims the RECORDS make ABOUT THE README.

THE PROBLEM
===========
A record the README names can make claims about the README itself.  This
one does, in its own header:

    This is the **only** `_verify/` record the shipped `README.mbt.md` cites
    (at its lines 1162 and 1217), so every promise made here is a promise
    the README inherits.

Both halves of that were FALSE, and nothing could see it:

  * the README now cites **two** `_verify/` records, not one -- the other
    is `_verify/UPSTREAM_PROVENANCE.md`;
  * the README is **896** lines long, so "its lines 1162 and 1217" pointed
    past the end of the document.  The README cites this record at its line
    563.

The reason it rotted is structural: the README is REGENERATED every round
and the record is not.  A round that edits the README moves the lines the
record talks about, and the record keeps promising the old ones.  The
house's file:line verifier cannot see this: it checks a pointer written
IN a document, and this claim is a pointer written ABOUT one.

THE RULE
========
  R1  the records are DERIVED: the `_verify/*.md` files the published
      README cites.  A record nobody cites is nobody's problem; a record
      the README cites is a promise the README inherits.
  R2  the README's ACTUAL citation lines are derived from the README
      itself -- the lines that name a record.
  R3  a record that names README line numbers must name them CORRECTLY:
      every number it claims must be a line where the README really cites
      a record, and every line where the README really cites a record must
      be claimed by some record.  The second direction matters as much as
      the first: a record that names the wrong line and a README citation
      that nobody accounts for are the same defect seen from two sides.
  R4  a record that says how MANY records the README cites must be right:
      "the only" means one, "one of the two" means two.

THE CLAIM'S SHAPE
=================
The claim is a phrase of the form "at its line 563" or "at its lines 16,
204 and 832".  Only numbers that sit in such a phrase are line numbers:
the same header paragraph also contains "2026-10-20", "round 17", "33
commits" and "18", and none of those is a line.

THE CONTROL ARM
================
A checker that has never been shown to fail is a comment.  Five cases, and
the rule has to get every one of them right -- four it must CATCH and one
it must ACCEPT:
  C1  a claimed line where the README cites nothing
  C2  a README citation that no record claims
  C3  "the only record" claimed while the README cites two
  C4  "one of the two" claimed while the README cites three
  C5  a correct claim

Run: python _verify/_verify_record_readme_refs_1680.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")

REC_MD = re.compile(r"_verify/[A-Za-z0-9_./-]+\.md")
# "at its line 563" / "at its lines 16, 204 and 832"
CLAIMED = re.compile(r"lines?\s+((?:\d+[\s,]*(?:and\s+)?)+)")
NUMBER_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5}

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %s  %-62s %s" % ("ok  " if ok else "*** FAIL ***", name, detail))
    if not ok:
        FAILS.append("%s -- %s" % (name, detail))


def read(p):
    with io.open(p, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def paragraphs(text):
    for para in re.split(r"\n\s*\n", text):
        if para.strip():
            yield para


def unquote(para):
    """A blockquoted paragraph, without the `>` markers.

    The records write their claims inside a Markdown blockquote, and the
    marker sits between the phrase and the word that follows it:
    "**one of the two** `_verify/`\n> records the shipped README cites".
    """
    out = []
    for line in para.split("\n"):
        s = line.lstrip()
        while s.startswith(">"):
            s = s[1:].lstrip()
        out.append(s)
    return "\n".join(out)


def cited_records(readme_text):
    """The `_verify/*.md` records the README cites, with the lines it does."""
    out = {}
    for i, line in enumerate(readme_text.split("\n"), 1):
        for m in REC_MD.finditer(line):
            out.setdefault(m.group(0), []).append(i)
    return out


def claimed_lines(record_text):
    """The README line numbers a record claims, in its own words.

    Only numbers inside a "at its line(s) N, M and K" phrase count.  The
    same paragraph carries dates and counts, and those are not lines.
    """
    claimed = set()
    for para in paragraphs(record_text):
        if "README" not in para:
            continue
        for m in CLAIMED.finditer(unquote(para)):
            for n in re.findall(r"\d+", m.group(1)):
                claimed.add(int(n))
    return claimed


def claimed_count(record_text):
    """How many records the README is claimed to cite -- None if it says no.

    "the only `_verify/` record" is one; "one of the two `_verify/` records"
    is two.  The word is the record's own, and markdown emphasis around it
    (`**one of the two**`) is part of the spelling, not part of the word.
    """
    for para in paragraphs(record_text):
        if "README" not in para:
            continue
        para = unquote(para)
        if re.search(r"the\s+\*{0,2}only\*{0,2}\s+`_verify/`\s+record", para):
            return 1
        m = re.search(r"one\s+of\s+the\s+\*{0,2}(\w+)\*{0,2}\s+`_verify/`\s+records", para)
        if m:
            w = m.group(1).lower()
            if w in NUMBER_WORDS:
                return NUMBER_WORDS[w]
            if w.isdigit():
                return int(w)
    return None


# ---------------------------------------------------------------- the checks
def check_claimed(claimed, actual):
    """R3, first direction: every line the record claims must be a line
    where the README really cites a record."""
    problems = []
    for n in sorted(claimed):
        if n not in actual:
            problems.append("claims README line %d, where the README cites no record" % n)
    return problems


def check_covered(claimed, actual):
    """R3, second direction: every line where the README cites a record
    must be claimed by some record."""
    problems = []
    for n in sorted(actual):
        if n not in claimed:
            problems.append("the README cites a record at its line %d, and no record claims it" % n)
    return problems


def check_count(claimed_n, actual_n):
    """R4: the count the record states must be the count there is."""
    if claimed_n is None:
        return []
    if claimed_n != actual_n:
        return ["claims the README cites %s `_verify/` record(s), and it cites %d"
                % ("one" if claimed_n == 1 else claimed_n, actual_n)]
    return []


# ================================================================== the run
print()
print("the published README")
readme_text = read(README)
rlines = readme_text.split("\n")
actual = cited_records(readme_text)
actual_lines = set()
for rel, lines in actual.items():
    actual_lines |= set(lines)
print("   %d bytes, %d lines" % (len(readme_text.encode("utf-8")), len(rlines)))
print("   the `_verify/*.md` records it cites: %d" % len(actual))
for rel in sorted(actual):
    print("      %-46s at line(s) %s" % (rel, ", ".join(str(x) for x in actual[rel])))

print()
print("A. the claims the records make about the README")
total_claimed = set()
for rel in sorted(actual):
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(path):
        print("   *** %s is cited but NOT PRESENT" % rel)
        continue
    text = read(path)
    claimed = claimed_lines(text)
    total_claimed |= claimed
    cn = claimed_count(text)
    print()
    print("   %s" % rel)
    print("      the record claims : %s" % (", ".join(str(x) for x in sorted(claimed)) or "no lines"))
    print("      the record says   : the README cites %s `_verify/` record(s)"
          % ("no number" if cn is None else cn))
    problems = check_claimed(claimed, actual_lines)
    problems += check_count(cn, len(actual))
    for p in problems:
        print("      *** FAIL *** %s" % p)
    check("%s: its claims about the README are right" % rel,
          not problems, "" if not problems else "%d problem(s)" % len(problems))

# the union direction: no README citation may go unclaimed
problems = check_covered(total_claimed, actual_lines)
for p in problems:
    print("   *** FAIL *** %s" % p)
check("every README record citation is claimed by some record",
      not problems, "" if not problems else "%d problem(s)" % len(problems))

# ---------------------------------------------------------------- the control arm
print()
print("B. the control arm: synthetic claims, and what the rule does with them")
REAL = {16, 204, 563, 832}

check("C1 a claimed line where the README cites nothing is REJECTED",
      bool(check_claimed({1162, 1217}, REAL)),
      "the rule must catch it")
check("C2 a README citation that no record claims is REJECTED",
      bool(check_covered({16, 204, 832}, REAL)),
      "the rule must catch it")
check("C3 'the only record' claimed while the README cites two is REJECTED",
      bool(check_count(1, 2)),
      "the rule must catch it")
check("C4 'one of the two' claimed while the README cites three is REJECTED",
      bool(check_count(2, 3)),
      "the rule must catch it")
check("C5 a correct claim is ACCEPTED",
      not check_claimed(REAL, REAL) and not check_covered(REAL, REAL)
      and not check_count(2, 2),
      "the rule must not fire on a good claim")
check("C6 the count parser reads the record's own wording",
      claimed_count("> This is the **only** `_verify/` record the shipped "
                    "`README.mbt.md` cites, so every promise here is inherited.") == 1
      and claimed_count("> This is **one of the two** `_verify/` records the "
                       "shipped `README.mbt.md` cites.") == 2
      and claimed_count("> The README says nothing about records.") is None,
      "the emphasis is part of the spelling, not part of the word")
check("C7 the line-number parser ignores dates and counts",
      claimed_lines("> Re-audited 2026-10-20 (round 17). The shipped "
                    "`README.mbt.md` cites this at its lines 1162 and 1217. "
                    "33 commits have landed.") == {1162, 1217},
      "only the numbers in a 'at its line(s) ...' phrase are lines")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
