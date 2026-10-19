"""Check self-citations of the form `<file>.mbt:<line>` inside .mbt comments.

A comment that says "see foo.mbt:355" is a machine-checkable claim. Two ways
it rots:

  1. the cited line moved (someone edited the file the comment points at);
  2. the cited line is blank or is the comment itself.

This linter catches both, package-wide. It is deliberately mechanical: it does
NOT try to guess what the author *meant* at that line, only whether the line
exists, is non-blank, and is not the citing comment. Anything semantic is still
a human call.

Scope note: only citations whose target is a .mbt file in this package are
resolved. Citations into `_verify/` artifacts or upstream Python are skipped --
those line numbers belong to files this linter does not read.
"""
import io
import os
import re
import sys

PKG = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(PKG)
SRC = os.path.join(ROOT, "moonbit_doubleML")

# Explicit citations: an optional directory prefix, a file name and an
# extension. Classifying by EXTENSION is the whole trick -- a `.py` citation is
# an upstream Python anchor and is out of scope, while a `.mbt` citation names a
# file in this package and is checkable.
EXPLICIT = re.compile(r"\b([A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*\.(mbt|py)):(\d+)")
# The shorthand: `(plr.mbt:394, :399)` -- a bare `:NNN` continuing the previous
# citation. It is ONLY a self-citation if the run it belongs to is a .mbt run.
BARE = re.compile(r"(?<![A-Za-z0-9_./-]):(\d+)")

problems = []
checked = 0

files = [f for f in sorted(os.listdir(SRC)) if f.endswith(".mbt")]
lines_by_file = {}
for f in files:
    with io.open(os.path.join(SRC, f), encoding="utf-8") as fh:
        lines_by_file[f] = fh.read().replace("\r\n", "\n").split("\n")

# v0.164.3: a `.mbt` citation can also name a file OUTSIDE the package -- the
# `examples/<bin>/main.mbt` drivers live at the repo root, and the package
# happens to have no `main.mbt`, so `examples/fuzz/main.mbt:412` was reported
# as "cites an unknown .mbt file" when the file exists and the line is right.
# The scope note above said "this package"; the real scope is "this
# repository", so the repo root is searched too.
for dp, dn, fn in os.walk(ROOT):
    dn[:] = [d for d in dn if d not in (".git", "_target", "_build", "_verify",
                                        ".mooncakes", "native", "debug", "node_modules")]
    for f in fn:
        if not f.endswith(".mbt"):
            continue
        rel = os.path.relpath(os.path.join(dp, f), ROOT).replace("\\", "/")
        if rel in lines_by_file:
            continue
        with io.open(os.path.join(dp, f), encoding="utf-8", errors="replace") as fh:
            lines_by_file[rel] = fh.read().replace("\r\n", "\n").split("\n")
REPO_MBT = {k for k in lines_by_file if "/" in k}


def comment_block_start(lines, idx0):
    """Walk back to the first line of the contiguous comment block at idx0.

    `idx0` and the return value are both 0-BASED indices into `lines`. Mixing
    the two conventions here silently yields an EMPTY slice when the block
    starts at line 1, which makes the linter report "OK" while checking
    nothing -- the exact failure the positive control exists to catch.
    """
    j = idx0
    while j > 0 and lines[j - 1].strip().startswith("//"):
        j -= 1
    return j


for f in files:
    lines = lines_by_file[f]
    # Walk the block once, in order, remembering the most recently cited
    # FILE. The bare `:NNN` shorthand means "same file as the citation I just
    # wrote" -- so `(apo.mbt:343, :1087)` inside a TEST file resolves both
    # numbers against apo.mbt, NOT against the file that happens to contain the
    # comment. Getting this backwards reports every cross-file shorthand as an
    # out-of-range line in the citing file.
    #
    # v0.164.3: the inherited target's EXTENSION matters too. A bare `:NNN`
    # that follows a `.py` citation is an UPSTREAM anchor (e.g. lplr.mbt
    # quotes `plm/lplr.py:254` and then `(:836)` for `plm/lplr.py:836`), and
    # resolving it against the last `.mbt` file mentioned in the same block
    # reported four out-of-range lines that were not defects. The shorthand
    # inherits the MOST RECENT citation of any extension.
    last_mbt = None
    for i, line in enumerate(lines, start=1):
        s = line.strip()
        if not s.startswith("//"):
            continue
        lo = comment_block_start(lines, i - 1)
        if lo == i - 1:
            last_mbt = None  # this line opens a fresh block; nothing to inherit
        block_text = "\n".join(lines[lo:i])

        cites_here = []
        for target, ext, num in EXPLICIT.findall(line):
            if ext != "mbt":
                # an upstream Python anchor: the bare shorthand after it
                # inherits a .py target, which is out of scope
                last_mbt = None
                continue
            name = os.path.basename(target)
            key = target.replace("\\", "/")
            if key in lines_by_file:
                name = key
            num = int(num)
            cites_here.append((name, num, "%s:%d" % (target, num)))
            if name in lines_by_file:
                last_mbt = name
            else:
                problems.append((f, i, "%s:%d" % (target, num), "cites an unknown .mbt file"))

        # Bare shorthands inherit `last_mbt` from earlier in the same block.
        for num in BARE.findall(line):
            num = int(num)
            # skip range ends like `foo.mbt:1634-1641`, already checked above
            if any(n <= num <= n + 8 for _, n, _ in cites_here):
                continue
            if last_mbt is None:
                continue  # no .mbt run to inherit from
            cites_here.append((last_mbt, num, "%s:%d" % (last_mbt, num)))

        for name, num, cite in cites_here:
            if name not in lines_by_file:
                continue
            checked += 1
            tl = lines_by_file[name]
            if num < 1 or num > len(tl):
                problems.append((f, i, cite, "line %d out of range (file has %d)" % (num, len(tl))))
            elif name == f and num == i:
                problems.append((f, i, cite, "cites itself"))
            elif not tl[num - 1].strip():
                problems.append((f, i, cite, "line %d is blank" % num))

print("checked %d .mbt self-citations across %d files" % (checked, len(files)))
if problems:
    print("PROBLEMS: %d" % len(problems))
    for f, i, cite, why in problems:
        print("  %s:%d  %s  -- %s" % (f, i, cite, why))
    sys.exit(1)
print("OK: every resolved .mbt citation points at an existing, non-blank line")
sys.exit(0)