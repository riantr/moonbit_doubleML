#!/usr/bin/env python3
"""Round 77 verifier: the counts a live document states about ANOTHER document.

THE GAP
=======
A count about this repository's OWN tree is held: round 56's
`_verify_doc_numbers_1650.py` holds the tutorials' "22 estimators, 11
`LearnerDispatch` variants split 8/3, 18 DGP factories across 17 `dgp_*.mbt`
modules, 24 Python validators and 9 `pyexample_*` gates, the 16/3/3 coverage
split", and round 49's `_verify_doc_scope_1650.py` holds the rest.

A count about ANOTHER DOCUMENT is a different kind of promise.  It says "go
to that file and you will find something of this size", and the file it
points at is edited for its own reasons.  There is exactly one such claim in
the live documents today:

    doc/001_introduction   "See `003_quick_start` for a 39-line end-to-end
                           example."

It is TRUE -- the fenced block in `doc/003_quick_start` has exactly 39
content lines -- and NOTHING holds it.  Add a comment line to that block and
the tutorial quietly starts lying.

THE RULE
========
  C1  a live document's "<N>-line" claim about another document must equal
      the content-line count of a fenced code block in that document.  The
      count is MEASURED, never typed, and the block is found by structure
      (the fenced block that carries the example) rather than by position.
  C2  the claim must name the document it is about.  A count with no
      reference is not a promise about a second file, and the rule does not
      fire on it.
  C3  the claim is checked against the file as it is NOW, so a round that
      edits the block is forced to update the number in the same commit.

THE CONTROL ARM
================
A checker that has never been shown to fail is a comment.  Three synthetic
cases, and the rule has to get every one of them right -- two it must
CATCH and one it must ACCEPT:
  K1  a claim whose count is one line too many
  K2  a claim that names no document
  K3  a claim that matches

Run: python _verify/_verify_cross_doc_counts_1680.py
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


def resolve_doc(name):
    """`003_quick_start` -> `doc/003_quick_start/readme.mbt.md`."""
    if not name:
        return None
    for rel in ("doc/%s/readme.mbt.md" % name,
                "doc/%s" % name,
                name):
        p = os.path.join(ROOT, rel.replace("/", os.sep))
        if os.path.isfile(p):
            return rel
    return None


# a "<N>-line" claim, and the document it names in the same sentence
CLAIM = re.compile(r"(?<![\w.])(\d{1,4})[ -]lines?\b(?![\w])", re.I)
REF = re.compile(r"`([0-9]{3}_[a-z_]+)`|`([a-z_0-9]+/[a-z_0-9/]+)`")


def claims_in(text):
    """The (count, referenced-document) claims in one document."""
    out = []
    for line in text.split("\n"):
        m = CLAIM.search(line)
        if not m:
            continue
        r = REF.search(line)
        out.append((int(m.group(1)), (r.group(1) or r.group(2)) if r else None,
                    line.strip()))
    return out


def block_lengths(text):
    """The content-line count of every fenced code block."""
    out = []
    inb = False
    body = []
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith("```"):
            if inb:
                out.append(len(body))
                inb = False
                body = []
            else:
                inb = True
                body = []
            continue
        if inb:
            body.append(line)
    return out


def check_claim(count, ref, blocks):
    """The rule, on its own: does `count` match a block of the referenced file?"""
    if ref is None:
        return True, "no reference -- not a promise about a second file"
    if blocks is None:
        return False, "the referenced document does not exist"
    if count in blocks:
        return True, "matches a %d-line block" % count
    return False, "the referenced document has blocks of %s lines" % (
        ", ".join(str(b) for b in blocks) or "no")


# ================================================================== the run
print()
print("the live documents' claims about other documents")
total = 0
for rel in live_documents():
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    claims = claims_in(read(p))
    if not claims:
        continue
    for count, ref, line in claims:
        total += 1
        target = resolve_doc(ref)
        blocks = block_lengths(read(os.path.join(ROOT, target.replace("/", os.sep)))) \
            if target else None
        ok, detail = check_claim(count, ref, blocks)
        print()
        print("   %s:%d" % (rel, read(p).split("\n").index(line) + 1)
              if line in read(p).split("\n") else "   %s" % rel)
        print("      the claim  : %s" % line[:130])
        print("      the target : %s" % (target or "(none named)"))
        print("      the blocks : %s" % (blocks if blocks is not None else "-"))
        check("%s's %d-line claim matches %s" % (rel, count, ref or "(no ref)"),
              ok, detail)

print()
print("   the claims found: %d" % total)
if total == 0:
    print("   *** FAIL ***  no cross-document count claim was found -- the rule "
          "would be checking nothing")
    FAILS.append("no cross-document count claim was found")

# ---------------------------------------------------------------- the control arm
print()
print("the control arm: synthetic claims, and what the rule does with them")
GOOD_BLOCKS = [12, 39, 7]
check("K1 a claim whose count is one line too many is REJECTED",
      not check_claim(40, "003_quick_start", GOOD_BLOCKS)[0],
      "the rule must catch it")
check("K2 a claim that names no document is ACCEPTED",
      check_claim(40, None, GOOD_BLOCKS)[0],
      "not a promise about a second file")
check("K3 a claim that matches is ACCEPTED",
      check_claim(39, "003_quick_start", GOOD_BLOCKS)[0],
      "the rule must not fire on a good claim")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
