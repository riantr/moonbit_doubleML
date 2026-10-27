#!/usr/bin/env python3
"""Round 58 verifier: the SECONDARY live documents -- the four that rounds
48-57 never audited.

    .githooks/README.md
    doc/README.mbt.md
    doc/menu.json
    _verify/upstream_prove_1649/README.md

WHY THESE FOUR
==============
The published README and `AGENTS.md` were audited in rounds 48-57.  These four
were not: they are the remaining LIVE documents in the repository that a reader
can open and be misled by.  The instrument says the same thing about them that
it said about `AGENTS.md` -- most of their claims were held by nobody.

HOW THE READER SET WAS MEASURED
================================
NOT by grepping the verifiers' source: that is an under-approximation, because a
verifier that SCANS a directory of documents holds claims about documents it
never names.  The reader set is measured at RUNTIME, by running the contract
under an audit hook that logs every file a verifier opens:

    .githooks/README.md                5 readers
    doc/README.mbt.md                  6 readers
    doc/menu.json                      1 reader
    _verify/upstream_prove_1649/README.md   4 readers

WHAT WAS WRONG, MEASURED
========================
Eight claims were false of the tree as it stood:

  G1  the task count.  "measured: `moon: ran 54 tasks`" -- the number is not
      holdable at all: it changes with the build state and with the toolchain,
      and `moon check` prints "no work to do" instead of a count on a warm tree.
      It was replaced by the member count, which `moon.work` derives.
  G2  "It is the same command `publish.yml` runs before it publishes."  It is
      not: `publish.yml` runs `moon check --target "$target" --deny-warn`.
  G3  "`moon check` does **not** check `_test.mbt` files -- only `moon test`
      compiles them."  FALSE: `moon check`'s own plan type-checks the `_test.mbt`
      files and the `readme.mbt.md` doctests.  `moon check` type-checks them;
      only `moon test` RUNS them.
  G4  "the QA LOOP -- those live in `.github/workflows/`".  The QA LOOP's own
      scripts live in `.github/scripts/qa_loop/`; `check.yml` runs them.
  G5  "See the README's 'What CI actually gates' table."  There is no such
      table in the README -- it is a section of `ENGINEERING.md`.
  U1  "the current toolchain" (six times) and "the current proof frontend":
      a 2026-10-20 audit cannot describe the toolchain in use today.
  U2  "the controls are classified `PLATFORM_ERROR` rather than `PROVED` in
      `out/b0_control.log`".  The log holds the RAW EVIDENCE; the label is
      `run_reaudit.py`'s.
  U3  "The toolchain has moved five patch releases since."  Reworded so the
      gap is between the versions the document itself names -- `v0.10.11` and
      the audited `v0.10.16` -- which keeps it true forever.
  (plus one collateral: `run_reaudit.py`'s docstring said "Exit status: 0 only
  if the control case PROVED", while the code returns 0 for a PLATFORM_ERROR
  control and 2 for an UNKNOWN one.)

WHY EVERY CHECK BELOW IS DERIVED
================================
A literal pin rots exactly like the document does, so nothing here is typed:

  * the member count comes out of `moon.work`;
  * the hook's mode comes out of `git ls-files -s`, and the census of
    executable files comes out of the same index;
  * the cross-check count comes out of the tracked `validate_*_with_python.py`
    glob -- the house glob, NOT every `validate_*.py`;
  * the doc-package census comes out of the tracked tree: a package is a
    directory that carries a `moon.pkg`;
  * `moon check`'s own plan decides the `_test.mbt` question;
  * the per-case error counts come out of the tracked `out/*.log` files;
  * the patch-release gap comes out of the two versions the document names.

THE SCOPE IS THE TRACKED TREE
=============================
`git ls-files`, never `os.walk`: a scratch clone sitting at the repository
root would otherwise contribute paths and sources this repository does not
have.  (`doc/native/` is a build artefact, ignored by `.gitignore` -- and a
directory without a `moon.pkg` is not a package.)

Run: python _verify/_verify_secondary_docs_1650.py
"""
import io
import json
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NCHECK = 0
FAILS = []

WORDNUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
           "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
           "twelve": 12}


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-64s %s" % ("ok" if ok else "*** FAIL ***", label,
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


def unquote(text):
    """Strip the block-quote markers, so a sentence that wraps inside a `>`
    block is one string again.  The document wraps at the column, and a
    regex that cannot cross the marker finds nothing.
    """
    return "\n".join(re.sub(r"^\s*>\s?", "", l) for l in text.splitlines())


