"""Pin the dependency claims and the Quick Start's working directory.

Three claims that had drifted:

1. The dependency table's `moonbitlang/async@0.22.5` row said the api_server
   example "declares it in its own `moon.mod`".  The example declared
   `moonbitlang/async@0.20.3` -- a DIFFERENT pin -- so the library's 0.22.5
   line was referenced by nothing at all.  A table cell that names the wrong
   version is worse than no note.

2. The Quick Start block never said where to run it.  All three commands work
   from the repository root; two of them FAIL from inside `moonbit_doubleML/`
   ("failed to resolve path `examples/main`" and "can't open file
   ...validate_irm_with_python.py").  The block was therefore correct but
   ambiguous, and a reader who guessed the library directory got two errors.

3. (round 44) The check that owned claim 1 PINNED THE TREE IN PLACE.  It
   asserted that the example's async pin DIFFERS from the library's, which
   encodes ONE shape -- two different pins -- and forbids the tree from
   taking any other shape, including the correct one.  That is a
   straitjacket: it is a check about a DOCUMENT'S SHAPE wearing the clothes
   of a check about a DOCUMENT'S TRUTH.  The example's pin was two published
   versions behind the library's, and the README's own rule says to pin the
   latest published version, so the right move was to MOVE THE PIN -- which
   the straitjacket forbade.

   The class the check was meant to own is "a version a document names must
   be a version the tree declares", and that is what it asserts now:

     * the note states the example's ACTUAL pin,
     * the note names no version the tree does not declare,
     * the service sentence states the example's ACTUAL pin,

   and the RULE the README states -- "Pin to the latest published version" --
   gets a check of its own, which SKIPS when the registry cannot be reached.

A NOTE ON HOW THE PINS ARE READ
===============================
The manifests are read with their `//` COMMENTS STRIPPED.  `moon.mod` carries
the template's own example line inside a comment:

    // import {
    //   "moonbitlang/x@0.4.6",
    // }

so a manifest audit that does not strip comments reads a package the tree does
not declare -- and a check that requires such a package to be "the published
latest" would then ask the registry about `moonbitlang/x`, which is not a
package anyone publishes.

Only TRACKED manifests are read: a promise about a dependency is a promise
about the tree that ships.
"""
import io
import json
import os
import re
import subprocess
import sys
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
API = os.path.join(ROOT, "examples", "api_server")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

fails = []
skips = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def skip(label, detail=""):
    print("  %-58s %s" % (label, "SKIP"))
    skips.append("%s -- %s" % (label, detail))


def strip_comments(text):
    """The text with every `//` line comment removed.

    MoonBit's `moon.mod` uses `//` for comments.  A commented-out import is a
    TEMPLATE, not a dependency.
    """
    out = []
    for line in text.split("\n"):
        out.append(line.split("//", 1)[0])
    return "\n".join(out)


def imports_of(moon_mod):
    txt = io.open(moon_mod, encoding="utf-8").read()
    return re.findall(r"\"([^\"]+@[^\"]+)\"", strip_comments(txt))


def tracked_manifests():
    """Every TRACKED `moon.mod` in the tree."""
    try:
        raw = subprocess.run(["git", "ls-files", "-z", "--", "*moon.mod"],
                             cwd=ROOT, capture_output=True, timeout=120)
        paths = [p for p in raw.stdout.decode("utf-8", "replace").split("\0") if p]
    except (OSError, subprocess.SubprocessError):
        paths = []
    if paths:
        return [os.path.join(ROOT, p) for p in paths]
    # git is not available: walk the tree instead, skipping the build and
    # cache directories that are not part of the tree.
    found = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "_build", "node_modules", ".mooncakes")]
        if "moon.mod" in filenames:
            found.append(os.path.join(dirpath, "moon.mod"))
    return found


def registry_latest(pkg):
    """The registry's `latest_version` for a package, or None if unreachable."""
    url = "https://mooncakes.io/api/v0/modules/%s" % pkg
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            raw = r.read()
        data = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return None
    v = data.get("latest_version")
    return v if isinstance(v, str) and v else None


lib_imports = imports_of(os.path.join(LIB, "moon.mod"))
api_imports = imports_of(os.path.join(API, "moon.mod"))
print("library imports   : %s" % lib_imports)
print("api_server imports: %s" % api_imports)

# every version the TREE declares, across every tracked manifest
declared = set()
for m in tracked_manifests():
    declared.update(imports_of(m))
print("declared pins     : %s" % sorted(declared))
print("")

