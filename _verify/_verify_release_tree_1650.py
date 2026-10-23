#!/usr/bin/env python3
"""Round 34 verifier: the tree that is RELEASED must be the tree that was TESTED.

WHAT THIS EXISTS FOR
====================
Round 33 published v0.164.27 with `examples/api_server/moon.mod` pinning
`0.164.26` while the library was at `0.164.27` -- the exact defect round 31
was created to eliminate.  Nothing was wrong with the checks: the round-31
pin verifier READ THE WORKING TREE, and on disk the manifest was correct.
The COMMIT captured the INDEX, and the index still held round 32's blob,
because the `git add` list for that release was HAND-WRITTEN and had missed
the file.

So the tree that was tested and the tree that was released were DIFFERENT
TREES, and nothing in the release sequence noticed.

THE INVARIANT
=============
At a given ref, the tree must satisfy the version promises the working tree
satisfies:

  R1  the library's version is readable at the ref;
  R2  every example manifest at the ref pins THAT version -- an example's
      import pin names the library the example was written against, and a
      promise of an old version is a defect;
  R3  every other bump SITE at the ref carries that version and names no
      other library version.  The site set is DERIVED from the bump script's
      own `EDITS` table -- "every place the version lives" is a NAMED set,
      not a guess, and it is the same set the bump writes;
  R4  the two README copies at the ref are byte-identical -- the registry
      serves one file, so a README that differs from the repo by a byte is a
      different document;
  R5  the README at the ref names that version.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the manifests, from the tree at the ref;
  * the site set, from `_verify/_bump_1636.py`'s own EDITS table;
  * the version, from `moonbit_doubleML/moon.mod` at the ref.

The set sizes are declared and asserted, so a tree that gains or loses an
example cannot pass silently.

WHY THE REF MATTERS
===================
The default ref is HEAD -- the tree that was last committed, and therefore
the tree the registry was last given.  A release that commits a tree the
checks never saw fails here on the NEXT round, and the release procedure
runs this verifier against the new commit BEFORE the tag is made:

    git commit ...
    python _verify/_verify_release_tree_1650.py HEAD
    git tag -a vX.Y.Z ...

Run: python _verify/_verify_release_tree_1650.py [ref]
"""
import ast
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUMP = os.path.join(ROOT, "_verify", "_bump_1636.py")

REF = sys.argv[1] if len(sys.argv) > 1 else "HEAD"

# The declared set sizes.  A change to either is a change to the SET.
EXPECTED_MANIFESTS = 21
EXPECTED_SITES = 26
EXPECTED_OTHER_SITES = 5

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-56s %s" % (label, detail))
    else:
        FAILS.append(label)
        print("  *** FAIL ***  %-50s %s" % (label, detail))


def git(*args):
    p = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True,
                       text=True, encoding="utf-8", errors="replace",
                       timeout=180)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def read_at(path):
    """The file's text at the ref, or None when it is not there."""
    rc, out = git("show", "%s:%s" % (REF, path))
    if rc != 0:
        return None
    return out


def paths_at(pattern):
    rc, out = git("ls-tree", "-r", REF, "--name-only")
    if rc != 0:
        return []
    return [l for l in out.split("\n") if re.match(pattern, l)]


def bump_sites():
    """The site set, from the bump script's own EDITS table.

    The script is PARSED, not imported: importing it would RUN the bump.
    """
    with io.open(BUMP, encoding="utf-8") as fh:
        tree = ast.parse(fh.read())
    edits = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) == "EDITS" for t in node.targets):
            edits = node.value
            break
    if edits is None:
        raise SystemExit("!! the bump script has no EDITS table")
    sites = []
    for node in ast.walk(edits):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "join"):
            parts = []
            ok = True
            for a in node.args:
                if isinstance(a, ast.Constant) and isinstance(a.value, str):
                    parts.append(a.value)
                elif isinstance(a, ast.Name) and a.id == "ROOT":
                    continue
                else:
                    ok = False
                    break
            if ok and parts:
                sites.append("/".join(parts))
    return sorted(set(sites))


# the library's version literal, in the form it is written.  The version is
# three numbers, and nothing else: a greedy match would swallow the closing
# backtick of `riantr/moonbit_doubleML@0.164.27`.
LIBPIN = re.compile(r"riantr/moonbit_doubleML@(\d+\.\d+\.\d+)")
VERSION_FIELD = re.compile(r'version = "([^"]+)"')

