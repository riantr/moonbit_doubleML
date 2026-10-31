#!/usr/bin/env python3
"""Round 77 verifier: the brackets in the LIVE documents' prose.

THE GAP
=======
Round 76 found a bracket that does not close -- "`P(y = 1 | x]`" -- and fixed
it, TWICE, in the README.  It did not fix the THIRD occurrence, and the third
occurrence is in a document a coding agent reads before it writes a line
against this library:

    skills/moonbit_doubleML.md

        because it models `E[y | x]`, not `P(y = 1 | x]`.

The fix was applied to the README because the README is GENERATED, and the
README's copy lives in `_verify/_r18_build_readme_1650.py` as a patch.  The
SKILL is a plain document: it is edited in place, and nobody was looking at it.
The house's own rule -- "when a tracked verifier is wrong, fix the verifier,
not the README" -- has a companion here: when a tracked verifier is MISSING,
fix the tree, and then write the verifier that holds it.

Nothing in this repository held the bracket, so the third copy survived a
release that announced the removal of the first two.

THE RULE
========
  B1  the SCOPE is the LIVE documents -- the same derivation the round's
      other two checks use: both README copies, the six tutorials under
      `doc/`, the agent skill, and the example service's own README.  The
      FROZEN SNAPSHOT in `ENGINEERING.md` is deliberately out of scope: it is
      the record of what the README said at v0.164.11, and a snapshot is not
      rewritten.
  B2  an INLINE CODE SPAN -- a backticked span in prose -- must not OPEN a
      bracket and leave it unclosed.  A span that opens a bracket and never
      closes it is the defect round 76 fixed twice.  The rule is about an
      UNCLOSED opening bracket, NOT about the two counts being equal: a shell
      pattern such as `case "$line" in *PASS*)` closes a bracket it never
      opened, and that is legitimate prose -- two live documents say exactly
      that, and a rule that flagged them would be wrong in the same way the
      hazard table's rule was.
  B3  FENCED CODE BLOCKS are out of scope: code legitimately contains
      unbalanced brackets, and this rule is about PROSE.
  B4  a code span in CommonMark may CROSS A LINE BREAK, so the prose is read
      as ONE body and the spans are paired across it -- the same rule the
      ledger-counts verifier reads the banner with.  A rule that read line by
      line would look at 842 of the README's 846 spans and miss four.
  B5  the prose's backticks must PAIR UP.  An odd count is an unclosed span,
      and a document whose spans cannot be paired cannot be audited at all.
  B6  the rule must have LOOKED at something.  After the fix the live
      documents carry no such span, and that is the DESIRED state -- so the
      check is that the scan read a real number of spans, not that it found a
      defect.  A rule that can only be satisfied by a defect is a rule that
      wants the tree to be broken.

THE CONTROL ARM
================
A checker that has never been shown to fail is a comment.  Six synthetic
cases, and the rule has to get every one of them right -- three it must
CATCH and three it must ACCEPT:

  D1  a span with an unclosed round bracket
  D2  a span with an unclosed square bracket
  D3  a span inside a fenced code block
  D4  a balanced span
  D5  a span that CLOSES a bracket it never opened -- the shell pattern two
      live documents use -- which is prose, not a defect
  D6  prose whose backticks do NOT pair up

Run: python _verify/_verify_live_doc_brackets_1680.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

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


def live_documents():
    """The documents a reader is pointed at.  DERIVED, not typed."""
    docs = ["README.mbt.md",              # the README the repository presents
            "moonbit_doubleML/README.mbt.md",   # the one the registry SERVES
            "skills/moonbit_doubleML.md",
            "examples/api_server/README.md"]
    docdir = os.path.join(ROOT, "doc")
    if os.path.isdir(docdir):
        for d in sorted(os.listdir(docdir)):
            p = os.path.join("doc", d, "readme.mbt.md")
            if os.path.isfile(os.path.join(ROOT, p.replace("/", os.sep))):
                docs.append(p.replace(os.sep, "/"))
    return docs


FENCE = "`" * 3
SPAN = re.compile(r"`([^`]*)`", re.S)


def prose_body(text):
    """The prose, with the fenced code blocks removed.

    A code span in CommonMark may cross a line break, so the prose is read as
    ONE body: the spans are then paired across it, and a rule that read line
    by line would look at 842 of the README's 846 spans and miss four.
    """
    out = []
    inb = False
    for line in text.split("\n"):
        if line.strip().startswith(FENCE):
            inb = not inb
            continue
        if inb:
            continue
        out.append(line)
    return "\n".join(out)


def code_spans(body):
    """(line, span) for every inline code span in the prose."""
    out = []
    pos = 0
    line = 1
    for m in SPAN.finditer(body):
        line += body.count("\n", pos, m.start())
        out.append((line, m.group(1)))
        pos = m.start()
    return out


def pairs_up(body):
    """The prose's backticks pair up: an odd count is an unclosed span."""
    return body.count("`") % 2 == 0


