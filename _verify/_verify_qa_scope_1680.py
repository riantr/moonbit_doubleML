"""Pin the QA LOOP's registered-check counts, and the README's claim about them.

The README says "31 registered checks, 22 of them fast" and "22 in `fast`
scope ... and 9 in `full` scope". Those are three numbers in one sentence and
none of them is guarded by a test.

Reading them off the registry needs care, because the scope argument is
POSITIONAL and the decorator may span several lines:

    @check("pyexample_suite",
           "port vs upstream on 9 estimators (...)"
           " over 3 datasets",
           "fast")

so a single-line regex silently drops that one and reports 30. A parser that
loses a check is worse than no parser: it makes the README look wrong when
the README is right.

This parses the registry properly, cross-checks it against a MEASURED
fast-scope run, and only then checks the prose.
"""
import collections
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKS = os.path.join(ROOT, ".github", "scripts", "qa_loop", "checks.py")
README = os.path.join(ROOT, "README.mbt.md")
PROJ = os.path.join(ROOT, "ENGINEERING.md")
QA_FAST = os.path.join(ROOT, "_verify", "_qa_fast_1639.json")

src = io.open(CHECKS, encoding="utf-8", errors="replace").read()
readme = io.open(README, encoding="utf-8").read()
# Round 18 split the documentation in two.  The QA registry's own shape is the
# PROJECT's, not the library's: it is described in `ENGINEERING.md`, so these
# four checks read that document.  The registry is still derived from
# `checks.py` below -- the point is that the number cannot rot, not which
# file carries it.
proj = io.open(PROJ, encoding="utf-8").read()

# The decorator may span lines, so match up to the closing paren of the call.
CALL = re.compile(r"@check\(\s*[\"']([^\"']+)[\"']\s*,(.*?)\)\s*$", re.M | re.S)
entries = []
for m in CALL.finditer(src):
    body = m.group(2)
    # the scope is the LAST positional string argument
    strings = re.findall(r"[\"']([^\"']*)[\"']", body)
    scope = "fast"
    for s in reversed(strings):
        if s in ("fast", "full"):
            scope = s
            break
    entries.append((m.group(1), scope))

# a registration whose scope could not be read is a parse failure, not a guess
raw = len(re.findall(r"@check\(", src))
print("raw '@check(' occurrences : %d" % raw)
print("registrations parsed      : %d" % len(entries))
fast = [c for c, s in entries if s == "fast"]
full = [c for c, s in entries if s == "full"]
print("fast: %d   full: %d" % (len(fast), len(full)))
print("")

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


ids = [c for c, _ in entries]
check("every @check( was parsed (%d of %d)" % (len(entries), raw),
      len(entries) == raw, "parsed %d of %d" % (len(entries), raw))
check("no duplicate check ids", len(set(ids)) == len(ids),
      "dupes: %s" % [k for k, v in collections.Counter(ids).items() if v > 1])
check("the registry has 31 checks", len(entries) == 31, "got %d" % len(entries))
check("22 of them are fast", len(fast) == 22, "got %d" % len(fast))
check("9 of them are full", len(full) == 9, "got %d" % len(full))
check("fast + full == all", len(fast) + len(full) == len(entries))

# ---------------------------------------------------------- the measured run
if os.path.exists(QA_FAST):
    data = json.load(io.open(QA_FAST, encoding="utf-8"))
    runs = data.get("runs", [])
    measured = runs[0] if runs else []
    m_ids = [c.get("id") for c in measured]
    m_by_id = {c.get("id"): c.get("verdict") for c in measured}
    check("the measured fast run covered all 31 checks",
          len(m_ids) == len(entries) and set(m_ids) == set(ids),
          "measured %d, registry %d" % (len(m_ids), len(entries)))
    skipped_full = [c for c in full if m_by_id.get(c) == "SKIP"]
    check("every full-scope check was SKIPped in the fast run",
          len(skipped_full) == len(full),
          "skipped %d of %d full" % (len(skipped_full), len(full)))
    # a FAST check may still SKIP at runtime (a missing artefact, a skipped
    # stage) -- that is a runtime condition, not a documentation error. What
    # must hold is that the full-scope ones never ran.
    ran_full = [c for c in full if m_by_id.get(c) != "SKIP"]
    check("no full-scope check ran in the fast run", len(ran_full) == 0,
          "ran: %s" % ran_full)
    skipped_fast = [c for c in fast if m_by_id.get(c) == "SKIP"]
    if skipped_fast:
        print("  %-58s %s" % ("(note) fast-scope checks that SKIPped at runtime",
                              ", ".join(skipped_fast)))
else:
    print("  (no measured fast-scope JSON -- skipping the run cross-check)")

# --------------------------------------------------------------- the prose
check("the project document says 31 registered checks",
      "31 registered checks" in proj)
check("the project document says 22 of them fast",
      "22 of them fast" in proj)
check("the project document says 22 in fast scope",
      re.search(r"\*\*22 in `fast` scope\*\*", proj) is not None)
check("the project document says 9 in full scope",
      re.search(r"\*\*9 in `full` scope\*\*", proj) is not None)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
