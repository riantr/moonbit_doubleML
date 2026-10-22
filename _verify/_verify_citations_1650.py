#!/usr/bin/env python3
"""Round 30 verifier: the `file:line` CITATIONS in the tracked prose.

WHY THIS EXISTS
===============
Rounds 21-29 audited the README, the tutorials, the `score` argument and the
public API docstrings.  This one audits the LAST un-audited prose surface: the
`file:line` citations that the tracked prose uses to point at a source line.

A line citation is a PROMISE.  It says: the thing this sentence names is AT
that line.  Nothing keeps that promise.  The port's `.mbt` files are edited
every release, so a citation written for one release points at whatever
happened to be on that line in the next one -- and the sentence still reads
perfectly, because the sentence was never re-read.

FOUR OF THEM HAD ALREADY BROKEN
================================
  * `did_binary.mbt:445` -- cited for the FOUR-ROW dummy inner model.  Line
    445 is now a `catch` arm; the dummy is built at 439-441.
  * `lplr.mbt:1630` -- cited for `set_sample_splitting`.  Line 1630 is now a
    prediction assignment; `set_sample_splitting` is at 2022.
  * `lplr.mbt:758` -- cited for the `kfold` draw.  Line 758 is now a loop
    header; the draw is at 781.
  * `did_cs.mbt:1263` -- cited for the panic on a 3-row stub.  Line 1263 is
    now an unrelated `require`; the panic site is `did.mbt:276`.

THE INVARIANT
=============
A citation must point at a line that MENTIONS the thing the sentence names.
The check is deliberately mechanical:

  1. the cited file must exist in this repo;
  2. the cited line must be within the file;
  3. the cited line must contain the LONGEST IDENTIFIER the sentence names.

Point 3 uses the longest identifier rather than the whole quoted string,
because the prose is allowed to write the maths (`nu2 = mean(2 * m_alpha -
rr^2)`) where the code writes numpy (`np.multiply(2.0, m_alpha) -
np.square(rr)`).  The identifier is what both spellings share, and it is what
makes the citation rot when the code moves away.

HOW THE ANCHOR IS FOUND
========================
The prose is read in PARAGRAPHS, not lines, so a claim whose quote and whose
citation sit on adjacent wrapped lines still binds.  Within the paragraph the
anchor is the first of:

  1. the nearest backticked CODE token before the citation;
  2. the nearest backticked CODE token after it;
  3. the first plain-text chunk after it -- the table style, where a comment
     lays out `file:line   the code at that line`.

A backticked token that names a FILE is not code and is skipped: `plr.mbt:107`
is a pointer, not an identifier.  When no anchor can be found the citation is
UNCHECKABLE and fails; the fix is to quote the code, not to loosen the check.

WHICH CITATIONS ARE IN SCOPE
============================
Only the ones that name a file IN THIS REPO.  A citation that names an
upstream Python file is a promise about a pinned third-party package
(`doubleml` 0.11.4) that this repo does not ship; its line numbers are the
pin's business, and the vendored upstream tree is not tracked, so a tracked
verifier could not check them anyway.  The count of those is DECLARED and
asserted too, so the set cannot move silently in either direction.

Both counts are declared here and asserted in section 1, which is what keeps
the published check count FIXED: a citation cannot be added or removed without
the declaration moving with it.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the prose files that carry citations, derived from `git ls-files`;
  * for each citation: the cited file, the cited line's TEXT, and the
    identifiers the sentence names;
  * the counts, which the CHANGELOG publishes and this verifier witnesses.

Run: python _verify/_verify_citations_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")

# The two counts.  A change to either is a change to the SET, so it is
# declared here and asserted below: the set cannot move without the
# declaration moving with it.
EXPECTED_PORT_CITATIONS = 103
EXPECTED_UPSTREAM_CITATIONS = 266
EXPECTED_FILES = 40

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


CITE = re.compile(r"(?P<file>[A-Za-z0-9_./-]+\.(?:py|mbt)):(?P<lo>\d+)(?:-(?P<hi>\d+))?")
SPAN = re.compile(r"`([^`\n]+)`")
IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
PATHISH = re.compile(r"^[\w./-]+\.(py|mbt|md|json|txt|ps1|sh)(:\d+(-\d+)?)?$")

# words that are part of every language and carry no identity
STOP = {
    "require", "fn", "pub", "def", "let", "mut", "if", "else", "elif", "for",
    "in", "while", "break", "continue", "return", "match", "struct", "enum",
    "impl", "type", "trait", "self", "none", "true", "false", "new", "get",
    "set", "and", "or", "not", "is", "as", "import", "from", "class", "pass",
    "raise", "assert", "with", "lambda", "yield", "the", "of", "to", "be",
    "int", "bool", "string", "unit", "array", "option", "result", "moonbit",
    "python", "upstream", "port", "this", "that", "its", "one", "two", "mean",
    "sum", "value", "values", "data", "here", "there",
}


def identifiers(text):
    """-> the identifiers a piece of text names, longest first."""
    out = [w for w in IDENT.findall(text)
           if len(w) >= 2 and w.lower() not in STOP]
    out.sort(key=len, reverse=True)
    return out


def chunk_ids(chunk):
    """-> the identifiers of one whitespace-separated chunk, if it is code."""
    c = chunk.strip().strip("`").strip("(),.;:").strip()
    if not c or PATHISH.match(c):
        return []
    return identifiers(c)


def tracked(rel):
    r = subprocess.run(["git", "ls-files", "--", rel], cwd=ROOT,
                       capture_output=True, text=True)
    return [x for x in r.stdout.split("\n") if x.strip()]


def port_path(f):
    """-> the in-repo path the citation names, or None if it names an upstream file."""
    for c in (os.path.join(LIB, f), os.path.join(ROOT, f),
              os.path.join(ROOT, "examples", f)):
        if os.path.isfile(c):
            return c
    return None


def prose_units(path):
    """-> [(kind, text)] -- one unit per PROSE PARAGRAPH.

    A paragraph is a run of consecutive prose lines, so a claim whose quote
    and whose citation sit on adjacent wrapped lines still binds, and the
    table-style comments keep their rows.
    """
    s = read(path)
    units = []
    if path.endswith(".mbt"):
        runs = []
        for kind, body in (("docstring", None), ("comment", None)):
            pass
        cur = None
        for ln in s.split("\n"):
            st = ln.strip()
            if st.startswith("///"):
                k, b = "docstring", st[3:].strip()
            elif st.startswith("//"):
                b = st[2:].strip()
                if b and not re.fullmatch(r"[-=~*]{3,}", b):
                    k = "comment"
                else:
                    b = None
            else:
                b = None
                k = None
            if b is None:
                if cur is not None:
                    units.append(cur)
                    cur = None
                continue
            if cur is None or cur[0] != k:
                if cur is not None:
                    units.append(cur)
                cur = (k, [b])
            else:
                cur[1].append(b)
        if cur is not None:
            units.append(cur)
    else:
        m = re.search(r'^"""(.*?)"""', s, re.S | re.M)
        if m:
            para = []
            for ln in m.group(1).split("\n"):
                if ln.strip():
                    para.append(ln.strip())
                elif para:
                    units.append(("docstring", list(para)))
                    para = []
            if para:
                units.append(("docstring", list(para)))
        para = []
        for ln in s.split("\n"):
            st = ln.strip()
            if st.startswith("#") and not st.startswith("#!"):
                para.append(st)
            else:
                if para:
                    units.append(("comment", list(para)))
                    para = []
        if para:
            units.append(("comment", list(para)))
    return [(k, "\n".join(v)) for k, v in units]


def prose_files():
    """-> [(path, label)] for every tracked file that can carry prose."""
    out = []
    for rel in tracked("."):
        if rel.startswith("_verify/"):
            continue
        if rel.endswith(".mbt"):
            out.append((os.path.join(ROOT, rel), rel))
        elif rel.endswith(".py"):
            if (rel.startswith("validate_") and rel.endswith("_with_python.py")) \
                    or rel.startswith("pyexample_"):
                out.append((os.path.join(ROOT, rel), rel))
    return out


def anchor_for(text, cstart, cend):
    """The identifier the citation names, found in the same paragraph.

    The anchor is the quoted code token CLOSEST to the citation -- before or
    after it -- because that is the one the sentence is pointing at.  A token
    that names a FILE is not code and is skipped: `plr.mbt:107` is a pointer,
    not an identifier.

    When the two sides are within EIGHT characters of each other the token
    BEFORE wins.  A citation normally points at what was just said -- the
    form `(`code`, `file:line`)` -- and a tie decided by two stray characters
    of connective prose would be a rule that reads differently every time.
    """
    before = None
    after = None
    for m in SPAN.finditer(text):
        t = m.group(1).strip()
        if PATHISH.match(t):
            continue
        ids = identifiers(t)
        if not ids:
            continue
        if m.end() <= cstart:
            d = cstart - m.end()
            if before is None or d < before[0]:
                before = (d, ids[0], t)
        elif m.start() >= cend:
            d = m.start() - cend
            if after is None or d < after[0]:
                after = (d, ids[0], t)
    pick = None
    if before is not None and after is not None:
        pick = before if before[0] <= after[0] + 8 else after
    else:
        pick = before or after
    if pick is not None:
        return pick[1], pick[2], "quoted"
    # the table style: the plain text after the citation
    tail = text[cend:].split("`")[0]
    for chunk in tail.split():
        ids = chunk_ids(chunk)
        if ids:
            return ids[0], chunk, "table cell"
    return None, None, None


# ==============================================================================
print("=" * 78)
print("1. the citation set")
print("=" * 78)

RECORDS = []
for path, label in prose_files():
    for kind, text in prose_units(path):
        for c in CITE.finditer(text):
            f, lo = c.group("file"), int(c.group("lo"))
            hi = int(c.group("hi")) if c.group("hi") else lo
            p = port_path(f)
            ident, quote, how = anchor_for(text, c.start(), c.end())
            RECORDS.append((label, kind, f, lo, hi, p, ident, quote, how, text))

port = [r for r in RECORDS if r[5] is not None]
upstream = [r for r in RECORDS if r[5] is None]

print("  port-side citations:    %d" % len(port))
print("  upstream-side citations: %d" % len(upstream))

check("the tracked prose carries %d port-side citations" % EXPECTED_PORT_CITATIONS,
      len(port) == EXPECTED_PORT_CITATIONS, "found %d" % len(port))
check("the tracked prose carries %d upstream-side citations"
      % EXPECTED_UPSTREAM_CITATIONS,
      len(upstream) == EXPECTED_UPSTREAM_CITATIONS, "found %d" % len(upstream))

# ==============================================================================
print()
print("=" * 78)
print("2. every port-side citation points at a line that mentions the thing")
print("=" * 78)

for label, kind, f, lo, hi, p, ident, quote, how, text in port:
    tag = "%s cites %s:%d" % (label, f, lo)
    lines = read(p).split("\n")
    if not (1 <= lo <= len(lines)) or not (1 <= hi <= len(lines)):
        check(tag, False, "the cited line is out of range (the file has %d lines)"
              % len(lines))
        continue
    if ident is None:
        check(tag, False, "the prose names no code beside the citation, so the "
                          "claim cannot be checked")
        continue
    window = "\n".join(lines[lo - 1:hi])
    ok = ident in window
    check(tag, ok, "%-14s %-26r %s"
          % (how or "?", ident,
             lines[lo - 1].strip()[:60] if not ok else ""))

# ==============================================================================
print()
print("=" * 78)
print("3. the prose files that carry the citations")
print("=" * 78)
by_file = {}
for r in port:
    by_file.setdefault(r[0], []).append(r)
for label in sorted(by_file):
    print("  %-46s %d: %s"
          % (label, len(by_file[label]),
             ", ".join("%s:%d" % (r[2], r[3]) for r in by_file[label])))
check("the port-side citations live in %d prose files" % EXPECTED_FILES,
      len(by_file) == EXPECTED_FILES, "got %d" % len(by_file))

# ==============================================================================
print()
print("== 4. the published check count, witnessed ==")
# ------------------------------------------------------------------------------
# The CHANGELOG publishes this verifier's check count.  The count is the number
# of port-side citations plus the fixed checks above and below, so it is fixed
# on every tree that passes: a citation added without moving the declaration
# fails section 1, and the published number cannot drift.
# ==============================================================================
_found = re.findall(r"_verify_citations_1650\.py` \(\*\*(\d+)\*\* checks\)",
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
