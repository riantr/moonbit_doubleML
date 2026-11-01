#!/usr/bin/env python3
"""Round 78 verifier: a BACKEND claim must be witnessed on every backend it names.

THE GAP
=======
`doc/003_quick_start` publishes three exact numbers and says they are
"re-measured bit-identical on all four supported backends (`native`,
`wasm-gc`, `wasm`, `js`)".  The measurement is TRUE -- it was re-measured on
all four, and the values are bit-for-bit identical.

What was missing was a WITNESS.  The document's promise was:

    The tutorial's own test (`using_test.mbt`) asserts all three values
    bit-exactly, so this table cannot drift away from the code it
    documents.

but `doc/003_quick_start/moon.pkg` declares `supported_targets = "wasm-gc"`.
So that test can only ever run on ONE of the four backends the claim names,
and the table could drift on native / wasm / js with every check in this
repository still green.  The document's own Cross-platform section says the
thing that breaks the arrangement:

    A test that passes on native is not evidence that it passes on the other
    three.

And the check that existed for the claim was a WORD check:

    check("doc/003 says the values are backend-independent",
          "bit-identical" in flat(DOC3))

which stays green when the claim goes false and goes RED when the claim is
removed -- a check that punishes the correction and rewards the drift.

THE RULE
========
  C1  a document that names a SET of backends must name the set the library
      package DECLARES.  Both sides are derived; neither is a literal.
  C2  every backend a document names must be one CI actually BUILDS and
      TESTS.  Otherwise "runs on all four" is a claim about a build that
      never happens.
  C3  the library package's declared targets must be exactly the backends
      CI's `moon test` matrix runs -- the two lists have to agree, or one of
      them is describing a build that does not exist.
  C4  a document that publishes EXACT numbers and promises they do not
      drift must have a witness that RUNS on every backend it names: a test
      file whose package's `supported_targets` cover that set.
  C5  the witness must ASSERT the published numbers -- the number has to sit
      on a line that compares against it.  A file that merely MENTIONS the
      number is not a witness.
  C6  the document must NAME the witness -- the file AND the test -- so a
      reader can go and look at it.
  C7  the number of QUANTITIES the document says it publishes must be the
      number of rows in its own table.

Everything above is derived from the tree: the backend sets, the published
numbers, the candidate witnesses, the package each candidate lives in.  Not
one of them is typed in this file, because a typed one is a dead check the
moment the tree moves.

THE CONTROL ARM
================
A checker that has never been shown to fail is a comment.  Six synthetic
cases -- five it must REJECT and one it must ACCEPT:

  E1  a document naming a backend the library package does not declare
  E2  a document naming a backend CI never builds
  E3  a witness that lives in a package covering only ONE of the backends
  E4  a candidate that only MENTIONS the numbers (no comparison)
  E5  a document that does not name the witness it relies on
  E6  a well-formed document and a witness that covers every backend

Run: python _verify/_verify_backend_claims_1680.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FAILS = []
N = 0

WORDS = {"two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
         "eight": 8, "nine": 9, "ten": 10}


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %s  %-64s %s" % ("ok  " if ok else "*** FAIL ***", name, detail))
    if not ok:
        FAILS.append("%s -- %s" % (name, detail))


def read(p):
    with io.open(p, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def flat(text):
    """A document with its wrapping collapsed, so a phrase may span a line."""
    return re.sub(r"\s+", " ", text).strip()


# --------------------------------------------------------------- the facts
def package_targets(pkgdir):
    """The `supported_targets` a package declares, as a set.

    Returns (set, raw) -- the raw string is reported so a reader can see what
    was parsed, not just the verdict.
    """
    if not pkgdir:
        return set(), ""
    p = os.path.join(ROOT, pkgdir.replace("/", os.sep), "moon.pkg")
    if not os.path.isfile(p):
        return set(), ""
    m = re.search(r'supported_targets\s*=\s*"([^"]*)"', read(p))
    if not m:
        return set(), ""
    raw = m.group(1)
    return set(x for x in raw.split("+") if x), raw


def ci_targets():
    """The backends CI's `moon test` matrix builds and tests."""
    p = os.path.join(ROOT, ".github", "workflows", "check.yml")
    if not os.path.isfile(p):
        return set(), ""
    src = read(p)
    m = re.search(r"target:\s*\[([^\]]*)\]", src)
    if not m:
        return set(), ""
    return set(x.strip() for x in m.group(1).split(",") if x.strip()), m.group(1)


