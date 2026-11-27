#!/usr/bin/env python3
"""Measure the house's ANALYSER EVIDENCE on the PACKAGE -- the artefact the
registry serves -- and write the record the release publishes.

WHY THIS EXISTS
===============
Round 92 measured the house's own analyser runs and read the report's own
table:

    | Functions entered | 1137 | ... | its own budget | spent |

The tool's module-wide STEP BUDGET (100,000 by default) stopped the dynamic
layer after 274 of the package's 1411 analysed functions, and the house had
been publishing the resulting counts as if the scan had covered the package.
The house raised the CFG layer's caps (`--max-cfg-functions`, `--max-cfg`) and
never raised this one, and the run was called "the full view".

Because the budget is spent in FILE ORDER, the truncation point depends on
what ELSE is in the scanned directory: the repository view and the package
view disagree about the same library file.  So the scope has to be the
ARTEFACT, and the coverage has to travel with the counts.

WHAT IT DOES
============
  1. DERIVES the package directory: the workspace member (`moon.work`) whose
     `moon.mod` declares the package NAME.  Nothing here is a hand-kept path.
  2. COPIES that directory to a scratch tree outside the repository, so the
     measurement cannot see -- or leave -- anything the working tree holds.
  3. RUNS the analyser on the copy, with the flags in `ANALYSER_FLAGS`.
  4. READS the tool's OWN report: the ingestion table and the per-package
     table say how many functions were entered and how many were SKIPPED.
  5. WRITES the record: the scope, the coverage, the counts, and a digest of
     the package's bytes so a later reader can tell that the evidence is
     about THIS package.

The budget is given EXPLICITLY, not left at the tool's default: a default
that moves under the house would move the evidence silently.

Run: python _verify/_measure_analyser_package_1650.py [--out <record.json>]
"""
import glob
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(ROOT, "_verify")

# The package this house ships.  Its NAME is an identity, not a count; its
# DIRECTORY is derived from the tree (see `package_dir`).
PACKAGE_NAME = "riantr/moonbit_doubleML"

# The analyser coordinate, and the flags the measurement runs with.  The
# verifier reads `ANALYSER_FLAGS` from HERE, so the two cannot drift.
ANALYSER = "riantr/LunaFlow"
ANALYSER_FLAGS = ["--funnel", "--max-cfg-functions", "3000", "--max-cfg", "12",
                  "--max-total-steps", "100000"]


# --------------------------------------------------------------------------- #
# the tree: the package directory, derived
# --------------------------------------------------------------------------- #
def package_dir():
    """The workspace member whose `moon.mod` declares the package NAME."""
    work = io.open(os.path.join(ROOT, "moon.work"), encoding="utf-8").read()
    members = re.findall(r'"([^"]+)"', work)
    for m in members:
        mod = os.path.join(ROOT, m.replace("/", os.sep), "moon.mod")
        if not os.path.isfile(mod):
            continue
        txt = io.open(mod, encoding="utf-8").read()
        name = re.search(r'(?m)^name\s*=\s*"([^"]+)"', txt)
        if name and name.group(1) == PACKAGE_NAME:
            return m.replace("/", os.sep), name.group(1)
    raise SystemExit("!! no workspace member declares the name %r" % PACKAGE_NAME)


def mbt_files(d):
    return sorted(f for f in os.listdir(d) if f.endswith(".mbt"))


def package_digest(d, files):
    """A digest over the package's SOURCE bytes -- the analyser's input.

    `moon.mod` is deliberately NOT in it: the version bump moves it, and the
    analyser's result does not depend on it.
    """
    h = hashlib.sha256()
    for f in files:
        h.update(f.encode("utf-8"))
        h.update(b"\0")
        with open(os.path.join(d, f), "rb") as fh:
            h.update(fh.read())
    return "sha256:" + h.hexdigest()


# --------------------------------------------------------------------------- #
# the tool's version, from the registry
# --------------------------------------------------------------------------- #
def tool_version(module):
    url = "https://mooncakes.io/api/v0/modules/%s" % module
    req = urllib.request.Request(url, headers={"User-Agent": "mavis-qa"})
    raw = urllib.request.urlopen(req, timeout=60).read().decode("utf-8")
    data = json.loads(raw)
    entries = data if isinstance(data, list) else data.get("versions", [])
    vs = []
    for e in entries:
        if isinstance(e, dict) and e.get("version"):
            vs.append(e["version"])
        elif isinstance(e, str):
            vs.append(e)
    vs.sort(key=lambda v: tuple(int(p) for p in v.split(".")))
    return vs[-1] if vs else "unknown"


# --------------------------------------------------------------------------- #
# the report: the tool's OWN numbers
# --------------------------------------------------------------------------- #
def cell(txt, label):
    m = re.search(r"(?m)^\|\s*%s\s*\|\s*([^|]+?)\s*\|" % re.escape(label), txt)
    return m.group(1).strip() if m else None


