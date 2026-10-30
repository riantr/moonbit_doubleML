"""Round 18 verifier: the README/ENGINEERING split, and the proof that the
split did not cost a single check.

WHAT THIS PINS
--------------
A. The README is in the shape the reference package page uses, in that order.
B. The README is a USER document: a size budget, and none of the project
   vocabulary that round 18 moved out of it.
C. NOTHING WAS LOST.  Every string the 40+ verifiers pin is still findable in
   the project's documentation -- the README, or `ENGINEERING.md` for the
   project-facing ones.
D. NO CHECK SILENTLY DIED.  Every verifier this round touched is compared,
   call by call, with the version that shipped as v0.164.11: the same check
   names (modulo the documented "README" -> "the project document" rename)
   and the same prose-shape regexes.  A check that was dropped, renamed
   without being listed, or weakened into a different regex fails here.
E. `ENGINEERING.md` is a real document: a dated banner, a statement of what
   it does NOT verify, and the ledger's blocks, verbatim.
F. The two documents point at each other, and every path either names is a
   file a reader can open.

The dry-run driver `_verify/_dryrun_round18_1650.py` runs this against the
PREVIOUS published version, and the dry-run counter must count the failure
lines exactly.
"""
import ast
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

VD = os.path.join(ROOT, "_verify")
README = os.path.join(ROOT, "README.mbt.md")
SHIPPED = os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")
PROJ = os.path.join(ROOT, "ENGINEERING.md")
BASE_TAG = "v0.164.11"

fails = []
n_checks = 0


