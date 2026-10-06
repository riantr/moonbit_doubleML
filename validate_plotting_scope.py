"""Keeps the "plotting is not ported" claim true, or loudly red.

v0.110.0 closed the RDD item; this is the last item of the v0.107.0
coverage audit -- recording that upstream's plotting is DELIBERATELY not
ported, instead of leaving it as a silent absence. A silent absence rots:
the next reader cannot tell an omission from a decision, and within a
few releases someone "fixes" it by adding matplotlib calls to a package
whose targets are wasm / native / js.

What this gate checks, in BOTH directions, because a one-directional
check is immune to exactly the case that matters:

  1. `README.mbt.md` states the decision. Absent -> FAIL, because a
     decision nobody wrote down is an omission with extra steps.
  2. No plotting entry point exists in the package.
  3. If one DOES exist, the gate FAILS rather than passing -- the README
     is then lying, and the lying is the defect.

Direction 3 is the whole point. A gate that only checks "the README
says not ported" would keep passing after plotting landed, which is
precisely when the sentence becomes false.

SCOPE NOTE, stated rather than left to be discovered: this file is NOT
matched by `validate_suite_meta.py`'s `validate_*_with_python.py` glob,
so that meta-gate does not audit it. The three buckets it maintains
(reads MoonBit / reference-only / hard-coded verdict) do not describe a
fourth kind -- a validator that audits a documentation claim against the
source tree -- and forcing it into one of them would be a false label.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
README = os.path.join(HERE, "moonbit_doubleML", "README.mbt.md")
PKG = os.path.join(HERE, "moonbit_doubleML")

# The upstream surface that is not ported. Names, not paths, because the
# point of the check is "these have no counterpart here".
UPSTREAM_PLOTTING = {
    "doubleml/utils/_plots.py",
    "doubleml/did/utils/_plot.py",
    "DoubleMLDIDMulti::plot",
    "DoubleMLDID::plot",
    "DoubleMLPolicyTree::plot",
}

# What a port would look like on this side: a definition, not a call site
# and not the word "plot" inside a comment. Anchored to column 0 or to a
# `pub fn`, so `// draw the plot` cannot masquerade as one.
PLOT_DEF = re.compile(
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:fn|let|extern\s+\w+)\s+(?:\w+::)?plot\b",
    re.M,
)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main():
    problems = []

    readme = read(README)

    # (1) the decision must be written down
    stated = "not ported" in readme.lower() and "plot" in readme.lower()
    print(f"README states the plotting decision : {stated}")
    if not stated:
        problems.append(
            "README.mbt.md does not state that upstream plotting is not "
            "ported. A decision nobody wrote down reads as an omission."
        )

    # (2) find plotting definitions in the package
    found = []
    for name in sorted(os.listdir(PKG)):
        if not name.endswith(".mbt") or name.endswith("_test.mbt"):
            continue
        src = read(os.path.join(PKG, name))
        for m in PLOT_DEF.finditer(src):
            line = src[: m.start()].count("\n") + 1
            found.append((name, line, m.group(0).strip()))
    for name, line, text in found:
        print(f"  plotting definition: {name}:{line}  {text}")
    print(f"plotting definitions in the package : {len(found)}")

    # (3) the two must agree
    if found and stated:
        problems.append(
            "the package defines plotting entry point(s) "
            + ", ".join(f"{n}:{l}" for n, l, _ in found)
            + " while README.mbt.md still says plotting is not ported. "
            "The README is now false -- update it in the same commit that "
            "added the code."
        )

    if not found and not stated:
        problems.append(
            "no plotting code AND no statement: the decision is simply "
            "missing."
        )

    print()
    if problems:
        print("Plotting-scope claim is NOT holding:")
        for p in problems:
            print(f"  - {p}")
        print("plotting-scope check: FAIL")
        return 1

    print("Plotting-scope claim holds: README states the decision, and no "
          f"plotting entry point exists ({len(UPSTREAM_PLOTTING)} upstream "
          "names deliberately unported).")
    print("plotting-scope cross-check: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
