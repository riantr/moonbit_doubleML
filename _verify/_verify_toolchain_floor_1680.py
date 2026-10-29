"""Hold the README's TOOLCHAIN FLOOR -- the requirement a reader must meet.

WHAT THIS IS ABOUT
==================
`capnp@0.1.0` says which MoonBit it needs ("需要 MoonBit 0.10.14 或更新版本").
Round 59 REFUSED to publish a floor for this README, and the refusal was
correct at the time: nothing in this tree established one.  The tree pinned
`moonbitlang/async@0.22.5`, and the published source of 0.22.5 does not
touch the MoonBit core at all -- so ANY `moon` could build this package, and
a floor would have been decoration.

Round 70 moved the pin to `moonbitlang/async@0.22.6`, and THAT established
the floor.  Measured:

  * the published source of 0.22.6 imports `moonbitlang/core/async` (six
    files); every earlier published version -- 0.10.0 through 0.22.5 -- does
    not.  So the pin move is what created the requirement;
  * the core that ships with `moon 0.1.20261028` (core 0.10.18) carries the
    subpackage; the core of `moon 0.1.20261023` (core 0.10.17) does not;
  * a CONSUMER on the old core cannot build the published package at all --
    "Cannot find import 'moonbitlang/core/async' in
    moonbitlang/async@0.22.6" -- and the same consumer builds it on the new
    one.  That pair is a control arm: the old arm fails FOR THAT REASON and
    the new arm succeeds, so the failure is the floor and not something else.

So the floor is a FACT about the published package, and this file holds the
README's statement of it.

WHAT IS CHECKED
===============
  F1  the tree declares exactly one `moonbitlang/async` pin, and it is READ
      from `moon.mod` -- never written here;
  F2  the Installation section states a requirement, and it names the pin the
      tree declares;
  F3  the requirement names the subpackage the pin imports;
  F4  the published source of the pin REALLY imports that subpackage, measured
      out of the toolchain's own downloaded copy of the package -- not out of
      a description of it, and not out of this file's own belief;
  F5  the core that is installed here really provides the subpackage;
  F6  the OTHER declared dependency imports no `moonbitlang/core/async`, so
      the floor is forced by one pin and not by two;
  F7  the requirement and the Status table's Toolchain row name the SAME
      toolchain -- two sites, one fact;
  F8  the requirement is not NEWER than the toolchain the release was
      verified on.  A floor above the verified toolchain would be a release
      that cannot build on the floor it publishes;
  F9  the requirement lives INSIDE the Installation section;
  F10 the "Not covered" section says what the dead pin COSTS, so "dead" does
      not read as "harmless";
  F11 the installation guide states the same floor, and no longer says the
      repository pins no minimum.

TWO METHOD POINTS
==================
  * THE PIN IS DERIVED.  It is read out of `moon.mod` with the `//` comments
    stripped, so this file cannot name a version the tree does not declare.
  * THE PUBLISHED SOURCE IS MEASURED, NOT ASSERTED.  The toolchain downloads
    every declared dependency into its own registry cache; the pin's zip is
    read there and its contents searched.  If that copy is not there, the
    measurement is SKIPPED and says so -- loudly -- rather than being
    reported as a pass.  A check that cannot fail is not a check.

WHAT IS NOT CHECKED HERE, AND WHY
=================================
  * That the floor is the FIRST toolchain that could work.  The argument is
    a date argument -- the core that carries the subpackage is dated
    2026-10-28, and no `moon` released before it can bundle it -- and it is
    recorded in the ENGINEERING banner rather than asserted here, because a
    check that re-derives it would have to trust a release list this tree
    does not have.
  * That the requirement names a version the tree declares.  That class is
    owned by `_verify/_verify_dep_pins_1680.py`, which now covers the
    Installation site too.  One verifier per fact.

Run: python _verify/_verify_toolchain_floor_1680.py
"""
import io
import os
import re
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
SHIPPED = os.path.join(PKG, "README.mbt.md")
GUIDE = os.path.join(ROOT, "doc", "002_installation", "readme.mbt.md")
MOON_MOD = os.path.join(PKG, "moon.mod")