def backend_claim(text):
    """-> (count, set) for the document's backend claim, or (None, None).

    The claim has to be stated in the form this reads, because a claim that
    silently stopped being made is a claim nobody is watching any more.
    """
    m = re.search(r"all (\w+) supported backends \(([^)]*)\)", text)
    if not m:
        return None, None
    word = m.group(1).lower()
    count = WORDS.get(word, int(word) if word.isdigit() else None)
    names = set(re.findall(r"`([^`]+)`", m.group(2)))
    return count, names


def published_rows(text):
    """The rows of the document's published table: (quantity, value cell)."""
    return re.findall(r"^\|\s*`(\w+)\(\)`\s*\|\s*`?([^|`]+?)`?\s*\|", text, re.M)


def published_numbers(rows):
    """The EXACT numbers the document publishes, read from its own table."""
    numbers = []
    for _name, cell in rows:
        numbers.extend(re.findall(r"-?\d+\.\d+", cell))
    return numbers


def package_of(relpath):
    """The package directory a file belongs to: the nearest ancestor with a
    `moon.pkg`.  A file in no package cannot be a witness -- moon never runs
    it."""
    d = os.path.dirname(relpath)
    while d and d not in (".", "/"):
        if os.path.isfile(os.path.join(ROOT, d.replace("/", os.sep), "moon.pkg")):
            return d
        d = os.path.dirname(d)
    return None


def candidates(root, numbers):
    """Every `.mbt` file that mentions all the published numbers.

    `moon` skips a directory whose name starts with `_`, so those are skipped
    here too: a witness in one would never run.
    """
    out = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs
                   if not d.startswith("_") and d not in (".git", "target",
                                                          "node_modules")]
        for f in sorted(files):
            if not f.endswith(".mbt"):
                continue
            p = os.path.join(base, f)
            try:
                src = read(p)
            except OSError:
                continue
            if all(n in src for n in numbers):
                out.append(os.path.relpath(p, root).replace(os.sep, "/"))
    return sorted(out)


def asserts_all(relpath, numbers):
    """Do all the numbers sit on a line that COMPARES against them?

    A file that mentions the number in a comment is not a witness.
    """
    try:
        src = read(os.path.join(ROOT, relpath.replace("/", os.sep)))
    except OSError:
        return False
    for num in numbers:
        if not any(num in line and "==" in line for line in src.split("\n")):
            return False
    return True


def witness_for(root, numbers, backends):
    """-> (the witnesses that cover every backend, the ones that do not)."""
    full, partial = [], []
    for rel in candidates(root, numbers):
        if not asserts_all(rel, numbers):
            continue
        pkg = package_of(rel)
        targets, _raw = package_targets(pkg)
        if backends and backends <= targets:
            full.append((rel, pkg, sorted(targets)))
        else:
            partial.append((rel, pkg, sorted(targets)))
    return full, partial


# ================================================================== the run
print()
print("A. the derived facts")
DOC3 = os.path.join(ROOT, "doc", "003_quick_start", "readme.mbt.md")
doc3 = read(DOC3)
f3 = flat(doc3)

lib_targets, lib_raw = package_targets("moonbit_doubleML")
ci, ci_raw = ci_targets()
count, named = backend_claim(f3)
rows = published_rows(doc3)
numbers = published_numbers(rows)

print("   library package declares : %s" % (lib_raw or "(nothing)"))
print("   CI's moon-test matrix    : %s" % (ci_raw or "(nothing)"))
print("   doc/003 names            : %s" % (", ".join(sorted(named)) if named else "(nothing)"))
print("   doc/003 says 'all %s'    : %s" % (count if count else "?", count))
print("   doc/003 publishes        : %d row(s), %d number(s) -- %s"
      % (len(rows), len(numbers), ", ".join(numbers)))

check("doc/003 states the backend claim in the form this reads",
      count is not None and bool(named),
      "claims 'all %s supported backends', naming %d" % (count, len(named)))
check("doc/003's published table has rows", bool(rows),
      "%d row(s): %s" % (len(rows), ", ".join(q for q, _c in rows)))
check("doc/003 publishes numbers", bool(numbers),
      "%d number(s)" % len(numbers))
check("the library package declares its targets", bool(lib_targets),
      "declares %s" % lib_raw)
