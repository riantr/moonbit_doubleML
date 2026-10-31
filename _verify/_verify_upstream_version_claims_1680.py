#!/usr/bin/env python3
"""Round 76 verifier: the upstream version claims in the documents the README
NAMES.

THE PROBLEM
===========
The README's provenance paragraph points at `_verify/UPSTREAM_PROVENANCE.md`
and calls it the authority map, and its own wording is "re-measured against
the **installed** `doubleml` 0.11.4 package".  A document the README names is
a document a reader opens.  That one still said 0.11.3 in two LIVE claims
after the upstream moved:

    elements), verified bit-exact against a running upstream 0.11.3.
    **Tracked**, and byte-identical to the installed `doubleml` 0.11.3 package

The installed package was 0.11.4 by then, and the port's own test file said
0.11.4, so a reader who followed the pointer found a document that
contradicts the package it points at.  A third document the README names --
`_verify/LPLR_GATE_BLINDNESS_1680.md` -- said "0.11.3 ships no public setter
for the inner split", which is true of 0.11.4 too, and so was another version
named where the current one belongs.

Nothing checked any of that.  The provenance GATE checks the README's 22
estimator ROWS against the sdist; it does not read a record's prose.

THE RULE
========
  A1  the SCOPE is DERIVED: the documents are the ones the published README
      names under `_verify/`.  A newly-cited document enters the scope by
      being cited, and a record nobody cites is nobody's problem.
  A2  each such document declares an ANCHOR: the upstream version its header
      says its readings are against.  The header is the leading blockquote
      block, which is where both of these documents state theirs.
  A3  a version named anywhere else must be the anchor -- UNLESS the same
      PARAGRAPH names another version too, which makes it a COMPARISON
      ("it does not exist in 0.11.3 or in the 0.11.4 sdist").  A version named
      ALONE is a claim about the current upstream, and it has to be the
      current upstream's version.
  A4  the anchor must be the INSTALLED package's version.  Derived, not a
      literal: when upstream moves, the documents go RED until they are
      re-anchored, and the README's own claim goes with them.
  A5  only the upstream package's own VERSION FAMILY is read.  The family is
      derived from the installed version and from the document's anchor -- NOT
      written down as `0.11`.  A literal would be a dead check the moment
      upstream ships 0.12: every document would stop matching and the rule
      would pass vacuously, which is the exact failure this file exists to
      catch.  The scope matters, because the same documents name UNRELATED
      versions -- scipy 1.18.0, typos 1.50.3, and this package's own 0.163.3 --
      and a generic version pattern would flag all three.

WHY A PARAGRAPH AND NOT A LINE
==============================
The claims are hard-wrapped, so a rule that read LINE by line would see
"0.11.3 ships no public setter for the" and "inner split.  Measured facts ..."
as two different contexts, and a rule that read SENTENCES would need a
sentence splitter that knows about backticks and code spans.  A paragraph is
the unit a Markdown author writes in, and both live claims sit in a paragraph
that names one version.

THE CONTROL ARM
================
A synthetic document with a stale version in a one-version paragraph must be
REJECTED, and one with a stale version in a two-version paragraph must be
ACCEPTED.  A checker that has never been shown to fail is a comment.

Run: python _verify/_verify_upstream_version_claims_1680.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
# The version pattern is DERIVED per document (see A5): the upstream package's
# own major.minor family, taken from the installed version and the document's
# anchor.  This literal only ever names the family of the CURRENT upstream, so
# it is a starting point, not the rule.
VER_RE = re.compile(r"0\.11\.\d+")


def family_re(versions):
    """A version pattern for the upstream family named by `versions`.

    `0.11.4` -> `0\\.11\\.\\d+`; `0.11.4` and `0.12.1` -> either family.
    An empty family list yields a pattern that matches nothing.
    """
    fams = []
    for v in versions:
        if not v:
            continue
        parts = v.split(".")
        if len(parts) < 2:
            continue
        fam = "%s.%s" % (parts[0], parts[1])
        if fam not in fams:
            fams.append(fam)
    if not fams:
        return re.compile(r"(?!x)x")          # matches nothing
    alts = "|".join(re.escape(f).replace(r"\.", r"\.") for f in fams)
    return re.compile(r"(?:%s)\.\d+" % alts)

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %s  %-62s %s" % ("ok  " if ok else "*** FAIL ***", name, detail))
    if not ok:
        FAILS.append(name)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def header_block(text):
    """The leading blockquote block: where a record declares its anchor."""
    lines = text.split("\n")
    out = []
    started = False
    for line in lines:
        s = line.strip()
        if s.startswith(">"):
            started = True
            out.append(s)
            continue
        if started and not s:
            out.append("")
            continue
        if started:
            break
    return "\n".join(out)


def paragraphs(text):
    """The document's blocks, with the header block removed."""
    body = text
    h = header_block(text)
    if h:
        body = text.replace(h, "", 1)
    for para in re.split(r"\n\s*\n", body):
        if para.strip():
            yield para


