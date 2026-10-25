"""Check the Project-layout and Features numbers against the tree.

Claims under test:
  * "examples/  <- 21 driver binaries (all listed in moon.work)"
  * "main/      <- 12 estimators, one perfect-DGP run each"
  * "moon.work  <- 23-member workspace aggregator (the library, doc/, 21 examples)"
  * "doc/       <- wasm-gc-targeted numbered tutorials" ... 006_python_check
  * the wasm-gc test total is "lib + 6 doc tutorials"
  * the nightly workflow's own claim about what it checks

`examples/main` prints one banner per RUN, not per estimator: five estimators
get a second `(n_rep=5)` arm and RDD runs twice (sharp and fuzzy), so 12
estimators produce 18 banners. "one perfect-DGP run each" is therefore the
kind of phrase that only looks right until the driver is read.

The nightly workflow is the last claim here, and it was the last one nobody
read: its comment said the package was "flat-layout (no moon.work)" and that
it checked "the package root directly rather than iterating over workspace
members" -- which was true when it was written and stopped being true when
`moon.work` arrived.  The repository root carries the workspace, the package
directory does not, and `moon check` resolves UP to the workspace root from
any directory inside it, so the step checks every member.  The comment now
says that, and these checks keep it saying it.
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# ------------------------------------------------------------- moon.work
work = io.open(os.path.join(ROOT, "moon.work"), encoding="utf-8").read()
members = re.findall(r"\"([^\"]+)\"", work)
print("moon.work members: %d" % len(members))
ex = [m for m in members if m.startswith("examples/")]
print("  examples/ members: %d" % len(ex))
check("moon.work has 23 members", len(members) == 23, "got %d" % len(members))
check("21 of them are examples/", len(ex) == 21, "got %d" % len(ex))
check("the library and doc/ are members",
      "moonbit_doubleML" in members and "doc" in members)

# every examples/ directory with a moon.mod should be a member
dirs = sorted(d for d in os.listdir(os.path.join(ROOT, "examples"))
              if os.path.isfile(os.path.join(ROOT, "examples", d, "moon.mod")))
print("  examples/ dirs with a moon.mod: %d" % len(dirs))
check("every examples/ package is in moon.work",
      set(dirs) == set(m.split("/", 1)[1] for m in ex),
      "dirs=%s members=%s" % (dirs, sorted(m.split("/", 1)[1] for m in ex)))

# ----------------------------------------------------------------- doc/
doc = os.path.join(ROOT, "doc")
# `doc/native` is a target-specific variant, not a numbered tutorial
tutorials = sorted(d for d in os.listdir(doc)
                   if os.path.isdir(os.path.join(doc, d)) and re.match(r"^\d{3}_", d))
all_doc_dirs = sorted(d for d in os.listdir(doc) if os.path.isdir(os.path.join(doc, d)))
print("  doc/ dirs: %d -> %s" % (len(all_doc_dirs), all_doc_dirs))
print("  doc/ numbered tutorials: %d -> %s" % (len(tutorials), tutorials))
check("there are 6 numbered doc tutorials", len(tutorials) == 6,
      "got %d" % len(tutorials))
check("the last is 006_python_check", tutorials[-1] == "006_python_check",
      "got %s" % tutorials[-1])

# ------------------------------------------------------- examples/main
main = io.open(os.path.join(ROOT, "examples", "main", "main.mbt"),
               encoding="utf-8").read()
# a banner is the string after "=== " up to " ===", across the println call
banners = re.findall(r"=== (.+?) ===", main)
models = []
for b in banners:
    b = b.replace("MoonBit DML ", "").replace("MoonBit ", "")
    b = re.sub(r"\s*\(.*\)$", "", b)
    models.append(b)
distinct = []
for m in models:
    if m not in distinct:
        distinct.append(m)
print("  examples/main banners: %d, distinct models: %d" % (len(banners), len(distinct)))
print("  models: %s" % ", ".join(distinct))
n_rep = [b for b in banners if "n_rep=5" in b]
rdd = [b for b in banners if "RDD" in b]
print("  (n_rep=5) arms: %d, RDD runs: %d" % (len(n_rep), len(rdd)))

check("examples/main prints 18 banners", len(banners) == 18, "got %d" % len(banners))
check("examples/main runs 12 distinct estimators", len(distinct) == 12,
      "got %d: %s" % (len(distinct), distinct))
check("5 of the runs are the (n_rep=5) arm", len(n_rep) == 5, "got %d" % len(n_rep))
check("RDD runs twice (sharp and fuzzy)", len(rdd) == 2, "got %d" % len(rdd))
check("12 estimators + 5 n_rep arms + 1 extra RDD run = 18 banners",
      len(distinct) + len(n_rep) + (len(rdd) - 1) == len(banners))

# --------------------------------------------------------------- the prose
check("the layout says '21 driver binaries'", "21 driver binaries" in readme)
check("the layout says 12 estimators in 18 runs",
      "12 estimators in 18 runs" in readme)
check("the layout explains the 6 extra runs",
      "5 also run with" in readme and "RDD runs twice" in readme)
check("the old 'one perfect-DGP run each' is gone",
      "one perfect-DGP run each" not in readme)
check("the layout says '23-member workspace aggregator'",
      "23-member workspace aggregator" in readme)
check("the wasm-gc count says 'lib + 6 doc tutorials'",
      "lib + 6 doc tutorials" in readme)

# ------------------------------------------- a repository PATH in the prose
# A path in prose is a PROMISE: it has to exist, and it has to be tracked.
# The layout block named `example/consumer_demo` -- which is the example's
# PACKAGE NAME (what `examples/consumer_demo/moon.mod` declares), not a
# repository path.  The directory is `examples/consumer_demo`, and it is
# tracked; the name that was printed is neither.
#
# The distinction is DERIVED, not asserted: a backticked `owner/name` token
# is a PACKAGE when its owner is one the manifests actually declare
# (`moonbitlang`, `moonbit-community`, `riantr`), and a REPOSITORY PATH
# otherwise.  So a path that does not exist cannot hide behind the package
# rule, and a package cannot be demanded to exist as a directory.
try:
    _tracked = set(subprocess.run(["git", "ls-files", "-z"], cwd=ROOT,
                                   capture_output=True, timeout=120)
                   .stdout.decode("utf-8", "replace").split("\0"))
except Exception:                                    # noqa: BLE001
    _tracked = set()

_owners = set()
_manifest_pins = set()
for _rel in sorted(r for r in _tracked if r.endswith("moon.mod")):
    _txt = io.open(os.path.join(ROOT, _rel), encoding="utf-8",
                   errors="replace").read()
    _txt = "\n".join(l.split("//", 1)[0] for l in _txt.split("\n"))
    for _imp in re.findall(r"\"([^\"]+@[^\"]+)\"", _txt):
        _manifest_pins.add(_imp)
        _owners.add(_imp.split("/", 1)[0])


def _is_tracked(path):
    p = path.rstrip("/")
    if p in _tracked:
        return True
    pref = p + "/"
    return any(f.startswith(pref) for f in _tracked)


_parts = readme.split("## Project layout", 1)
_layout = ""
if len(_parts) > 1:
    # The FIRST fenced block after the heading is the tree.  `split("```")`
    # without a limit is what takes it: the block is delimited by the first
    # pair of fences, and a limited split would run on into the rest of the
    # document.
    _seg = _parts[1].split("```")
    if len(_seg) > 1:
        _layout = _seg[1]
check("the layout block is findable", "moon.work" in _layout,
      "the first fenced block after '## Project layout' is not the tree")
_tokens = re.findall(r"`([^`\n]+)`", _layout)
_paths = [t for t in _tokens
          if not (t.count("/") >= 1 and t.split("/", 1)[0] in _owners)]
print("  layout block tokens: %s" % _tokens)
print("  layout block repository paths: %s" % _paths)
for _p in _paths:
    check("the layout's path `%s` exists" % _p,
          os.path.exists(os.path.join(ROOT, _p.rstrip("/"))),
          "no such path in the tree")
    check("the layout's path `%s` is tracked" % _p, _is_tracked(_p),
          "the path is not in `git ls-files`")

# ------------------------------------------------- the nightly workflow's claim
# The workflow file is TRACKED, so a clone has it, and the claims it makes
# about the tree can be checked against the tree.
NIGHTLY = os.path.join(ROOT, ".github", "workflows", "nightly.yml")
nightly = io.open(NIGHTLY, encoding="utf-8").read()
pkg_work = os.path.join(ROOT, "moonbit_doubleML", "moon.work")

check("the repository root carries the workspace", os.path.isfile(
      os.path.join(ROOT, "moon.work")))
check("the package directory carries no workspace of its own",
      not os.path.exists(pkg_work))
check("the nightly workflow claims no flat layout",
      "flat-layout" not in nightly and "no moon.work" not in nightly,
      "the stale claim is still in the file")
check("the nightly workflow says the workspace is checked",
      "moon.work" in nightly and "workspace" in nightly)
check("the nightly check step runs at the workspace root",
      "working-directory" not in nightly,
      "a working-directory would move the step off the workspace root")

# ------------------------------------------------- the line endings of a clone
# A clone must not depend on the CLONER's `core.autocrlf` to reproduce the
# tree.  `_verify/_bitexact_mutation_1640.py` matches LITERAL newlines in
# `examples/bitexact/main.mbt`; in a CRLF working tree two of its four
# mutations matched nothing, the battery SKIPPED them, and it exited 1 --
# while the README published "all four mutations killed".  The release
# machine carried a local `core.autocrlf=false`, which is not part of the
# tracked tree, so only the machine that cut the release ever saw the
# claim hold.
#
# So the repository pins its own line endings.  The SOURCE types are pinned
# to LF; the captured artefacts under `_verify/` and `_probe/` are BYTE
# RECORDS of past runs and are marked `-text`, so they are never converted
# in either direction -- normalising them would rewrite the evidence they
# are.
GITATTR = os.path.join(ROOT, ".gitattributes")
gattr = io.open(GITATTR, encoding="utf-8").read() if os.path.isfile(GITATTR) else ""
check("the repository carries a .gitattributes", bool(gattr),
      "a clone's line endings are then its own business")
for ext in ("*.mbt", "*.mod", "*.md", "*.py", "*.yml"):
    check("the .gitattributes pins %s to LF" % ext,
          re.search(r"^%s\s+text\s+eol=lf$" % re.escape(ext), gattr, re.M)
          is not None,
          "no `text eol=lf` rule for %s" % ext)
check("the .gitattributes keeps CHANGELOG.md byte-for-byte",
      re.search(r"^CHANGELOG\.md\s+-text$", gattr, re.M) is not None,
      "the CHANGELOG is not marked -text")
check("the .gitattributes keeps the _verify byte records byte-for-byte",
      re.search(r"^_verify/\*\.json\s+-text$", gattr, re.M) is not None,
      "the byte records are not marked -text")

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
