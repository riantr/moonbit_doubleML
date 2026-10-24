"""Bump the release version in every place that names it, byte-precisely.

Every place the version lives, per the convention documented in
examples/api_server/main.mbt:
  1. moonbit_doubleML/moon.mod            version = "X"
  2. README.mbt.md   (edited copy)        status table + project layout + --release-tag example
  3. moonbit_doubleML/README.mbt.md       (shipped copy, must stay byte-identical to 2)
  4. examples/api_server/main.mbt         library: "riantr/moonbit_doubleML@X"
  5. doc/001_introduction/readme.mbt.md   "Status at vX" + "published as ...@X"
  6. doc/002_installation/readme.mbt.md   the pinned import "riantr/moonbit_doubleML@X"
  7. examples/api_server/README.md        the /version response sample
  8. examples/<name>/moon.mod  (21 of them)  the pinned import "riantr/moonbit_doubleML@X"
  9. skills/moonbit_doubleML.md  the agent skill's quoted api_server pin
 10. doc/moon.mod  the doc project's own library pin

Places 2 and 3 are not text-replaced: round 18 moved the README into
`_verify/_r18_build_readme_1650.py`, which takes the version from
`moonbit_doubleML/moon.mod` and writes both copies byte-identically.  So the
EDITS table below holds every place except those two, and the list above is
the whole set.

Sites 5 and 6 were added in v0.164.3 (round 8): the two tutorials named the
version, and had been left at 0.52.0 for many releases. A version that a
document names but the bump script does not update is a version that goes
stale -- which is exactly how those two tutorials ended up frozen.

Site 7 was added in v0.164.4 (round 9): the api_server README quotes a
measured `GET /version` response, and the library field of that response
is the version under release. A quoted output that goes stale is worse
than no quoted output, so the sample is bumped with the rest.

Site 8 was added in v0.164.25 (round 31): EVERY example manifest named the
library version, and every one of them had been left behind -- 19 at 0.52.0
and 2 at 0.162.0, against a package at 0.164.24.  A version that a file
names but the bump script does not update is a version that goes stale, and
an example's pin is a promise about what a reader who copies the example out
of the tree will install.

Site 9 was added in v0.164.33 (round 39): the AGENT SKILL quotes the
api_server's declared library pin, and it was still at 0.52.0 -- the same
rot sites 5 and 6 had, in the same shape, missed for 132 releases because
the skill is a DOCUMENT and no check read it.  The skill is a user-facing
surface: it is what a coding agent reads before writing code against this
library, so a stale literal in it is a promise the tree cannot keep.  The
skill is now audited by `_verify/_verify_skill_claims_1650.py`, and its
pin is bumped with the rest.

Site 10 was added in v0.164.34 (round 40): the DOC PROJECT's own manifest,
`doc/moon.mod`, named the library at 0.52.0 -- the LAST file in the tree
still carrying that pin, and the same rot sites 5, 6 and 9 had.  It was
missed by rounds 31 and 39 because both of those read the EXAMPLE manifests
and the SKILL: `doc/moon.mod` is a third kind of file, and the round-31
stale-literal scan covers the version SITES only -- the files this script
owns.  The doc project is a member of `moon.work`, so in-tree the pin is
INERT (the workspace member wins) and the examples build against the current
library while the manifest names a version from 159 releases ago; outside
the tree it is the only thing that decides what gets installed.  It is now
bump site 10, so it moves with the release.

The `--release-tag v0.164.11` example used to live in the README's CI
section; round 18 moved the CI section to `ENGINEERING.md`, which is the
HISTORICAL document and must keep the version it was written with.

LF-only, no BOM, in and out. Reports every replacement it made so an
unmatched site is visible rather than silent.
"""
import io, os, shutil, subprocess, sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLD, NEW = sys.argv[1], sys.argv[2]