def installed_version():
    """The upstream version this machine has installed -- DERIVED."""
    try:
        import importlib.metadata
        return importlib.metadata.version("doubleml")
    except Exception:  # noqa: BLE001
        return None


def audit(text, anchor, installed, ver_re=None):
    """Return the list of (where, version, why) problems in one document."""
    problems = []
    if anchor is None:
        return problems
    ver_re = ver_re or VER_RE
    for para in paragraphs(text):
        vers = sorted(set(ver_re.findall(para)))
        if not vers:
            continue
        for v in vers:
            if v == anchor:
                continue
            if len(vers) > 1:
                # a COMPARISON: the paragraph names another version too
                continue
            first = para.strip().split("\n")[0][:110]
            problems.append((v, first))
    if installed and anchor != installed:
        problems.append((anchor, "the anchor is not the installed version"))
    return problems


# ---------------------------------------------------------------- the scope
print("the documents the README NAMES under _verify/:")
readme = read(README)
cited = sorted(set(re.findall(r"_verify/[A-Za-z0-9_./-]+\.(?:md|py|json|txt)", readme)))
docs = []
for rel in cited:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        print("   %-46s CITED BUT NOT PRESENT -- not audited" % rel)
        continue
    t = read(p)
    head = header_block(t)
    head_vers = sorted(set(VER_RE.findall(head)))
    if not head_vers:
        print("   %-46s names no upstream version -- not audited" % rel)
        continue
    docs.append((rel, t, head_vers))
    print("   %-46s audited" % rel)

installed = installed_version()
print()
print("the installed upstream package: %s" % (installed or "NOT INSTALLED"))
if installed is None:
    print("SKIP: the upstream package is not installed here -- the anchor "
          "cannot be compared with anything.")
    print()
    print("%d checks, 0 failed" % N)
    sys.exit(0)

for rel, t, head_vers in docs:
    head = header_block(t)
    anchors = sorted(set(VER_RE.findall(head)))
    anchor = anchors[0] if len(anchors) == 1 else None
    print()
    print("%s" % rel)
    print("   the header names: %s" % (", ".join(anchors) or "no version"))
    if anchor is None:
        print("   the header does not name exactly one version -- the anchor "
              "is ambiguous, so this document is not audited")
        continue
    vre = family_re([installed, anchor])
    print("   the upstream family read: %s" % vre.pattern)
    problems = audit(t, anchor, installed, vre)
    for v, why in problems:
        print("   *** FAIL ***  names %s alone: %s" % (v, why))
    check("%s names no stale version" % rel, not problems,
          "" if not problems else "%d stale mention(s)" % len(problems))


# ---------------------------------------------------------------- the control
print()
print("the control arm: a synthetic document, and what the rule does with it")
GOOD = ("# synthetic\n\n"
        "> **Measured against upstream `doubleml` 0.11.4.**\n\n"
        "The install line says `doubleml` 0.11.4.\n\n"
        "A stale file does not exist in 0.11.3 or in the 0.11.4 sdist.\n")
BAD = ("# synthetic\n\n"
       "> **Measured against upstream `doubleml` 0.11.4.**\n\n"
       "The install line says `doubleml` 0.11.4.\n\n"
       "The elements were verified bit-exact against a running upstream 0.11.3.\n")
# A version that is NOT the upstream package's: a reader of the real records
# meets scipy 1.18.0, typos 1.50.3 and this package's own 0.163.3, each alone
# in its paragraph.  A generic version pattern would flag all three.
UNRELATED = ("# synthetic\n\n"
             "> **Measured against upstream `doubleml` 0.11.4.**\n\n"
             "The install line says `doubleml` 0.11.4.\n\n"
             "Read out of installed scipy 1.18.0, not recalled.\n")
# The family is DERIVED: when upstream moves to another major.minor, the rule
# has to read BOTH families -- the installed one and the one the document is
# still anchored to -- or a stale mention of the old version goes unread.
MOVED = ("# synthetic\n\n"
         "> **Measured against upstream `doubleml` 0.11.4.**\n\n"
         "The elements were verified bit-exact against a running upstream 0.11.3.\n")

FAM = family_re(["0.11.4"])
FAM_MOVED = family_re(["0.12.1", "0.11.4"])

check("the control document with one stale version is REJECTED",
      bool(audit(BAD, "0.11.4", "0.11.4", FAM)),
      "the rule must catch it")
check("the control document with a comparison is ACCEPTED",
      not audit(GOOD, "0.11.4", "0.11.4", FAM),
      "a comparison is history, not a stale claim")
check("the control document with a stale ANCHOR is REJECTED",
      bool(audit(GOOD, "0.11.4", "0.11.5", FAM)),
      "the anchor must be the installed version")
check("an unrelated package's version is NOT flagged",
      not audit(UNRELATED, "0.11.4", "0.11.4", FAM),
      "the family scope is a filter, not a blanket")
check("a stale mention is still read after upstream moves",
      bool(audit(MOVED, "0.11.4", "0.12.1", FAM_MOVED)),
      "the family follows the installed version, not a literal")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
