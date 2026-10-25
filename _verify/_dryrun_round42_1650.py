"""Dry-run the round-42 checks against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 42 gave four promise classes an owner and a fifth one a new owner:

  _verify/_verify_license_1650.py        the LICENCE the tree claims and
                                         the licence it grants
  _verify/_verify_file_line_refs_1650.py the in-repo `file:line` pointers
  _verify/_verify_doc_claims_1650.py     the api_server's routing
                                         instruction, the introduction's
                                         example size, the source comment's
                                         own wasm recipe
  _verify/_verify_package_claims_1650.py the "Used By" section's pins
  _verify/_verify_layout_1680.py         the repository's own line endings

A check that cannot fail is not a check, so each mechanism here breaks ONE
promise in the tree and the failure count must GROW at every step.

THE MECHANISMS
===============
  1. the root LICENSE goes back to the Apache-2.0 text;
  2. a manifest declares Apache-2.0 again;
  3. a `file:line` pointer names a file that is not in the tree;
  4. a `file:line` pointer names a line past the end of its file;
  5. the api_server README drops the `/ping` exception;
  6. the introduction's example size goes stale;
  7. the "Used By" section regains another project's version literal;
  8. the repository's `.gitattributes` goes away.

THEY CANNOT ALL BE BROKEN BY THE SAME MUTATION
===============================================
A mutation of the LICENCE moves the count that the licence check reads; a
mutation of the README moves the count that the doc-claims and
package-claims checks read; a mutation of a pointer moves the count the
file-line check reads.  Each class is proved separately, because a class
proved by one mechanism is a class with one mechanism.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round CHANGED are copied in from the INDEX -- the index is what
the release will commit -- so the tree under test is exactly the tree that
carries the checks being exercised.

Run: python _verify/_dryrun_round42_1650.py
"""
import io
import os
import re
import shutil
import stat
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMIT = "HEAD"
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r42")
VERIFIERS = [
    "_verify/_verify_license_1650.py",
    "_verify/_verify_file_line_refs_1650.py",
    "_verify/_verify_doc_claims_1650.py",
    "_verify/_verify_package_claims_1650.py",
    "_verify/_verify_layout_1680.py",
]


def run(cmd, cwd=REPO, timeout=1800):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def read(path):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", errors="replace", newline="") as fh:
        fh.write(text)


def sub_once(path, pattern, repl):
    """Replace the regex `pattern` with `repl`, exactly once.

    A REGEX, not a literal: the mechanisms must patch the text as it NOW
    STANDS, and the numbers in these files move with every release.  A
    literal here would be a literal that goes stale.
    """
    text = read(path)
    crlf = "\r\n" in text
    pat = pattern.replace("\n", "\r\n") if crlf and "\r\n" not in pattern else pattern
    rep = repl.replace("\n", "\r\n") if crlf and "\r\n" not in repl else repl
    n = len(re.findall(pat, text))
    if n != 1:
        raise SystemExit("!! %s: %r matched %d times (expected 1)"
                         % (path, pattern, n))
    write(path, re.sub(pat, rep, text))


def commit(work, paths, message):
    rc, out = run(["git", "-C", work, "add", "--"] + paths, cwd=work)
    if rc != 0:
        raise SystemExit("!! git add failed: %s" % out.strip()[:300])
    rc, out = run(["git", "-C", work, "-c", "user.name=dry-run",
                   "-c", "user.email=dry-run@example.invalid",
                   "commit", "-m", message], cwd=work)
    if rc != 0:
        if "nothing to commit" in out or "nothing added to commit" in out:
            return "(already in the tree)"
        raise SystemExit("!! git commit failed: %s" % out.strip()[:300])
    return out.strip().splitlines()[0] if out.strip() else ""


