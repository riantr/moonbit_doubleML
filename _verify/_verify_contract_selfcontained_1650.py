"""Verify that the tracked verifier contract is SELF-CONTAINED.

The local suite is the tracked `_verify/` contract: `git ls-files _verify`
intersected with the scripts the runner picks up.  A green contract is
supposed to be a statement about THE REPOSITORY.  It was not.

Measured in a FRESH CLONE of the repository, the contract behaved like this:

  * 15 of the 51 tracked verifiers located their tree by an ABSOLUTE path
    -- the working copy's own path, typed in.  In a clone they therefore
    read the ORIGINAL tree: they went green for the wrong reason, and a
    green row proved nothing about the clone.

  * 2 tracked verifiers depended on files git does not track
    (`_verify/_probe_ops_1640.mbt`, `_verify/_qa_fast_1639.json`), so a
    clone had no copy of them.

  * 2 tracked verifiers FAILED in a clone, because they check a downloaded
    third-party tree that a clone does not have -- they had no notion of
    "the subject is not here".

So this file states the invariant and holds the contract to it:

  C1  No tracked file under `_verify/` may name an absolute path.  A
      verifier that knows where the tree lives is a verifier that can
      check a different tree.

  C2  Every tracked verifier that defines a repository root must resolve
      it -- by `__file__` -- to THIS repository (the one holding
      `moonbit_doubleML/moon.mod`).

  C3  Every repository-relative path a tracked verifier READS must be a
      TRACKED file.  An untracked input is invisible to a clone and to
      anybody who downloads the package.

C1 and C2 are static and cheap.  C3 is static too: the paths are read
out of the AST, so a verifier that builds a path by concatenation is
seen the same way as one that names it literally.
"""
import ast
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VD = os.path.join(ROOT, "_verify")

# the same set the suite runner uses
SKIP = re.compile(r"_verify_published_readme_16\d\d\.py$"
                  r"|_verify_typos_pinned"
                  r"|^_final_1600_verify\.py$"
                  r"|^_release_verify_1590\.py$")

# A Windows drive letter followed by a separator: C:\\, D:/, ...
# The lookbehind keeps "https://" (an "s" preceded by a letter) and
# "%s:\s*" (a format specifier) from matching.  The tail requires real
# path characters, so a character class such as "[\s:\-|]" -- where the
# "s:" is a range and the "\" an escaped dash -- does not match either.
ABSOLUTE = re.compile(r"(?<![A-Za-z0-9_%])[A-Za-z]:[\\/]{1,2}[A-Za-z0-9_.]{2,}")

# names a verifier is likely to give its repository root
ROOTNAMES = ("ROOT", "REPO", "BASE", "ROOT_DIR", "REPO_ROOT", "PROJECT_ROOT",
             "PKG_ROOT", "TOP", "HERE")

fails = []
notes = []
NCHECK = [0]


