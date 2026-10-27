#!/usr/bin/env python3
"""Round 57 verifier: AGENTS.md's claims, and the fact that nobody held them.

WHAT THIS EXISTS FOR
====================
`AGENTS.md` is the document an agent opens FIRST: it is the project map, and
it is the only live document at the repository ROOT that rounds 48-56 never
audited.  Round 56 measured that the tutorial pages' numbers had no holder at
all -- and the same instrument, run against this document, says the same thing
about almost all of it:

    tracked contract verifiers: 74
    verifiers that READ AGENTS.md at runtime: 7
      _verify/_verify_agents_claims_1650.py
      _verify/_verify_mlm_defaults_1650.py
      _verify/_verify_number_coverage_1650.py
      _verify/_verify_path_promises_1650.py
      _verify/_verify_repro_paths_1650.py
      _verify/_verify_round9_docs_1644.py
      _verify/_verify_shipped_docs_1643.py

Of eleven claims put to the probe, THREE were held -- the `moon.work` member
count and the example count by `_verify/_verify_shipped_docs_1643.py`, and the
smoke-test path by `_verify/_verify_path_promises_1650.py`.  The other EIGHT
were held by NOBODY: the library's location, the tutorial range, the
dependency rule, the async version, the commit citation, the public API calls
and the "no test file" claim could all have been wrong, and no red line would
have appeared.

HOW THE READER SET WAS MEASURED
===============================
NOT by grepping the verifiers' source for "AGENTS.md": that finds FOUR, and
it is an under-approximation -- the path-promises verifier reads every
tracked markdown document, so it holds AGENTS.md's path promises without the
string ever appearing in its source.  The reader set is measured at RUNTIME,
by running the contract under an audit hook that logs every file a verifier
opens.  Seven verifiers open AGENTS.md.

WHAT WAS WRONG, MEASURED
========================
Three claims were false of the tree as it stood:

  A1  the dependency rule.  "Only official (`moonbitlang/*`) packages are
      allowed.  Non-official packages may only be `riantr/*`" -- while the
      library's OWN `moonbit_doubleML/moon.mod` declares
      `moonbit-community/sqlite3@0.2.3`, which is neither.  Round 49 fixed
      exactly this sentence in `skills/moonbit_doubleML.md`; AGENTS.md was
      never given the same edit, so the two documents described two different
      rules.
  A2  the interface file.  "each package has a generated interface file
      `.mbti`" -- the toolchain writes `pkg.generated.mbti`, and the tracked
      `.gitignore` ignores it, so "Check the diffs of `.mbti` file" asks for
      a diff that `git diff` can never produce.  No tracked file ends in
      `.mbti` at all.
  A3  the package layout.  "each directory contains a `moon.pkg` file" --
      `doc/` is a MODULE of six packages and has no `moon.pkg` of its own,
      and `_verify/` holds MoonBit source with no package at all.

WHY EVERY CHECK BELOW IS DERIVED
================================
A literal pin rots exactly like the document does, so nothing here is typed:

  * the workspace census comes out of `moon.work`;
  * the dependency carve-out comes out of every tracked `moon.mod`'s import
    block, with the COMMENTS stripped first -- `moon.mod` carries a
    commented-out `import { ... }` in its header, and a naive regex reads
    THAT block and finds `moonbitlang/x@0.4.6`, which the tree does not
    declare;  * the package census comes out of the tracked tree;
  * the interface file's name and its ignored-ness come out of the tracked
    `.gitignore` and from the absence of any tracked `.mbti`;
  * the commit citation is resolved against the git object database.

THE SCOPE IS THE TRACKED TREE
=============================
`git ls-files`, never `os.walk`: a scratch clone sitting at the repository
root would otherwise contribute paths and sources this repository does not
have.

Run: python _verify/_verify_agents_claims_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-66s %s" % ("ok" if ok else "*** FAIL ***", label,
                               " ".join(str(detail).split())[:70]))
    if not ok:
        FAILS.append(label)


def git(*args):
    r = subprocess.run(["git", "-C", ROOT, *args], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.stdout


def read(rel):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        return ""
    return io.open(p, encoding="utf-8", errors="replace").read()


def gitobj(kind):
    return git("cat-file", "-t", kind).strip()


TRACKED = [l.strip().replace("\\", "/") for l in git("ls-files").splitlines()
           if l.strip()]
TSET = set(TRACKED)

AGENTS = read("AGENTS.md")

# ---------------------------------------------------------------------------
# the derived census
# ---------------------------------------------------------------------------
MOONWORK = read("moon.work")
MEMBERS = re.findall(r'"([^"]+)"', MOONWORK)
EXAMPLES = sorted(m.split("/", 1)[1] for m in MEMBERS if m.startswith("examples/"))


def declared_deps(text):
    """The import block of a `moon.mod`, with the comments stripped first."""
    t = re.sub(r"//[^\n]*", "", text)
    blk = re.search(r"import\s*\{([^}]*)\}", t, re.S)
    if not blk:
        return []
    out = []
    for raw in blk.group(1).split("\n"):
        s = raw.strip().strip(",").strip('"').strip()
        if s:
            out.append(s)
    return out


def pkg_imports(text):
    """The import block of a `moon.pkg`, with the comments stripped first.

    `moon.pkg` carries prose in comments -- and the proof pilots' files quote
    identifiers in that prose -- so a regex over the WHOLE file finds strings
    that are not imports at all.
    """
    t = re.sub(r"//[^\n]*", "", text)
    blk = re.search(r"import\s*\{([^}]*)\}", t, re.S)
    if not blk:
        return []
    out = []
    for raw in blk.group(1).split("\n"):
        s = raw.strip().strip(",").strip('"').strip()
        if s:
            out.append(s)
    return out


MODS = [p for p in TRACKED if os.path.basename(p) == "moon.mod"]
DEPS = {m: declared_deps(read(m)) for m in MODS}
ALL_DEPS = sorted({d for deps in DEPS.values() for d in deps})
NONCONFORMING = sorted(d for d in ALL_DEPS
                       if not (d.startswith("moonbitlang/") or d.startswith("riantr/")))

# the directories that hold MoonBit source
MBT_DIRS = {}
for rel in TRACKED:
    if rel.endswith(".mbt"):
        d = os.path.dirname(rel) or "."
        MBT_DIRS.setdefault(d, []).append(rel)

# the top-level directories that hold MoonBit source OUTSIDE the workspace
def inside_member(d):
    """Is this directory inside a moon.work member?"""
    parts = [p for p in d.split("/") if p]
    for i in range(1, len(parts) + 1):
        if "/".join(parts[:i]) in MEMBERS:
            return True
    return False


OUTSIDE = set()
for d in MBT_DIRS:
    if inside_member(d):
        continue
    parts = [p for p in d.split("/") if p]
    if parts:
        OUTSIDE.add(parts[0])
OUTSIDE = sorted(OUTSIDE)

# the doc packages: directories under doc/ that hold source
DOC_PKGS = sorted(d for d in MBT_DIRS if d.startswith("doc/") and d.count("/") == 1)

# the packages: every directory with a moon.pkg
PKGS = sorted({os.path.dirname(p) for p in TRACKED
               if os.path.basename(p) == "moon.pkg"})

# the interface file: what the toolchain writes, and what the tree tracks
GITIGNORE = read(".gitignore")
MBTI_TRACKED = [p for p in TRACKED if p.endswith(".mbti")]

LIB_SRC = "\n".join(read("moonbit_doubleML/" + f) for f in
                     sorted(os.listdir(os.path.join(ROOT, "moonbit_doubleML")))
                     if f.endswith(".mbt") and not f.endswith("_test.mbt")
                     and not f.endswith("_wbtest.mbt"))

# ---------------------------------------------------------------------------
print("=" * 78)
print("A. the project structure")
print("=" * 78)

m_lib = re.search(r"The library lives at `([^`]+)`", AGENTS)
LIBDIR = (m_lib.group(1).rstrip("/") if m_lib else "")
check("AGENTS names the library's directory", bool(LIBDIR), LIBDIR)
check("the library directory is a moon.work member", LIBDIR in MEMBERS, MEMBERS[:3])
check("the library holds its own moon.mod",
      (LIBDIR + "/moon.mod") in TSET, LIBDIR)
check("the library holds its own moon.pkg",
      (LIBDIR + "/moon.pkg") in TSET, LIBDIR)
check("the library holds MoonBit source", bool(MBT_DIRS.get(LIBDIR)),
      "%d files" % len(MBT_DIRS.get(LIBDIR, [])))

_m = re.search(r"its own `([^`]+)`\s+and\s+`([^`]+)`", AGENTS)
check("AGENTS names the library's own moon.mod and moon.pkg",
      bool(_m) and _m.group(1) == "moon.mod" and _m.group(2) == "moon.pkg",
      _m.groups() if _m else "no match")

_root_mbt = [p for p in TRACKED if "/" not in p and p.endswith(".mbt")]
check("the root owns no MoonBit source itself", not _root_mbt, _root_mbt)
check("AGENTS says the root owns no MoonBit source",
      "owns no MoonBit source itself" in AGENTS)

_missing_mod = [m for m in MEMBERS if (m + "/moon.mod") not in TSET]
check("every moon.work member is a module with a moon.mod",
      not _missing_mod, _missing_mod)

_mc = re.search(r"members \((\d+) total\)", AGENTS)
check("AGENTS states the real member count (derived %d)" % len(MEMBERS),
      bool(_mc) and int(_mc.group(1)) == len(MEMBERS),
      _mc.group(1) if _mc else "not stated")

# the example bullet, taken from the document
_lines = AGENTS.split("\n")
_ex_i = next((i for i, l in enumerate(_lines) if "`examples/<bin>/`" in l), None)
_ex_blk = ""
if _ex_i is not None:
    _ex_blk = _lines[_ex_i]
    for l in _lines[_ex_i + 1:]:
        if not l.startswith("  "):
            break
        _ex_blk += "\n" + l

_ec = re.search(r"× (\d+)", _ex_blk)
check("AGENTS states the real example count (derived %d)" % len(EXAMPLES),
      bool(_ec) and int(_ec.group(1)) == len(EXAMPLES),
      _ec.group(1) if _ec else "not stated")

_named = set(re.findall(r"`([a-z][a-z0-9_]*)`", _ex_blk))
check("AGENTS enumerates exactly the derived example set",
      _named == set(EXAMPLES),
      "extra=%s missing=%s" % (sorted(_named - set(EXAMPLES)),
                               sorted(set(EXAMPLES) - _named)))
_no_dir = [e for e in EXAMPLES if ("examples/" + e + "/") not in
           "".join(p + "\n" for p in TRACKED)]
check("every example AGENTS names is a tracked directory",
      not _no_dir, _no_dir)

# the doc bullet
_doc_i = next((i for i, l in enumerate(_lines) if l.strip().startswith("- `doc/`")), -1)
_doc_blk = _lines[_doc_i] if _doc_i >= 0 else ""
if _doc_i >= 0:
    for l in _lines[_doc_i + 1:]:
        if not l.startswith("  "):
            break
        _doc_blk += "\n" + l

check("AGENTS names the doc module as a moon.work member", "doc" in MEMBERS)
check("the doc module has its own moon.mod", "doc/moon.mod" in TSET)
_dc = re.search(r"module of (\d+) wasm-gc-targeted packages", _doc_blk)
check("AGENTS states the real doc package count (derived %d)" % len(DOC_PKGS),
      bool(_dc) and int(_dc.group(1)) == len(DOC_PKGS),
      _dc.group(1) if _dc else "not stated")
_doc_no_pkg = [d for d in DOC_PKGS if (d + "/moon.pkg") not in TSET]
check("every doc package has its own moon.pkg", not _doc_no_pkg, _doc_no_pkg)
_doc_tgt = [d for d in DOC_PKGS
            if 'supported_targets = "wasm-gc"' not in read(d + "/moon.pkg")]
check("every doc package is wasm-gc-targeted", not _doc_tgt, _doc_tgt)

_doc_names = re.findall(r"`(\d{3}_[a-z_]+)`", _doc_blk)
check("AGENTS names the first and last doc package",
      len(_doc_names) == 2, _doc_names)
if len(_doc_names) == 2:
    first = "doc/" + _doc_names[0]
    last = "doc/" + _doc_names[1]
    check("the first doc package AGENTS names is real", first in DOC_PKGS, first)
    check("the last doc package AGENTS names is real", last in DOC_PKGS, last)
    check("the doc range AGENTS names covers every doc package",
          DOC_PKGS and DOC_PKGS[0] == first and DOC_PKGS[-1] == last,
          DOC_PKGS)

# the out-of-workspace bullet
_oc = re.search(r"(\w+) directories hold MoonBit source outside the workspace",
                AGENTS)
_word_num = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
             "seven": 7, "eight": 8, "nine": 9, "ten": 10}
_num_of = (_word_num.get((_oc.group(1) if _oc else "").lower(), None))
check("AGENTS states the real out-of-workspace count (derived %d)" % len(OUTSIDE),
      _num_of == len(OUTSIDE), _oc.group(1) if _oc else "not stated")
_out_named = {t.rstrip("/") for t in re.findall(r"`(_[a-z0-9_]+/)`", AGENTS)}
check("AGENTS names exactly the out-of-workspace directories",
      _out_named == set(OUTSIDE),
      "named=%s derived=%s" % (sorted(_out_named), OUTSIDE))
_pilots = sorted(re.findall(r"`(_prove\w+/)`", AGENTS))
check("AGENTS names the proof pilots", len(_pilots) == 2, _pilots)
for p in _pilots:
    check("the proof pilot %s holds its own moon.pkg" % p.rstrip("/"),
          (p + "moon.pkg") in TSET, p)
check("the _verify directory holds MoonBit source with no moon.pkg",
      bool(MBT_DIRS.get("_verify")) and "_verify/moon.pkg" not in TSET,
      "%d files" % len(MBT_DIRS.get("_verify", [])))
check("the proof pilots are not moon.work members",
      "_prove_pilot" not in MEMBERS and "_prove_pilot2" not in MEMBERS)

# every package's imports resolve to an official package or to this repository
_bad_import = []
for p in PKGS:
    for imp in pkg_imports(read(p + "/moon.pkg")):
        if imp.startswith("moonbitlang/") or imp.startswith("riantr/"):
            continue
        _bad_import.append((p, imp))
check("every package's own imports resolve to an official package or to this repo",
      not _bad_import, _bad_import)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("B. the tooling -- the generated interface file")
print("=" * 78)

_if = re.search(r"interface file `([^`]+)`", AGENTS)
IFACE = _if.group(1) if _if else ""
check("AGENTS names the interface file", bool(IFACE), IFACE)
check("the interface file AGENTS names is the one the tree ignores",
      any(re.search(r"^\s*%s\s*$" % re.escape(IFACE), l)
          for l in GITIGNORE.splitlines()),
      IFACE)
check("no tracked file ends in .mbti", not MBTI_TRACKED, MBTI_TRACKED)
_spans = set(re.findall(r"`([^`]*\.mbti)`", AGENTS))
check("every .mbti span in AGENTS is the real interface file",
      _spans == {IFACE}, _spans)
check("AGENTS says the interface file is git-ignored",
      "**git-ignored**" in AGENTS)
check("AGENTS no longer tells the reader to check a .mbti diff",
      "diffs of `.mbti` file" not in AGENTS)

_sep = 0
_sep_files = 0
for d in MBT_DIRS:
    for f in MBT_DIRS[d]:
        _n = sum(1 for line in read(f).splitlines()
                  if line.strip().startswith("///|"))
        if _n:
            _sep_files += 1
            _sep += _n
check("the tree uses `///|` block separators (derived %d lines in %d files)"
      % (_sep, _sep_files), _sep > 0, _sep)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("C. the dependency rule")
print("=" * 78)

_DEPSEC = AGENTS.split("## Dependency rule", 1)[1].split("\n## ", 1)[0] \
    if "## Dependency rule" in AGENTS else ""

check("AGENTS states the general rule",
      "Only official (`moonbitlang/*`) packages are allowed." in _DEPSEC)
check("AGENTS states the riantr half of the rule",
      "Non-official packages may only be `riantr/*`" in _DEPSEC)

_named_exc = sorted({t for t in re.findall(r"`([^`]+)`", _DEPSEC)
                     if "@" in t and not t.startswith("moonbitlang/")})
check("AGENTS names exactly the derived carve-out (%d)" % len(NONCONFORMING),
      _named_exc == NONCONFORMING,
      "named=%s derived=%s" % (_named_exc, NONCONFORMING))
check("AGENTS discloses that the rule is not met today",
      "does not meet the rule" in _DEPSEC)
check("AGENTS names the file the carve-out is declared in",
      "moonbit_doubleML/moon.mod" in _DEPSEC)

for exc in NONCONFORMING:
    pkg = exc.split("@")[0]
    short = pkg.split("/")[-1]
    hits = [f for f in MBT_DIRS.get("moonbit_doubleML", []) if short in read(f)]
    check("no .mbt in the library imports %s (0 references)" % short,
          not hits, hits)

_pinned = set(ALL_DEPS)
_cited = set(re.findall(r"`([a-z][a-z0-9_\-]*/[a-z0-9_\-]+@[0-9][^`]*)`", _DEPSEC))
check("every version AGENTS cites is a version the tree pins",
      _cited <= _pinned, sorted(_cited - _pinned))

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("D. the HTTP service")
print("=" * 78)

_HTTP = AGENTS.split("## HTTP service", 1)[1] if "## HTTP service" in AGENTS else ""

_av = re.search(r"`moonbitlang/async@([0-9.]+)`", _HTTP)
check("AGENTS cites an async version", bool(_av), _av.group(1) if _av else "")
_api_deps = [d for d in DEPS.get("examples/api_server/moon.mod", [])
             if d.startswith("moonbitlang/async@")]
check("the async version AGENTS cites is the one api_server pins",
      bool(_av) and bool(_api_deps) and _av.group(1) == _api_deps[0].split("@")[1],
      _api_deps)

_third = [i for i in pkg_imports(read("examples/api_server/moon.pkg"))
          if not (i.startswith("moonbitlang/") or i.startswith("riantr/"))]
check("the api_server imports no third-party package", not _third, _third)

_cm = re.search(r"commit `([0-9a-f]{7,40})`", _HTTP)
check("AGENTS cites a commit", bool(_cm), _cm.group(1) if _cm else "")
check("the commit AGENTS cites exists",
      bool(_cm) and gitobj(_cm.group(1)) == "commit",
      gitobj(_cm.group(1)) if _cm else "")

_main = re.search(r"lives in\s+`([^`]+)`", _HTTP, re.S)
MAIN = _main.group(1) if _main else ""
check("AGENTS names the api_server's source file", bool(MAIN), MAIN)
check("the source file AGENTS names is tracked", MAIN in TSET, MAIN)
_api_mbt = sorted(f for f in MBT_DIRS.get("examples/api_server", []))
check("the api_server package's only source file is the one AGENTS names",
      _api_mbt == [MAIN], _api_mbt)

_main_src = read("examples/api_server/main.mbt")
for span in re.findall(r"`([^`]+)`", _HTTP):
    if "::" not in span:
        continue
    _clean = span.replace("@moonbit_doubleML.", "").strip()
    _m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)::([A-Za-z_][A-Za-z0-9_]*)"
                   r"(\([^)]*\))?(.*)$", _clean)
    if not _m:
        continue
    _ty, _meth, _args, _suffix = _m.group(1), _m.group(2), _m.group(3) or "", _m.group(4)
    check("the library exports %s::%s" % (_ty, _meth),
          re.search(r"\bfn\s+%s::%s\b" % (re.escape(_ty), re.escape(_meth)),
                    LIB_SRC) is not None, _ty)
    _call = r"@moonbit_doubleML\.%s::%s\([^)]*\)%s" % (re.escape(_ty),
                                                       re.escape(_meth),
                                                       re.escape(_suffix))
    check("the api_server calls %s::%s%s" % (_ty, _meth, _suffix),
          re.search(_call, _main_src) is not None, _ty)

_api_tests = [p for p in TRACKED
              if p.startswith("examples/api_server/")
              and (p.endswith("_test.mbt") or p.endswith("_wbtest.mbt"))]
check("the api_server ships no test file", not _api_tests, _api_tests)
check("AGENTS says the api_server ships no test file",
      "ships **no** test file" in _HTTP)

_sm = re.search(r"recipe in\s+`([^`]+)`", _HTTP, re.S)
SMOKE = _sm.group(1) if _sm else ""
check("AGENTS names the smoke-test recipe's file", bool(SMOKE), SMOKE)
check("the smoke-test file AGENTS names is tracked", SMOKE in TSET, SMOKE)
check("the smoke-test recipe is a PowerShell recipe",
      "PowerShell" in read(SMOKE) if SMOKE else False)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("E. the coding convention")
print("=" * 78)

_dm = re.search(r"file called `([^`]+)`", AGENTS)
DEPF = _dm.group(1) if _dm else ""
check("AGENTS names the deprecated-blocks file", bool(DEPF), DEPF)
_dep_files = [p for p in TRACKED if os.path.basename(p) == DEPF]
check("the deprecated-blocks file AGENTS names does not exist in the tree",
      not _dep_files, _dep_files)
check("AGENTS says the deprecated-blocks file does not exist today",
      ("No `%s` file exists in the tree today." % DEPF) in AGENTS
      if DEPF else False)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
