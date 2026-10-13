"""Guard: the README that ships must be the README people edit.

WHY THIS EXISTS
---------------
There are two files named README.mbt.md:

    README.mbt.md                  <- edited by humans, rendered by GitHub
    moonbit_doubleML/README.mbt.md  <- referenced by moon.mod, SHIPPED

`moon.mod` sits in the package dir and says `readme = "README.mbt.md"`, which
resolves RELATIVE TO THE PACKAGE DIR. So the package copy is what `moon publish`
sends to mooncakes.io and what the registry page renders.

The two drifted silently: the package copy was still at v0.115.0 / 855 tests
while the repo was at v0.159.0 / 1120 -- 44 versions of the published page
showing stale numbers. Nothing failed, because nothing compared them.

This checks three things:
  1. moon.mod's `readme` path actually resolves to a non-empty file
  2. the shipped README exists and is non-empty
  3. the two READMEs are byte-identical

Exits 0 when all hold, 1 otherwise, with a message that says which one failed.
"""
import os
import re
import sys

# A gate is only as useful as its failure message. On a non-UTF-8 console (this
# repo is developed on a GBK one) printing a diff line containing a BOM or any
# non-ASCII raises UnicodeEncodeError and the guard exits on a TRACEBACK instead
# of on the check -- which is the exact failure mode it exists to catch.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # noqa: BLE001 - very old Python, or a non-TextIO stdout
    pass

def find_repo_root(start):
    """Walk up until we find the directory holding moonbit_doubleML/moon.mod.

    Location-independent on purpose: this file has to keep working whether it
    lives in .github/scripts/ or _verify/, and a hardcoded
    parent-of-parent would silently compute the wrong root if it were moved --
    which is the same class of bug this guard exists to catch.
    """
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "moonbit_doubleML", "moon.mod")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            sys.exit("ABORT: could not locate the repo root (no moonbit_doubleML/moon.mod found above)")
        d = parent


ROOT = find_repo_root(os.path.dirname(os.path.abspath(__file__)))
MOON_MOD = os.path.join(ROOT, "moonbit_doubleML", "moon.mod")


def read(p):
    with open(p, "rb") as f:
        return f.read()


problems = []

# 1. what does moon.mod declare, and does it resolve inside the package dir?
declared = None
try:
    txt = read(MOON_MOD).decode("utf-8")
    m = re.search(r'^readme\s*=\s*"([^"]+)"', txt, re.M)
    if m is None:
        problems.append("moon.mod does not declare a `readme` field at all")
    else:
        declared = m.group(1)
        pkg = os.path.join(ROOT, "moonbit_doubleML")
        resolved = os.path.normpath(os.path.join(pkg, declared))
        if not os.path.isfile(resolved):
            problems.append(
                f'moon.mod declares readme = "{declared}", which resolves to\n'
                f"    {resolved}\n"
                f"  and that file does not exist. moon publish would ship no README."
            )
        elif len(read(resolved)) == 0:
            problems.append(f"the shipped README {declared} is EMPTY")
except FileNotFoundError:
    sys.exit(f"ABORT: {MOON_MOD} not found")

# 2/3. compare the edited copy with the shipped copy
HUMAN = os.path.join(ROOT, "README.mbt.md")
SHIPPED = os.path.join(ROOT, "moonbit_doubleML", declared) if declared else None

if SHIPPED and os.path.isfile(SHIPPED) and os.path.isfile(HUMAN):
    a, b = read(HUMAN), read(SHIPPED)
    if a != b:
        # report the first differing line, which is far more actionable than
        # "they differ" when the delta is a whole stale version
        al = a.decode("utf-8", "replace").splitlines()
        bl = b.decode("utf-8", "replace").splitlines()
        first = next(
            (i for i in range(min(len(al), len(bl))) if al[i] != bl[i]),
            min(len(al), len(bl)),
        )
        problems.append(
            "the shipped README and the edited README have DIVERGED.\n"
            f"  edited : {os.path.relpath(HUMAN, ROOT)} ({len(a)} bytes, {len(al)} lines)\n"
            f"  shipped: {os.path.relpath(SHIPPED, ROOT)} ({len(b)} bytes, {len(bl)} lines)\n"
            f"  first difference at line {first + 1}:\n"
            f"    edited : {al[first] if first < len(al) else '<EOF>'}\n"
            f"    shipped: {bl[first] if first < len(bl) else '<EOF>'}\n"
            "  mooncakes.io renders the SHIPPED one, so fix by copying edited ->\n"
            "  shipped, not the other way round."
        )

if problems:
    print("::error::README sync check failed")
    for p in problems:
        print(p)
    sys.exit(1)

print(
    f"README sync OK: moon.mod readme=\"{declared}\" resolves to a non-empty file "
    f"and it is byte-identical to {os.path.relpath(HUMAN, ROOT)} "
    f"({len(read(SHIPPED))} bytes)"
)
sys.exit(0)