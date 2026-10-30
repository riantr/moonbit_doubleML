"""Hold the README's SHAPE -- the structure the two references have.

WHY
===
Rounds 48-58 audited the TEXT of every live document.  This round audits the
SHAPE: what a reader is GIVEN, and in what order.

The references the user named -- `Ridge-Lab/capnp@0.1.0` and
`gaato/discord@0.10.0` -- were MEASURED feature by feature against this
README (the table is reproduced below, from that measurement).  Four gaps came
out of the comparison -- the table's last column is the README AS IT STOOD
BEFORE THIS ROUND'S PATCHES, because the patches are what close them:

  G1  the README carried NO IMAGE at all -- both references open with a CI
      badge, and this README had none;
  G2  the README had no STATUS paragraph near the top -- discord opens its
      prose with one, and this README's status sat 590 lines down, under
      "Development status";
  G3  the README stated no MINIMUM toolchain -- capnp says which MoonBit it
      needs ("需要 MoonBit 0.10.14 或更新版本").  NOTHING in this tree
      establishes a floor: `moon.mod` declares no toolchain constraint, and
      the workflows install the LATEST `moon` rather than pinning one.  So a
      floor is REFUSED rather than published, and what the README says
      instead -- the toolchain it was VERIFIED on -- is held here;
  G4  the shape was not HELD: nothing failed if the next bump dropped the
      badge, because the README is GENERATED and a generator change can lose
      a section without any red line.

G1, G2 and G4 are closed by this file and by the two patches in
`_verify/_r18_build_readme_1650.py`.  G3 is closed by the refusal itself: the
README states the toolchain it was measured on, and this verifier holds that
statement's presence.

A LATER ROUND (71) CHANGED G3's PREMISE
========================================
The G3 paragraph above is the round-59 finding, and it is LEFT AS IT WAS
WRITTEN -- a record of what was true then.  It is no longer true.  The tree
DOES establish a floor now, and the README states it.

What changed is the dependency.  Round 70 moved the pin to
`moonbitlang/async@0.22.6`, and that is the first published version whose
source imports `moonbitlang/core/async`: every version from 0.10.0 to 0.22.5
imports it in ZERO files.  The core shipped with `moon 0.1.20261028` is the
first to carry the subpackage, so the pin move created a floor where there
had been none.  A CONSUMER on the older core cannot resolve the dependency at
all -- "Cannot find import 'moonbitlang/core/async' in
moonbitlang/async@0.22.6" -- and the same consumer builds on the newer one.

So the README now states the requirement in its Installation section, and
`_verify/_verify_toolchain_floor_1680.py` holds it.  The refusal is not
reversed here: this file still holds the toolchain the release was VERIFIED
on, which is a different statement from the minimum a reader needs.

A LATER ROUND (72) MEASURED THE BADGE ROW AGAIN, AND DROPPED THE PLAN
=====================================================================
The G1 finding above left a plan open: give this README discord@0.10.0's
six-badge opening (CI, Voice shim, Release, mooncakes, DeepWiki, License).
Round 72 re-measured the references -- they have both published since round
59 measured them -- and that plan is DROPPED, on the references' own
evidence:

  package            badges at the named version              badges now
  Ridge-Lab/capnp    1 (CI)                                   1 (CI)
  gaato/discord      6 (CI, Voice shim, Release, mooncakes,
                       DeepWiki, License)                     2 (CI, License)

discord REMOVED four of its six badges between 0.10.0 and 0.13.0: the
Release, the mooncakes, the DeepWiki and the Voice shim ones are gone.  The
reference author dropped them, so a badge row is not a property the
references have -- it is decoration that one of them has since deleted.
capnp carries exactly ONE badge, the CI one, at BOTH versions -- which is
what this README carries.

So the badge row stays as it is: one CI badge, which is what capnp has and
what discord kept.  (The DeepWiki badge was never a candidate anyway: its
badge URL answers 429, so it cannot be verified.)

THE MEASUREMENT (the two references against this README BEFORE THIS ROUND)
==========================================================================
  feature                                capnp@0.1.0    discord@0.10.0  this README
  an image at all                        yes            yes            NO   <- G1
  a CI badge (actions/workflows)         yes            yes            NO   <- G1
  a status line near the top             --             yes            NO   <- G2
  a minimum toolchain stated             yes            --             NO   <- G3
  a console block (cmd + output)         --             --             yes
  a shell block                          yes            yes            yes
  a moonbit block                        yes            --             yes
  a section for what is NOT covered      yes            --             yes
  a section for verification             yes            --             yes
  a licence section                      --             yes            yes
  an install/add command                 yes            yes            yes
  says 'moon update'                     yes            yes            yes
  a provenance/attribution pointer       yes            --             yes
  a table                                yes            yes            yes
  a backend/target column in a table     --             yes            yes
  states a test count                    --             --             yes

WHAT THIS FILE DOES NOT CHECK, AND WHY
======================================
* The VALUES the README states.  A shape check asks "is the badge there and
  does it point at a workflow that runs?"; a VALUE check asks "is the number
  right?".  The numbers are held by `_verify/_verify_number_promises_1650.py`
  (51), `_verify/_verify_doc_numbers_1650.py` (52),
  `_verify/_verify_testcounts_1610.py` and
  `_verify/_verify_toolchain_claims_1640.py`.  Two verifiers holding the same
  value is how they drift apart.
* The references themselves.  They live on a registry, not in this tree, so a
  check that fetched them would fail on a machine with no network -- and the
  shape they define is reproduced above, in full, from a measurement that is
  dated in this file's own words.

WHERE THE README COMES FROM
============================
It is GENERATED: `_verify/_r18_build_readme_1650.py` reads a base and applies
a list of patches, each of which must match exactly once.  So a shape that is
only in the built file is lost by the next bump, and this verifier is what
says so.  This verifier reads the WORKING TREE on purpose: a mutation of the
README is then visible without a commit, which is what the dry-run driver
needs.

Run: python _verify/_verify_readme_shape_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-62s %s" % (label[:62], detail))
    else:
        print("  *** FAIL *** %-54s %s" % (label[:54], detail))
        FAILS.append("%s -- %s" % (label, detail))


def git(*args):
    p = subprocess.run(["git"] + list(args), cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return p.returncode, ((p.stdout or "") + (p.stderr or ""))


def read(rel):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        return ""
    return io.open(p, encoding="utf-8", errors="replace").read()


_rc, _out = git("ls-files")
TRACKED = [ln.strip().replace("\\", "/") for ln in _out.splitlines() if ln.strip()]
TRACKED_SET = set(TRACKED)

README = read("README.mbt.md")
MANIFEST = read(os.path.join("moonbit_doubleML", "moon.mod"))

# --------------------------------------------------------------------------
# 1.  THE TREE -- the quantities the shape is measured against
# --------------------------------------------------------------------------

def manifest_field(name):
    m = re.search(r"(?m)^\s*%s\s*=\s*\"([^\"]*)\"" % re.escape(name), MANIFEST)
    return m.group(1) if m else ""


LICENSE = manifest_field("license")
VERSION = manifest_field("version")
TARGETS = manifest_field("supported_targets")
BACKENDS = [t for t in TARGETS.split("+") if t]

# the estimator structs: a `DoubleML*` struct that is not a `*Data` container.
# The SAME derivation as `_verify/_verify_number_promises_1650.py`, so the two
# verifiers cannot disagree about how many estimators there are.
pkg_prod = [t for t in TRACKED
            if t.startswith("moonbit_doubleML/") and t.endswith(".mbt")
            and "/" not in t[len("moonbit_doubleML/"):]
            and not t.endswith("_test.mbt") and not t.endswith("_wbtest.mbt")]
structs = {}
for rel in pkg_prod:
    body = read(rel)
    for m in re.finditer(r"^\s*(?:pub\s+)?(?:struct|enum)\s+(DoubleML[A-Za-z0-9]*)",
                         body, re.M):
        structs.setdefault(m.group(1), set()).add(rel)
ESTIMATORS = sorted(n for n in structs if not n.endswith("Data"))
NEST = len(ESTIMATORS)

# --------------------------------------------------------------------------
# 2.  THE DOCUMENT -- where the shape lives
# --------------------------------------------------------------------------

LINES = README.split("\n")
FIRST_H2 = next((n for n, l in enumerate(LINES) if l.startswith("## ")), len(LINES))
HEADINGS = [l.lstrip("#").strip() for l in LINES if re.match(r"^#{2,3}\s+\S", l)]

# the images the README carries
IMAGES = re.findall(r"!\[([^\]]*)\]\(([^)]+)\)", README)
BADGE_RE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/actions/workflows/([^/]+)/badge\.svg$")

badges = []
for alt, url in IMAGES:
    m = BADGE_RE.match(url)
    if m:
        badges.append((alt, url, m.group(1), m.group(2), m.group(3)))

# the README's own repository, from its own Repository row
repo_row = re.search(r"(?m)^\|\s*Repository\s*\|\s*`([^`]+)`\s*\|", README)
REPO_URL = repo_row.group(1) if repo_row else ""
repo_m = re.match(r"^https://github\.com/([^/]+)/([^/]+)/?$", REPO_URL)
REPO_OWNER = repo_m.group(1) if repo_m else ""
REPO_NAME = repo_m.group(2) if repo_m else ""

# the status paragraph: a blockquote whose first line says **Status**
STATUS_LINE_RE = re.compile(r"^>\s*\*\*Status\*\*\s*:")
status_start = None
for n, l in enumerate(LINES):
    if STATUS_LINE_RE.match(l):
        status_start = n
        break
status_lines = []
if status_start is not None:
    for l in LINES[status_start:]:
        if not l.startswith(">"):
            break
        status_lines.append(l)
STATUS = "\n".join(status_lines)

# --------------------------------------------------------------------------
# 3.  THE BADGE -- G1
# --------------------------------------------------------------------------
print("=== the badge ===")

check("the README carries an image at all", len(IMAGES) >= 1,
      "%d image(s)" % len(IMAGES))
check("exactly one image is a CI badge", len(badges) == 1,
      "%d badge(s)" % len(badges))

badge = badges[0] if badges else None
if badge is None:
    check("the badge names a tracked workflow", False, "no badge to check")
    check("the badge points at this project's repository", False, "no badge")
    check("the badge's alt text is the workflow's name", False, "no badge")
    check("the badge's link target is the workflow's page", False, "no badge")
    check("the badge's workflow runs on a push to the release branch", False, "no badge")
    check("the badge is in the README's opening screen", False, "no badge")
else:
    alt, url, owner, name, wf = badge
    wf_rel = ".github/workflows/%s" % wf
    check("the badge names a tracked workflow", wf_rel in TRACKED_SET, wf_rel)

    check("the badge points at this project's repository",
          owner == REPO_OWNER and name == REPO_NAME,
          "%s/%s vs the README's %s/%s" % (owner, name, REPO_OWNER, REPO_NAME))

    wf_body = read(wf_rel)
    nm = re.search(r"(?m)^name:\s*(.+?)\s*$", wf_body)
    wf_name = nm.group(1).strip().strip('"') if nm else ""
    check("the badge's alt text is the workflow's name", alt == wf_name,
          "alt=%r name=%r" % (alt, wf_name))

    target = "https://github.com/%s/%s/actions/workflows/%s" % (owner, name, wf)
    check("the badge's link target is the workflow's page",
          target in README, target)

    # the `on:` block: does a push to the release branch run it?
    on_m = re.search(r"(?m)^on:\s*$", wf_body)
    on_block = ""
    if on_m:
        for l in wf_body[on_m.end():].split("\n"):
            if l.strip() == "" or l.startswith(" "):
                on_block += l + "\n"
            else:
                break
    push_m = re.search(r"(?m)^\s*push:\s*$", on_block)
    branches = ""
    if push_m:
        bm = re.search(r"(?m)^\s*branches:\s*\[([^\]]*)\]", on_block)
        if bm:
            branches = bm.group(1)
        else:
            bm = re.search(r"(?m)^\s*branches:\s*$", on_block)
            if bm:
                for l in on_block[bm.end():].split("\n"):
                    if l.strip() == "" or l.startswith(" "):
                        branches += l
                    else:
                        break
    branch_names = re.findall(r"[\w.-]+", branches)
    check("the badge's workflow runs on a push to the release branch",
          ("master" in branch_names or "main" in branch_names),
          "push branches: %s" % (branch_names or "(none)"))

    badge_line = next((n for n, l in enumerate(LINES)
                       if url in l), len(LINES))
    check("the badge is in the README's opening screen", badge_line < FIRST_H2,
          "line %d, first H2 at line %d" % (badge_line + 1, FIRST_H2 + 1))

# the OPENING ORDER: title, badge, opening paragraph, status, first section.
# The shape is an ORDER, not a set -- a badge at the bottom of the file is a
# different shape from a badge at the top, and only the order tells them apart.
TITLE_IDX = next((n for n, l in enumerate(LINES) if l.startswith("# ")), 0)
BADGE_IDX = next((n for n, l in enumerate(LINES)
                  if any(u in l for _, u in IMAGES)), len(LINES))
INTRO_IDX = next((n for n, l in enumerate(LINES)
                  if n > TITLE_IDX and l.strip() and not l.startswith(">")
                  and not any(u in l for _, u in IMAGES)), len(LINES))
STATUS_IDX = status_start if status_start is not None else len(LINES)
check("the opening has the reference's order: title, badge, paragraph, status",
      TITLE_IDX < BADGE_IDX < INTRO_IDX < STATUS_IDX < FIRST_H2,
      "title %d, badge %d, paragraph %d, status %d, first H2 %d"
      % (TITLE_IDX + 1, BADGE_IDX + 1, INTRO_IDX + 1, STATUS_IDX + 1,
         FIRST_H2 + 1))

# --------------------------------------------------------------------------
# 4.  THE STATUS PARAGRAPH -- G2
# --------------------------------------------------------------------------
print()
print("=== the status paragraph ===")

check("the README has a status paragraph", status_start is not None,
      "line %s" % (status_start + 1 if status_start is not None else "-"))
check("the status paragraph is one paragraph", len(status_lines) >= 1,
      "%d quoted line(s)" % len(status_lines))
if status_start is not None:
    check("the status paragraph is in the README's opening screen",
          status_start < FIRST_H2,
          "line %d, first H2 at line %d" % (status_start + 1, FIRST_H2 + 1))
else:
    check("the status paragraph is in the README's opening screen", False, "none")

check("the status paragraph names the licence", LICENSE in STATUS,
      "%s %s" % (LICENSE, "found" if LICENSE in STATUS else "MISSING"))
check("the status paragraph names every declared backend",
      all(b in STATUS for b in BACKENDS),
      "%s" % ", ".join(BACKENDS))
check("the status paragraph names the estimator count",
      re.search(r"\b%d\b" % NEST, STATUS) is not None,
      "%d estimators" % NEST)
check("the status paragraph points at a section that exists",
      any(h and h in STATUS for h in HEADINGS),
      ", ".join(h for h in HEADINGS if h and h in STATUS) or "none")
check("the status paragraph says what is NOT claimed",
      re.search(r"not\*{0,2}\s+claimed", STATUS, re.I) is not None, "")
# a version literal in a NEW place is a new bump site; the bump script does not
# know about it, so the number would go stale on the next release.
ver_prefix = ".".join(VERSION.split(".")[:2]) + "." if VERSION else ""
check("the status paragraph carries no library version literal",
      (ver_prefix not in STATUS) if ver_prefix else True,
      "no %s" % ver_prefix)

# --------------------------------------------------------------------------
# 5.  THE SHAPE THE REFERENCES SHARE
# --------------------------------------------------------------------------
print()
print("=== the shape the references share ===")

CONSOLE_RE = re.compile(r"```console\n(.*?)```", re.S)
consoles = CONSOLE_RE.findall(README)
cmd_block = next((c for c in consoles if re.search(r"(?m)^\$\s+\S", c)), "")
check("the README has a console block with a command and its output",
      bool(cmd_block) and bool(re.search(r"(?m)^\S.*\n", cmd_block.split("\n", 1)[-1])),
      "%d console block(s)" % len(consoles))
check("the README has a shell block with the install command",
      re.search(r"```(?:sh|bash)\n[^`]*\bmoon add\b", README) is not None, "")
check("the install flow names `moon update`",
      "moon update" in README, "")
check("the README has a MoonBit block with an import",
      re.search(r"```moonbit\b[^`]*import \{", README) is not None, "")
check("the README has a section for what is NOT covered",
      any(re.search(r"(?i)not covered|not implemented", h) for h in HEADINGS),
      ", ".join(h for h in HEADINGS if re.search(r"(?i)not covered|not implemented", h)))
check("the README has a licence section",
      any(re.match(r"(?i)licen[cs]e", h) for h in HEADINGS), "")
check("the README has an attribution or provenance section",
      any(re.search(r"(?i)attribution|provenance", h) for h in HEADINGS), "")
# a table row that names EVERY declared backend -- derived from the manifest,
# so the row is held against the manifest's own list, not a hand-kept wording
backend_rows = [l for l in README.split("\n")
                if l.startswith("|") and all(b in l for b in BACKENDS)]
check("the README has a table row naming every declared backend",
      len(backend_rows) >= 1, "%d row(s)" % len(backend_rows))
check("the README states the toolchain it was verified on",
      re.search(r"`moon\s+\d+\.\d+\.\d+`", README) is not None, "")
check("the README states a test count",
      re.search(r"(?m)^\|\s*Tests\b[^|]*\|\s*\*\*\d+", README) is not None, "")

# the file the provenance section names must be a TRACKED path
prov = [h for h in HEADINGS if re.search(r"(?i)attribution|provenance", h)]
prov_paths = []
for m in re.finditer(r"`([^`\n]+\.md)`", README):
    tok = m.group(1)
    if tok.startswith("_verify/") or tok.startswith("doc/"):
        prov_paths.append(tok)
untracked = sorted(set(p for p in prov_paths if p not in TRACKED_SET))
check("every provenance file the README names is tracked", not untracked,
      ", ".join(untracked) or "%d path(s) checked" % len(set(prov_paths)))

# --------------------------------------------------------------------------
print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    print("=" * 78)
    for f in FAILS:
        print("  FAIL %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