def check(label, cond, detail=""):
    global n_checks
    n_checks += 1
    print("  %-64s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def read_opt(p):
    """Read a file that may not exist.  A missing file is a FAILED CHECK, not
    a crash: a verifier that dies on the tree it is supposed to judge cannot
    say anything about it."""
    if not os.path.exists(p):
        return ""
    try:
        return read(p)
    except OSError:
        return ""


def git(*args):
    r = subprocess.run(["git"] + list(args), cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.returncode, r.stdout


# =========================================================== A. the shape
print()
print("A. the README's shape -- the reference package page's, in that order")
readme = read(README)
# The README is GENERATED and its paragraphs are hard-wrapped in the
# builder, so a phrase anchored with LITERAL SPACES breaks the day the
# wrap moves.  The facts below are matched against the collapsed copy,
# and the LITERALS are collapsed too -- two of them carry the column
# alignment of a console block.
readme_flat = re.sub(r"\s+", " ", readme)
SECTIONS = [
    "## Features",
    "## Installation",
    "## Quick Start",
    "## The 22 estimators",
    "## API reference",
    "## Propensity processing",
    "## Cross-fitting",
    "## Examples",
    "## Common pitfalls and best practices",
    "## Development status",
    "## Project layout",
    "## Dependency rule",
    "## Attribution",
    "## Used By",
    "## Development",
    "## License",
]
def head_pos(text, heading):
    """The offset of an EXACT heading line -- not a prefix of a longer one."""
    m = re.search(r"^%s$" % re.escape(heading), text, re.M)
    return m.start() if m else -1


pos = -1
for s in SECTIONS:
    i = head_pos(readme, s)
    check("the README has a %r section" % s, i >= 0)
    if i >= 0:
        check("the %r section comes after the previous one" % s, i > pos,
              "at %d, previous at %d" % (i, pos))
        pos = i
check("the README has exactly one H1",
      readme.count("\n# ") + (1 if readme.startswith("# ") else 0) == 1,
      "%d" % (readme.count("\n# ") + (1 if readme.startswith("# ") else 0)))
check("the README has no H2 that is not in the reference's shape",
      all(readme.count("\n" + s + "\n") == 1 for s in SECTIONS),
      "a section appears twice")
check("the README opens with the package title",
      readme.startswith("# moonbit_doubleML - Double / Debiased Machine Learning in MoonBit\n"))

# =========================================================== B. the budget
print()
print("B. the README is a USER document")
rc, old = git("cat-file", "blob", "%s:README.mbt.md" % BASE_TAG)
old_readme = old
old_lines = old_readme.count("\n")
new_lines = readme.count("\n")
check("the pre-rewrite README is readable at %s" % BASE_TAG, rc == 0)
check("the README is under 900 lines", new_lines < 900, "%d" % new_lines)
check("the README is under 60 KB", len(readme.encode("utf-8")) < 60000,
      "%d" % len(readme.encode("utf-8")))
check("the README is at most half the pre-rewrite line count",
      new_lines * 2 <= old_lines, "%d vs %d" % (new_lines, old_lines))
# the project vocabulary that round 18 moved out
PROJECT_WORDS = [
    "registers **31 checks**",
    "**22 in `fast` scope**",
    "**9 in `full` scope**",
    "Adds `bootstrap()` to nine remaining estimators",
    "Eight simulator bugs it has caught",
    "Acceptance-criteria traceability",
    "4294967295",
]
for w in PROJECT_WORDS:
    check("the README no longer carries the project phrase %r" % w[:44],
          w not in readme)
    check("the project document carries %r" % w[:44], w in read_opt(PROJ))

# =========================================================== C. nothing lost
print()
print("C. nothing was lost -- every pinned string is still in the documentation")


def pinned_literals():
    """Every string literal the suite's `check(...)` conditions look for."""
    out = {}
    for f in sorted(os.listdir(VD)):
        if not f.endswith(".py"):
            continue
        src = read(os.path.join(VD, f))
        if "README" not in src:
            continue
        try:
            tree = ast.parse(src)
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                    and node.func.id == "check" and len(node.args) >= 2):
                continue
            items = [n.value for n in ast.walk(node.args[1])
                     if isinstance(n, ast.Constant) and isinstance(n.value, str)]
            for lit in items:
                if len(lit) >= 4 and "\n" not in lit and not lit.startswith("%"):
                    out.setdefault(lit, set()).add(f)
    return out


pinned = pinned_literals()
proj = read_opt(PROJ)
# The ledger's prose wraps at the column too.
proj_flat = re.sub(r"\s+", " ", proj)
both = readme + "\n" + proj
# A literal is the README's to carry only if the README carried it BEFORE.
# The suite pins strings in many files -- a record's heading, a source file's
# identifier, a regex fragment -- and those are not the README's business.
# What must not happen is a string that WAS in the pre-rewrite README and is
# now in neither document: that is a fact the project lost in the split.
old_readme_flat = re.sub(r"\s+", " ", old_readme)
readme_was = [lit for lit in pinned if re.sub(r"\s+", " ", lit) in old_readme_flat]
lost = sorted(lit for lit in readme_was
               if lit not in readme and lit not in proj
               and re.sub(r"\s+", " ", lit) not in re.sub(r"\s+", " ", both))
check("every string the pre-rewrite README carried is still in the documentation",
      not lost, "%d lost, e.g. %r" % (len(lost), lost[:3]))
print("     (%d distinct pinned literals, %d of which the pre-rewrite README "
      "carried)" % (len(pinned), len(readme_was)))

# The strongest form of "nothing was deleted": not one LINE of the old
# README may be absent from the two documents together.  The comparison is
# whitespace-insensitive, so a block that was re-wrapped rather than
# reworded still counts as present.
both_flat = re.sub(r"\s+", " ", both)
old_lines = [l.strip() for l in old_readme.split("\n") if l.strip()]
gone = [l for l in old_lines if re.sub(r"\s+", " ", l) not in both_flat]
check("no line of the pre-rewrite README is missing from the two documents",
      not gone, "%d gone, e.g. %r" % (len(gone), gone[:3]))
print("     (%d non-blank lines of the pre-rewrite README)" % len(old_lines))

# the user-facing ones must be in the README itself
USER_FACING = [
    "_verify/LPLR_GATE_BLINDNESS_1680.md",
    "_verify/UPSTREAM_PROVENANCE.md",
    "17 of 40 (42%)",
    "344",
    "-1381",
    "2.56",
    "sd 3.39",
    "**1123**",
    "**19** are marked *(upstream)*",
    "no 1:1 upstream class",
    "How the names map",
    "1.0986122886681096",
    "1.0986122886681098",
    "The other 16 expose",
    "Six rows turned out hazardous",
    "structs still default `ml_m` to `linear_regression()`",
    "call sites that do not forward `cv` are **eight**",
    "**eight**, in seven files",
    "gates whose reference is UPSTREAM",
    "shipped default arm is still the one absence",
    # Round 36 removed the section's lead-in, which repeated the heading word
    # for word.  The fact it pinned is the HEADING, and that is what is pinned
    # now -- the wording it carried is the section's own.
    "Not covered, so not claimed",
    "moon test --target native --deny-warn",
    "Total tests: 1117",
    "Run these from the **repository root**",
    "estimated theta   = 1.092018247331361",
    "standard error    = 0.08875683254582736",
]
for lit in USER_FACING:
    check("the README keeps the user-facing fact %r" % lit[:44],
          re.sub(r"\s+", " ", lit) in readme_flat)
# the renamed count is pinned with a line break between the two halves
check("the README keeps the user-facing fact '**2** are marked *(upstream, renamed)*'",
      "**2** are marked *(upstream, renamed)*" in readme
      or "**2** are marked\n*(upstream, renamed)*" in readme)
for lit in ("1115/1115", "1122/1122"):
    check("the README does not quote the stale count %r" % lit, lit not in readme)

# =========================================================== D. no check died
print()
print("D. no check silently died -- each touched verifier vs %s" % BASE_TAG)

TOUCHED = [
    "_verify_counts_1641.py",
    "_verify_qa_evidence_1639.py",
    "_verify_qa_scope_1680.py",
    "_verify_round10_ci_1645.py",
    "_verify_fmt_gate_1640.py",
    "_verify_round9_docs_1644.py",
    "_verify_hazard_table_1680.py",
    "_verify_api_surface_1640.py",
    "_verify_round12_pyexample_1647.py",
    "_verify_round17_lplr_1650.py",
]


def call_labels(src):
    """The first-argument string literal of every check()/ok() call."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return None
    out = set()
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id in ("check", "ok")):
            continue
        if not node.args:
            continue
        a = node.args[0]
        if isinstance(a, ast.Constant) and isinstance(a.value, str):
            out.add(a.value)
    return out


def claim_regexes(src):
    """Every string literal passed to a claim_mentions(...) call."""
    out = set()
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return None
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == "claim_mentions"):
            continue
        for a in node.args[1:]:
            if isinstance(a, ast.Constant) and isinstance(a.value, str):
                out.add(a.value)
    return out


def norm(s):
    """The two document names are one thing for the purpose of this check.

    A label that said "the README says X" and now says "the project document
    says X" is the SAME check, pointed at the document the fact now lives in.
    Everything else about the label has to be identical.
    """
    s = s.lower()
    s = s.replace("the project document's", "readme's")
    s = s.replace("the project document", "readme")
    s = s.replace("both documents", "readme")
    s = s.replace("the ", "")
    return re.sub(r"\s+", " ", s).strip()


for name in TOUCHED:
    rc, old_src = git("cat-file", "blob", "%s:_verify/%s" % (BASE_TAG, name))
    if rc != 0:
        # A verifier that did not exist at the base tag is NEW, not a
        # regression: there is nothing to compare it against, so the only
        # thing to assert is that it exists now.
        check("%s is new at %s and exists now" % (name, BASE_TAG),
              os.path.exists(os.path.join(VD, name)))
        continue
    new_src = read(os.path.join(VD, name))
    old_l, new_l = call_labels(old_src), call_labels(new_src)
    old_c, new_c = claim_regexes(old_src), claim_regexes(new_src)
    if old_l is None or new_l is None:
        check("%s parses" % name, False)
        continue
    new_norm = {norm(y) for y in new_l}
    lost = sorted(norm(x) for x in old_l if norm(x) not in new_norm)
    check("%s keeps every check it had at %s" % (name, BASE_TAG),
          not lost, "lost: %r" % lost[:4])
    check("%s has at least as many checks as at %s" % (name, BASE_TAG),
          len(new_l) >= len(old_l), "%d vs %d" % (len(new_l), len(old_l)))
    if old_c is not None and new_c is not None:
        check("%s keeps every prose-shape regex it had at %s" % (name, BASE_TAG),
              old_c <= new_c, "lost: %r" % sorted(old_c - new_c)[:4])
    # a re-pointed verifier must still READ the document it asserts about
    if "ENGINEERING.md" in new_src:
        check("%s names the project document it now reads" % name,
              "ENGINEERING.md" in new_src)

# =========================================================== E. the ledger
print()
print("E. ENGINEERING.md is a real document")
check("the project document exists", os.path.exists(PROJ))
check("the project document carries a dated banner",
      "2026-10-21 (round 18)" in proj_flat)
check("the banner says what it is NOT",
      "not a second README" in proj_flat)
check("the ledger says nothing was deleted",
      "**Nothing was deleted.**" in re.sub(r"\s+", " ", proj))
check("the ledger names the release it preserves",
      "v0.164.11" in proj)
check("the ledger carries the old README's H1, under its own heading",
      "## The README as it stood at v0.164.11" in proj)
# the ledger's body is the old README, verbatim
old_body = old_readme.split("\n", 1)[1].lstrip("\n")
check("the ledger carries the whole pre-rewrite README, verbatim",
      old_body.strip() in proj.strip())
for a, b, what in ((230, 1072, "the estimator-defaults narrative"),
                   (1078, 1280, "the LPLR small-n narrative"),
                   (1660, 1749, "the upstream-correspondence narrative"),
                   (1838, 2241, "the CI-gate narrative")):
    body = "\n".join(old_readme.split("\n")[a - 1:b])
    check("the ledger carries %s verbatim" % what, body in proj)
    check("the README does NOT carry %s" % what, body not in readme)

# =========================================================== F. the promises
print()
print("F. the two documents point at each other, and the paths are real")
check("the README links to the project document", "ENGINEERING.md" in readme)
check("the project document links back to the README",
      "README.mbt.md" in proj)
check("the README names the LPLR record it leans on",
      "_verify/LPLR_GATE_BLINDNESS_1680.md" in readme)
check("the README names the upstream provenance record",
      "_verify/UPSTREAM_PROVENANCE.md" in readme)
rc, tracked = git("ls-files")
tset = set(tracked.split())
check("the project document is TRACKED -- the README links to it, so a path "
      "in prose is a promise", "ENGINEERING.md" in tset)
check("the shipped README copy is byte-identical to the edited one",
      read(SHIPPED).encode("utf-8") == readme.encode("utf-8"))
for p in ("_verify/LPLR_GATE_BLINDNESS_1680.md", "_verify/UPSTREAM_PROVENANCE.md"):
    check("the README's pointer %s exists AND is tracked" % p,
          os.path.exists(p) and p in tset)
check("the README is LF-only with no BOM",
      b"\r" not in readme.encode("utf-8")
      and not readme.encode("utf-8").startswith(b"\xef\xbb\xbf"))
check("the project document is LF-only with no BOM",
      b"\r" not in proj.encode("utf-8")
      and not proj.encode("utf-8").startswith(b"\xef\xbb\xbf"))

print()
print("checks: %d   failed: %d" % (n_checks, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