def unbalanced(span):
    """The brackets this span OPENS and never closes.

    A closing bracket with no opening one is NOT a defect: the shell
    patterns `case "$line" in *PASS*)` and the like close a bracket the
    shell opened.  Only an OPENING bracket that is never closed is.
    """
    bad = []
    if span.count("(") > span.count(")"):
        bad.append("(")
    if span.count("[") > span.count("]"):
        bad.append("[")
    return bad


def audit(body):
    """(line, span, brackets) for every unbalanced span in one body."""
    out = []
    for ln, span in code_spans(body):
        bad = unbalanced(span)
        if bad:
            out.append((ln, span, bad))
    return out


# ================================================================== the run
print()
print("the live documents")
docs = live_documents()
for rel in docs:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if os.path.isfile(p):
        print("   %-44s %7d bytes" % (rel, os.path.getsize(p)))

print()
print("A. the brackets in the live documents")
total_spans = 0
for rel in docs:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    body = prose_body(read(p))
    spans = code_spans(body)
    problems = audit(body)
    total_spans += len(spans)
    check("%s's backticks pair up" % rel, pairs_up(body),
          "%d backtick(s)" % body.count("`"))
    for ln, span, bad in problems:
        print("      *** FAIL *** %s:%d  %r  -- %s never closes"
              % (rel, ln, span, " and ".join(bad)))
    check("%s has no unbalanced bracket in a code span" % rel,
          not problems,
          "%d span(s) read, %d unbalanced" % (len(spans), len(problems)))

print()
print("   the inline code spans the rule read: %d" % total_spans)
if total_spans == 0:
    print("   *** FAIL ***  the rule read no inline code span at all -- it "
          "would be checking nothing")
    FAILS.append("the rule read no inline code span")

# ---------------------------------------------------------------- the control arm
print()
print("B. the control arm: synthetic prose, and what the rule does with it")
OPEN_ROUND = "The accessor is `coef( and the other is `se()`.\n"
OPEN_SQUARE = "The slot is `x[0 and the other is `y[0]`.\n"
FENCED = "```moonbit\nlet x = foo(\n```\n"
BALANCED = "The accessors are `coef()`, `se()`, `confint()` and `x[0]`.\n"
CLOSED_ONLY = "The CI step greps for it with `case \"$line\" in *PASS*)`.\n"
ODD_BACKTICK = "The accessor is `coef() and the other is `se()`.\n"

check("D1 a span with an unclosed round bracket is REJECTED",
      bool(audit(prose_body(OPEN_ROUND))), "the rule must catch it")
check("D2 a span with an unclosed square bracket is REJECTED",
      bool(audit(prose_body(OPEN_SQUARE))), "the rule must catch it")
check("D3 a span inside a fenced code block is NOT flagged",
      not audit(prose_body(FENCED)), "code may hold unbalanced brackets")
check("D4 a balanced span is ACCEPTED",
      not audit(prose_body(BALANCED)), "the rule must not fire on good prose")
check("D5 a span that closes a bracket it never opened is ACCEPTED",
      not audit(prose_body(CLOSED_ONLY)), "a shell pattern is prose, not a defect")
check("D6 prose whose backticks do not pair up is REJECTED",
      not pairs_up(prose_body(ODD_BACKTICK)), "the spans cannot be paired at all")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
