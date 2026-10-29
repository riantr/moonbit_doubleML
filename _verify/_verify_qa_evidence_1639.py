"""Check the two quoted QA pieces of evidence in the project's documentation.

1. The `dependencies` check's WARN evidence is quoted verbatim in the README:
     "2 declared; non-conforming: ['moonbit-community/sqlite3@0.2.3'];
      declared but unreferenced by library code: [both]"
2. The project document says the QA LOOP registers its checks "over the **22**
   required activities" -- a different 22 from the 22 fast-scope checks, and
   worth confirming it is not the same number by accident.

Round 18 split the documentation in two: `README.mbt.md` is the LIBRARY
document and `ENGINEERING.md` is the PROJECT document.  The dependency
evidence is quoted in the README's "Not covered, so not claimed" section,
because a user is entitled to see the warning the QA harness actually
raised.  The QA registry's own counts are the project's, so that check
reads `ENGINEERING.md`.
"""
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QA_FAST = os.path.join(ROOT, "_verify", "_qa_fast_1639.json")
CHECKS = os.path.join(ROOT, ".github", "scripts", "qa_loop", "checks.py")
README = os.path.join(ROOT, "README.mbt.md")
PROJ = os.path.join(ROOT, "ENGINEERING.md")

readme = io.open(README, encoding="utf-8").read()
proj = io.open(PROJ, encoding="utf-8").read()
data = json.load(io.open(QA_FAST, encoding="utf-8"))
runs = data.get("runs", [])
measured = {c.get("id"): c for c in (runs[0] if runs else [])}

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# ---------------------------------------------- 1. the quoted WARN evidence
dep = measured.get("dependencies", {})
print("dependencies verdict: %s" % dep.get("verdict"))
print("dependencies evidence: %s" % (dep.get("evidence") or "")[:400])
print("")

ev = (dep.get("evidence") or "").strip()
check("the dependencies check is WARN in the measured run",
      dep.get("verdict") == "WARN", "got %r" % dep.get("verdict"))

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
    check("it says 2 declared", "2 declared" in ev, "measured: %s" % ev)
    check("it names sqlite3 as non-conforming",
          "moonbit-community/sqlite3@0.2.3" in ev and "non-conforming" in ev,
          "measured: %s" % ev)
    check("it names BOTH unreferenced packages, not a summary",
          "declared but unreferenced by library code: "
          "['moonbit-community/sqlite3@0.2.3', 'moonbitlang/async@0.22.6']"
          in re.sub(r"\s+", " ", ev),
          "measured: %s" % ev)
    check("the quote is not the '[both]' paraphrase",
          "[both]" not in quoted, "the README summarised the evidence")

# ------------------------------------------------- 2. the required activities
# the `qa_process` check reports both numbers itself:
#   "<N> checks registered, <M> required activities"
qp = measured.get("qa_process", {})
qp_ev = (qp.get("evidence") or "").strip()
print("")
print("qa_process verdict : %s" % qp.get("verdict"))
print("qa_process evidence: %s" % qp_ev)

mm = re.search(r"(\d+) checks registered, (\d+) required activities", qp_ev)
check("the qa_process check reported its two counts", mm is not None, qp_ev)
if mm:
    n_checks, n_act = int(mm.group(1)), int(mm.group(2))
    check("it registered 31 checks", n_checks == 31, "got %d" % n_checks)
    check("there are 22 required activities", n_act == 22, "got %d" % n_act)
    check("the project document's '22 required activities' matches",
          re.search(r"\*\*22\*\*\s*\n?required activities", proj) is not None
          or "**22**\nrequired activities" in proj
          or re.search(r"over the \*\*22\*\*\s*required activities", proj) is not None,
          "the project document's phrase was not found")

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
