#!/usr/bin/env python3
"""The check that holds the house's ANALYSER EVIDENCE to the SCOPE and the
COVERAGE it claims.

THE DEFECT THIS EXISTS FOR
==========================
Round 92 read the analyser's own report and found this table in it:

    | Package | Functions entered | Functions skipped | Steps | ... | budget |
    | ``      | 274               | 1137              | 100619| ... | spent  |

The tool's module-wide STEP BUDGET (100,000) stopped the dynamic layer after
274 of the package's 1411 analysed functions.  The house had been publishing
the resulting counts as the tree's findings, with no scope and no coverage:
the house's own script called the run "the full view" because it had raised
the CFG layer's caps (`--max-cfg-functions`, `--max-cfg`) and had NOT raised
this one.

And the truncation point depends on FILE ORDER -- the budget is spent in file
order -- so the same library file yields different findings depending on what
else is in the scanned directory.  Measured: the repository view and the
package view disagree, in BOTH directions.

THE RULES
=========
  R1  the record names the analyser and its version;
  R2  the record's SCOPE is the package -- the artefact the registry serves;
  R3  the scope DIRECTORY is the workspace member whose `moon.mod` declares
      that name (derived from the tree, never a hand-kept path);
  R4  the record's file count is the package's own `.mbt` count;
  R5  the record was measured on THIS package -- its digest matches the tree,
      so a stale record is red rather than published;
  R6  the COVERAGE is stated: entered + skipped == the analysed functions;
  R7  a run that skipped functions says the budget was spent;
  R8  the `BUDGET-EXCEEDED` count is the number of sites;
  R9  the four round-91 fixture sites are absent;
  R10 the flags are the house's own flags, read from the measurement script so
      the two cannot drift.

THE CONTROL ARM
===============
Each rule is proved to BITE by mutating a copy of the record in memory and
requiring the judgement to reject it AND to name the field.  An arm that
changes nothing is reported as such, because an arm that measures nothing
would report PASS.

Run: python _verify/_verify_analyser_evidence_1650.py
"""
import hashlib
import importlib.util
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(ROOT, "_verify")
RECORD = os.path.join(VERIFY, "ANALYSER_EVIDENCE.json")
MEASURE = os.path.join(VERIFY, "_measure_analyser_package_1650.py")
PACKAGE_NAME = "riantr/moonbit_doubleML"

# the four sites the house's own probe fixture used to cost the library; they
# were removed when the fixture became a template, and they must not come back
FIXTURE_SITES = ("did_bootstrap_t_stat", "make_iivm_data",
                 "make_plr_CCDDHNR2018",
                 "irm_style_sensitivity_cluster_from_elements")

FAILS = []
N = 0


def check(label, ok, detail=""):
    global N
    N += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "FAIL", label, detail))
    if not ok:
        FAILS.append(label)
    return ok


# --------------------------------------------------------------------------- #
# the tree
# --------------------------------------------------------------------------- #
def package_dir():
    work = io.open(os.path.join(ROOT, "moon.work"), encoding="utf-8").read()
    for m in re.findall(r'"([^"]+)"', work):
        mod = os.path.join(ROOT, m.replace("/", os.sep), "moon.mod")
        if not os.path.isfile(mod):
            continue
        txt = io.open(mod, encoding="utf-8").read()
        name = re.search(r'(?m)^name\s*=\s*"([^"]+)"', txt)
        if name and name.group(1) == PACKAGE_NAME:
            return m.replace("/", os.sep), name.group(1)
    return None, None


def package_digest(d):
    h = hashlib.sha256()
    for f in sorted(x for x in os.listdir(d) if x.endswith(".mbt")):
        h.update(f.encode("utf-8"))
        h.update(b"\0")
        with open(os.path.join(d, f), "rb") as fh:
            h.update(fh.read())
    return "sha256:" + h.hexdigest()


