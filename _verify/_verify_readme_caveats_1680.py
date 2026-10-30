#!/usr/bin/env python3
"""Hold the README's CAVEATS -- the two promises about itself nobody held.

WHY THIS EXISTS
===============
Round 72 corrected three passages that had gone out of date.  One of them
(the vectorised surface) has its own verifier,
`_verify/_verify_vectorised_surface_1680.py`.  The other TWO are prose, and
until this file NOTHING held them -- which is the point: prose that no
verifier reads is prose that rots in silence, and one of these two had ALREADY
rotted once.

  CAVEAT 1 -- THE OPENING PARAGRAPH'S API-SHAPE CAVEAT.
  It read: "Delivers one `DoubleMLXxx::new(...).fit()` API across all 22
  estimators".  Six of those constructors differ, and the README says so --
  eleven lines further down, in the Features list, and again in the API
  reference's constructor table.  The opening paragraph did not.

  This is not a new concern.  ENGINEERING.md's round-22 ledger records that
  round 22 corrected "a claim that one API shape covered all 22 estimators
  when six constructors differ" -- and round 48's condensation dropped the
  caveat from the opening paragraph AGAIN, while keeping it in the Features
  list.  A correction that has to be made twice is a correction that needs a
  holder, not another round's memory.

  CAVEAT 2 -- WHERE THE CURRENT GATE COMMANDS LIVE.
  The Development section said the test suite, the Python cross-checks, the QA
  harness and the reproducibility commands "are all documented in
  `ENGINEERING.md`".  They are -- but `ENGINEERING.md`'s BODY is this README
  as it stood at `v0.164.11`, word for word (it says so in its own header),
  so a reader sent there for the CURRENT commands is sent to a snapshot.  The
  live ones are in `.github/workflows/check.yml` and
  `.github/scripts/qa_loop/`, and the section now says so.

WHAT IS CHECKED
===============
  C1  the opening paragraph states the API as a SHAPE and names the
      constructor caveat -- the unqualified sentence must be gone;
  C2  the Features list states the same caveat, so the two agree;
  C3  the "six" the prose names is the SIX the API reference's own
      constructor table lists (the rows that are not "the other 16");
  C4  the Development section says what `ENGINEERING.md` IS, and the version
      it names is the version `ENGINEERING.md` names for itself;
  C5  the Development section names the LIVE gate sources, and both paths
      exist in the tree;
  C6  the stale promise -- that the gate commands "are all documented in
      `ENGINEERING.md`" -- is gone.

ONE VERIFIER PER FACT
=====================
The constructor SET is owned by `_verify/_verify_ctor_options_1650.py`, which
derives it from the package's own signatures and compares the README's table
against it.  This file does NOT re-derive it: it checks that the README
STATES the caveat, and that the number it states is the number the README's
own table lists.  Two verifiers must not disagree about one file.

Run: python _verify/_verify_readme_caveats_1680.py
"""
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

README = os.path.join(ROOT, "README.mbt.md")
LEDGER = os.path.join(ROOT, "ENGINEERING.md")

N = 0
FAILS = []


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %-62s %s" % (name[:62], "OK" if ok else "*** FAIL ***"))
    if not ok:
        FAILS.append(name)
        if detail:
            print("        %s" % detail)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


readme = read(README)
flat = re.sub(r"\s+", " ", readme)
ledger = read(LEDGER)

# --------------------------------------------------------- caveat 1: the shape
print("=== caveat 1: the opening paragraph's API-shape caveat ===")

# the opening paragraph: the one that says "Delivers one ... API".
# BOUNDED to the paragraph.  A fixed character window bleeds into the Features
# list -- which states the same caveat -- and then a broken opening paragraph
# reads as a correct one.
lines = readme.split("\n")
opening = ""
for i, l in enumerate(lines):
    if "Delivers one" in l:
        para = []
        for l2 in lines[i:]:
            if not l2.strip():
                break
            para.append(l2.strip())
        opening = " ".join(para)
        break
check("the opening paragraph was found", bool(opening))

# the Features list, bounded the same way
features = ""
f = re.search(r"## Features\n(.*?)(?=\n## )", readme, re.S)
if f:
    features = re.sub(r"\s+", " ", f.group(1))

check("the opening paragraph calls it an API SHAPE, not an unqualified API",
      "API shape" in opening,
      "the opening paragraph no longer says 'API shape'")
check("the opening paragraph names the constructor caveat",
      "different constructor" in opening,
      "the opening paragraph no longer names the six constructors that differ")
check("the opening paragraph points at the API reference for them",
      "**API reference**" in opening,
      "the opening paragraph no longer points at **API reference**")

check("the Features list states the same caveat",
      "six in their constructors" in features,
      "the Features list no longer states the constructor caveat")

# the API reference's CONSTRUCTOR table -- the one whose header names the
# three cross-fitting options.  Scoped by its header row, because the API
# reference holds three tables and the learner table has four columns too.
lines = readme.split("\n")
hdr = None
for i, l in enumerate(lines):
    if l.startswith("| estimators | `n_folds` |"):
        hdr = i
        break
check("the API reference's constructor table was found", hdr is not None)
named = []
if hdr is not None:
    for l in lines[hdr + 2:]:
        if not l.startswith("|"):
            break
        cells = [c.strip() for c in l.strip().strip("|").split("|")]
        if not cells or cells[0].startswith("the other"):
            continue
        named += [w.strip(" `") for w in cells[0].split(",") if w.strip(" `")]
check("the constructor table lists the estimators whose constructor differs",
      len(named) > 0, "no constructor table rows were found")
check("the prose's 'six' is the table's own count",
      ("six" in opening) and len(named) == 6,
      "the table lists %d: %s" % (len(named), ", ".join(named)))

# --------------------------------------------------------- caveat 2: the pointer
print()
print("=== caveat 2: where the current gate commands live ===")

d = re.search(r"## Development\n(.*?)(?=\n## |\Z)", readme, re.S)
dev = d.group(1) if d else ""
check("the Development section was found", bool(dev))
devflat = re.sub(r"\s+", " ", dev)

check("the Development section names ENGINEERING.md", "`ENGINEERING.md`" in devflat)
check("it says ENGINEERING.md's body is a SNAPSHOT, not the current text",
      "snapshot" in devflat or "stood at" in devflat,
      "the section no longer says the body is a snapshot")

# the version: the README's claim must match ENGINEERING.md's own statement.
# The ledger's header is a blockquote, so the version is preceded by "> ".
mver = re.search(r"stood at[^`]*`(v[\d.]+)`", devflat)
mled = re.search(r"stood at[^`]*`(v[\d.]+)`", re.sub(r"\s+", " ", ledger))
check("the section names the snapshot version", mver is not None)
check("that version is the one ENGINEERING.md names for itself",
      mver is not None and mled is not None and mver.group(1) == mled.group(1),
      "README says %s, ENGINEERING.md says %s"
      % (mver.group(1) if mver else None, mled.group(1) if mled else None))

for path in (".github/workflows/check.yml", ".github/scripts/qa_loop/"):
    check("the section names %s" % path, path in devflat)
    check("%s exists in the tree" % path,
          os.path.exists(os.path.join(ROOT, path.replace("/", os.sep))))

check("the stale promise is gone: the gate commands are not 'all documented "
      "in `ENGINEERING.md`'",
      "are all documented in `ENGINEERING.md`" not in devflat,
      "the section still promises that ENGINEERING.md documents the gate "
      "commands")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)
print("ALL PASS")