# --------------------------------------------------- 1. the dependency table
lib_async = [i for i in lib_imports if i.startswith("moonbitlang/async")]
api_async = [i for i in api_imports if i.startswith("moonbitlang/async")]
check("the library declares exactly one async", len(lib_async) == 1, str(lib_async))
check("the example declares exactly one async", len(api_async) == 1, str(api_async))

row = re.search(r"^\|\s*`moonbitlang/async@([\d.]+)`\s*\|\s*no\s*\|\s*(.*?)\s*\|\s*$",
                readme, re.M)
check("the dependency table has an async row", row is not None)
if row:
    note = row.group(2)
    print("  note: %s" % note)
    check("the row's version is the library's own pin",
          row.group(1) == lib_async[0].split("@")[1],
          "row=%s library=%s" % (row.group(1), lib_async[0]))
    check("the note states the example's ACTUAL pin",
          api_async[0].split("@")[1] in note,
          "the example declares %s" % api_async[0])
    # The class the straitjacket stood in for: a document must not name a
    # version the tree does not declare.  The note names ONE version, and it
    # has to be one of ours.
    named = set(re.findall(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@\d[\w.+-]*", note))
    check("the note names no version the tree does not declare",
          named and named <= declared,
          "the note names %s, the tree declares %s"
          % (sorted(named), sorted(declared)))
    check("the old claim that the example declares 'it' is gone",
          "which declares it in its own `moon.mod`" not in readme)

# The SAME pin is quoted in a second place -- the sentence that says what the
# service is built on.  It was right only by luck: it happened to quote the
# example's own pin while the dependency table quoted a different one.
m_svc = re.search(r"The service is built directly on `([^`]+)`", readme)
check("the README's service sentence names a pin", m_svc is not None)
if m_svc:
    check("the service sentence states the example's ACTUAL pin",
          m_svc.group(1) == api_async[0],
          "the sentence says %s, the example declares %s"
          % (m_svc.group(1), api_async[0]))

# the library's .mbt files import neither
refs = 0
for f in os.listdir(LIB):
    if f.endswith(".mbt"):
        s = io.open(os.path.join(LIB, f), encoding="utf-8", errors="replace").read()
        refs += len(re.findall(r"moonbitlang/async|sqlite3", s))
check("the library's .mbt files reference neither package (0)", refs == 0,
      "got %d references" % refs)

# --------------------------------------- 2. the Quick Start's working directory
check("the README says to run the Quick Start from the repository root",
      re.search(r"Run these from the \*\*repository root\*\*", readme) is not None)
check("it says the two repo-root paths fail from moonbit_doubleML/",
      "fail from inside `moonbit_doubleML/`" in readme)

# measure it: the two commands must fail from the library dir
print("")
for cmd, marker in ((["moon", "run", "examples/main"], "examples/main"),
                     ([sys.executable, "validate_irm_with_python.py"],
                      "validate_irm_with_python.py")):
    p = subprocess.run(cmd, cwd=LIB, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    check("`%s` fails from the library dir" % " ".join(cmd[:2]),
          p.returncode != 0 and (marker in out or "No such file" in out
                                 or "failed to resolve" in out),
          "rc=%d out=%s" % (p.returncode, out[:160].replace("\n", " ")))

# and the validator must exist at the repo root
check("validate_irm_with_python.py exists at the repo root",
      os.path.isfile(os.path.join(ROOT, "validate_irm_with_python.py")))

# ------------------------------------------- 3. the rule the README states
# "Pin to the latest published version (e.g. `moonbitlang/async@0.22.5`)."
# The registry is the authority on what "latest" means, and it is a NETWORK
# resource: a pin that cannot be checked is SKIPPED, never failed.  The
# number of checks is fixed by the number of third-party pins, not by the
# network.
#
# `riantr/*` is EXCLUDED: this repository's own package is published by this
# very release, so "the published latest" is the version being cut -- and the
# library's own `moon.mod` cannot name a version that does not exist yet.
print("")
print("  -- the rule: every third-party pin is the published latest --")
third_party = sorted({p for p in declared if not p.startswith("riantr/")})
for pin in third_party:
    pkg, ver = pin.split("@", 1)
    latest = registry_latest(pkg)
    if latest is None:
        skip("%s is pinned at the published latest" % pkg,
             "the registry could not be reached")
        continue
    check("%s is pinned at the published latest" % pkg,
          ver == latest,
          "pinned %s, the registry publishes %s" % (ver, latest))

print("")
print("checks failed: %d" % len(fails))
print("checks skipped: %d" % len(skips))
for f in fails:
    print("  - %s" % f)
for s in skips:
    print("  - skipped: %s" % s)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