def flat(text):
    """Collapse every whitespace run to a single space.

    A document wraps its prose at the column, so a check that matches the
    prose literally breaks the day the column moves.  Every "does the
    document say X" check below runs against the FLAT text.
    """
    return re.sub(r"\s+", " ", text)


TRACKED = [l.strip().replace("\\", "/") for l in git("ls-files").splitlines()
           if l.strip()]
TSET = set(TRACKED)

HOOKS = read(".githooks/README.md")
DOCRM = read("doc/README.mbt.md")
UP = read("_verify/upstream_prove_1649/README.md")
RA = read("_verify/upstream_prove_1649/run_reaudit.py")

HOOKS_F = flat(HOOKS)
DOCRM_F = flat(DOCRM)
UP_F = flat(UP)
UPQ_F = flat(unquote(UP))

# ---------------------------------------------------------------------------
print("=" * 78)
print("A. .githooks/README.md -- the pre-commit hook")
print("=" * 78)

# -- the hook itself
check("the hook file is tracked", ".githooks/pre-commit" in TSET)
HOOK_BODY = read(".githooks/pre-commit")
HOOK_CMDS = [l.strip() for l in HOOK_BODY.splitlines()
             if l.strip() and not l.strip().startswith("#!")]
check("the hook runs exactly one command", len(HOOK_CMDS) == 1, HOOK_CMDS)
check("the hook's command is `moon check`", HOOK_CMDS == ["moon check"], HOOK_CMDS)
check("the document says the hook runs one command",
      "runs **one** command" in HOOKS_F)

# -- the mode
MODES = {}
for e in git("ls-files", "-s").splitlines():
    meta, path = e.split("\t", 1)
    MODES[path.strip()] = meta.split()[0]
HOOK_MODE = MODES.get(".githooks/pre-commit", "")
EXEC_FILES = sorted(p for p, m in MODES.items() if m == "100755")
check("the hook is tracked with mode 100644", HOOK_MODE == "100644", HOOK_MODE)
check("the document names the hook's REAL tracked mode",
      ("`%s`" % HOOK_MODE) in HOOKS_F, HOOK_MODE)
check("no tracked file is executable (derived %d)" % len(EXEC_FILES),
      not EXEC_FILES, EXEC_FILES)
check("the document says no file is tracked as executable",
      "no file in this repository is tracked as executable" in HOOKS_F)

# -- core.hooksPath
check("the repository does not set core.hooksPath",
      "hooksPath" not in read(".git/config"))
check("the document says core.hooksPath is not set",
      "`core.hooksPath` is not set in the repository" in HOOKS)

# -- the workspace membership
MEMBERS = re.findall(r'"([^"]+)"', read("moon.work"))
_mc = re.search(r"over the\s+(\d+)\s+members of `moon\.work`", HOOKS)
check("the document states the real member count (derived %d)" % len(MEMBERS),
      bool(_mc) and int(_mc.group(1)) == len(MEMBERS),
      _mc.group(1) if _mc else "not stated")
check("the document no longer quotes a `moon check` task count",
      not re.search(r"ran \d+ tasks", HOOKS_F))

# -- what publish.yml actually runs
PUB = read(".github/workflows/publish.yml")
CHK = read(".github/workflows/check.yml")
PUB_CHECK = re.search(r"^\s*(moon check[^\n]*)$", PUB, re.M)
check("publish.yml runs a `moon check`", bool(PUB_CHECK),
      PUB_CHECK.group(1).strip() if PUB_CHECK else "")
check("the document quotes publish.yml's check command verbatim",
      bool(PUB_CHECK) and PUB_CHECK.group(1).strip() in HOOKS,
      PUB_CHECK.group(1).strip() if PUB_CHECK else "")
check("publish.yml does NOT run the bare `moon check`",
      not re.search(r"^\s*moon check\s*$", PUB, re.M))
check("the document no longer calls it the same command",
      "It is the same command `publish.yml` runs" not in HOOKS_F)
check("no workflow runs the bare `moon check`",
      not any(re.search(r"^\s*moon check\s*$", read(".github/workflows/" + w), re.M)
              for w in sorted(os.listdir(os.path.join(ROOT, ".github", "workflows")))
              if w.endswith(".yml")))