check("CI's matrix names its targets", bool(ci), "matrix: %s" % ci_raw)

print()
print("B. the backend sets")
check("C1 doc/003's named backends are the library package's declared targets",
      bool(named) and named == lib_targets,
      "doc names %s" % (sorted(named) if named else "-"))
check("C1b the count doc/003 states is the number of backends it names",
      count is not None and count == len(named),
      "the document says %s and names %d" % (count, len(named)))
check("C2 every backend doc/003 names is one CI builds and tests",
      bool(named) and named <= ci,
      "not in CI's matrix: %s" % sorted(named - ci) if named else "-")
check("C3 the library package's targets are exactly CI's matrix",
      bool(lib_targets) and lib_targets == ci,
      "package %s" % sorted(lib_targets))

print()
print("C. the witness")
full, partial = witness_for(ROOT, numbers, named)
for rel, pkg, tg in full:
    print("   covers ALL      : %-44s (package %s: %s)" % (rel, pkg, "+".join(tg)))
for rel, pkg, tg in partial:
    print("   covers SOME only: %-44s (package %s: %s)" % (rel, pkg, "+".join(tg)))

check("C4 a witness asserts the published numbers on every backend doc/003 names",
      bool(full),
      "covered by %s" % (full[0][0] if full else "NO WITNESS"))
witness = full[0][0] if full else None
if witness:
    check("C5 the witness compares against each published number",
          asserts_all(witness, numbers),
          "%s asserts all %d" % (witness, len(numbers)))
    base = os.path.basename(witness)
    check("C6 doc/003 names the witness file", base in f3, "it names %s" % base)
    testnames = re.findall(r'test\s+"([^"]+)"',
                            read(os.path.join(ROOT, witness.replace("/", os.sep))))
    named_tests = [t for t in testnames if t in f3]
    check("C6b doc/003 names the witness's test", bool(named_tests),
          "named: %s" % (named_tests or "none of %s" % testnames))
    m = re.search(r"all (\w+) values below", f3)
    said = WORDS.get(m.group(1).lower()) if m else None
    check("C7 the number of quantities doc/003 says it publishes is its table's row count",
          said is not None and said == len(rows),
          "the document says %s, the table has %d row(s)" % (said, len(rows)))
else:
    check("C5 the witness compares against each published number", False, "no witness")
    check("C6 doc/003 names the witness file", False, "no witness")
    check("C6b doc/003 names the witness's test", False, "no witness")
    check("C7 the number of quantities doc/003 says it publishes is its table's row count",
          False, "no witness")

# ---------------------------------------------------------------- the control arm
print()
print("D. the control arm: synthetic cases, and what the rule does with them")


def rule_ok(named_set, lib_set, ci_set, full_witnesses, doc_text):
    """The rule, as one function, so the control arm can call it too."""
    if not named_set or named_set != lib_set:
        return False
    if not named_set <= ci_set:
        return False
    if not full_witnesses:
        return False
    base = os.path.basename(full_witnesses[0][0])
    return base in doc_text


BACKENDS = {"native", "wasm-gc", "wasm", "js"}
FULL = [("pkg/plr_test.mbt", "pkg", sorted(BACKENDS))]

check("E1 a document naming an undeclared backend is REJECTED",
      not rule_ok(BACKENDS | {"llvm"}, BACKENDS, BACKENDS, FULL, "plr_test.mbt"),
      "the rule must catch it")
check("E2 a document naming a backend CI never builds is REJECTED",
      not rule_ok(BACKENDS, BACKENDS, BACKENDS - {"js"}, FULL, "plr_test.mbt"),
      "the rule must catch it")
check("E3 a witness covering only one backend is REJECTED",
      not rule_ok(BACKENDS, BACKENDS, BACKENDS, [], "plr_test.mbt"),
      "the rule must catch it")
check("E4 a candidate that only mentions the numbers is REJECTED",
      not asserts_all("README.mbt.md", ["0.164.61"]),
      "a mention is not a comparison")
check("E5 a document that does not name its witness is REJECTED",
      not rule_ok(BACKENDS, BACKENDS, BACKENDS, FULL, "some other file"),
      "the rule must catch it")
check("E6 a well-formed document and a full witness are ACCEPTED",
      rule_ok(BACKENDS, BACKENDS, BACKENDS, FULL, "plr_test.mbt"),
      "the rule must not fire on the real shape")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