def house_flags():
    spec = importlib.util.spec_from_file_location("_measure_analyser", MEASURE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return list(mod.ANALYSER_FLAGS)


# --------------------------------------------------------------------------- #
# the judgement -- a pure function of the record and the tree
# --------------------------------------------------------------------------- #
def judge(rec, tree):
    """Every rule that the record breaks, as (field, message) pairs.

    A pure function, so the control arm can mutate a record and ask the SAME
    question of the mutation that it asks of the real one.
    """
    bad = []
    rel, name = tree["dir"], tree["name"]
    if not rec.get("tool") or not rec.get("tool_version"):
        bad.append(("tool", "the record does not name the analyser and its "
                            "version"))
    if rec.get("scope") != "package":
        bad.append(("scope", "the scope is %r, not the package" %
                    rec.get("scope")))
    if rec.get("scope_dir") != rel.replace(os.sep, "/"):
        bad.append(("scope_dir", "the scope dir is %r, not the package's %r" %
                    (rec.get("scope_dir"), rel.replace(os.sep, "/"))))
    if rec.get("scope_name") != name:
        bad.append(("scope_name", "the scope name is %r, not %r" %
                    (rec.get("scope_name"), name)))
    if rec.get("files") != tree["files"]:
        bad.append(("files", "the record says %r files, the package has %d" %
                    (rec.get("files"), tree["files"])))
    if rec.get("package_digest") != tree["digest"]:
        bad.append(("package_digest", "the record was measured on a DIFFERENT "
                                      "package -- the evidence is stale"))
    entered, skipped = rec.get("functions_entered"), rec.get("functions_skipped")
    cfg = rec.get("cfg_functions")
    if entered is None or skipped is None or cfg is None:
        bad.append(("functions_entered", "the coverage is not stated"))
    elif entered + skipped != cfg:
        bad.append(("functions_skipped", "%d entered + %d skipped is not the "
                    "%d analysed functions" % (entered, skipped, cfg)))
    if skipped and rec.get("budget_spent") is not True:
        bad.append(("budget_spent", "%d functions were skipped, so the budget "
                    "was spent -- the record says it was not" % skipped))
    sites = rec.get("budget_exceeded_sites")
    if not isinstance(sites, list):
        bad.append(("budget_exceeded_sites", "the site list is not a list"))
    elif rec.get("budget_exceeded") != len(sites):
        bad.append(("budget_exceeded", "the record says %r, the list holds %d" %
                    (rec.get("budget_exceeded"), len(sites))))
    if isinstance(sites, list):
        for s in sites:
            for f in FIXTURE_SITES:
                if f in s:
                    bad.append(("budget_exceeded_sites",
                                "the round-91 fixture site %s is back" % f))
    if rec.get("flags") != tree["flags"]:
        bad.append(("flags", "the flags are %r, the house's are %r" %
                    (rec.get("flags"), tree["flags"])))
    if not isinstance(rec.get("findings"), int) or rec.get("findings") <= 0:
        bad.append(("findings", "the findings count is not stated"))
    return bad


# --------------------------------------------------------------------------- #
print("== the record ==")
if not os.path.isfile(RECORD):
    print("!! %s is missing -- run _verify/_measure_analyser_package_1650.py"
          % RECORD)
    print("VERDICT: FAIL")
    sys.exit(1)
rec = json.load(io.open(RECORD, encoding="utf-8"))
print("   %s" % RECORD)

rel, name = package_dir()
if rel is None:
    print("!! no workspace member declares the name %r" % PACKAGE_NAME)
    print("VERDICT: FAIL")
    sys.exit(1)
pkg = os.path.join(ROOT, rel)
tree = {
    "dir": rel,
    "name": name,
    "files": len([f for f in os.listdir(pkg) if f.endswith(".mbt")]),
    "digest": package_digest(pkg),
    "flags": house_flags(),
}
print("   the package, derived: %s (%s), %d .mbt files"
      % (rel, name, tree["files"]))
print("   the house's flags    : %s" % " ".join(tree["flags"]))

print()
print("== the rules ==")
bad = judge(rec, tree)
for field, msg in bad:
    print("  FAIL %-22s %s" % (field, msg))
    FAILS.append("%s: %s" % (field, msg))
N += len(bad)
if not bad:
    print("  ok   the record states its scope, its coverage and its counts")

print()
print("== the control arm: each rule must bite ==")
ARMS = [
    ("scope", lambda r: r.update(scope="repository")),
    ("scope_dir", lambda r: r.update(scope_dir="examples")),
    ("files", lambda r: r.update(files=999)),
    ("package_digest", lambda r: r.update(package_digest="sha256:" + "0" * 64)),
    ("functions_skipped", lambda r: r.update(functions_skipped=1)),
    ("budget_spent", lambda r: r.update(budget_spent=False)),
    ("budget_exceeded", lambda r: r.update(budget_exceeded=999)),
    ("budget_exceeded_sites",
     lambda r: (r.update(budget_exceeded_sites=list(
         r.get("budget_exceeded_sites", [])) +
         ["bootstrap.mbt:97 did_bootstrap_t_stat"]),
         r.update(budget_exceeded=len(r.get("budget_exceeded_sites", [])) + 1))),
    ("flags", lambda r: r.update(flags=["--funnel"])),
    ("tool", lambda r: r.update(tool_version="")),
]
for field, mutate in ARMS:
    mutated = json.loads(json.dumps(rec))
    mutate(mutated)
    moved = mutated != rec
    hits = [f for f, _ in judge(mutated, tree)]
    check("the %s arm is REJECTED and NAMES the field" % field,
          moved and field in hits,
          "the mutation changed nothing" if not moved
          else ("rejected by %r" % hits if field in hits
                else "!! NOT rejected (the judge said %r)" % hits))

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAIL %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))
sys.exit(1 if FAILS else 0)
