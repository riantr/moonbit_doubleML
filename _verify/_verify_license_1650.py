#!/usr/bin/env python3
"""Round 42 verifier: the LICENCE the tree claims and the licence it grants.

WHAT THIS EXISTS FOR
=====================
Round 42's promise audit found the tree contradicting itself three ways:

  * `moonbit_doubleML/moon.mod` declared `license = "MIT"`, the README said
    MIT in two places, and mooncakes.io published `license: MIT`;
  * the root `LICENSE` was the STOCK APACHE-2.0 TEXT -- 202 lines, with
    its `Copyright [yyyy] [name of copyright owner]` placeholder unfilled,
    and untouched since the initial commit 57f2434 (Release 0.4.0);
  * `examples/api_server/LICENSE` was the same stock Apache-2.0 text, and
    22 manifests -- the `doc` project and all 21 examples -- still carried
    the pre-v0.60.0 default `license = "Apache-2.0"`.

`CHANGELOG.md`'s v0.60.0 entry records the intent:

    "the original `项目申报书` rewrote the license to MIT in the v0.60.0
     cycle.  Fixed `moon.mod` to `license = "MIT"` so mooncakes.io displays
     the right SPDX tag."

What that cycle fixed was the MANIFEST.  The licence TEXTS were never
rewritten, so a reader who downloaded the repository was handed Apache-2.0
while every document told them MIT.  A licence is the one promise in a
package that cannot be hedged: it says what the reader is allowed to do.

THE RESOLUTION
==============
MIT everywhere -- the recorded intent, the declared SPDX, the published
registry metadata, and the author's own house text (the same MIT wording,
with the same copyright line, is the licence of the sibling project
`riantr/pyroduct`).  The two LICENSE files now carry that text, and every
manifest declares it.

THE COUNT IS FIXED AT 11
========================
The count this verifier publishes is 11, and it is 11 in EVERY network
condition and in every tree.  The manifest checks are AGGREGATE rather than
one-per-file, so adding a manifest does not move the published number; and
the registry check SKIPS -- still counted, still visible -- when the
registry cannot be reached, because an unreachable registry is not a wrong
licence.  (The round-41 precedent: a skip must stand for exactly the check
it replaces, so the count is a property of this file and not of the
network.)

Run: python _verify/_verify_license_1650.py
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
REGISTRY = "https://mooncakes.io/api/v0/modules/riantr/moonbit_doubleML"

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


def flat(s):
    return re.sub(r"\s+", " ", s)


MIT_MARK = "Permission is hereby granted, free of charge"
APACHE_MARK = "Apache License"

print()
print("A. the licence TEXTS")

root_lic = read(os.path.join(ROOT, "LICENSE"))
check("the root LICENSE grants MIT", MIT_MARK in root_lic,
      "the MIT grant is not in LICENSE")
check("the root LICENSE carries a copyright line",
      bool(re.search(r"^Copyright \(c\) \d{4} .+$", root_lic, re.M)),
      "no `Copyright (c) <year> <holder>` line")
check("the root LICENSE is not the Apache-2.0 text", APACHE_MARK not in root_lic,
      "LICENSE still carries the Apache-2.0 header")

api_lic_path = os.path.join(ROOT, "examples", "api_server", "LICENSE")
if os.path.isfile(api_lic_path):
    api_lic = read(api_lic_path)
    check("the api_server's LICENSE grants MIT", MIT_MARK in api_lic,
          "the MIT grant is not in examples/api_server/LICENSE")
else:
    check("the api_server's LICENSE grants MIT", False,
          "examples/api_server/LICENSE does not exist")

print()
print("B. the manifests")

out = subprocess.run(["git", "ls-files", "-z", "*moon.mod"], cwd=ROOT,
                     capture_output=True)
# The manifests under `_verify/upstream_prove_1649/cases/` are TEST FIXTURES
# -- little packages that exercise the upstream-proof harness -- and they
# declare no licence at all, which is correct for a fixture.  The manifests
# this check is about are the ones a reader INSTALLS: the library, the doc
# project, and the examples.
manifests = [f for f in out.stdout.decode("utf-8", "replace").split("\0")
             if f and not f.startswith("_verify/")]
decl = {}
for rel in manifests:
    m = re.search(r'^\s*license\s*=\s*"([^"]*)"', read(os.path.join(ROOT, rel)),
                  re.M)
    decl[rel] = m.group(1) if m else None
wrong = {k: v for k, v in decl.items() if v != "MIT"}
check("every tracked manifest declares license = \"MIT\"", not wrong,
      "%d manifest(s) declare something else: %s"
      % (len(wrong), ", ".join("%s=%s" % (k, v) for k, v in sorted(wrong.items())[:5])))
check("every tracked manifest declares a licence at all",
      all(v is not None for v in decl.values()),
      "%d manifest(s) declare none"
      % sum(1 for v in decl.values() if v is None))

print()
print("C. the documents")

readme = flat(read(os.path.join(ROOT, "README.mbt.md")))
# the api_server README's layout block is read RAW: `flat()` collapses the
# newlines too, and a line-anchored pattern needs them.
api_readme_raw = read(os.path.join(ROOT, "examples", "api_server", "README.md"))
api_readme = flat(api_readme_raw)

m = re.search(r"\|\s*License\s*\|\s*([^|]+)\|", readme)
check("the README's licence row says MIT",
      m is not None and "MIT" in m.group(1),
      "the row is %r" % (m.group(1) if m else None))
m = re.search(r"## License\s+(.{0,200})", readme)
check("the README's License section says MIT",
      m is not None and "MIT" in m.group(1),
      "the section is %r" % (m.group(1)[:60] if m else None))
m = re.search(r"^\s*LICENSE\s+<-\s*([^,]+),", api_readme_raw, re.M)
check("the api_server README's layout block says MIT",
      m is not None and "MIT" in m.group(1),
      "the block says %r" % (m.group(1) if m else None))
check("the api_server README says the example's licence is the library's",
      "same terms as the library" in api_readme,
      "the sentence is not there")

print()
print("D. the PUBLISHED metadata")

try:
    req = urllib.request.Request(REGISTRY, headers={
        "User-Agent": "moonbit_doubleML-verify/1.0 (licence check)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        payload = json.loads(r.read().decode("utf-8", "replace"))
    lic = payload.get("metadata", {}).get("license")
    check("the published registry metadata says MIT", lic == "MIT",
          "the registry says %r" % (lic,))
except Exception as e:  # noqa: BLE001
    skip("the published registry metadata says MIT",
         "%s: %s" % (type(e).__name__, e))

print()
print("checks run: %d, checks failed: %d, skipped: %d"
      % (NCHECK, len(FAILS), len(SKIPPED)))
for f in FAILS:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))
sys.exit(1 if FAILS else 0)
