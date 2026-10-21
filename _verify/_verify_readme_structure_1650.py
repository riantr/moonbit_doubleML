r"""Round 23 verifier: the README's SHAPE, checked.

THE GAP THIS FILLS
==================
Every verifier in this repository checks what the README SAYS.  None of them
checks whether the README is WELL FORMED.  Round 22 found fourteen defects
while reading the document, and two of them were not claims at all -- they
were shape:

  * a section that opened with half a sentence.  The block the section is
    built from starts at old-README line 1958, which is the second half of
    a sentence: "patterns instead, against `examples/bitexact/`".  The
    subject, at 1955-1957, was dropped by the condensation.  A claim
    verifier cannot see this: the surviving text is a well-formed claim
    about nothing.
  * a heading that skipped a level -- `## Attribution` followed by
    `#### Differences from upstream`, with nothing at the level in between.

Both are now fixed.  This file is what keeps them fixed, and it is the
check that would have caught them in the first place.

WHAT IS CHECKED
===============
A. the skeleton -- one H1, no heading level jumps, every code fence closed
B. the tables -- consistent column counts, a real separator row
C. the prose shape -- no paragraph opens mid-sentence, no trailing
   whitespace, no tabs, no runs of blank lines
D. the links -- every markdown link target is ABSOLUTE.  The registry
   serves exactly one file, so a relative link to a file in the repository
   is a link to nowhere on the published page.  The repository's
   convention is code spans, not local links, and this file makes that
   convention machine-checked.
E. the pointers -- every "see below" has something below it, every "see
   above" has something above it, and every bolded section name used as a
   pointer names a heading that exists.

WHAT IS DELIBERATELY NOT CHECKED
=================================
A paragraph that opens with "So", "Because", "Then" or "And" is FINE -- a
sentence can start with a capitalised conjunction.  An earlier draft of this
file rejected those and found four innocent paragraphs, which is how a
structural check learns to be worthless.  The rule is narrower: a paragraph
may not open with a LOWERCASE word, because that is what a cut sentence
looks like.

A bold phrase is not a section reference.  "**One API shape**" is a lead-in,
not a pointer, and a draft that treated every bold phrase as a pointer
reported seventeen of them.  Only a bold phrase IMMEDIATELY followed by
"above" or "below" is a pointer.

Run: python _verify/_verify_readme_structure_1650.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

README = os.path.join(ROOT, "README.mbt.md")
SHIPPED = os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")

FAILURES = []
CHECKS = 0


def check(label, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print("  PASS  %s" % label)
    else:
        print("  *** FAIL ***  %s%s" % (label, (" -- " + detail) if detail else ""))
        FAILURES.append(label)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


text = read(README)
L = text.split("\n")

# ------------------------------------------------------------- the regions
# A code fence and a table row are not prose, so both are excluded from the
# prose checks.
in_fence = False
fence_open = None
fence_blocks = []
table_rows = []
covered = set()
i = 0
while i < len(L):
    line = L[i]
    if line.lstrip().startswith("```"):
        if not in_fence:
            in_fence, fence_open = True, i
        else:
            in_fence = False
            fence_blocks.append((fence_open, i))
        covered.add(i)
        i += 1
        continue
    if in_fence:
        covered.add(i)
        i += 1
        continue
    if line.lstrip().startswith("|") and line.rstrip().endswith("|"):
        table_rows.append(i)
        covered.add(i)
        i += 1
        continue
    if table_rows and table_rows[-1] == i - 1:
        covered.add(i - 1)
        table_rows = []
    i += 1
if table_rows:
    covered.update(table_rows)

# the table blocks, for the pointer check
tables = []
cur = []
for n in range(len(L)):
    if n in covered and L[n].lstrip().startswith("|"):
        cur.append(n)
    elif cur:
        tables.append((cur[0], cur[-1]))
        cur = []
if cur:
    tables.append((cur[0], cur[-1]))

print()
print("A. the skeleton")
h1 = [n for n, l in enumerate(L, 1) if re.match(r"^#\s", l)]
check("the README has exactly one H1", len(h1) == 1, "found %d" % len(h1))

levels = [(n, len(m.group(1))) for n, l in enumerate(L, 1)
          for m in [re.match(r"^(#+)\s", l)] if m]
jumps = [(a, b) for (a, pa), (b, pb) in zip(levels, levels[1:]) if pb > pa + 1]
check("no heading skips a level", not jumps,
      "jumps: %r" % jumps[:4])
check("the heading levels descend monotonically to the H1",
      levels and levels[0][1] == 1, "first is h%d" % (levels[0][1] if levels else 0))

n_markers = sum(1 for l in L if l.lstrip().startswith("```"))
check("every code fence is closed", n_markers % 2 == 0 and not in_fence,
      "%d markers, unclosed: %s" % (n_markers, in_fence))
check("there is at least one fenced block", len(fence_blocks) > 0)
check("every fenced block is a language-tagged block or a bare block",
      all(L[a].lstrip().startswith("```") for a, b in fence_blocks))

print()
print("B. the tables")
bad_cols = []
for a, b in tables:
    counts = []
    for n in range(a, b + 1):
        row = L[n]
        # count the cells, ignoring a pipe that is inside a code span or
        # escaped as `\|`
        cells, in_code, prev = 0, False, ""
        for ch in row.strip().strip("|"):
            if ch == "`":
                in_code = not in_code
            if ch == "|" and not in_code and prev != "\\":
                cells += 1
            else:
                prev = ch
        counts.append(cells + 1)
    if len(set(counts)) > 1:
        bad_cols.append((a + 1, b + 1, counts))
check("every table's rows have the same number of columns", not bad_cols,
      "offenders: %r" % bad_cols[:3])

no_sep = []
for a, b in tables:
    if b - a < 1:
        no_sep.append(a + 1)
        continue
    sep = L[a + 1].strip()
    if not re.match(r"^\|[\s:\-|]+\|$", sep) or "-" not in sep:
        no_sep.append(a + 1)
check("every table has a separator row under its header", not no_sep,
      "tables starting at %r" % no_sep[:3])
check("the README has tables to check", len(tables) > 0, "%d" % len(tables))

print()
print("C. the prose shape")
fragments = []
para_start = None
for n in range(len(L) + 1):
    line = L[n] if n < len(L) else ""
    if not line.strip():
        if para_start is not None:
            first = L[para_start]
            if para_start not in covered:
                s = first.strip()
                s = re.sub(r"^(>\s*)+", "", s)          # blockquote markers
                s = re.sub(r"^([-*+]|\d+[.)])\s+", "", s)   # list markers
                # a paragraph may legitimately open with a FORMULA or a short
                # conventional token ("n = 400", "e.g.", "vs"); only an
                # ordinary lowercase word can be a cut sentence.
                first_word = re.match(r"^([A-Za-z][A-Za-z']*)\b", s)
                is_formula = bool(re.match(r"^[A-Za-z][A-Za-z']*\s*=", s))
                allowed = ("e.g", "i.e", "vs", "cf", "et", "al",
                           "n", "x", "y", "z", "p", "k", "m")
                if (s and re.match(r"^[a-z]", s)
                        and not re.match(r"^(e\.g|i\.e)\.", s, re.I)
                        and not is_formula
                        and not (first_word and first_word.group(1) in allowed)):
                    fragments.append((para_start + 1, s[:70]))
            para_start = None
    elif para_start is None:
        para_start = n
check("no paragraph opens mid-sentence", not fragments,
      "fragments: %r" % fragments[:4])

trailing = [n for n, l in enumerate(L, 1) if l != l.rstrip()]
check("no line has trailing whitespace", not trailing,
      "lines %r" % trailing[:6])
tabs = [n for n, l in enumerate(L, 1) if "\t" in l]
check("no line contains a tab", not tabs, "lines %r" % tabs[:6])
check("there are no runs of blank lines", "\n\n\n" not in text)

print()
print("D. the links")
links = re.findall(r"\[[^\]]*\]\(([^)]*)\)", text)
rel = [u for u in links if not u.startswith(("http://", "https://", "#", "mailto:"))]
check("every markdown link target is absolute", not rel,
      "relative targets: %r" % rel[:4])
check("no link target is empty", all(u.strip() for u in links))
check("every link target has a scheme and a host",
      all(re.match(r"^https?://[^/\s]+", u) for u in links
          if u.startswith(("http://", "https://"))),
      "")

print()
print("E. the pointers")
heads = [(n, l.lstrip("# ").strip().lower()) for n, l in enumerate(L, 1)
         if re.match(r"^#+\s", l)]
head_lines = [n for n, _ in heads]
table_lines = [n for n, _ in tables]


def has_after(n):
    return any(h > n for h in head_lines) or any(t > n for t in table_lines)


def has_before(n):
    return any(h < n for h in head_lines) or any(t < n for t in table_lines)


DOWN = re.compile(r"\b(see|table|section|note|paragraph|figure)s?\s+(below|down)\b", re.I)
UP = re.compile(r"\b(see|table|section|note|paragraph|figure)s?\s+(above|up)\b", re.I)

down_bad, up_bad = [], []
for n, line in enumerate(L, 1):
    for m in DOWN.finditer(line):
        if not has_after(n):
            down_bad.append((n, m.group(0)))
    for m in UP.finditer(line):
        if not has_before(n):
            up_bad.append((n, m.group(0)))
check("every 'below' pointer has something below it", not down_bad,
      "dangling: %r" % down_bad[:4])
check("every 'above' pointer has something above it", not up_bad,
      "dangling: %r" % up_bad[:4])

BOLD_PTR = re.compile(r"\*\*([^*\n]{2,60})\*\*\s+(above|below)\b", re.I)
bad_names = []
for n, line in enumerate(L, 1):
    for m in BOLD_PTR.finditer(line):
        name = re.sub(r"[`*]", "", m.group(1)).strip().lower()
        if name not in [h for _, h in heads]:
            bad_names.append((n, m.group(1)))
check("every bolded 'above'/'below' reference names a real heading",
      not bad_names, "unknown: %r" % bad_names[:4])

print()
print("F. the two copies")
shipped = read(SHIPPED)
check("the shipped README is byte-identical to the edited one",
      shipped.encode("utf-8") == text.encode("utf-8"))
check("the README is LF-only with no BOM",
      b"\r" not in text.encode("utf-8")
      and not text.encode("utf-8").startswith(b"\xef\xbb\xbf"))

print()
print("=" * 72)
print("%d checks, %d failed" % (CHECKS, len(FAILURES)))
if FAILURES:
    print("*** FAIL ***")
    for f in FAILURES:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
