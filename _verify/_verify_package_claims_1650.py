#!/usr/bin/env python3
"""Round 38 verifier: the README's claims about the PACKAGE.

Round 37 gave the API's POSITIVE promises a check (the learner arguments,
the constructor defaults, the DID data types).  Round 38 checks the other
kind of promise: the claims the README makes about what the PACKAGE IS and
what it PROVIDES -- a file it names, a capability it exports, a rule its own
manifest breaks, a measurement it quotes.

Four defects of exactly this kind were live in the README when this check
was written:

  A  the Project-layout block named `moonbit_doubleML.mbt` -- "the main
     re-export file (the import surface)".  There is no such file:
     `git log --all --diff-filter=AD -- '*moonbit_doubleML.mbt'` is EMPTY,
     so it never existed in this repository.  A layout that names a file
     that is not there is a promise the tree cannot keep.

  B  the API bullet promised "optional JSON in/out for native / wasm-gc /
     wasm / js backends".  The library has NO JSON API: with comments and
     docstrings stripped, no production file in the package mentions a
     JSON type, a `to_json` or a `from_json`.  The JSON that exists
     belongs to `examples/api_server/`, which does its own request and
     response encoding.

  C  the dependency-rule bullet asserted "only `moonbitlang/*` official
     packages" while `moonbit_doubleML/moon.mod` declares
     `moonbit-community/sqlite3@0.2.3` -- a non-official package that
     nothing imports.  The README's own Dependency-rule section says "the
     rule is not met, by one line", so the bullet and the section
     contradicted each other.

  D  the hazard table's QTE row said the OLS arm was "frozen at `-1.583`
     for tau `0.50`-`0.90`".  The release that measured it recorded
     FIVE taus and found the freeze at THREE of them (`0.50 / 0.75 /
     0.90`); at `0.10` and `0.25` it was not frozen.  A hyphen reads as a
     continuous interval the evidence does not support.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the layout's file names, from the README's own layout block, against the
    files git TRACKS;
  * the library's JSON surface, from the package's sources with comments
    and docstrings stripped;
  * the dependency set, from `moonbit_doubleML/moon.mod`;
  * the QTE taus, from the CHANGELOG's own v0.139.0 measurement.

WHAT IS NOT CHECKED, AND WHY
============================
The upstream package (`doubleml` 0.11.3 / the 0.11.4 sdist) is not tracked,
so no claim about UPSTREAM's surface can be checked here; the tracked
record `_verify/UPSTREAM_PROVENANCE.md` holds those.

Run: python _verify/_verify_package_claims_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
MOONMOD = os.path.join(PKG, "moon.mod")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-62s %s" % ("ok" if ok else "*** FAIL ***", label))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))
        print("      %s" % detail)


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def flat(s):
    return re.sub(r"\s+", " ", s)


readme = read(README)
readme_flat = flat(readme)
changelog = read(CHANGELOG)

# --------------------------------------------------------------------------- #
# A. the Project-layout block names files that must exist
# --------------------------------------------------------------------------- #
print()
print("A. the Project layout names only files that exist")

m = re.search(r"##\s+Project layout\s*\n+```\n(.*?)\n```", readme, re.S)
check("the Project-layout block is findable", m is not None)
layout = m.group(1) if m else ""

tracked = set()
out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True,
                     encoding="utf-8", errors="replace").stdout
for line in out.splitlines():
    if line.strip():
        tracked.add(line.strip())
tracked_basenames = set(os.path.basename(p) for p in tracked)

named = re.findall(r"[\w-][\w./-]*\.(?:mbt|pkg|mod)\b", layout)
named = sorted(set(n for n in named if not n.endswith(".mbtp")))
print("   the layout names %d file(s): %s" % (len(named), named))
for n in named:
    base = os.path.basename(n)
    check("the layout's %s exists in the tracked tree" % n,
          base in tracked_basenames,
          "no tracked file named %s" % base)

check("the layout does not name the file that never existed",
      "moonbit_doubleML.mbt" not in layout,
      "the layout still names moonbit_doubleML.mbt")
check("the layout names the package's real interface file",
      "moon.pkg" in layout, "the layout does not name moon.pkg")

# ---- round 39: the layout names DIRECTORIES and plain FILES too ------------
# Round 38's check matched only `.mbt` / `.pkg` / `.mod`, so every DIRECTORY
# the layout names -- `001_introduction/`, `main/`, `did_binary/`, ... -- and
# every plain file (`moon.work`, `AGENTS.md`, `skills/moonbit_doubleML.md`)
# went unchecked.  A path in prose is a promise whether or not it ends in an
# extension.
parent = ""
layout_paths = []
for line in layout.split("\n"):
    if "<-" in line:
        head = line.split("<-", 1)[0]
    else:
        head = line
    if not head.strip():
        continue
    indented = head[:1] in (" ", "\t")
    for tok in head.split(","):
        tok = tok.strip()
        if not tok or tok == "...":
            continue
        if not re.search(r"[/\w]\.\w{2,}$", tok) and not tok.endswith("/"):
            continue
        if indented and parent:
            layout_paths.append(parent + tok)
        else:
            layout_paths.append(tok)
            if tok.endswith("/"):
                parent = tok
print("   the layout names %d path(s): %s" % (len(layout_paths), layout_paths))
for p in sorted(set(layout_paths)):
    full = p if p.endswith("/") else p
    probe = full.rstrip("/")
    ok = os.path.isdir(os.path.join(ROOT, probe)) \
        or os.path.isfile(os.path.join(ROOT, probe))
    tracked_p = probe in tracked or (probe + "/") in tracked \
        or any(t.startswith(probe + "/") for t in tracked)
    check("the layout's %s exists and is tracked" % p, ok and tracked_p,
          "exists=%s tracked=%s" % (ok, tracked_p))

# --------------------------------------------------------------------------- #
# B. the library's JSON surface
# --------------------------------------------------------------------------- #
print()
print("B. the library's JSON surface, read from the sources")

prod = [f for f in sorted(os.listdir(PKG)) if f.endswith(".mbt")
        and not f.endswith("_test.mbt") and not f.endswith("_wbtest.mbt")]


def strip_comments(src):
    """Remove comments and docstrings: a JSON mention in a COMMENT is not a
    JSON API, and the round-37 lesson is to measure the code, not the prose
    around it."""
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    src = re.sub(r"///[^\n]*", " ", src)
    return src


json_hits = []
for f in prod:
    code = strip_comments(read(os.path.join(PKG, f)))
    for pat in (r"\bJson\b", r"\bto_json\b", r"\bfrom_json\b", r"\bserialize\b"):
        if re.search(pat, code):
            json_hits.append("%s: %s" % (f, pat))
print("   production files mentioning a JSON symbol: %d %s"
      % (len(json_hits), json_hits))
check("the library's sources export no JSON surface", not json_hits,
      str(json_hits))
check("the README says the library exports no JSON in/out",
      "**no** JSON in/out" in readme_flat,
      "the README does not carry the disclosure")
check("the README no longer promises JSON in/out",
      "with optional JSON in/out" not in readme_flat,
      "the old promise is still there")
check("the JSON surface is located where it actually is",
      "examples/api_server/" in readme_flat,
      "the README does not point at examples/api_server/")

# --------------------------------------------------------------------------- #
# C. the dependency rule against the manifest
# --------------------------------------------------------------------------- #
print()
print("C. the dependency rule against moon.mod")

mod = read(MOONMOD)
# the manifest's import block is preceded by a COMMENTED example, so the
# comments come off before the declarations are read -- otherwise the
# example's `moonbitlang/x` is counted as a declared dependency.
mod_code = re.sub(r"//[^\n]*", " ", mod)
declared = re.findall(r'"([^"]+@\d[^"]*)"', mod_code)
declared = [d for d in declared if not d.startswith("riantr/")]
official = [d for d in declared if d.startswith("moonbitlang/")]
unofficial = [d for d in declared if not d.startswith("moonbitlang/")]
print("   moon.mod declares %d package(s): official %s, unofficial %s"
      % (len(declared), official, unofficial))
check("the manifest's unofficial packages are exactly the ones the README names",
      all(u.split("@")[0] in readme for u in unofficial),
      str(unofficial))
if unofficial:
    check("the README does not assert the rule is met while it is broken",
          "does not meet it today" in readme_flat,
          "the bullet still asserts 'only `moonbitlang/*` official packages'")
    check("the README's own Dependency-rule section still says it is not met",
          "the rule is not met, by one line" in readme_flat,
          "the section no longer discloses the breach")

# --------------------------------------------------------------------------- #
# D. the QTE freeze: a sampled set, not a range
# --------------------------------------------------------------------------- #
print()
print("D. the QTE freeze, read from the CHANGELOG's own measurement")

m = re.search(r"^## \[(0\.139\.0)\][^\n]*\n(.*?)(?=^## \[|\Z)", changelog,
              re.M | re.S)
check("the CHANGELOG's v0.139.0 entry is findable", m is not None)
entry = m.group(2) if m else ""
mt = re.search(r"freezes at\s+`-?[\d.]+`\s+for\s*\n?\s*`tau = ([^`]+)`", entry)
if not mt:
    mt = re.search(r"freezes at[^\n]*`tau = ([^`]+)`", entry)
check("the v0.139.0 entry records the frozen taus", mt is not None)
taus = re.findall(r"[\d.]+", mt.group(1)) if mt else []
print("   the recorded frozen taus: %s" % taus)
check("the recorded freeze is at THREE sampled taus, not a range",
      len(taus) == 3, "got %d: %s" % (len(taus), taus))

row = re.search(r"^\|\s*`DoubleMLQTE`\s*\|[^\n]*hazardous[^\n]*$", readme, re.M)
check("the README's QTE HAZARD row is findable", row is not None)
cell = row.group(0) if row else ""
print("   the README's row: %s" % cell)
readme_taus = re.findall(r"`([\d.]+)`", cell)
print("   the taus the row names: %s" % readme_taus)
check("the row names the recorded taus", sorted(readme_taus) == sorted(taus),
      "README %s vs CHANGELOG %s" % (readme_taus, taus))
check("the row does not present the taus as a range",
      not re.search(r"`[\d.]+`-`[\d.]+`", cell),
      "the row still reads as a range")

# --------------------------------------------------------------------------- #
# E. the import isolation the README promises
# --------------------------------------------------------------------------- #
print()
print("E. the import isolation the README promises")

pkg_src = "\n".join(strip_comments(read(os.path.join(PKG, f))) for f in prod)
src_imports = sorted(set(re.findall(r'^\s*import\s+["\']([^"\']+)["\']',
                                    pkg_src, re.M)))
print("   the library's sources declare %d import(s) of their own: %s"
      % (len(src_imports), src_imports))
check("the library's sources import nothing outside the package manifest",
      not src_imports, str(src_imports))
check("the README says the library imports nothing outside `moonbitlang/core`",
      "outside `moonbitlang/core`" in readme_flat,
      "the README does not carry the claim")

pkgfile = os.path.join(PKG, "moon.pkg")
if not os.path.isfile(pkgfile):
    check("the package's moon.pkg exists", False, "it is missing")
else:
    pkg_body = strip_comments(read(pkgfile))
    m = re.search(r"import\s*\{(.*?)\}", pkg_body, re.S)
    pkg_imports = sorted(set(re.findall(r'"([^"]+)"', m.group(1)))) if m else []
    print("   moon.pkg's import block: %s" % pkg_imports)
    check("the package's manifest declares an import block", bool(pkg_imports),
          "the import block is missing or empty")
    check("the package's manifest imports only `moonbitlang/core`",
          all(i.startswith("moonbitlang/core") for i in pkg_imports),
          str(pkg_imports))
    check("the library's whole import surface is `moonbitlang/core`",
          bool(pkg_imports)
          and all(i.startswith("moonbitlang/core") for i in pkg_imports)
          and not src_imports,
          "manifest=%s sources=%s" % (pkg_imports, src_imports))

# ------------------------------------------------------- the third-party pins
# The "Used By" section said pyroduct's `dmlref` package "cross-checks its
# own from-scratch DoubleML PLR against `riantr/moonbit_doubleML` v0.163.3
# (its current pin)".  "its current pin" was a promise about ANOTHER
# repository: pyroduct bumps its import pins on its own schedule, and by
# the time this README shipped, pyroduct's `moon.mod` imported
# `riantr/moonbit_doubleML@0.164.34`.  The literal `0.163.3` survived only
# inside a COMMENT in pyroduct's own manifest.
#
# A version literal of somebody else's package is a promise THIS
# repository cannot keep, so the section must not carry one.  What it may
# carry is the substance: the cross-check, its nuisance, its size, its true
# parameter and its two deltas.
i_used = readme.find("## Used By")
used_by = readme[i_used:readme.find("\n## ", i_used + 1)] if i_used >= 0 else ""
check("the README has a Used By section", i_used >= 0,
      "the section is not there")
# NO version literal at all -- not even this package's.  The promise was
# about pyroduct's PIN of this package, so a literal naming this package is
# exactly the thing that rots: pyroduct bumps its pins on its own
# schedule, and this repository does not know when.
version_literals = re.findall(r"v?\d+\.\d+\.\d+", used_by)
check("the Used By section carries no version literal",
      not version_literals,
      "it names %s" % ", ".join(version_literals))
check("the Used By section still states the cross-check's figures",
      "n = 400" in used_by and "0.017" in used_by and "0.001" in used_by,
      "the figures are not there")

# WHO measured them.  The figures are true -- pyroduct's own `dmlref` report
# says exactly this -- but they are produced by code in ANOTHER repository:
# the published pyroduct package ships no sources, and its published README
# does not carry the figures, so nothing in this tree can re-derive them.
# A reader must not take them for this repository's measurements, and the
# only way to keep that from drifting is to require the attribution.
check("the Used By section says whose measurement the figures are",
      "pyroduct's own measurement" in used_by,
      "the attribution is not there")
check("the Used By section says the figures are not re-measured here",
      "does not re-measure" in used_by,
      "the scope statement is not there")

print()
print("=" * 74)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