def packages_table(txt):
    """The per-package table: entered / skipped / steps / events / findings /
    budget.  The column order comes from the table's own header row."""
    m = re.search(r"(?s)### 2\.1 The packages(.*?)(?:\n## |\Z)", txt)
    if not m:
        return None
    rows = [l.strip() for l in m.group(1).split("\n")
            if l.strip().startswith("|")]
    rows = [r for r in rows if not re.match(r"^\|[\s|:-]+\|$", r)]
    if len(rows) < 2:
        return None
    head = [c.strip() for c in rows[0].strip("|").split("|")]
    data = [c.strip() for c in rows[1].strip("|").split("|")]
    return dict(zip(head, data))


def parse_report(md):
    txt = io.open(md, encoding="utf-8", errors="replace").read()
    pk = packages_table(txt) or {}
    out = {
        "files": cell(txt, "Source files parsed"),
        "functions_extracted": cell(txt, "Functions extracted"),
        "cfg_functions": cell(txt, "CFG functions"),
        "observed_functions": cell(txt, "Observed functions"),
        "steps": cell(txt, "Interpreted steps"),
    }
    out["functions_entered"] = pk.get("Functions entered")
    out["functions_skipped"] = pk.get("Functions skipped")
    out["budget_spent"] = (pk.get("Its own budget") or "").strip() == "spent"
    return out


def parse_findings(jsonl):
    fam = {}
    sites = []
    n = 0
    with io.open(jsonl, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            n += 1
            fam[r.get("rule")] = fam.get(r.get("rule"), 0) + 1
            if r.get("rule") == "BUDGET-EXCEEDED":
                sites.append("%s:%s %s" % (r.get("file"), r.get("line"),
                                           r.get("fn")))
    return n, fam, sorted(sites)


# --------------------------------------------------------------------------- #
# the run
# --------------------------------------------------------------------------- #
def run_analyzer(pkg_copy, out_dir):
    cmd = ["moonx", "%s@latest" % ANALYSER, "analyze", "--dir", ".", "--out",
           out_dir] + ANALYSER_FLAGS
    print("   $ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=pkg_copy, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=3600)
    if p.returncode != 0:
        print((p.stdout or "") + (p.stderr or ""))
        raise SystemExit("!! the analyser exited %d" % p.returncode)
    return p.stdout or ""


def main():
    out_path = os.path.join(VERIFY, "ANALYSER_EVIDENCE.json")
    argv = sys.argv[1:]
    if argv and argv[0] == "--out":
        out_path = argv[1]

    rel, name = package_dir()
    src = os.path.join(ROOT, rel)
    files = mbt_files(src)
    print("== the package, derived from the tree ==")
    print("   workspace member : %s" % rel)
    print("   declared name    : %s" % name)
    print("   .mbt files       : %d" % len(files))
    digest = package_digest(src, files)
    print("   source digest    : %s" % digest)

    scratch = tempfile.mkdtemp(prefix="_analyser_evidence_")
    try:
        copy = os.path.join(scratch, "pkg")
        shutil.copytree(src, copy)
        # the copy must BE the package: digest it again, here
        if package_digest(copy, mbt_files(copy)) != digest:
            raise SystemExit("!! the copy is not the package")
        out = os.path.join(scratch, "reports")
        print()
        print("== the analyser ==")
        stdout = run_analyzer(copy, out)
        mds = glob.glob(os.path.join(out, "*.md"))
        jsls = glob.glob(os.path.join(out, "*_findings.jsonl"))
        if not mds or not jsls:
            raise SystemExit("!! the analyser wrote no report")
        rep = parse_report(mds[0])
        n, fam, sites = parse_findings(jsls[0])
        summary = glob.glob(os.path.join(out, "*_summary.json"))
        s = json.load(io.open(summary[0], encoding="utf-8")) if summary else {}

        print()
        print("== the tool's own report ==")
        for k in ("files", "functions_extracted", "cfg_functions",
                  "observed_functions", "functions_entered",
                  "functions_skipped", "steps"):
            print("   %-22s %s" % (k, rep.get(k)))
        print("   %-22s %s" % ("budget_spent", rep.get("budget_spent")))
        print("   findings             %d" % n)
        print("   BUDGET-EXCEEDED      %d" % len(sites))
        for x in sites:
            print("      - %s" % x)

        record = {
            "tool": ANALYSER,
            "tool_version": tool_version(ANALYSER),
            "scope": "package",
            "scope_name": name,
            "scope_dir": rel.replace(os.sep, "/"),
            "package_digest": digest,
            "flags": ANALYSER_FLAGS,
            "files": int(rep["files"]),
            "functions_extracted": int(rep["functions_extracted"]),
            "cfg_functions": int(str(rep["cfg_functions"]).split()[0]),
            "functions_entered": int(rep["functions_entered"]),
            "functions_skipped": int(rep["functions_skipped"]),
            "step_budget": int(ANALYSER_FLAGS[ANALYSER_FLAGS.index(
                "--max-total-steps") + 1]),
            "budget_spent": bool(rep["budget_spent"]),
            "steps": int(rep["steps"]),
            "findings": n,
            "budget_exceeded": len(sites),
            "budget_exceeded_sites": sites,
            "families": dict(sorted(fam.items(), key=lambda kv: -kv[1])),
        }
        with io.open(out_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
        print()
        print("wrote %s" % out_path)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
