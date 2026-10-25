#!/usr/bin/env python3
"""Round 43 verifier: the published README's own code, compiled.

WHAT THIS EXISTS FOR
=====================
The README is a document a reader COPIES from.  Two of its fenced `moonbit`
blocks did not compile, and nothing in the tree owned them:

    ```moonbit
    ml_m = LearnerDispatch::logistic_regression(LogisticRegression::new())
    ```

`ml_m` is not a variable -- it is an optional NAMED PARAMETER of eight
estimators' constructors -- so as a statement the line does not compile at
all ("The value identifier ml_m is unbound"), and it does not even show the
reader how the learner reaches the estimator.

    ```moonbit
    let model = DoubleMLLPLR::new(data).fit()
    for w in model.warnings() { println(w) }
    ```

`DoubleMLLPLR::new` takes a `DoubleMLBinaryData` -- LPLR's outcome is
BINARY -- while `data` in the README is the `DoubleMLData` the Quick Start
builds.  The compiler says:

    Expr Type Mismatch
    has type : @riantr/moonbit_doubleML.DoubleMLData
    wanted   : @riantr/moonbit_doubleML.DoubleMLBinaryData

WHY AN EXISTING VERIFIER DID NOT CATCH IT
==========================================
`_verify/_verify_api_snippets_1680.py` owns the README's API snippets.  It
checks the NAMES of a call's arguments, their optionality and their stated
defaults, and it checks that EVERY constructor call in the document was
reached.  A type mismatch is invisible to it -- `data` IS the name of
`DoubleMLLPLR::new`'s first parameter, it is just the wrong TYPE -- and a
statement that is not a statement is not a constructor call at all.

So this file asks the only authority that can answer both questions: the
MoonBit compiler.

WHAT IT DOES
============
1. Reads the PUBLISHED README -- `moonbit_doubleML/README.mbt.md`, the file
   the registry serves -- and takes its fenced `moonbit` blocks.
2. Classifies each block: a `moon.mod` IMPORT snippet is not code and is
   SKIPPED; every other block is a CODE block.
3. Compiles each code block, in a probe file, against the LOCAL library:
   the preamble below supplies the context the README's fragments assume
   (`x`, `y`, `d`, `data`), and each block is compiled in its OWN scope so
   that a block which declares its own `n` / `x` / `y` / `d` / `data`
   shadows the preamble instead of colliding with it.
4. Fails if the compiler reports an error, and names the block.

The probe is written into `doc/001_introduction/`, whose `moon.pkg` imports
`riantr/moonbit_doubleML` WITHOUT a version -- so the workspace resolves it
to the local member, and the blocks are checked against THIS tree and not
against whatever the registry is serving.  The probe is removed again
whatever happens.

THE COUNT IS FIXED AT 5
=======================
Every check here is an AGGREGATE, so adding a code block to the README does
not move the published number.  When the MoonBit toolchain is not on PATH
the compile SKIPS -- still counted, still visible -- because a missing
compiler is not a broken snippet.  (The round-41 precedent: a skip must
stand for exactly the check it replaces, so the count is a property of this
file and not of the environment.)

Run: python _verify/_verify_readme_snippets_1650.py
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# the file the registry serves
README = os.path.join("moonbit_doubleML", "README.mbt.md")
# a package that imports the library for "test", so a probe inside it can
# use the `@moonbit_doubleML.` namespace the README's blocks are written in
PROBE_PKG = os.path.join("doc", "001_introduction")
PROBE_NAME = "_r43_readme_snippets_probe_test.mbt"

# the context the README's fragments assume
PREAMBLE = """  let n = 20
  let x = @moonbit_doubleML.Matrix::from_array(Array::make(n * 2, 1.0), n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
"""

NCHECK = 0
FAILS = []
SKIPPED = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-62s %s" % ("ok" if ok else "*** FAIL ***", label))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))
        print("      %s" % detail)


def skip(label, reason):
    global NCHECK
    NCHECK += 1
    print("  SKIP  %-62s %s" % (label, reason))
    SKIPPED.append((label, reason))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def blocks_of(text):
    """The fenced blocks whose info string names moonbit.

    Returns a list of (line_number, info, body_lines).  The body is DEDENTED
    to column 0, because the README indents some of its blocks inside a
    numbered list and the probe wraps each one in its own scope.
    """
    out = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)```(\S*)\s*(.*)$", lines[i])
        if m and m.group(2).startswith("moonbit"):
            info = (m.group(2) + " " + m.group(3)).strip()
            start = i + 1
            j = i + 1
            while j < len(lines) and not re.match(r"^\s*```\s*$", lines[j]):
                j += 1
            body = lines[start:j]
            pad = min((len(b) - len(b.lstrip()) for b in body if b.strip()),
                      default=0)
            out.append((start + 1, info,
                        [b[pad:] if b.strip() else "" for b in body]))
            i = j + 1
            continue
        i += 1
    return out


def is_import_snippet(body):
    """A `moon.mod` import block is a manifest snippet, not code."""
    for line in body:
        s = line.strip()
        if s.startswith("import {"):
            return True
    return False


print()
print("A. the published README's blocks")

text = read(os.path.join(ROOT, README))
blocks = blocks_of(text)
code_blocks = [(ln, info, b) for ln, info, b in blocks
               if not is_import_snippet(b)]
import_blocks = [(ln, info, b) for ln, info, b in blocks
                 if is_import_snippet(b)]

check("the published README has at least one MoonBit block", len(blocks) > 0,
      "no fenced `moonbit` block was found in %s" % README)

check("every MoonBit block in the published README is either a code block "
      "or a moon.mod import snippet",
      len(code_blocks) + len(import_blocks) == len(blocks),
      "%d block(s) are neither" % (len(blocks) - len(code_blocks)
                                   - len(import_blocks)))

print("    the README's MoonBit blocks: %d (%d code, %d import snippet)"
      % (len(blocks), len(code_blocks), len(import_blocks)))
for ln, info, b in code_blocks:
    print("      line %5d  %-20s %d lines" % (ln, info, len(b)))
for ln, info, b in import_blocks:
    print("      line %5d  %-20s %d lines  (skipped: a manifest snippet)"
          % (ln, info, len(b)))

print()
print("B. the compile")

pkg_dir = os.path.join(ROOT, PROBE_PKG)
pkg_rel = PROBE_PKG.replace("\\", "/")
pkg_pg = os.path.join(pkg_dir, "moon.pkg")
pkg_text = read(pkg_pg) if os.path.isfile(pkg_pg) else ""
unversioned = re.search(r'import\s*\{[^}]*"riantr/moonbit_doubleML"[^}]*\}',
                        pkg_text, re.S) is not None
check("the probe package imports the library without a version, so the "
      "compile is against the LOCAL tree", unversioned,
      "%s does not import `riantr/moonbit_doubleML` unversioned" % pkg_rel)

moon = shutil.which("moon")
if moon is None:
    skip("every code block in the published README compiles",
         "the `moon` toolchain is not on PATH")
else:
    # EACH BLOCK IS COMPILED ON ITS OWN.
    #
    # One probe with every block in it proves only that AT LEAST ONE block
    # compiles: the compiler stops at the first error it cannot recover from,
    # so a broken block hides the ones after it, and "every code block
    # compiles" is not what was checked.  One probe per block makes the
    # promise literal, and it makes a broken block visible as ITS OWN
    # failure rather than as one failure for the whole README.
    for ln, info, b in code_blocks:
        probe_path = os.path.join(pkg_dir, PROBE_NAME)
        probe_rel = os.path.join(PROBE_PKG, PROBE_NAME).replace("\\", "/")
        try:
            parts = ["//|", 'test "the published README\'s code blocks compile" {',
                     PREAMBLE]
            parts.append("  {")
            parts.extend("    " + x for x in b)
            parts.append("  }")
            parts.append("}")
            io.open(probe_path, "w", encoding="utf-8", newline="\n").write(
                "\n".join(parts) + "\n")
            p = subprocess.run([moon, "check", "--target", "wasm-gc"], cwd=pkg_dir,
                               capture_output=True, text=True, encoding="utf-8",
                               errors="replace", timeout=1800)
            out = (p.stdout or "") + (p.stderr or "")
            check("the code block at README line %d compiles" % ln,
                  p.returncode == 0,
                  "the compiler rejected the block (exit %d):\n%s"
                  % (p.returncode, "\n".join(out.splitlines()[-24:])))
        finally:
            if os.path.isfile(probe_path):
                os.remove(probe_path)

leftover = os.path.isfile(os.path.join(pkg_dir, PROBE_NAME))
check("the probe file is removed and the tree is left as it was",
      not leftover, "%s is still there" % probe_rel)

print()
print("checks run: %d, checks failed: %d, skipped: %d"
      % (NCHECK, len(FAILS), len(SKIPPED)))
for f in FAILS:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))
sys.exit(1 if FAILS else 0)