def check(label, cond, detail=""):
    NCHECK[0] += 1
    print("  %-64s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def note(text):
    notes.append(text)
    print("  %-64s %s" % (text, ""))


def git_ls_files():
    r = subprocess.run(["git", "ls-files", "_verify"], cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    return r.stdout.split()


def git_tracked(path):
    r = subprocess.run(["git", "ls-files", "--error-unmatch", "--", path],
                       cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.returncode == 0


tracked = git_ls_files()
tracked_set = set(tracked)
contract = sorted(os.path.basename(p) for p in tracked
                  if p.endswith(".py")
                  and re.search(r"verify", os.path.basename(p))
                  and not SKIP.search(os.path.basename(p)))

print("tracked files under _verify : %d" % len(tracked))
print("the tracked contract        : %d verifiers" % len(contract))
print("")

# ==============================================================================
# C1 -- no absolute path anywhere in the tracked contract
# ==============================================================================
print("== C1: no tracked verifier names an absolute path ==")

# Only the CONTRACT is scanned.  The other tracked files under `_verify/`
# are historical records -- captured logs, the round-18 ledger, the
# mutation drivers -- and a path inside a record is evidence, not a
# dependency.  A path inside a VERIFIER is a dependency.
abs_hits = []
for name in contract:
    p = "_verify/" + name
    full = os.path.join(ROOT, p.replace("/", os.sep))
    if not os.path.isfile(full):
        continue
    text = io.open(full, encoding="utf-8", errors="replace").read()
    for i, line in enumerate(text.splitlines(), 1):
        m = ABSOLUTE.search(line)
        if m:
            abs_hits.append((p, i, m.group(0), line.strip()[:70]))
check("no tracked verifier names an absolute path",
      not abs_hits,
      "%d hit(s): %s" % (len(abs_hits), abs_hits[:3]))
for p, i, tok, line in abs_hits:
    print("      %s:%d  %s  |  %s" % (p, i, tok, line))
print("")

# ==============================================================================
# C2 -- every root resolves to THIS repository
# ==============================================================================
print("== C2: every tracked verifier's root resolves to this repository ==")

MARKER = os.path.join("moonbit_doubleML", "moon.mod")


def module_namespace(path, tree):
    """Evaluate the module's top-level assignments, in order."""
    ns = {"os": os, "sys": sys, "__file__": path, "__name__": "_scan"}
    try:
        from pathlib import Path
        ns["Path"] = Path
    except Exception:  # noqa: BLE001
        pass
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not isinstance(node.value, ast.Constant):
            try:
                val = eval(compile(ast.Expression(node.value), "<scan>", "eval"),
                           ns, {})
            except Exception:  # noqa: BLE001
                continue
        else:
            val = node.value.value
        for t in node.targets:
            if isinstance(t, ast.Name):
                ns[t.id] = val
    return ns


roots_seen = 0
no_root = []
bad_root = []
outside_root = []
reaches_repo = 0
for name in contract:
    path = os.path.join(VD, name)
    src = io.open(path, encoding="utf-8", errors="replace").read()
    try:
        tree = ast.parse(src)
    except SyntaxError:
        continue
    ns = module_namespace(path, tree)
    found = [(k, v) for k, v in ns.items()
             if k in ROOTNAMES and isinstance(v, str) and v]
    if not found:
        no_root.append(name)
        continue
    roots_seen += 1
    # every root-ish name must point INSIDE this repository: a verifier
    # may aim at a subdirectory (`_verify/`), but never outside.
    for k, v in found:
        try:
            inside = os.path.commonpath([os.path.abspath(v), ROOT]) == ROOT
        except ValueError:
            inside = False
        if not inside:
            outside_root.append((name, k, v))
    # and at least one of them must reach the repository root itself
    if any(os.path.abspath(v) == ROOT for _k, v in found):
        reaches_repo += 1

check("every tracked verifier's root points inside this repository",
      not outside_root,
      "%d outside: %s" % (len(outside_root), outside_root[:3]))
for name, k, v in outside_root:
    print("      %s: %s = %s" % (name, k, v))
check("every tracked verifier reaches the repository root",
      reaches_repo == roots_seen,
      "%d of %d reach it" % (reaches_repo, roots_seen))
note("%d of %d verifiers declare a root; %d do not"
     % (roots_seen, len(contract), len(no_root)))
print("")

# ==============================================================================
# C3 -- every repository-relative path a verifier reads is TRACKED
# ==============================================================================
print("== C3: every file a tracked verifier READS is tracked ==")

# A path under a DOWNLOADED third-party tree cannot be tracked: it is
# fetched, not authored.  A verifier that reads one must SKIP when it is
# absent -- that is checked separately, below.
DOWNLOADED = ("_verify/_upstream",)
SDIST = re.compile(r"^_verify/doubleml-.*\.tar\.gz$")

# a build output directory: produced by the toolchain, never tracked
BUILT = ("_build/", ".mooncakes/", "__pycache__/")


def resolve(node, ns):
    """The path a node denotes, or None."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        v = ns.get(node.id)
        return v if isinstance(v, str) else None
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
            and node.func.attr == "join":
        parts = [resolve(a, ns) for a in node.args]
        if all(isinstance(p, str) for p in parts):
            return os.path.join(*parts)
        return None
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        l = resolve(node.left, ns)
        r = resolve(node.right, ns)
        if isinstance(l, str) and isinstance(r, str):
            return l + r
    return None


def read_paths(tree, ns):
    """The files this module opens for reading, and the ones it runs."""
    reads, runs = set(), set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        if isinstance(f, ast.Name) and f.id == "open" or \
                (isinstance(f, ast.Attribute) and f.attr == "open"):
            if not node.args:
                continue
            p = resolve(node.args[0], ns)
            if p:
                mode = ""
                if len(node.args) > 1 and isinstance(node.args[1], ast.Constant) \
                        and isinstance(node.args[1].value, str):
                    mode = node.args[1].value
                if not any(c in mode for c in "wax+"):
                    reads.add(p)
        if isinstance(f, ast.Attribute) and f.attr in ("run", "check_output",
                                                       "Popen", "call"):
            # only PATH-LIKE arguments: a command's flags and subcommands
            # ("moon", "run", "--target") are not files.
            for a in node.args:
                items = a.elts if isinstance(a, (ast.List, ast.Tuple)) else [a]
                for item in items:
                    p = resolve(item, ns)
                    if p and ("/" in p or "\\" in p):
                        runs.add(p)
    return reads, runs


def classify(p):
    """(kind, repo-relative path) for a resolved path."""
    ap = os.path.abspath(p)
    if not ap.startswith(ROOT):
        return ("outside", ap)
    rel = os.path.relpath(ap, ROOT).replace(os.sep, "/")
    if rel.startswith(DOWNLOADED) or SDIST.match(rel):
        return ("downloaded", rel)
    if rel.startswith(BUILT):
        return ("built", rel)
    return ("repo", rel)


untracked_dep = []
missing_read = []
downloaded_reads = []
checked_paths = 0
for name in contract:
    path = os.path.join(VD, name)
    src = io.open(path, encoding="utf-8", errors="replace").read()
    try:
        tree = ast.parse(src)
    except SyntaxError:
        continue
    ns = module_namespace(path, tree)
    reads, runs = read_paths(tree, ns)
    for p in sorted(reads | runs):
        if "%" in p or "{" in p or "*" in p:
            continue
        kind, rel = classify(p)
        if kind == "outside":
            continue
        if kind == "built":
            continue
        checked_paths += 1
        if kind == "downloaded":
            downloaded_reads.append((name, rel))
            continue
        if not os.path.exists(os.path.join(ROOT, rel.replace("/", os.sep))):
            missing_read.append((name, rel))
            continue
        if not git_tracked(rel):
            untracked_dep.append((name, rel))

check("every file a tracked verifier reads exists in the checkout",
      not missing_read,
      "%d missing: %s" % (len(missing_read), missing_read[:3]))
for name, rel in missing_read:
    print("      %s reads %s -- not present" % (name, rel))
check("every file a tracked verifier reads is TRACKED",
      not untracked_dep,
      "%d untracked: %s" % (len(untracked_dep), untracked_dep[:3]))
for name, rel in untracked_dep:
    print("      %s reads %s -- untracked" % (name, rel))
note("%d repository-relative reads were examined" % checked_paths)

# C5 -- a verifier that reads a DOWNLOADED tree must SKIP when it is absent
print("")
print("== C5: a verifier over a downloaded tree skips when it is absent ==")
if downloaded_reads:
    for name, rel in downloaded_reads:
        src = io.open(os.path.join(VD, name), encoding="utf-8",
                      errors="replace").read()
        check("%s has a SKIP path for a missing subject" % name,
              re.search(r"\bSKIP\b|\bskip\(", src) is not None,
              "no SKIP marker in the source")
    note("%d read(s) live under a downloaded tree" % len(downloaded_reads))
else:
    note("no tracked verifier reads a downloaded tree")

# ==============================================================================
# C4 -- the contract the runner will execute is the contract that is tracked
# ==============================================================================
print("")
print("== C4: the runner's contract is the tracked one ==")

on_disk = sorted(f for f in os.listdir(VD)
                 if f.endswith(".py") and re.search(r"verify", f)
                 and not SKIP.search(f))
untracked_on_disk = [f for f in on_disk if "_verify/" + f not in tracked_set]
tracked_but_absent = [f for f in contract if not os.path.isfile(os.path.join(VD, f))]
check("every tracked contract verifier is present on disk",
      not tracked_but_absent, str(tracked_but_absent))
check("the contract is not empty", len(contract) > 0)
note("%d scripts on disk match the rule; %d of them are scratch (not contract)"
     % (len(on_disk), len(untracked_on_disk)))
for f in untracked_on_disk:
    print("      (scratch, not contract) %s" % f)

print("")
print("checks run: %d" % NCHECK[0])
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