def verify(work):
    """Run the verifiers in `work`.

    Returns (exit code, output, failure count, per-verifier failure lists).

    WHAT IS COUNTED
    ===============
    A failing CHECK.  The marker `*** FAIL ***` goes on each failing check
    line; a line whose WHOLE content is the marker is a section HEADER some
    verifiers print after their counter, and a header is not a check, so it
    is excluded.

    The count is by CONTAINMENT, not by prefix or by suffix: the verifier
    families print the marker in different positions -- at the front, at
    the back, in the middle -- and a rule that matched only one position
    would under-count the failures of the others.
    """
    total = 0
    by_verifier = []
    chunks = []
    rc = 0
    for rel in VERIFIERS:
        r, out = run([sys.executable, os.path.join(work, rel)], cwd=work,
                     timeout=3600)
        rc = rc or r
        chunks.append(out)
        lines = []
        for l in out.splitlines():
            if "*** FAIL ***" in l and l.strip() != "*** FAIL ***":
                lines.append(l.strip())
        by_verifier.append(lines)
        total += len(lines)
    return rc, "\n".join(chunks), total, by_verifier


def summaries_of(out):
    """The verifiers' own failure counts, in either summary convention.

    Two conventions are in the contract: the `N checks, M failed` form and
    the `checks failed: M` form.  A rule that read only one of them would
    under-count the failures of the other family.
    """
    found = re.findall(r"(\d+) checks,\s*(\d+) failed", out)
    found += [(None, m.group(1)) for m in re.finditer(r"checks failed:\s*(\d+)", out)]
    return found


if os.path.isdir(WORK):
    try:
        shutil.rmtree(WORK)
    except PermissionError:
        for _root, _dirs, _files in os.walk(WORK):
            for _f in _files:
                try:
                    os.chmod(os.path.join(_root, _f), stat.S_IWRITE)
                except OSError:
                    pass
        shutil.rmtree(WORK)
os.makedirs(WORK, exist_ok=True)

print("=== cloning locally and checking out %s ===" % COMMIT)
rc, out = run(["git", "clone", "--local", "--shared", "--no-checkout", ".", WORK])
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "checkout", "--detach", COMMIT], cwd=WORK)
if rc != 0:
    print(out)
    sys.exit(1)
rc, out = run(["git", "rev-parse", "HEAD"], cwd=WORK)
print("  %s -> %s" % (COMMIT, out.strip()))