print("=" * 78)
print("the release tree at %s" % REF)
print("=" * 78)

# ------------------------------------------------------------------- R1
lib_body = read_at("moonbit_doubleML/moon.mod")
version = None
if lib_body:
    m = VERSION_FIELD.search(lib_body)
    if m:
        version = m.group(1)
check("the library's version is readable at the ref", version is not None,
      version or "moonbit_doubleML/moon.mod carries no version field")

if version is None:
    print()
    print("%d checks, %d failed" % (NCHECK, len(FAILS)))
    sys.exit(1)

# ------------------------------------------------------------------- R2
manifests = paths_at(r"^examples/[^/]+/moon\.mod$")
check("the manifest set is the declared size",
      len(manifests) == EXPECTED_MANIFESTS,
      "found %d, declared %d" % (len(manifests), EXPECTED_MANIFESTS))

for p in manifests:
    body = read_at(p) or ""
    pins = LIBPIN.findall(body)
    ok = len(pins) == 1 and pins[0] == version
    if ok:
        detail = "pins %s" % pins[0]
    elif not pins:
        detail = "carries no library pin"
    else:
        detail = "pins %s, not %s" % (",".join(pins), version)
    check("the manifest %-34s pins the version" % p.replace("examples/", ""),
          ok, detail)

# ------------------------------------------------------------------- R3
sites = bump_sites()
check("the bump-site set is the declared size",
      len(sites) == EXPECTED_SITES,
      "found %d, declared %d" % (len(sites), EXPECTED_SITES))

# the sites R2 does not already cover: the manifests are covered above.
other = [p for p in sites if p not in manifests]
check("the other-site set is the declared size",
      len(other) == EXPECTED_OTHER_SITES,
      "found %d, declared %d" % (len(other), EXPECTED_OTHER_SITES))

for p in other:
    body = read_at(p)
    if body is None:
        check("the site %-40s carries the version" % p, False,
              "the file is not in the tree at %s" % REF)
        continue
    pins = LIBPIN.findall(body)
    stale = sorted({x for x in pins if x != version})
    carries = version in body
    ok = carries and not stale
    if not ok and stale:
        detail = "also names %s" % ",".join(stale)
    elif not ok:
        detail = "does not name %s at all" % version
    else:
        detail = "carries %s" % version
    check("the site %-40s carries the version" % p, ok, detail)

# ------------------------------------------------------------------- R4
r1 = read_at("README.mbt.md")
r2 = read_at("moonbit_doubleML/README.mbt.md")
if r1 is None or r2 is None:
    check("the two README copies are byte-identical", False,
          "a copy is missing from the tree at %s" % REF)
else:
    # `read_at` returns the DECODED text, so len() would count characters,
    # not bytes -- the README carries multi-byte characters and the number
    # would be short.  The blob's own size is the byte count.
    _rc, _sz = git("cat-file", "-s", "%s:README.mbt.md" % REF)
    check("the two README copies are byte-identical", r1 == r2,
          "both are %s bytes" % _sz.strip() if r1 == r2
          else "the edited copy and the shipped copy differ")

# ------------------------------------------------------------------- R5
readme = r1 or ""
_status = "| `moon.mod` version | **%s** |" % version
_install = '"riantr/moonbit_doubleML@%s"' % version
check("the README's status table names the version", _status in readme,
      "names %s" % version if _status in readme
      else "the status table does not name %s" % version)
check("the README's install block pins the version", _install in readme,
      "pins %s" % version if _install in readme
      else "the install block does not pin %s" % version)

# ------------------------------------------------------------------- R6
# The published check count, witnessed -- but only once the tree at the ref
# is the tree that published it.  A ref that predates this verifier has no
# count to compare against, and demanding one there would fail every tree
# that did not introduce it.
_chlog = read_at("CHANGELOG.md") or ""
_found = re.findall(r"_verify_release_tree_1650\.py` \(\*\*(\d+)\*\* checks\)",
                    _chlog)
if _found:
    published = int(_found[0])
    check("the published check count is the count this run made",
          published == NCHECK + 1,
          "published %d, this run makes %d" % (published, NCHECK + 1))
else:
    check("the published check count is the count this run made", True,
          "the tree at %s does not publish this verifier's count yet" % REF)

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
