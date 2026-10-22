#!/usr/bin/env python3
"""Round 31 verifier: the library PIN in every example manifest.

WHY THIS EXISTS
===============
`examples/<name>/moon.mod` import the library:

    import {
      "riantr/moonbit_doubleML@0.52.0",
    }

That version was current when the examples were written.  It was never
revisited, and nothing in CI could see it: in the WORKSPACE the pin is
INERT -- the workspace member wins -- so the example builds against the
current library while its manifest names a version from 159 releases ago.

Outside the workspace the pin is the only thing that decides what gets
installed.  A user who copies an example -- which is exactly what the
README's Examples section invites -- and runs `moon update` there resolves
`riantr/moonbit_doubleML@0.52.0` from the registry: a library whose API is
nothing like the one the example was written against.  The README even
describes `examples/consumer_demo/` as "the library-user pattern that mirrors
what an external `moon add riantr/moonbit_doubleML` consumer would write",
and it pinned a version 159 releases old.

The same drift happened once already, in the api_server example's ADVERTISED
version, and it took 124 releases to notice: the QA loop's `/version` check
only asserted that the substring appeared at all.  The manifest pin is the
same promise in a different file, and nobody was looking at it.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the library's version, from `moonbit_doubleML/moon.mod`;
  * the example manifests, from the filesystem;
  * the set of version SITES, from the bump script's own
    `os.path.join(ROOT, ...)` calls -- so "every site" is a NAMED set rather
    than a guess;
  * the published check count, which the CHANGELOG publishes and this
    verifier witnesses.

Both counts are declared here and asserted in section 1, which is what keeps
the published check count FIXED: an example cannot be added or removed
without the declaration moving with it.

THE SCOPE IS DELIBERATE
=======================
The stale-literal scan in section 3 covers the version SITES only -- the
files the bump script owns.  A historical record may name an old version on
purpose: `CHANGELOG.md` and the `_verify/` records are exactly where an old
version belongs, and scanning them would flag history as if it were a
defect.  A MANIFEST, by contrast, is a promise about what to install, and a
promise of an old version is a defect.

Run: python _verify/_verify_example_pins_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
EXAMPLES = os.path.join(ROOT, "examples")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
BUMP = os.path.join(ROOT, "_verify", "_bump_1636.py")

# The two counts.  A change to either is a change to the SET, so it is
# declared here and asserted below.
EXPECTED_EXAMPLES = 21

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-58s %s" % (label, detail))
    else:
        FAILS.append(label)
        print("  *** FAIL ***  %-52s %s" % (label, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


PIN = re.compile(r'"riantr/moonbit_doubleML@([^"]+)"')

# ==============================================================================
print("=" * 78)
print("1. the set")
print("=" * 78)

ver_m = re.search(r'^version\s*=\s*"([^"]+)"', read(os.path.join(LIB, "moon.mod")), re.M)
VER = ver_m.group(1) if ver_m else None

manifests = sorted(os.path.join(EXAMPLES, d, "moon.mod")
                   for d in os.listdir(EXAMPLES)
                   if os.path.isfile(os.path.join(EXAMPLES, d, "moon.mod")))

print("  the library is at %s" % VER)
print("  example manifests: %d" % len(manifests))

check("the library's version is derived from moon.mod", VER is not None, str(VER))
check("there are %d example manifests" % EXPECTED_EXAMPLES,
      len(manifests) == EXPECTED_EXAMPLES, "found %d" % len(manifests))

# ==============================================================================
print()
print("=" * 78)
print("2. every example manifest pins the library at the current version")
print("=" * 78)

for p in manifests:
    rel = os.path.relpath(p, ROOT).replace("\\", "/")
    hits = PIN.findall(read(p))
    if len(hits) != 1:
        check("%s pins the library once" % rel, False,
              "it carries %d library pins" % len(hits))
        continue
    check("%s pins the library at %s" % (rel, VER), hits[0] == VER,
          "it pins %s" % hits[0])

# ==============================================================================
print()
print("=" * 78)
print("3. no version SITE carries a stale library literal")
print("=" * 78)
# The sites are the bump script's own paths, so the set is NAMED: the same
# list the release process bumps.
bump_src = read(BUMP)
sites = set()
for m in re.finditer(r'os\.path\.join\(\s*ROOT\s*,\s*((?:"[^"]+"\s*,\s*)*"[^"]+")\s*\)',
                     bump_src):
    sites.add("/".join(re.findall(r'"([^"]+)"', m.group(1))))
print("  version sites (from the bump script): %d" % len(sites))

stale = []
for rel in sorted(sites):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    for hit in PIN.findall(read(p)):
        # a TEMPLATE is not a version: the README builder carries
        # `riantr/moonbit_doubleML@%(v)s`, where `%(v)s` is filled in at
        # build time.  Only a real version number can be stale.
        if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", hit):
            continue
        if hit != VER:
            stale.append("%s -> %s" % (rel, hit))
check("no version site names a library older than %s" % VER,
      not stale, "; ".join(stale[:6]))

# ==============================================================================
print()
print("=" * 78)
print("4. the README's install instruction")
print("=" * 78)
# The README tells the reader what to write in their own moon.mod.  If the
# examples are re-pinned and the README is not, the reader copies the wrong
# one.
readme = read(os.path.join(ROOT, "README.mbt.md"))
check("the README's install block names %s" % VER,
      ('"riantr/moonbit_doubleML@%s"' % VER) in readme,
      "it does not")
check("the README names no other library version",
      all(h == VER for h in PIN.findall(readme)),
      "; ".join(sorted(set(h for h in PIN.findall(readme) if h != VER))[:6]))

# ==============================================================================
print()
print("== 5. the published check count, witnessed ==")
# The CHANGELOG publishes this verifier's check count.  The count is fixed on
# every tree that passes: the set sizes are declared and asserted in section
# 1, so an example cannot be added or removed without the declaration moving
# with it, and the published number cannot drift.
# ==============================================================================
_found = re.findall(r"_verify_example_pins_1650\.py` \(\*\*(\d+)\*\* checks\)",
                    read(CHANGELOG))
published = int(_found[0]) if _found else None
check("the CHANGELOG publishes this verifier's check count",
      published is not None,
      "the '(**N** checks)' line for this verifier is absent" if published is None
      else "published %d (of %d occurrences, newest first)"
      % (published, len(_found)))
check("the published check count is the count this run made",
      published is not None and published == NCHECK + 1,
      "published %s, this run makes %d" % (published, NCHECK + 1))

# ==============================================================================
print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
if FAILS:
    for f in FAILS:
        print("  FAILED: %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