EDITS = [
    (os.path.join(ROOT, "moonbit_doubleML", "moon.mod"),
     [('version = "%s"' % OLD, 'version = "%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "api_server", "main.mbt"),
     [('library: "riantr/moonbit_doubleML@%s"' % OLD,
       'library: "riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "doc", "001_introduction", "readme.mbt.md"),
     [("## Status at v%s" % OLD, "## Status at v%s" % NEW),
      ("riantr/moonbit_doubleML@%s" % OLD, "riantr/moonbit_doubleML@%s" % NEW)]),
    (os.path.join(ROOT, "doc", "002_installation", "readme.mbt.md"),
     [("riantr/moonbit_doubleML@%s" % OLD, "riantr/moonbit_doubleML@%s" % NEW)]),
    (os.path.join(ROOT, "examples", "api_server", "README.md"),
     [("riantr/moonbit_doubleML@%s" % OLD, "riantr/moonbit_doubleML@%s" % NEW)]),
    # The AGENT SKILL quotes the api_server's declared library pin.  It is a
    # document a coding agent reads before writing code against this library,
    # so a literal in it is a promise the tree has to keep -- and it had been
    # frozen at 0.52.0 because nothing read it.  Site 9, round 39.
    (os.path.join(ROOT, "skills", "moonbit_doubleML.md"),
     [("riantr/moonbit_doubleML@%s" % OLD, "riantr/moonbit_doubleML@%s" % NEW)]),
    # the DOC PROJECT's own manifest.  It names the library version the six
    # tutorials were written against, and it was the last file in the tree
    # still carrying 0.52.0.  In-tree the pin is inert -- the project is a
    # member of `moon.work`, so the workspace member wins -- and outside the
    # tree it is the only thing that decides what gets installed.  Site 10,
    # round 40.
    (os.path.join(ROOT, "doc", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    # the EXAMPLE manifests: an example's import pin names the library
    # version, and a copied example must resolve the library it was
    # written against -- not the version it happened to be created at.
    (os.path.join(ROOT, "examples", "api_server", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "apo", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "apos", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "bitexact", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "cluster", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "consumer_demo", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "cvar", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "datasets", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "did_binary", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "did_cross_section", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "did_cs", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "did_cs_binary", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "did_multi", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "fuzz", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "lplr", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "main", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "parity", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "pava", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "plpr", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "splitting", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
    (os.path.join(ROOT, "examples", "ssm", "moon.mod"),
     [('"riantr/moonbit_doubleML@%s"' % OLD,
       '"riantr/moonbit_doubleML@%s"' % NEW)]),
]

total = 0
for path, pairs in EDITS:
    raw = io.open(path, encoding="utf-8", newline="").read()
    for old, new in pairs:
        n = raw.count(old)
        if n != 1:
            print("!! %s : %r matched %d times (expected 1) -- ABORT"
                  % (os.path.relpath(path, ROOT), old, n))
            sys.exit(1)
        raw = raw.replace(old, new)
        total += 1
        print("   %-28s %s" % (os.path.basename(path), old[:52]))
    io.open(path, "w", encoding="utf-8", newline="").write(raw)

# The README is generated, not text-replaced: the builder reads the version
# from the `moon.mod` this script has just bumped.
print()
print("   regenerating the README from moon.mod ...")
r = subprocess.run([sys.executable,
                    os.path.join(ROOT, "_verify", "_r18_build_readme_1650.py")],
                   cwd=ROOT, capture_output=True, text=True,
                   encoding="utf-8", errors="replace")
print(r.stdout or "", end="")
if r.returncode != 0:
    print(r.stderr)
    sys.exit("the README builder failed: %d" % r.returncode)

src = os.path.join(ROOT, "README.mbt.md")
dst = os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")

a = io.open(src, "rb").read()
b = io.open(dst, "rb").read()
print()
print("readme edited=%d  shipped=%d  identical=%s  CR=%d  BOM=%s"
      % (len(a), len(b), a == b, a.count(b"\r"), a[:3] == b"\xef\xbb\xbf"))
print("replacements: %d" % total)

# the README's version sites must now carry the new version
txt = a.decode("utf-8")
if ("riantr/moonbit_doubleML@%s" % NEW) not in txt:
    print("!! the README does not name the new version -- ABORT")
    sys.exit(1)
if ("| `moon.mod` version | **%s** |" % NEW) not in txt:
    print("!! the README's Status table does not name the new version -- ABORT")
    sys.exit(1)
