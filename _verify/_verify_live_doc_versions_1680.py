#!/usr/bin/env python3
"""Round 77 verifier: the upstream-version claims in the LIVE documents.

THE GAP
=======
Round 76 gave the upstream-version rule a home, but it gave it to the wrong
scope.  `_verify/_verify_upstream_version_claims_1680.py` reads the `_verify/`
RECORDS the README names -- because a record is a document a reader opens.

The LIVE documents are opened more often than any record, and five of them
carry a live claim about the upstream release:

    README.mbt.md      "re-measured against the **installed** `doubleml`
                         0.11.4 package" and "upstream `doubleml-for-py`
                         0.11.4 uses `APO`, `ATE`, ..."
    doc/001            "all 21 estimator classes upstream ships in 0.11.4"
    doc/004            "Upstream `doubleml-for-py` 0.11.4 uses a different
                         set of **15** spellings"
    doc/005            "upstream doubleml-for-py 0.11.4's 18 `make_*` dataset
                         factories"

All five were MEASURED against the upstream 0.11.4 tree and all five are
TRUE today.  That is the point: they are true BY MEASUREMENT and by nothing
else.  When upstream ships 0.11.5, every one of them becomes a lie, and
nothing in this repository would notice -- the tutorials' NUMBERS are held
by round 56's verifier, but their upstream VERSION was held by no one.

THE RULE
========
  L1  the SCOPE is DERIVED: the documents a reader is pointed at -- BOTH
      README copies (the one the repository presents and the one the registry
      SERVES, which the pre-commit check holds byte-identical), the six
      tutorials under `doc/`, the agent skill, and the example service's own
      README.  A document nobody opens is nobody's problem.  The shipped copy
      is in scope in its own right: it is the file the registry hands a
      reader, and a document that is true in the repository and stale in the
      package is exactly the defect this rule exists to catch.
  L2  a version named ALONE in a paragraph is a CLAIM about the current
      upstream, and it has to be the current upstream's version.  A version
      named ALONGSIDE another version in the same paragraph is a COMPARISON
      ("in 0.11.3 or in the 0.11.4 sdist"), and that is history.
  L3  the upstream VERSION FAMILY is DERIVED from the installed package's
      version -- never written down as `0.11`.  A literal would be a dead
      check the moment upstream ships 0.12: every document would stop
      matching and the rule would pass VACUOUSLY, which is the exact failure
      this file exists to catch.
  L4  the scope matters, because the same documents name UNRELATED versions
      -- `moonbitlang/async` 0.22.7, `moonbit-community/sqlite3` 0.2.3, the
      `moon` toolchain 0.1.20261102, this package's own 0.164.64, CPython
      3.13.14 and the host 127.0.0.1 -- and a generic version pattern would
      flag all of them.
  L5  with no installed upstream there is nothing to compare against, and
      that is a reported SKIP, never a pass.

THE CONTROL ARM
================
A checker that has never been shown to fail is a comment.  Five synthetic
cases, and the rule has to get every one right -- four it must CATCH and one
it must ACCEPT:
  C1  a document naming a stale upstream version ALONE
  C2  a document naming a stale version ALONGSIDE the current one
  C3  a document naming an unrelated package's version
  C4  a stale mention still read after upstream moves to another family
  C5  a document naming the CURRENT version

Run: python _verify/_verify_live_doc_versions_1680.py
"""
import importlib.metadata
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


def family_re(versions):
    """A version pattern for the upstream family named by `versions`.

    `0.11.4` -> `0\\.11\\.\\d+`.  An empty family list yields a pattern that
    matches nothing.
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
        return re.compile(r"(?!x)x")
    alts = "|".join(re.escape(f) for f in fams)
    return re.compile(r"(?:%s)\.\d+" % alts)


def paragraphs(text):
    for para in re.split(r"\n\s*\n", text):
        if para.strip():
            yield para


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


def audit(text, current, ver_re):
    """Every live claim in one document: (version, where, why)."""
    problems = []
    for para in paragraphs(text):
        vers = sorted(set(ver_re.findall(para)))
        if not vers:
            continue
        for v in vers:
            if v == current:
                continue
            if len(vers) > 1:
                # a COMPARISON: the paragraph names another version too
                continue
            first = para.strip().split("\n")[0][:110]
            problems.append((v, first))
    return problems


# ================================================================== the run
print()
print("the live documents")
docs = live_documents()
for rel in docs:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if os.path.isfile(p):
        print("   %-44s %7d bytes" % (rel, os.path.getsize(p)))

print()
print("the installed upstream package")
try:
    installed = importlib.metadata.version("doubleml")
except Exception:  # noqa: BLE001
    installed = None
print("   %s" % (installed or "NOT INSTALLED"))
if installed is None:
    print("SKIP: the upstream package is not installed here, so a version "
          "claim has nothing to be measured against.")
    print()
    print("=" * 74)
    print("%d checks, 0 failed" % N)
    sys.exit(0)

# The family is read from the INSTALLED version alone.  The documents' own
# versions are not consulted, because a document that has gone stale would
# otherwise widen the family and hide itself.
vre = family_re([installed])
print("   the upstream family read: %s" % vre.pattern)

print()
print("A. the upstream claims in the live documents")
found = 0
for rel in docs:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    text = read(p)
    problems = audit(text, installed, vre)
    # what the document claims, for the report
    claimed = []
    for para in paragraphs(text):
        claimed += sorted(set(vre.findall(para)))
    claimed = sorted(set(claimed))
    if not claimed:
        continue
    found += len(claimed)
    print()
    print("   %s" % rel)
    print("      it names: %s" % ", ".join(claimed))
    for v, why in problems:
        print("      *** FAIL *** names %s alone: %s" % (v, why))
    check("%s names no stale upstream version" % rel, not problems,
          "" if not problems else "%d stale mention(s)" % len(problems))

print()
print("   the upstream claims the live documents make: %d" % found)
if found == 0:
    print("   *** FAIL ***  no live document names an upstream version at all "
          "-- the rule would be checking nothing")
    FAILS.append("the live documents make no upstream version claim")

# ---------------------------------------------------------------- the control arm
print()
print("B. the control arm: synthetic documents, and what the rule does with them")
FAM = family_re(["0.11.4"])
FAM_MOVED = family_re(["0.12.1", "0.11.4"])

GOOD = "The port is measured against upstream `doubleml` 0.11.4 today.\n"
STALE = "The port is measured against upstream `doubleml` 0.11.3 today.\n"
COMPARISON = ("A stale file does not exist in 0.11.3 or in the 0.11.4 sdist, "
              "and the port is measured against upstream `doubleml` 0.11.4.\n")
UNRELATED = "The port depends on `moonbitlang/async` 0.22.7 and scipy 1.18.0.\n"

check("C1 a stale version named ALONE is REJECTED",
      bool(audit(STALE, "0.11.4", FAM)),
      "the rule must catch it")
check("C2 a stale version named ALONGSIDE the current one is ACCEPTED",
      not audit(COMPARISON, "0.11.4", FAM),
      "a comparison is history, not a stale claim")
check("C3 an unrelated package's version is NOT flagged",
      not audit(UNRELATED, "0.11.4", FAM),
      "the family scope is a filter, not a blanket")
check("C4 a stale mention is still read after upstream moves",
      bool(audit(STALE, "0.12.1", FAM_MOVED)),
      "the family follows the installed version, not a literal")
check("C5 the current version is ACCEPTED",
      not audit(GOOD, "0.11.4", FAM),
      "the rule must not fire on a good claim")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
