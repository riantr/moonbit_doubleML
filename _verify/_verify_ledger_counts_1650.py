#!/usr/bin/env python3
"""Round 40 verifier: the ENGINEERING banner's published check COUNTS.

WHAT THIS EXISTS FOR
====================
The ENGINEERING banner is the ledger of what each round corrected, and it
publishes a NUMBER for the checks it names --

    The new check `_verify/_verify_release_tree_1650.py` runs **34** checks

That number is a claim about the TREE, and it rots the moment the check it
names gains a check of its own.  Nothing read those numbers: the CHANGELOG
publishes its own counts and the checks that publish one assert it against
their own run, but the BANNER's numbers were asserted by nobody.  Four of
them were false when this verifier was written:

    `_verify/_verify_measurements_1650.py`     published  66, makes 70
    `_verify/_verify_release_tree_1650.py`     published  34, makes 36
    `_verify/_verify_package_claims_1650.py`   published  19, makes 48
    `_verify/_verify_score_argument_1650.py`   published 131, makes 135

The fourth is the one worth recording: it was never true.  The banner entry
that introduced the check published 19, and the check has made 48 checks since
the day it was written -- so a number that had never been measured was
published as if it had been.

THE INVARIANT
=============
  L1  a published count names the check it counts.  A count with no owner is
      not a claim about anything, and it is a hole in the ledger.
  L2  the LIVE claim for a check -- its LAST mention, the banner being
      ASCENDING -- is the number that check makes ON THIS TREE.
  L3  the CHANGELOG's newest publication of the same count agrees with the
      banner's.  The two documents are read side by side, and they must not
      contradict each other.

WHY THE LIVE CLAIM IS THE LAST MENTION
======================================
The banner lists the rounds ASCENDING (oldest first); the CHANGELOG lists them
DESCENDING.  So a check named twice in the banner has its OLD claim first and
its live claim last -- and the old one is history: the round-33 entry
corrected an earlier entry's published count in place, for the same reason
(those counts are tree-dependent by design, and a check that grows makes every
number it was ever published with false).

WHY THE COUNT IS MEASURED, NOT READ
===================================
A verifier's check count is not a literal in its source -- it is what the
checks it makes add up to.  So the count is MEASURED: the verifier is RUN and
its own summary is read.  Three summary shapes are in the contract:

    "28 checks, 0 failed"                  the common form
    "11 checks, 0 failed, 0 skipped"       the form with a skip count
    "checks run: 42" / "checks failed: 0"  the form without the word "checks"

A rule that read only one of them would under-count the others -- the
round-38 lesson, applied to the summary instead of the marker.

THE SCOPE
=========
Only the LIVE claim is checked.  The historical mentions are left alone: they
are the record of what a round measured then, and rewriting them would
falsify it.  A check the banner names WITHOUT a count is not in scope -- it
publishes nothing, so nothing can rot.

THE CONTRACT THE PROSE OWES
===========================
A count written in the "**N** checks" shape belongs to the check named
NEAREST BEFORE it -- so a count that is about a DIFFERENT check must not be
written in that shape.  This is not a subtlety: an earlier draft of the
round-40 entry ended with the sentence "that check has made **48** checks
since the day it was written", and the phrase was read as the live claim of
the check named two sentences earlier.  The check caught its own author,
which is the only reason the rule is written down here.

THERE ARE TWO SHAPES, AND THE SECOND ONE USED TO BE INVISIBLE
=============================================================
The banner writes a count about a named check in two ways: the "**N**
checks" shape, and the "published **X** and makes **Y**" shape the round-40
entry uses to record a correction.  The second shape carries no "checks"
word, so this verifier did not see it -- and the number it carried was
FALSE for the whole release it shipped in, because the check it names grew
two checks in the very round that wrote the sentence.

So the second shape is read now, and its LIVE half is the "makes" number:
the first is what the banner used to publish, which is history, exactly as
"v0.164.21's entry said ... runs **127**" is history in the CHANGELOG.
A prose claim that no check can see is a claim that rots in silence, and
silence is what let this one rot.

WHAT IS NOT CHECKED, AND WHY
============================
Whether the banner's prose about a round is accurate.  This checks the
NUMBERS a check makes against the numbers the banner publishes for it; the
narrative around them is the ledger's own business.

Run: python _verify/_verify_ledger_counts_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENG = os.path.join(ROOT, "ENGINEERING.md")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
SELF = "_verify/_verify_ledger_counts_1650.py"

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-60s %s" % ("ok" if ok else "*** FAIL ***", label, detail))
    if not ok:
        FAILS.append(label)


def read(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


NAME = re.compile(r"_verify/_verify_[A-Za-z0-9_]+\.py")
PHRASE = re.compile(r"\*\*(\d+)\*\*\s+checks?\b")

# The SECOND shape the banner uses for a count about a named check.  The
# round-40 entry records a correction as
#
#     `_verify/_verify_score_argument_1650.py` published **131** and makes
#     **135**
#
# which carries no "checks" word, so PHRASE never saw it -- and the number it
# carried was FALSE for the whole release it shipped in.  The FIRST number is
# what the banner used to publish: history, the way "entry said ... runs
# **127**" is history in the CHANGELOG.  The SECOND is what the check makes
# now, which is the LIVE claim, and it is owned like any other.
MAKES = re.compile(r"\*\*(\d+)\*\*\s+and\s+makes\s*\*\*(\d+)\*\*")

# How far back a count may look for the check it counts.  The banner's
# entries refer to checks named in an EARLIER paragraph ("The published count
# was wrong once ... It runs **135** checks on the tree as it stands"), and
# the longest such reach in the banner is under 500 characters.
WINDOW = 800


def flatten(text):
    """(text, line per character).

    The banner is a hard-wrapped quoted document: every line starts with
    "> " and a sentence can run over several lines.  The markers are stripped
    and the lines are joined, so that a number and the word "checks" it
    belongs to are found together even when a line break falls between them
    -- the round-36 lesson, applied to the ledger.
    """
    out = []
    lmap = []
    for i, ln in enumerate(text.split("\n"), 1):
        s = ln.strip()
        if s.startswith(">"):
            s = s[1:].strip()
        if out:
            out.append(" ")
            lmap.append(i)
        for ch in s:
            out.append(ch)
            lmap.append(i)
    return "".join(out), lmap


def banner():
    """The corrections ledger at the top of ENGINEERING.md.

    The body below it is the README as it stood at v0.164.11 -- a frozen
    snapshot, and not part of the ledger.
    """
    return read(ENG).split("## The README as it stood at", 1)[0]


def claims(text, lmap):
    """(name, count, line, position) for every published count.

    A count belongs to the check named NEAREST BEFORE it.  Not the nearest
    name in its own paragraph: the banner's entries are lists, and an entry
    runs on across the blank lines that separate its paragraphs -- so one
    paragraph can hold the count of a check named in the paragraph BEFORE it
    and the name of a check named after it.  The nearest name BEFORE the
    count is the one the text means; the score-argument entry is the case
    that proves it.
    """
    owned = []
    unowned = []
    names = [(m.start(), m.group(0)) for m in NAME.finditer(text)]
    for m in PHRASE.finditer(text):
        n = int(m.group(1))
        line = lmap[m.start()]
        before = [t for t in names if t[0] < m.start()]
        if not before:
            unowned.append((n, line, 0))
            continue
        best = before[-1]
        reach = m.start() - best[0]
        if reach > WINDOW:
            unowned.append((n, line, reach))
            continue
        owned.append((best[1], n, line, m.start()))
    for m in MAKES.finditer(text):
        # The live half of the pair: what the check makes NOW.
        n = int(m.group(2))
        line = lmap[m.start()]
        before = [t for t in names if t[0] < m.start()]
        if not before:
            unowned.append((n, line, 0))
            continue
        best = before[-1]
        reach = m.start() - best[0]
        if reach > WINDOW:
            unowned.append((n, line, reach))
            continue
        owned.append((best[1], n, line, m.start()))
    return owned, unowned


def live_count(name):
    """(count, how, exit code) -- the number the named verifier makes here.

    The verifier is RUN: a check count is what its checks add up to, so it
    cannot be read from the source.
    """
    path = os.path.join(ROOT, name.replace("/", os.sep))
    if not os.path.isfile(path):
        return None, "the file is not in the tree", None
    try:
        p = subprocess.run([sys.executable, path], cwd=ROOT, capture_output=True,
                           text=True, encoding="utf-8", errors="replace",
                           timeout=900)
    except subprocess.TimeoutExpired:
        return None, "the verifier did not finish in 900s", None
    out = (p.stdout or "") + (p.stderr or "")
    m = re.findall(r"(\d+)\s+checks,\s*(\d+)\s+failed", out)
    if m:
        return int(m[-1][0]), "the 'N checks, M failed' form", p.returncode
    m = re.findall(r"checks run:\s*(\d+)", out)
    if m:
        return int(m[-1]), "the 'checks run: N' form", p.returncode
    return None, "no summary line in its output", p.returncode


# A mention that REPORTS ANOTHER entry's number is not a publication of this
# check's count -- it is a note about the past ("v0.164.21's entry said
# `_verify/_verify_score_argument_1650.py` runs **127**").  The CHANGELOG
# carries both shapes, and only the publication is live.
ENTRY_REF = re.compile(r"entry(?:'s| said| says| published)")


def changelog_live(name):
    """(count, line) -- the count the CHANGELOG publishes for a check.

    The CHANGELOG is DESCENDING, so the newest publication is the first one
    found.  A mention that reports another entry's number is skipped: it is
    a correction note, not a publication.
    """
    text = read(CHANGELOG)
    for m in re.finditer(re.escape(name), text):
        before = text[max(0, m.start() - 80):m.start()]
        if ENTRY_REF.search(before):
            continue
        tail = text[m.end():m.end() + 200]
        cm = PHRASE.search(tail)
        if cm:
            return int(cm.group(1)), text.count("\n", 0, m.start()) + 1
    return None, None


print("=" * 78)
print("A. the banner's published counts")
print("=" * 78)

eng_raw = banner()
check("the ENGINEERING banner is findable", bool(eng_raw.strip()),
      "%d characters" % len(eng_raw))

eng, lmap = flatten(eng_raw)
owned, unowned = claims(eng, lmap)
check("every published count names the check it counts",
      not unowned,
      "; ".join("**%d** at L%d" % (n, l) for n, l, _r in unowned[:4])
      if unowned else "%d counts, all owned" % len(owned))

# the LIVE claim for a check is its LAST mention: the banner is ascending.
live = {}
for name, n, line, pos in owned:
    if name not in live or pos >= live[name][2]:
        live[name] = (n, line, pos)

print("  checks the banner publishes a count for: %d" % len(live))
for name in sorted(live, key=lambda k: live[k][1]):
    print("    %-52s %4d   L%d" % (name.replace("_verify/_verify_", ""),
                                   live[name][0], live[name][1]))

# ==============================================================================
print()
print("=" * 78)
print("B. the live claim is the number the check makes")
print("=" * 78)

for name in sorted(live, key=lambda k: live[k][1]):
    stated, line, _pos = live[name]
    short = name.replace("_verify/_verify_", "")
    if name == SELF:
        # this verifier IS the run: its count is this run's own.
        continue
    count, how, _rc = live_count(name)
    if count is None:
        check("%-52s runs and reports a count" % short, False, how)
        continue
    check("%-52s publishes %d and makes %d" % (short, stated, count),
          stated == count,
          "the banner says %d, the check makes %d (%s)" % (stated, count, how)
          if stated != count else "read from %s" % how)

# ==============================================================================
print()
print("=" * 78)
print("C. the CHANGELOG and the banner do not contradict each other")
print("=" * 78)

for name in sorted(live, key=lambda k: live[k][1]):
    stated, _line, _pos = live[name]
    short = name.replace("_verify/_verify_", "")
    newest, where = changelog_live(name)
    if newest is None:
        check("%-52s is published in the CHANGELOG" % short, True,
              "the CHANGELOG publishes no count for it")
        continue
    check("%-52s publishes the same count in both" % short,
          newest == stated,
          "the CHANGELOG says %d (L%d), the banner says %d"
          % (newest, where, stated) if newest != stated else "both say %d" % newest)

# ==============================================================================
print()
print("=" * 78)
print("D. this verifier's own published counts")
print("=" * 78)
# The CHANGELOG publishes this verifier's count, and the banner publishes it
# too.  Both are live claims, and both are checked here: the CHANGELOG's
# against the count this run makes, and the banner's against the same.
_found = re.findall(r"_verify_ledger_counts_1650\.py` \(\*\*(\d+)\*\* checks\)",
                    read(CHANGELOG))
published = int(_found[0]) if _found else None
# The total this run will report: the checks made so far, plus the three in
# this section.  It is computed ONCE, because the checks below increment the
# counter as they go.
_expected = NCHECK + 3
check("the CHANGELOG publishes this verifier's check count",
      published is not None,
      "the '(**N** checks)' line for this verifier is absent" if published is None
      else "published %d (of %d occurrences, newest first)" % (published, len(_found)))
check("the published check count is the count this run makes",
      published is not None and published == _expected,
      "published %s, this run makes %d" % (published, _expected))

# The banner's claim for THIS check is the same number, and it is checked
# against this run as well -- the banner is the other place the number is
# published, and a number nothing checks is a number that rots silently.
_self_live = live.get(SELF)
if _self_live is None:
    check("the banner publishes this verifier's count", False,
          "the banner does not name %s with a count" % SELF)
else:
    check("the banner publishes this verifier's count",
          _self_live[0] == _expected,
          "the banner says %d, this run makes %d" % (_self_live[0], _expected))

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
