"""Check the two quoted QA pieces of evidence in the project's documentation.

1. The `dependencies` check's WARN evidence is quoted verbatim in the README:
     "2 declared; non-conforming: ['moonbit-community/sqlite3@0.2.4'];
      declared but unreferenced by library code: ['moonbit-community/sqlite3@0.2.4',
      'moonbitlang/async@0.22.7']"
2. The project document says the QA LOOP registers its checks "over the **22**
   required activities" -- a different 22 from the 22 fast-scope checks, and
   worth confirming it is not the same number by accident.

Round 18 split the documentation in two: `README.mbt.md` is the LIBRARY
document and `ENGINEERING.md` is the PROJECT document.  The dependency
evidence is quoted in the README's "Not covered, so not claimed" section,
because a user is entitled to see the warning the QA harness actually
raised.  The QA registry's own counts are the project's, so that check
reads `ENGINEERING.md`.

THE MEASUREMENT IS LIVE
=======================
The evidence used to be read from a TRACKED SNAPSHOT --
`_verify/_qa_fast_1639.json`, written on 2026-10-30.  The snapshot said
`sqlite3@0.2.3`; the tree declares `sqlite3@0.2.4`, and the README quotes
`0.2.4`, so the check compared a MONTH-OLD measurement with the tree and
called the tree wrong.  A tracked snapshot of a measurement is the same
class of defect as a stale literal: it rots in silence, and the day the pin
moved the check went red for a reason that had nothing to do with the
promise it holds.

The measurement is LIVE now.  The REAL harness module
(`.github/scripts/qa_loop/checks.py`) is imported and its OWN check
functions are called, so the evidence is the one the harness produces on
THIS tree.  The pins are read from the manifest the library declares, so a
pin that moves moves the check with it -- and the registry's own counts are
compared with the counts the evidence reports, instead of with a file
nobody refreshes.

Run: python _verify/_verify_qa_evidence_1639.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QA = os.path.join(ROOT, ".github", "scripts", "qa_loop")
sys.path.insert(0, QA)

README = os.path.join(ROOT, "README.mbt.md")
PROJ = os.path.join(ROOT, "ENGINEERING.md")

readme = io.open(README, encoding="utf-8").read()
proj = io.open(PROJ, encoding="utf-8").read()

try:
    import checks as C
except Exception as _e:  # noqa: BLE001
    print("  *** FAIL *** the harness module must be importable: %r" % (_e,))
    print("1 checks, 1 failed")
    print("VERDICT: FAIL")
    sys.exit(1)


def declared_pins():
    """The dependency pins the library's own manifest declares.

    DERIVED, never typed in.  `moon.mod` carries the template's example line
    inside a COMMENT, so the comments are stripped first -- a commented-out
    import is a template, not a dependency.  A pin typed into a check is a pin
    that goes stale the moment the registry publishes the next version, and the
    registry publishes one every day.
    """
    txt = io.open(os.path.join(ROOT, "moonbit_doubleML", "moon.mod"),
                  encoding="utf-8").read()
    body = "\n".join(line.split("//", 1)[0] for line in txt.split("\n"))
    return sorted(set(re.findall(r'"([^"]+@[^"]+)"', body)))


def non_conforming(pins):
    """The pins that break the dependency rule, by the harness's own rule."""
    return [p for p in pins
            if not p.startswith(("moonbitlang/", "riantr/"))]


fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


pins = declared_pins()

# ---------------------------------------------- 1. the quoted WARN evidence
# LIVE: the harness's OWN check function, called on this tree.
dep = C.c_deps()
qp = C.c_qa_process()
ev = (dep.evidence or "").strip()
print("dependencies verdict: %s" % dep.verdict)
print("dependencies evidence: %s" % ev[:400])
print("")

check("the dependencies check is WARN in the measured run",
      dep.verdict == "WARN", "got %r" % dep.verdict)

m = re.search(r"`2 declared; non-conforming:\s*\[[^\]]*\]; declared but unreferenced "
               r"by library code:\s*\[[^\]]*\]`", readme, re.S)
check("the README quotes a dependencies evidence string", m is not None)
if m:
    quoted = re.sub(r"\s+", " ", m.group(0)).strip("`")
    print("  quoted  : %s" % quoted)
    print("  measured: %s" % re.sub(r"\s+", " ", ev))
    # the quote must be a PREFIX of the real evidence, whitespace-normalised
    check("the quoted evidence is a prefix of the measured one",
          re.sub(r"\s+", " ", ev).startswith(quoted),
          "measured: %s" % ev)
    # the declared count is the manifest's own, and the evidence says so
    check("it says 2 declared",
          ("%d declared" % len(pins)) in ev and len(pins) == 2,
          "measured: %s; the manifest declares %d" % (ev, len(pins)))
    # The non-conforming pins are DERIVED from the manifest by the harness's
    # own rule, so a pin that moves cannot leave the check naming the old one.
    nc = non_conforming(pins)
    check("it names sqlite3 as non-conforming",
          bool(nc) and any("sqlite3" in p for p in nc)
          and all(p in ev for p in nc) and "non-conforming" in ev,
          "measured: %s; non-conforming: %s" % (ev, nc))
    # The expected list is DERIVED from the tree's own manifest, in the order
    # the QA harness prints it (sorted), so a pin that moves does not take the
    # check with it.
    expected = "[%s]" % ", ".join("'%s'" % p for p in pins)
    check("it names BOTH unreferenced packages, not a summary",
          ("declared but unreferenced by library code: " + expected)
          in re.sub(r"\s+", " ", ev),
          "measured: %s\nexpected: %s" % (ev, expected))
    check("the quote is not the '[both]' paraphrase",
          "[both]" not in quoted, "the README summarised the evidence")

# ------------------------------------------------- 2. the required activities
# the `qa_process` check reports both numbers itself:
#   "<N> checks registered, <M> required activities"
qp_ev = (qp.evidence or "").strip()
print("")
print("qa_process verdict : %s" % qp.verdict)
print("qa_process evidence: %s" % qp_ev)

mm = re.search(r"(\d+) checks registered, (\d+) required activities", qp_ev)
check("the qa_process check reported its two counts", mm is not None, qp_ev)
if mm:
    n_checks, n_act = int(mm.group(1)), int(mm.group(2))
    # the registry's own size, measured: the evidence and the registry must
    # agree, and the registry's size is the number the documents publish.
    check("it registered 31 checks",
          n_checks == len(C.CHECKS) == 31,
          "the evidence says %d, the registry holds %d" % (n_checks, len(C.CHECKS)))
    check("there are 22 required activities", n_act == 22, "got %d" % n_act)
    # the project document's own number, read from the document
    md = re.search(r"\*\*(\d+)\*\*\s*required activities", proj)
    check("the project document's '22 required activities' matches",
          md is not None and n_act == int(md.group(1)),
          "the harness reports %d, the document states %s"
          % (n_act, md.group(1) if md else "nothing"))

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