# --- copy the INDEX in: it is what the release will commit ------------------
rc, out = run(["git", "diff", "--cached", "--name-only"], cwd=REPO)
STAGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
COPY_IN = []
for rel in list(VERIFIERS) + STAGED:
    rel = rel.replace("\\", "/")
    if rel in COPY_IN:
        continue
    src = os.path.join(REPO, rel.replace("/", os.sep))
    if not os.path.isfile(src):
        continue
    dst = os.path.join(WORK, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    COPY_IN.append(rel)
print("  copied in %d files from the index" % len(COPY_IN))
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checks")

LIC = os.path.join(WORK, "LICENSE")
MANIFEST = os.path.join(WORK, "examples", "apo", "moon.mod")
README = os.path.join(WORK, "README.mbt.md")
API_README = os.path.join(WORK, "examples", "api_server", "README.md")
DOC1 = os.path.join(WORK, "doc", "001_introduction", "readme.mbt.md")
GATTR = os.path.join(WORK, ".gitattributes")

# ---------------------------------------------------------------- the baseline
print()
print("=== baseline: the tree as it stands ===")
rc0, out0, n0, by0 = verify(WORK)
print("  exit=%d  failures=%d" % (rc0, n0))
if rc0 != 0 or n0 != 0:
    print(out0)
    print("!! the baseline is not green -- the dry-run would prove nothing")
    sys.exit(1)

# ------------------------------------------------------------ the mechanisms
MECHANISMS = [
    ("the root LICENSE goes back to the Apache-2.0 text",
     lambda: (sub_once(LIC,
                        r"MIT License\n\nCopyright \(c\) 2026",
                        "Apache License\n\nCopyright 2026"),
              commit(WORK, ["LICENSE"],
                     "dry-run: the licence text went stale"))),

    ("a manifest declares Apache-2.0 again",
     lambda: (sub_once(MANIFEST,
                        r'license = "MIT"',
                        'license = "Apache-2.0"'),
              commit(WORK, [os.path.join("examples", "apo", "moon.mod")],
                     "dry-run: a manifest's licence went stale"))),

    ("a `file:line` pointer names a file that is not in the tree",
     lambda: (sub_once(README,
                        r"`did\.mbt:628`",
                        "`did_not_there.mbt:628`"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a pointer named a file that is not there"))),

    ("a `file:line` pointer names a line past the end of its file",
     lambda: (sub_once(README,
                        r"`cvar\.mbt:736`",
                        "`cvar.mbt:999999`"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: a pointer named a line past the end"))),

    ("the api_server README drops the `/ping` exception",
     lambda: (sub_once(API_README,
                        r"`/ping` is the one exception",
                        "`/ping` is not an exception"),
              commit(WORK, [os.path.join("examples", "api_server", "README.md")],
                     "dry-run: the routing instruction lost its exception"))),

    ("the introduction's example size goes stale",
     lambda: (sub_once(DOC1,
                        r"a 35-line end-to-end example",
                        "a 30-line end-to-end example"),
              commit(WORK, [os.path.join("doc", "001_introduction", "readme.mbt.md")],
                     "dry-run: the example size went stale"))),

    ("the Used By section regains another project's version literal",
     lambda: (sub_once(README,
                        r"PLR against `riantr/moonbit_doubleML`:",
                        "PLR against `riantr/moonbit_doubleML` v0.163.3 (its current pin):"),
              commit(WORK, ["README.mbt.md"],
                     "dry-run: the Used By section regained a stale pin"))),

    ("the repository's .gitattributes goes away",
     lambda: (os.remove(GATTR),
              commit(WORK, [".gitattributes"],
                     "dry-run: the repository stopped pinning its line endings"))),
]

prev = n0
prev_by = by0
print()
print("=== the mechanisms, one at a time ===")
for i, (desc, apply_it) in enumerate(MECHANISMS, 1):
    apply_it()
    rc, out, n, by = verify(WORK)
    grew = n > prev
    print("  %2d. %-58s failures %d -> %d  %s"
          % (i, desc[:58], prev, n, "GROW" if grew else "*** FLAT ***"))
    for vi, cur in enumerate(by):
        for l in cur:
            if l not in prev_by[vi]:
                print("        + %s" % l[:100])
    for vi in range(len(by)):
        if len(by[vi]) < len(prev_by[vi]):
            print("!! mechanism %d repaired a failure -- ABORT" % i)
            sys.exit(1)
    if not grew:
        print(out)
        print("!! mechanism %d contributed nothing -- ABORT" % i)
        sys.exit(1)
    prev = n
    prev_by = by

# the counter must agree with the verifiers' own summaries
rc, out, n, by = verify(WORK)
print()
print("=== the counter and the verifiers' own summaries ===")
print("  the driver counted %d failures" % n)
summaries = summaries_of(out)
print("  the verifiers say  %s"
      % (", ".join("%s/%s" % (c, f) for c, f in summaries) if summaries else "NONE"))
if not summaries or sum(int(f) for _c, f in summaries) != n:
    print("!! the counter and the summary disagree -- ABORT")
    sys.exit(1)
if rc == 0:
    print("!! the broken tree still exits 0 -- ABORT")
    sys.exit(1)

def published_count(text, driver):
    """The failure count the CHANGELOG publishes FOR THIS DRIVER.

    The lookup is SCOPED twice: to the ENTRY that names the driver, and
    within that entry to the BULLET that names it.  The CHANGELOG is in
    descending order, so the newest entry wins -- and a newest entry that
    publishes two drivers' counts must not bind one driver's number to the
    other's.  An entry that NAMES a driver without publishing a count for it
    is not a publication, so the search falls through to the older one.
    """
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                         text, re.M | re.S):
        body = m.group(2)
        if driver not in body:
            continue
        lines = body.split("\n")
        start = None
        for i, l in enumerate(lines):
            if driver in l:
                start = i
                break
        if start is None:
            continue
        head = start
        while head > 0 and not lines[head].startswith("- "):
            head -= 1
        tail = start + 1
        while tail < len(lines) and not lines[tail].startswith("- "):
            tail += 1
        # The sentence that carries the number is hard-WRAPPED, so the
        # phrase is matched against a whitespace-COLLAPSED bullet.  A
        # pattern with literal spaces matches only the entries that
        # happen to keep the phrase on ONE line -- and the driver then
        # reads an OLDER entry's number and calls it its own.
        flat = re.sub(r"\s+", " ", "\n".join(lines[head:tail]))
        found = re.findall(r"requires the failure count to GROW at every step: "
                           r"\*\*(\d+)\*\* failures at the", flat)
        if found:
            return int(found[0])
    return None

# --- the published failure count, witnessed -----------------------------------
_entry = None
for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                     read(os.path.join(REPO, "CHANGELOG.md")), re.M | re.S):
    if "_dryrun_round42_1650.py" in m.group(2):
        _entry = m.group(2)
        break
published = published_count(read(os.path.join(REPO, "CHANGELOG.md")), "_dryrun_round42_1650.py")
print()
print("=== the published failure count, witnessed ===")
if published is None:
    print("  the CHANGELOG publishes no failure count for this dry-run -- ABORT")
    print("  (this run measured %d -- put that number in the CHANGELOG)" % n)
    sys.exit(1)
print("  the CHANGELOG publishes %d; this run measured %d" % (published, n))
if published != n:
    print("!! the published failure count and the measured one disagree -- ABORT")
    sys.exit(1)
print("  OK -- the published number is the number this run measured")

# The SAME number, in the ENGINEERING banner.  The banner is the other place
# the count is published, and a number nothing checks is a number that rots
# silently.
#
# The count that belongs to THIS driver is the one in the passage that NAMES
# it -- NOT the last count in the banner.  The banner lists the rounds
# ASCENDING (oldest first), so a LATER round's entry carries its own count,
# and the last "ends at **N** failures" in the banner stops being this
# driver's the moment the next round publishes one of its own.
_eng = read(os.path.join(REPO, "ENGINEERING.md"))
_eng_banner = _eng.split("## The README as it stood at", 1)[0]
# The banner is ASCENDING, so the LIVE claim for this driver is its LAST
# mention -- and a mention that publishes no count is not a publication,
# so the search falls back to an earlier one.  The passage is read with
# the banner's quote prefix stripped and its whitespace collapsed: the
# sentence that carries the number is hard-WRAPPED, and the break is
# followed by the quote prefix, not by a space.
_me = None
_eng_found = []
for _hit in reversed([m.start() for m in
                       re.finditer(re.escape("_verify/_dryrun_round42_1650.py"), _eng_banner)]):
    _next = re.search(r"^> \* \*\*Round ", _eng_banner[_hit:], re.M)
    _passage = (_eng_banner[_hit:_hit + _next.start()] if _next
                else _eng_banner[_hit:])
    _flat = re.sub(r"\s+", " ", re.sub(r"(?m)^>[ \t]*", "", _passage))
    _eng_found = re.findall(r"ends at \*\*(\d+)\*\* failures", _flat)
    if _eng_found:
        _me = _hit
        break
if _me is None:
    print("  the ENGINEERING banner publishes no failure count for this "
          "driver -- ABORT")
    print("  (this run measured %d -- put that number in the banner)" % n)
    sys.exit(1)
print()
print("=== the same count in the ENGINEERING banner ===")
if not _eng_found:
    print("  the ENGINEERING banner publishes no failure count -- ABORT")
    print("  (this run measured %d -- put that number in the banner)" % n)
    sys.exit(1)
_eng_published = int(_eng_found[0])
print("  the banner publishes %d; this run measured %d" % (_eng_published, n))
if _eng_published != n:
    print("!! the banner's count and the measured one disagree -- ABORT")
    sys.exit(1)
if "NFAIL42" in _eng_banner:
    print("!! the banner still carries an unsubstituted placeholder -- ABORT")
    sys.exit(1)
print("  OK -- the banner's number is the number this run measured")

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