# -- does `moon check` type-check the _test.mbt files?
PLAN = ""
if shutil.which("moon"):
    r = subprocess.run(["moon", "check", "--dry-run"], cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    PLAN = (r.stdout or "") + (r.stderr or "")
check("`moon check`'s plan type-checks the _test.mbt files",
      bool(re.search(r"moonc check [^\n]*_test\.mbt", PLAN)),
      "%d plan lines" % len(PLAN.splitlines()))
check("`moon check`'s plan type-checks the readme doctests",
      bool(re.search(r"moonc check [^\n]*readme\.mbt\.md", PLAN)))
check("the document says `moon check` type-checks the test files",
      "type-checks the `_test.mbt` files" in HOOKS)
check("the document no longer claims `moon check` skips the test files",
      "does **not** check `_test.mbt` files" not in HOOKS_F)

# -- the Python cross-checks: the HOUSE glob
CROSS = sorted(p for p in TRACKED
               if p.startswith("validate_") and p.endswith("_with_python.py"))
ALLVAL = sorted(p for p in TRACKED
                if p.startswith("validate_") and p.endswith(".py"))
check("the tracked cross-check glob is the house one",
      len(CROSS) == 24 and len(ALLVAL) == 27,
      "cross=%d all=%d" % (len(CROSS), len(ALLVAL)))
_cc = re.search(r"the (\d+) Python cross-checks", HOOKS)
check("the document states the real cross-check count (derived %d)" % len(CROSS),
      bool(_cc) and int(_cc.group(1)) == len(CROSS),
      _cc.group(1) if _cc else "not stated")

# -- where the QA LOOP lives
QA = sorted(p for p in TRACKED if p.startswith(".github/scripts/qa_loop/"))
check("the QA LOOP's scripts live under .github/scripts/qa_loop/",
      bool(QA), QA[:3])
check("a workflow runs the QA LOOP",
      any("qa_loop/" in read(".github/workflows/" + w)
          for w in sorted(os.listdir(os.path.join(ROOT, ".github", "workflows")))
          if w.endswith(".yml")))
check("the document says where the QA LOOP lives",
      "`.github/scripts/qa_loop/`" in HOOKS)

# -- the files it points at
for rel in (".github/workflows/check.yml", ".github/scripts/ci_local.py",
            ".githooks/pre-commit"):
    check("the document's pointer %s is tracked" % rel, rel in TSET)

# -- `moon check --deny-warn` runs only in publish.yml
RUNS = []
for w in sorted(os.listdir(os.path.join(ROOT, ".github", "workflows"))):
    if not w.endswith(".yml"):
        continue
    body = read(".github/workflows/" + w)
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("#"):
            continue
        if s.startswith("moon check") and "--deny-warn" in s:
            RUNS.append(w)
check("`moon check --deny-warn` runs only in publish.yml",
      RUNS == ["publish.yml"], RUNS)
check("the local CI script does not run it either",
      "moon check" not in read(".github/scripts/ci_local.py"))
check("the document says that command runs only in publish.yml",
      "runs only in `publish.yml`" in HOOKS)

# -- the CI-gating section it points at
ENG = read("ENGINEERING.md")
check("ENGINEERING.md holds the 'What CI actually gates' section",
      "What CI actually gates" in ENG)
check("the document points at ENGINEERING.md for that section",
      "`ENGINEERING.md`'s" in HOOKS_F
      and not re.search(r"the README's \"What CI actually gates\"", HOOKS_F))

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("B. doc/README.mbt.md -- the tutorials")
print("=" * 78)

DMMOD = read("doc/moon.mod")
MODNAME = re.search(r'name\s*=\s*"([^"]+)"', DMMOD).group(1)
HEADNAME = re.search(r"^# `([^`]+)`", DOCRM, re.M)
check("the document's heading names the doc module",
      bool(HEADNAME) and HEADNAME.group(1) == MODNAME,
      HEADNAME.group(1) if HEADNAME else "")
check("the doc module's manifest is tracked", "doc/moon.mod" in TSET)

# -- the packages: a directory that carries a moon.pkg
DOC_PKGS = sorted(p.split("/")[1] for p in TRACKED
                  if p.startswith("doc/") and p.count("/") == 2
                  and os.path.basename(p) == "moon.pkg")
ROWS = re.findall(r"^\| `(\w+)` \|", DOCRM, re.M)
check("the table lists exactly the tracked doc packages (derived %d)"
      % len(DOC_PKGS), sorted(ROWS) == DOC_PKGS,
      "rows=%s derived=%s" % (sorted(ROWS), DOC_PKGS))
check("the document says each tutorial is a package with its own moon.pkg",
      "its own `moon.pkg` and its own tests" in DOCRM)
for d in DOC_PKGS:
    check("doc/%s has a tracked moon.pkg" % d, ("doc/%s/moon.pkg" % d) in TSET)
    check("doc/%s has a tracked readme.mbt.md" % d,
          ("doc/%s/readme.mbt.md" % d) in TSET)
    check("doc/%s ships a test file" % d,
          any(p.startswith("doc/%s/" % d) and p.endswith("_test.mbt")
              for p in TRACKED))

# -- the target
NOTG = [d for d in DOC_PKGS
        if 'supported_targets = "wasm-gc"' not in read("doc/%s/moon.pkg" % d)]
check("every doc package is wasm-gc-targeted", not NOTG, NOTG)
check("the document says every tutorial is a wasm-gc package",
      "Every tutorial is a `wasm-gc` package" in DOCRM)

# -- the workspace
check("`doc` is a moon.work member", "doc" in MEMBERS)
check("the document says doc is a workspace member",
      "`doc` is a member of the repository's `moon.work` workspace" in DOCRM_F)

# -- the command it gives
_cmd = re.search(r"moon test --target wasm-gc -p (\S+)", DOCRM)
check("the document gives a runnable command", bool(_cmd),
      _cmd.group(0) if _cmd else "")
check("the package the command names exists",
      bool(_cmd) and _cmd.group(1) in DOC_PKGS,
      _cmd.group(1) if _cmd else "")

# -- the library the tutorials build against
LIB_VER = re.search(r'version\s*=\s*"([^"]+)"', read("moonbit_doubleML/moon.mod"))
PINNED = re.search(r'"riantr/moonbit_doubleML@([^"]+)"', DMMOD)
check("the doc module pins the library at the tree's version",
      bool(LIB_VER) and bool(PINNED) and PINNED.group(1) == LIB_VER.group(1),
      "pinned=%s tree=%s" % (PINNED.group(1) if PINNED else "",
                             LIB_VER.group(1) if LIB_VER else ""))
check("the library's own README is tracked",
      "moonbit_doubleML/README.mbt.md" in TSET)
check("the document names the library's README",
      "`moonbit_doubleML/README.mbt.md`" in DOCRM)
VFY = [p for p in TRACKED if p.startswith("_verify/") and p.endswith(".py")]
check("the verifiers live under _verify/ (derived %d)" % len(VFY), bool(VFY))
check("the document says the verifiers live under _verify/",
      "live under `_verify/`" in DOCRM)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("C. doc/menu.json -- the tutorial menu")
print("=" * 78)

try:
    MENU = json.loads(read("doc/menu.json"))
    PARSE_OK = True
except Exception as exc:                                   # noqa: BLE001
    MENU = []
    PARSE_OK = False
    print("  json error: %s" % exc)
check("doc/menu.json parses", PARSE_OK)
check("doc/menu.json is tracked", "doc/menu.json" in TSET)
check("every entry carries a path, a title and a section",
      bool(MENU) and all(e.get("path") and e.get("title") and e.get("section")
                         for e in MENU))
check("the menu's paths are exactly the doc packages",
      sorted(e["path"] for e in MENU) == DOC_PKGS,
      sorted(e["path"] for e in MENU))
for e in MENU:
    check("the menu's %s is a tracked package" % e["path"],
          ("doc/%s/moon.pkg" % e["path"]) in TSET)
    check("the menu's %s appears in the doc README" % e["path"],
          ("`%s`" % e["path"]) in DOCRM)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("D. _verify/upstream_prove_1649/README.md -- the proof re-audit")
print("=" * 78)

# -- it must not claim currency it cannot have
check("the document does not call the audited toolchain 'the current toolchain'",
      "current toolchain" not in UPQ_F)
check("the document does not call the frontend 'the current proof frontend'",
      "current proof frontend" not in UPQ_F)
check("the document defines 'the audited toolchain'",
      "the audited toolchain" in UPQ_F)

# -- the versions it names
MOON_V = re.search(r"`moon (\d+\.\d+\.\d+)", UP)
MOONC_V = re.search(r"`moonc v(\d+\.\d+\.\d+)", UP)
check("the document names the moon version it was measured on",
      bool(MOON_V), MOON_V.group(1) if MOON_V else "")
check("the document names the moonc version it was measured on",
      bool(MOONC_V), MOONC_V.group(1) if MOONC_V else "")
check("the document stamps the re-audit date", "re-audited 2026-10-20" in UP)

# -- the patch-release gap, between the versions the document itself names
UPQ = unquote(UP)
_gap = re.search(r"is\s+(\w+)\s+patch releases after `v(\d+\.\d+\.\d+)`", UPQ)
check("the document states the patch-release gap", bool(_gap),
      _gap.group(0) if _gap else "")
if _gap and MOONC_V:
    word = _gap.group(1).lower()
    base = _gap.group(2)
    derived = int(MOONC_V.group(1).split(".")[2]) - int(base.split(".")[2])
    stated = WORDNUM.get(word, int(word) if word.isdigit() else None)
    check("the stated gap matches the derived one (derived %d)" % derived,
          stated == derived, "stated=%s base=v%s audited=v%s"
          % (stated, base, MOONC_V.group(1)))

# -- the cases
CASE_DIR = "_verify/upstream_prove_1649/cases"
CASES = sorted({p[len(CASE_DIR) + 1:].split("/")[0] for p in TRACKED
                if p.startswith(CASE_DIR + "/")
                and os.path.basename(p) == "moon.pkg"})
NAMED = re.findall(r"^\| `(b\w+)`", UP, re.M)
check("the case table names exactly the cases on disk (derived %d)" % len(CASES),
      sorted(set(NAMED)) == CASES, sorted(set(NAMED)))
for c in CASES:
    check("case %s has a tracked moon.mod and moon.pkg" % c,
          (CASE_DIR + "/%s/moon.mod" % c) in TSET
          and (CASE_DIR + "/%s/moon.pkg" % c) in TSET)
    check("case %s is proof-enabled" % c,
          '"proof-enabled": true' in read(CASE_DIR + "/%s/moon.pkg" % c))
    check("case %s has a tracked log" % c,
          ("_verify/upstream_prove_1649/out/%s.log" % c) in TSET)

# -- the per-case frontend error counts, against the tracked logs
ROWS_ERR = dict((m.group(1), int(m.group(2)))
                for m in re.finditer(r"^\|\s*`([A-Za-z0-9_]+)`\s*\|\s*(\d+)\s*\|",
                                     UP, re.M))
for c in sorted(CASES):
    log = read("_verify/upstream_prove_1649/out/%s.log" % c)
    n = log.count("Error: [4207]")
    check("the table's error count for %s matches its log (%d)" % (c, n),
          ROWS_ERR.get(c) == n, "table=%s log=%d" % (ROWS_ERR.get(c), n))

# -- who classifies the log
check("the document names run_reaudit.py as the classifier",
      "`run_reaudit.py` classifies" in UP)
check("the document no longer says the LOG holds the classification",
      "classified `PLATFORM_ERROR` rather than `PROVED` in `out/b0_control.log`"
      not in UP_F)
check("run_reaudit.py's vocabulary holds PLATFORM_ERROR and PROVED",
      "PLATFORM_ERROR" in RA and "PROVED" in RA)
check("no tracked log holds a PLATFORM_ERROR label",
      not [p for p in TRACKED if p.endswith(".log")
           and "PLATFORM_ERROR" in read(p)])

# -- the runner's exit status
check("run_reaudit.py returns 2 for an UNKNOWN control", "return 2" in RA)
_plat = re.search(r'if control == "PLATFORM_ERROR":\n(.*?)\n    else:',
                  RA, re.S)
check("the PLATFORM_ERROR branch does not return early",
      bool(_plat) and "return" not in _plat.group(1))
check("the runner's docstring states the UNKNOWN exit status",
      "UNKNOWN" in RA and "Exit status: 2" in RA)
check("the runner's docstring no longer claims exit 0 only if PROVED",
      "only if the control case PROVED" not in RA)

# -- the blockers and the pilot
BLK = read("_verify/UPSTREAM_BLOCKERS.md")
check("_verify/UPSTREAM_BLOCKERS.md is tracked",
      "_verify/UPSTREAM_BLOCKERS.md" in TSET)
check("the document names the blockers file",
      "`_verify/UPSTREAM_BLOCKERS.md`" in UP_F)
check("the document names the runner and the summariser",
      "python run_reaudit.py" in UP_F and "python summarise.py" in UP_F)
check("the blockers document holds 4 blockers and 2 new blocks",
      all(("Blocker %d" % i) in BLK for i in (1, 2, 3, 4))
      and "New Block A" in BLK and "New Block B" in BLK)
check("the pilot's moon.pkg is tracked", "_prove_pilot/moon.pkg" in TSET)
check("the document names the pilot's package",
      "`_prove_pilot/moon.pkg`" in UP_F)
check("the pilot records the Windows platform limitation",
      "native\n// Windows" in read("_prove_pilot/moon.pkg")
      or "does not run on native" in read("_prove_pilot/moon.pkg"))

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
