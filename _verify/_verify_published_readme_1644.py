#!/usr/bin/env python3
"""Read back the PUBLISHED README of a release and check it.

The published README is the only file the registry serves: a paragraph that
is not in it is not in the artefact, and a claim in it is a claim the user
reads.  So this reads the asset the registry actually serves -- not the
repository's copy -- and checks it.

Three things are checked:
  1. the published README carries the version this release shipped;
  2. the project-facing acceptance-criteria paragraph is NOT in the published
     README -- it describes this repository's own `features/*.feature` file,
     not the library -- and the counts the PROJECT document states still
     agree with that feature file as it now stands (the counts are
     re-derived from the file in the repository, not written down here);
  3. the claims retracted in earlier rounds are still absent.

A freshly published asset 404s for a while, so the fetch is RETRIED:
one 404 is not a publishing defect, and a read-back that never fetches
would "pass" vacuously.

The published README keeps its `>` blockquote markers, so they are
stripped before matching -- otherwise a correct claim reads as ABSENT.

The version defaults to the one in `moon.mod`, so the check cannot be run
against a stale release by accident.

Run: python _verify/_verify_published_readme_1644.py [version]
"""
import json
import os
import re
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def moon_mod_version():
    """The version this tree publishes -- derived, never a literal."""
    src = open(os.path.join(ROOT, "moonbit_doubleML", "moon.mod"),
               encoding="utf-8").read()
    m = re.search(r'version\s*=\s*"([0-9.]+)"', src)
    return m.group(1) if m else ""


VER = sys.argv[1] if len(sys.argv) > 1 else moon_mod_version()
PKG = "riantr/moonbit_doubleML"
URL = "https://assets.mooncakes.io/assets/%s@%s/resource.json" % (PKG, VER)
PROJ = os.path.join(ROOT, "ENGINEERING.md")

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %s  %-56s %s" % ("ok  " if ok else "FAIL", name, detail))
    if not ok:
        FAILS.append(name)


print("fetching %s (retrying on a CDN 404)" % URL)
doc = None
for attempt in range(1, 9):
    try:
        with urllib.request.urlopen(URL, timeout=120) as r:
            doc = json.loads(r.read().decode("utf-8", "replace"))
        print("  fetched on attempt %d" % attempt)
        break
    except Exception as e:  # noqa: BLE001
        print("  attempt %d: %s: %s" % (attempt, type(e).__name__, e))
        time.sleep(20)
if doc is None:
    print("ERROR: could not fetch the published asset after 8 attempts")
    sys.exit(1)

rd = doc.get("readme_content") or ""
flat = re.sub(r"^\s*>\s?", "", rd, flags=re.M)   # strip blockquote markers
print("  readme_content: %d chars" % len(rd))
print()

# --- 1. the version this release shipped ---------------------------------- #
m = re.search(r"\| `moon\.mod` version \| \*\*([0-9.]+)\*\* \|", flat)
check("the published README carries version %s" % VER, bool(m) and m.group(1) == VER,
      m.group(1) if m else "(row not found)")

# --- 2. the traceability paragraph agrees with the feature file ----------- #
feat_path = os.path.join(ROOT, "features", "moonbit_doubleML_acceptance.feature")
feat = open(feat_path, encoding="utf-8").read()
lines = feat.splitlines()
n_feat = len(re.findall(r"^Feature:", feat, re.M))
n_scen = len(re.findall(r"^\s*Scenario", feat, re.M))
n_step = len(re.findall(r"^\s*(?:Given|When|Then|And)\s", feat, re.M))
mapped = []
for i, l in enumerate(lines):
    mm = re.match(r"\s*#\s*mapped to:\s*(.+)$", l)
    if not mm:
        continue
    acc = mm.group(1)
    nxt = lines[i + 1] if i + 1 < len(lines) else ""
    if (re.match(r"\s*#\s+\S", nxt)
            and not re.match(r"\s*(Scenario|Feature|Background|Examples|Given|When|Then|And|But|\*)\b", nxt)):
        acc += " " + nxt.split("#", 1)[1]
    mapped += [x.strip() for x in re.split(r",\s*|\s+and\s+", acc) if x.strip()]
n_distinct = len(set(mapped))
n_prose = len([x for x in mapped
                if re.search(r"\s(?:in|usage|validators|tests)\b|\.", x)])

# the published artefact is the LIBRARY document: the project's own
# acceptance-criteria census does not belong in it
check("the published README does NOT carry the project traceability paragraph",
      "Acceptance-criteria traceability" not in flat)
proj = ""
if os.path.exists(PROJ):
    proj = open(PROJ, encoding="utf-8").read()
i = proj.find("Acceptance-criteria traceability")
para = proj[i:i + 900] if i >= 0 else ""
check("the project document has the traceability paragraph", bool(para))
for label, value in (("Feature", n_feat), ("Scenario", n_scen), ("steps", n_step),
                      ("cited names", len(mapped)), ("distinct", n_distinct),
                      ("prose-exempt", n_prose)):
    check("the project document states %s = %d" % (label, value), str(value) in para, "")
check("the project document claims every cited name resolves",
      "All %d resolve" % len(mapped) in para or "%d against real" % n_distinct in para, "")

# --- 3. the claims retracted in earlier rounds are still absent ------------ #
for label, probe in (("the APO 'average prescriptive effect' wording", "average prescriptive effect"),
                      ("the retracted dgp_recovery tolerance claim", "dgp_recovery_test.mbt` enforces"),
                      ("the false 1:1 mapping claim", "maps 1:1 to an executable")):
    check("%s is absent" % label, probe not in flat)

print()
print("=" * 74)
print("checks: %d   failures: %d" % (N, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
    sys.exit(1)
print("ALL PASS")