HOME = os.path.expanduser("~")
# The toolchain's own convention: `MOON_HOME` selects the installation, and it
# defaults to `~/.moon`.  Reading it here means the measurement follows the
# toolchain -- and it means the measurement can be pointed at an installation
# that does NOT carry the subpackage, which is how the dry-run proves this
# check bites.
MOON_HOME = os.environ.get("MOON_HOME") or os.path.join(HOME, ".moon")
CACHE = os.path.join(MOON_HOME, "registry", "cache")
CORE = os.path.join(MOON_HOME, "lib", "core")

SUBPACKAGE = "moonbitlang/core/async"

fails = []
skips = []
NCHECK = 0


def check(label, cond, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def skip(label, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-62s SKIP" % label)
    print("      %s" % detail)
    skips.append("%s -- %s" % (label, detail))


def read(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


def section(text, heading, level=2):
    """The body of a section, up to the next heading of the same or higher level."""
    pat = r"(?m)^#{%d} %s\s*$" % (level, re.escape(heading))
    m = re.search(pat, text)
    if not m:
        return None
    rest = text[m.end():]
    nxt = re.search(r"(?m)^#{1,%d} \S" % level, rest)
    return rest[:nxt.start()] if nxt else rest


readme = read(README)
shipped = read(SHIPPED)

print("== the tree's pins ==")

# the pins, read from the manifest with the comments stripped
raw = read(MOON_MOD)
live = "\n".join(re.sub(r"//.*$", "", ln) for ln in raw.split("\n"))
imp = re.search(r"import\s*\{(.*?)\}", live, re.S)
deps = re.findall(r'"([^"]+)"', imp.group(1)) if imp else []
check("the package's import block is findable", bool(deps), str(deps))
async_pins = [d for d in deps if d.startswith("moonbitlang/async@")]
check("the tree declares exactly one moonbitlang/async pin",
      len(async_pins) == 1, str(async_pins))
if not async_pins:
    print("  no async pin: nothing else can be checked")
    sys.exit(1)
PIN = async_pins[0]
PIN_VER = PIN.split("@", 1)[1]
other_pins = [d for d in deps if not d.startswith("moonbitlang/async@")]
print("   the async pin : %s" % PIN)
print("   the other pin : %s" % (other_pins[0] if other_pins else "(none)"))

# ---------------------------------------------------------------------------
# F1 -- the README's Installation requirement
# ---------------------------------------------------------------------------
print()
print("== the Installation requirement ==")

install = section(readme, "Installation", 2)
check("the README has an Installation section", install is not None)
if install is None:
    print("  nothing else can be checked")
    sys.exit(1)

req = re.search(r"\*\*Requires `moon ([0-9]+\.[0-9]+\.[0-9]+)` or newer\.\*\*",
                install)
check("the Installation section states a minimum `moon` version", req is not None,
      "no '**Requires `moon X.Y.Z` or newer.**' sentence")
FLOOR = req.group(1) if req else ""
if FLOOR:
    print("   the stated floor: moon %s" % FLOOR)
    check("the requirement names the pin the tree declares",
          PIN in install, "the tree declares %s" % PIN)
    check("the requirement names the subpackage the pin imports",
          SUBPACKAGE in install, "no %s" % SUBPACKAGE)
    check("the requirement quotes the error an older core produces",
          "Cannot find import" in install, "the symptom is not stated")
    # F9 -- it lives in the Installation section, not somewhere else
    all_reqs = re.findall(r"\*\*Requires `moon ([0-9]+\.[0-9]+\.[0-9]+)` or newer\.\*\*",
                          readme)
    check("the requirement is stated ONCE, in the Installation section",
          len(all_reqs) == 1, "%d occurrences" % len(all_reqs))

# ---------------------------------------------------------------------------
# F2 -- the published source of the pin REALLY imports the subpackage
# ---------------------------------------------------------------------------
print()
print("== the published source of the pin ==")


def cached_zip(pin):
    """The toolchain's own downloaded copy of a pinned package."""
    owner_pkg, ver = pin.split("@", 1)
    owner, pkg = owner_pkg.split("/", 1)
    p = os.path.join(CACHE, owner, pkg, "%s.zip" % ver)
    return p if os.path.isfile(p) else None


def core_imports(zip_path):
    """Every `moonbitlang/core/...` a published source imports."""
    found = set()
    with zipfile.ZipFile(zip_path) as zf:
        for n in zf.namelist():
            if n.endswith("/"):
                continue
            try:
                body = zf.read(n)
            except Exception:  # noqa: BLE001
                continue
            for m in re.finditer(rb"moonbitlang/core([a-z0-9_/]*)", body):
                found.add("moonbitlang/core" + m.group(1).decode("ascii", "replace"))
    return found


zip_path = cached_zip(PIN)
if zip_path is None:
    skip("the published source of %s imports %s" % (PIN, SUBPACKAGE),
         "the toolchain has no downloaded copy of %s; run `moon update` and "
         "`moon build` to fetch it" % PIN)
else:
    imports = core_imports(zip_path)
    print("   the published source imports %d core subpackage(s)" % len(imports))
    check("the published source of %s imports %s" % (PIN, SUBPACKAGE),
          SUBPACKAGE in imports,
          "it imports: %s" % sorted(imports)[:6])

# ---------------------------------------------------------------------------
# F3 -- the core that is installed here provides the subpackage
# ---------------------------------------------------------------------------
print()
print("== the installed core ==")
check("the installed core provides %s" % SUBPACKAGE,
      os.path.isdir(os.path.join(CORE, "async")),
      "no %s" % os.path.join(CORE, "async"))

# ---------------------------------------------------------------------------
# F4 -- the OTHER declared dependency does not force the floor
# ---------------------------------------------------------------------------
print()
print("== the other declared dependency ==")
if not other_pins:
    check("the tree declares a second dependency to compare against", False,
          "there is none -- the comparison has nothing to compare")
else:
    other_zip = cached_zip(other_pins[0])
    if other_zip is None:
        skip("%s imports no %s" % (other_pins[0], SUBPACKAGE),
             "the toolchain has no downloaded copy of %s" % other_pins[0])
    else:
        other_imports = core_imports(other_zip)
        print("   %s imports %d core subpackage(s)"
              % (other_pins[0], len(other_imports)))
        check("%s imports no %s" % (other_pins[0], SUBPACKAGE),
              SUBPACKAGE not in other_imports,
              "it imports: %s" % sorted(other_imports)[:6])

# ---------------------------------------------------------------------------
# F5 -- the two README sites agree, and the floor is not above the verified one
# ---------------------------------------------------------------------------
print()
print("== the two sites, and the verified toolchain ==")

row = re.search(r"(?m)^\|\s*Toolchain\s*\|\s*`moon ([0-9]+\.[0-9]+\.[0-9]+)`",
                 readme)
check("the Status table has a Toolchain row", row is not None)
if row and FLOOR:
    VERIFIED = row.group(1)
    print("   the Status table's toolchain: moon %s" % VERIFIED)
    check("the requirement and the Toolchain row name the SAME toolchain",
          FLOOR == VERIFIED, "floor=%s row=%s" % (FLOOR, VERIFIED))
    # the floor may not be NEWER than the toolchain the release was verified
    # on: a floor above it would be a release that cannot build on its own
    # published floor.  The versions are date-shaped, so a string comparison
    # is the comparison.
    check("the floor is not newer than the toolchain this release was "
          "verified on", FLOOR <= VERIFIED,
          "floor=%s verified=%s" % (FLOOR, VERIFIED))

# ---------------------------------------------------------------------------
# F6 -- the "Not covered" section says what the dead pin costs
# ---------------------------------------------------------------------------
print()
print("== what the dead pin costs ==")
nc = section(readme, "Not covered, so not claimed", 3)
check("the README has the 'Not covered' section", nc is not None)
if nc:
    flat = " ".join(nc.split())
    check("it says the dead pin still sets a toolchain floor",
          "toolchain floor" in flat, "the cost is not stated")
    check("it points at the Installation section",
          "Installation" in flat, "no pointer to where the floor is stated")
    check("it says the dead pin imports the subpackage",
          SUBPACKAGE in flat, "the mechanism is not stated")

# ---------------------------------------------------------------------------
# F7 -- the installation guide agrees
# ---------------------------------------------------------------------------
print()
print("== the installation guide ==")
guide = read(GUIDE)
if FLOOR:
    check("the installation guide names the same floor",
          ("moon %s" % FLOOR) in guide, "the guide does not name moon %s" % FLOOR)
    check("the installation guide no longer says the repository pins no "
          "minimum", "pins no minimum" not in guide, "the old sentence is there")
    check("the installation guide names the subpackage",
          SUBPACKAGE in guide, "no %s" % SUBPACKAGE)

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("%d checks, %d failed, %d skipped" % (NCHECK, len(fails), len(skips)))
for f in fails:
    print("  FAIL %s" % f)
for s in skips:
    print("  SKIP %s" % s)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
