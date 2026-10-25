#!/usr/bin/env python3
"""Round 43 verifier: EVERY licence file in the tree, not just two of them.

WHAT THIS EXISTS FOR
=====================
Round 42 rewrote the licence TEXTS.  It rewrote two of them -- the root
`LICENSE` and `examples/api_server/LICENSE` -- and the v0.164.36 CHANGELOG
entry announced the class closed:

    "Both LICENSE files now carry MIT -- the same wording, and the same
     copyright line, as the author's other project -- and every manifest
     declares it."

The tree has SEVENTEEN tracked LICENSE files, and FIFTEEN of them still
carried the stock Apache-2.0 text -- each one sitting beside a `moon.mod`
that declared `license = "MIT"`.  Six package directories shipped no LICENSE
at all.  A reader who cloned an example was handed Apache-2.0 while the
manifest, the README and the registry all said MIT.

The check that was supposed to own this class could not see it: round 42's
`_verify_license_1650.py` reads `LICENSE` and `examples/api_server/LICENSE`
and nothing else.  It was written to match the fix that had been made, not
to match the class of defect.  A check that cannot fail is not a check.

THE RULE
========
One sentence, and every check below is an aggregate over the tree:

    Every LICENSE file in the tree is byte-identical to the root MIT text,
    and every package directory that has a manifest is covered by one.

"Covered by" means a LICENSE beside the manifest, or -- for the library
package `moonbit_doubleML/`, whose manifest sits one directory below the
repository root -- the repository root's LICENSE.

THE COUNT IS FIXED AT 5
======================
Every check here is an AGGREGATE over the tree, so adding a LICENSE file or
a package directory does not move the published number, and no check depends
on the network.  (The round-41 precedent: a published count must be fixed
against the ENVIRONMENT, not only against the tree.)

Run: python _verify/_verify_license_files_1650.py
"""
import hashlib
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-62s %s" % ("ok" if ok else "*** FAIL ***", label))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))
        print("      %s" % detail)


def git_ls(*patterns):
    out = subprocess.run(["git", "ls-files", "-z"] + list(patterns),
                         cwd=ROOT, capture_output=True)
    return [f for f in out.stdout.decode("utf-8", "replace").split("\0") if f]


def read_bytes(rel):
    """The file's bytes, or None if it is tracked but NOT on disk.

    A tracked LICENSE that has been deleted is a defect, not a crash: the
    checks below must say so rather than raising.
    """
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        return None
    return io.open(p, "rb").read()


def read_text(rel):
    b = read_bytes(rel)
    return "" if b is None else b.decode("utf-8", "replace")


MIT_MARK = "Permission is hereby granted, free of charge"
APACHE_MARK = "Apache License"

print()
print("A. every licence file in the tree")

root_lic = read_bytes("LICENSE")
licences = sorted(git_ls("*LICENSE"))

check("the tree has at least one LICENSE file", len(licences) > 0,
      "git ls-files '*LICENSE' returned nothing")

not_mit = [f for f in licences if MIT_MARK not in read_text(f)]
check("every tracked LICENSE file grants MIT", not not_mit,
      "%d file(s) do not: %s"
      % (len(not_mit), ", ".join(not_mit[:5])))

apache = [f for f in licences if APACHE_MARK in read_text(f)]
check("no tracked LICENSE file carries the Apache-2.0 text", not apache,
      "%d file(s) do: %s" % (len(apache), ", ".join(apache[:5])))

diff = [f for f in licences if read_bytes(f) != root_lic]
check("every tracked LICENSE file is byte-identical to the root LICENSE",
      not diff,
      "%d file(s) differ: %s"
      % (len(diff), ", ".join(diff[:5])))

no_copyright = [f for f in licences
                if not re.search(r"^Copyright \(c\) \d{4} .+$", read_text(f), re.M)]
check("every tracked LICENSE file carries a copyright line", not no_copyright,
      "%d file(s) do not: %s"
      % (len(no_copyright), ", ".join(no_copyright[:5])))

print()
print("B. every package directory is covered by a licence")

# The manifests a reader installs: the library, the doc project and the
# examples.  The manifests under `_verify/upstream_prove_1649/cases/` are TEST
# FIXTURES -- little packages that exercise the upstream-proof harness -- and
# a fixture correctly declares no licence of its own.
manifests = [m for m in git_ls("*moon.mod") if not m.startswith("_verify/")]
uncovered = []
for man in manifests:
    d = os.path.dirname(man)
    if d == "moonbit_doubleML":
        # the library package: the repository root's licence covers it
        covering = "LICENSE"
    else:
        covering = (d + "/LICENSE") if d else "LICENSE"
    if covering not in licences:
        uncovered.append("%s -> %s" % (man, covering))
check("every tracked package is covered by a LICENSE file", not uncovered,
      "%d package(s) are not: %s" % (len(uncovered), "; ".join(uncovered[:5])))

print()
print("the tree's licence files")
for f in licences:
    b = read_bytes(f)
    if b is None:
        print("  %-44s  *** MISSING FROM THE TREE ***" % f)
        continue
    print("  %-44s %5d bytes  sha256 %s"
          % (f, len(b), hashlib.sha256(b).hexdigest()[:12]))

print()
print("checks run: %d, checks failed: %d" % (NCHECK, len(FAILS)))
for f in FAILS:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))
sys.exit(1 if FAILS else 0)
