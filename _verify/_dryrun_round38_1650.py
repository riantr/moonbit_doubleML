"""Dry-run the round-38 verifiers against a tree whose promises rot.

WHAT THIS PROVES
=================
Round 38 gave the README's claims about the PACKAGE a check, and gave the
count registry the ability to SEE a count it could not see.  A check that
cannot fail is not a check, so each mechanism here breaks ONE promise in
the tree and the failure count must GROW at every step.

The two verifiers under test:

  _verify/_verify_package_claims_1650.py   the README's claims about the
                                           package: a file it names, a
                                           capability it exports, a rule its
                                           manifest breaks, a measurement it
                                           quotes
  _verify/_verify_count_referents_1650.py  the count registry -- widened in
                                           this round to reach the counts
                                           written as DIGITS

THE MECHANISMS
===============
  1. the Project layout names the file that never existed again;
  2. the layout names another file that is not there;
  3. the README promises JSON in/out again;
  4. the library's source grows a JSON API;
  5. the dependency-rule bullet asserts the rule is met again;
  6. the QTE row names taus the CHANGELOG did not record;
  7. the QTE row presents the taus as a range again;
  8. the README states an unregistered count;
  9. the README states the wrong estimator count;
 10. the tree grows a 25th Python reference script.

THE MECHANISMS ARE CUMULATIVE
==============================
Each one breaks the tree the previous one left behind, so a mechanism that
patches a passage an earlier mechanism already rewrote must patch the
TEXT AS IT NOW STANDS.  That is not a detail: mechanism 7 breaks the QTE
row's taus as a RANGE, and mechanism 6 has already replaced those taus
with three wrong ones -- so 7 patches the three wrong ones, not the
originals.

WHAT IS COPIED IN
=================
The clone is checked out from HEAD, so it carries the committed tree.  The
files this round CHANGED are copied in from the WORKING TREE and committed,
so the tree under test is exactly the tree that carries the checks being
exercised.

Run: python _verify/_dryrun_round38_1650.py
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
WORK = os.path.join(REPO, "_verify", "_dryrun1650", "r38_pkg")
VERIFIERS = [
    "_verify/_verify_package_claims_1650.py",
    "_verify/_verify_count_referents_1650.py",
]
TOUCHED = [
    "README.mbt.md",
    os.path.join("moonbit_doubleML", "README.mbt.md"),
    "CHANGELOG.md",
    os.path.join("_verify", "_r18_build_readme_1650.py"),
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


def patch(path, old, new, count=1):
    """Replace `old` with `new`, keeping the file's own line endings."""
    text = read(path)
    crlf = "\r\n" in text
    old = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
    new = new.replace("\n", "\r\n") if crlf and "\r\n" not in new else new
    n = text.count(old)
    if n != count:
        raise SystemExit("!! %s: %r matched %d times (expected %d)"
                         % (path, old[:70], n, count))
    write(path, text.replace(old, new))


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

    Returns (exit code, output, failure count, failing labels).

    WHAT IS COUNTED
    ===============
    A failing CHECK.  The marker `*** FAIL ***` goes on each failing check
    line; a line whose WHOLE content is the marker is a section HEADER that
    two of the verifiers print after their counter, and a header is not a
    check, so it is excluded.

    The count is by CONTAINMENT, not by prefix or by suffix: the verifier
    families print the marker in different positions, and a rule that
    matched only one position would under-count the failures of the other.

    WHY THE EXCLUSION MATTERS
    =========================
    The count has to equal the number the verifiers report in their own
    `N checks, M failed` summaries, because that is the number the
    CHANGELOG publishes.  A driver that counted the bare header would be
    inflated by one per failing verifier, and would publish a number no
    verifier ever reported.  The cross-check at the end of this file is what
    makes the two agree.
    """
    total = 0
    by_verifier = []
    chunks = []
    rc = 0
    for rel in VERIFIERS:
        r, out = run([sys.executable, os.path.join(work, rel)], cwd=work,
                     timeout=1800)
        rc = rc or r
        chunks.append(out)
        lines = []
        for l in out.splitlines():
            if "*** FAIL ***" in l and l.strip() != "*** FAIL ***":
                lines.append(l.strip())
        by_verifier.append(lines)
        total += len(lines)
    return rc, "\n".join(chunks), total, by_verifier


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

# --- copy the working tree's state in -----------------------------------------
rc, out = run(["git", "diff", "--name-only", "HEAD", "--"], cwd=REPO)
CHANGED = [l.strip().replace("\\", "/") for l in out.splitlines() if l.strip()]
ADDED = ["_verify/_verify_package_claims_1650.py",
         "_verify/_dryrun_round38_1650.py"]
COPY_IN = []
for rel in list(VERIFIERS) + [t for t in TOUCHED if t not in VERIFIERS] \
        + CHANGED + ADDED:
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
print("  copied in %d files from the working tree" % len(COPY_IN))
commit(WORK, COPY_IN, "dry-run: the tree under test carries the checks")

R1 = os.path.join(WORK, "README.mbt.md")
R2 = os.path.join(WORK, "moonbit_doubleML", "README.mbt.md")
PKG = os.path.join(WORK, "moonbit_doubleML")
# The count registry derives the number of Python reference scripts from the
# files matching `validate_*_with_python.py`.  A file that does not match that
# pattern would leave the derived count untouched and the mechanism would
# contribute NOTHING -- so the probe is named to be counted.
VALIDATORS = os.path.join(WORK, "validate_extra_1650_with_python.py")


def patch_readmes(old, new):
    patch(R1, old, new)
    patch(R2, old, new)
    commit(WORK, ["README.mbt.md",
                  os.path.join("moonbit_doubleML", "README.mbt.md")],
           "dry-run: the README's claim moved")


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
    # -- 1. the layout names the file that never existed ----------------------
    ("the Project layout names the file that never existed again",
     lambda: (patch_readmes(
         "  moon.pkg              <- the package's imports and supported targets",
         "  moonbit_doubleML.mbt   <- main re-export file (the import surface)"),
              commit(WORK, ["README.mbt.md",
                            os.path.join("moonbit_doubleML", "README.mbt.md")],
                     "dry-run: the layout named a file that does not exist"))),

    # -- 2. the layout names another file that is not there -------------------
    ("the layout names another file that is not there",
     lambda: patch_readmes(
         "  vectorized.mbt         <- v0.81.0+ vectorised cross-fit helpers",
         "  helper.mbt             <- a file that was never written")),

    # -- 3. the README promises JSON in/out again ----------------------------
    ("the README promises JSON in/out again",
     lambda: patch_readmes(
         "The library exports\n"
         "  **no** JSON in/out -- the JSON surface is `examples/api_server/`'s\n"
         "  own request/response encoding.",
         "with optional JSON in/out for native /\n"
         "  wasm-gc / wasm / js backends (Serverless / Wasm / edge\n"
         "  deployments).")),

    # -- 4. the library's source grows a JSON API ----------------------------
    ("the library's source grows a JSON API",
     lambda: (write(os.path.join(PKG, "json_probe_1650.mbt"),
                     "pub fn DoubleMLPLR::to_json(self : DoubleMLPLR) -> String {\n"
                     "  \"{}\"\n"
                     "}\n"),
              commit(WORK, [os.path.join("moonbit_doubleML",
                                         "json_probe_1650.mbt")],
                     "dry-run: the library grew a JSON API"))),

    # -- 5. the dependency-rule bullet asserts the rule is met ----------------
    ("the dependency-rule bullet asserts the rule is met again",
     lambda: patch_readmes(
         "  packages -- **one declared line does not meet it today**\n"
         "  (`moonbit-community/sqlite3`, which nothing imports). The\n"
         "  library's runtime supply chain is still `moonbitlang/core`\n"
         "  only.",
         "  packages. Minimal supply-chain surface.")),

    # -- 6. the QTE row names taus the CHANGELOG did not record --------------
    ("the QTE row names taus the CHANGELOG did not record",
     lambda: patch_readmes(
         "at the three measured taus `0.50` / `0.75` / `0.90`",
         "at the three measured taus `0.10` / `0.25` / `0.50`")),

    # -- 7. the QTE row presents the taus as a range again --------------------
    # The tree is CUMULATIVE: mechanism 6 has already replaced the taus, so
    # this one patches the text as it now stands.
    ("the QTE row presents the taus as a range again",
     lambda: patch_readmes(
         "at the three measured taus `0.10` / `0.25` / `0.50`",
         "for tau `0.50`-`0.90`")),

    # -- 8. the README states an unregistered count --------------------------
    ("the README states an unregistered count",
     lambda: patch_readmes(
         "- ✅ **22 estimators** in 19 source files",
         "- ✅ **33 estimators** in 19 source files")),

    # -- 9. the README states the wrong estimator count ----------------------
    # Round 46: the census sentence was re-worded to the precise spelling, so
    # this mechanism must mutate the PHRASE THE READER NOW SEES.  A driver
    # that patches a phrase the document no longer carries writes nothing and
    # silently stops proving anything.
    ("the README states the wrong estimator count",
     lambda: patch_readmes(
         "22 `DoubleML*` estimator structs in 19 production files",
         "23 `DoubleML*` estimator structs in 19 production files")),

    # -- 10. the tree grows a 25th Python reference script -------------------
    ("the tree grows a 25th Python reference script",
     lambda: (write(VALIDATORS, "#!/?usr/bin/env python3\n"
                                "print('probe')\n"),
              commit(WORK, ["validate_extra_1650_with_python.py"],
                     "dry-run: the tree grew a validator"))),
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
    # A mechanism must not REPAIR an earlier mechanism's failure -- that would
    # MASK it.  The guard compares COUNTS per verifier, not line identities:
    # one check can fail with a DIFFERENT DETAIL (the aggregate unregistered
    # count reports the phrase it found, so a new phrase changes its payload
    # while the check itself is still failing), and a line-identity comparison
    # would read that as a repair.
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
summaries = re.findall(r"(\d+) checks, (\d+) failed", out)
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
    if "_dryrun_round38_1650.py" in m.group(2):
        _entry = m.group(2)
        break
published = published_count(read(os.path.join(REPO, "CHANGELOG.md")), "_dryrun_round38_1650.py")
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

print()
print("OK: every mechanism contributed, and the counter agrees with the summary")
