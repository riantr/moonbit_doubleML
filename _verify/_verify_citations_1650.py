"""Check the README's source citations: does the cited line really say what
the sentence claims?

ROUNDS 32-34 LEFT THIS UNCHECKED
================================

The README cites source locations -- `ssm.mbt:73-74`, `irm.mbt:430`,
`did.mbt:97` -- and each one is a promise to the reader: "look here and you
will find this".  Nothing verified the promise.  Round 35 found the cost of
that: the DID paragraph cited `did.mbt:708` for "the observational DID score",
but line 708 is `let w_d = d_i / m_i`, which lives in the `else` branch opened
at did.mbt:704 -- the EXPERIMENTAL score.  The observational branch is
did.mbt:659-689, and its default form computes `(D - m) / (p_hat * (1 - m))`,
where `1 / m` appears NOWHERE.  The README's explanation of why the DID
family's OLS default is safe was describing a branch the shipped default never
runs.

TWO RULES
=========

C1 -- THE CITED LINE MUST CARRY THE CLAIMED TOKEN.
    A code span that looks like a source expression (it carries an operator)
    must occur, verbatim modulo whitespace, within the range the sentence
    cites.  Spans that are plain numbers are left to the measurement
    invariants; a span is charged to a citation only when the two are in the
    SAME SENTENCE -- the README is hard-wrapped, so a line break is not a
    sentence boundary, but a neighbouring sentence is not part of this
    citation's claim either.

C2 -- A CITATION THAT NAMES A CONFIGURATION MUST SIT IN THAT CONFIGURATION.
    If the sentence before the citation names a score configuration -- a
    string the source compares a `score` field against, DERIVED from the
    source, not listed here -- then the cited line must be inside the branch
    that configuration selects.  For a doc-comment citation the rule is the
    weaker one that the doc comment must NAME the configuration, because a
    doc comment states a score rather than running it.

C2 is the rule that catches the did.mbt:708 defect.  C1 is the rule that
catches an off-by-one or a citation to the wrong line.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
readme = io.open(os.path.join(ROOT, "README.mbt.md"), encoding="utf-8").read()

# The declared size.  A change to it is a change to the SET.
EXPECTED_CITATIONS = 13

# how close a code span must be to a citation to be charged to it
SPAN_WINDOW = 200

# a period that does not end a sentence
ABBREV = ("e.g", "i.e", "vs", "cf", "etc", "al", "No", "Fig", "approx", "resp")

fails = []
NCHECK = 0


def check(label, cond, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


# ---------------------------------------------------------------------------
# the source
# ---------------------------------------------------------------------------

def strip_code(line):
    """The line without its string literals and its trailing comment."""
    out = []
    in_str = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
            out.append(" ")
        else:
            if ch == '"':
                in_str = True
                out.append(" ")
            elif ch == "/" and i + 1 < len(line) and line[i + 1] == "/":
                break
            else:
                out.append(ch)
        i += 1
    return "".join(out)


def code_part(line):
    """The line up to its trailing comment, WITH its string literals intact."""
    in_str = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == "/" and i + 1 < len(line) and line[i + 1] == "/":
                return line[:i]
        i += 1
    return line


def load_source(name):
    """The lines of a cited file, or None."""
    for base in (LIB, ROOT):
        p = os.path.join(base, name)
        if os.path.isfile(p):
            return io.open(p, encoding="utf-8", errors="replace").read().split("\n")
    return None


# the score configurations the source compares against -- DERIVED, not listed
QUALIFIER_RE = re.compile(r"\b\w*score\w*\s*==\s*\"([^\"]+)\"")
QUALIFIERS = set()
for _f in sorted(os.listdir(LIB)):
    if _f.endswith(".mbt"):
        _s = io.open(os.path.join(LIB, _f), encoding="utf-8", errors="replace").read()
        QUALIFIERS |= set(QUALIFIER_RE.findall(_s))


def branch_extents(lines, qual):
    """The line ranges of the BRANCH a `score == "<qual>"` condition selects.

    An `if / else if / else` chain is ONE block, so the chain's closing brace
    is not the end of the `then` branch, and a NESTED chain inside it ends at
    the same brace depth.  The chain this condition belongs to is found by
    INDENTATION instead: the continuation (`} else if ...` / `} else {`) sits
    at the same indentation as the condition, while a nested chain sits deeper.
    """
    out = []
    pat = re.compile(r"\b\w*score\w*\s*==\s*\"%s\"" % re.escape(qual))
    for i, line in enumerate(lines):
        m = pat.search(code_part(line))
        if not m:
            continue
        rest = code_part(line)[m.end():]
        if "{" not in rest:
            nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
            if not nxt.startswith("{"):
                continue
        indent = len(line) - len(line.lstrip())
        then_end = len(lines)
        for j in range(i + 1, len(lines)):
            l = lines[j]
            if not l.strip():
                continue
            ind = len(l) - len(l.lstrip())
            if ind == indent and l.strip().startswith("}") and "else" in l:
                then_end = j
                break
        out.append((i + 1, then_end))
    return out


def doc_block(lines, lineno):
    """The maximal run of `///` lines containing lineno (1-based)."""
    if lineno - 1 >= len(lines) or not lines[lineno - 1].lstrip().startswith("///"):
        return None
    lo = lineno - 1
    while lo > 0 and lines[lo - 1].lstrip().startswith("///"):
        lo -= 1
    hi = lineno - 1
    while hi + 1 < len(lines) and lines[hi + 1].lstrip().startswith("///"):
        hi += 1
    return "\n".join(lines[lo:hi + 1])


# ---------------------------------------------------------------------------
# sentences
# ---------------------------------------------------------------------------

def sentence_bounds(para):
    """The character positions at which the paragraph breaks into sentences."""
    bounds = []
    # a list item starts a new sentence
    for m in re.finditer(r"(?m)^\s*\d+\.\s", para):
        bounds.append(m.start())
    # a period that ends a sentence
    for i, ch in enumerate(para):
        if ch != ".":
            continue
        if i and para[i - 1].isdigit():
            continue                       # 1.0, 0.007 -- not a sentence end
        j = i + 1
        while j < len(para) and para[j] in " \t":
            j += 1
        if j < len(para) and para[j].isdigit():
            continue                       # 3. -- a list number, handled above
        if j < len(para) and not (para[j].isupper() or para[j] == "`"):
            continue
        word = re.search(r"(\w+)\.$", para[:i + 1])
        if word and word.group(1) in ABBREV:
            continue
        bounds.append(j)
    return sorted(set(bounds))


def sentence_of(para, pos, cache={}):
    """The index of the sentence that contains `pos`."""
    if para not in cache:
        cache[para] = sentence_bounds(para)
    bounds = cache[para]
    n = 0
    for b in bounds:
        if b <= pos:
            n += 1
        else:
            break
    return n


# ---------------------------------------------------------------------------
# the README's citations
# ---------------------------------------------------------------------------

CITE_RE = re.compile(r"`([\w./-]+\.mbt):(\d+)(?:-(\d+))?`")
SPAN_RE = re.compile(r"`([^`]+)`")
NUMBERISH = re.compile(r"^[-+~ ]*\d+(\.\d+)*(e[-+]?\d+)?$")
OPERATORS = set("=*/+()-")


def is_numberish(s):
    return NUMBERISH.match(s.strip()) is not None


def has_operator(s):
    return any(c in OPERATORS for c in s)


def norm(s):
    return re.sub(r"\s+", "", s)


paragraphs = readme.split("\n\n")
citations = []          # (paragraph_index, start, end, file, lo, hi)
spans = []              # (paragraph_index, start, end, content)

for pi, para in enumerate(paragraphs):
    for m in CITE_RE.finditer(para):
        lo = int(m.group(2))
        hi = int(m.group(3)) if m.group(3) else lo
        citations.append((pi, m.start(), m.end(), m.group(1), lo, hi))
    for m in SPAN_RE.finditer(para):
        if CITE_RE.fullmatch(m.group(0)):
            continue
        spans.append((pi, m.start(), m.end(), m.group(1)))

print("== the citation set ==")
check("the citation set is the declared size",
      len(citations) == EXPECTED_CITATIONS,
      "found %d, declared %d" % (len(citations), EXPECTED_CITATIONS))
print("   the score configurations the source compares against: %s"
      % ", ".join(sorted(QUALIFIERS)))

# ---------------------------------------------------------------------------
# C1 -- the cited line must carry the claimed token
# ---------------------------------------------------------------------------

print("")
print("== C1 -- the cited range carries the token the sentence claims ==")

cited_text = {}
for pi, cs, ce, fname, lo, hi in citations:
    lines = load_source(fname)
    if lines is None:
        check("%s:%d -- the cited file exists" % (fname, lo), False,
              "no such file under the package or the repository root")
        continue
    check("%s:%d -- the cited file exists" % (fname, lo), True)
    check("%s:%d-%d -- the cited range exists" % (fname, lo, hi),
          1 <= lo <= hi <= len(lines),
          "the file has %d lines" % len(lines))
    if not (1 <= lo <= hi <= len(lines)):
        continue
    body = "\n".join(lines[lo - 1:hi])
    if not body.strip():
        check("%s:%d -- the cited line is not blank" % (fname, lo), False,
              "the range is whitespace")
    else:
        check("%s:%d -- the cited line is not blank" % (fname, lo), True)
    cited_text[(pi, cs)] = (fname, lo, hi, norm(body))

for pi, para in enumerate(paragraphs):
    para_cites = [(cs, ce, fname, lo, hi)
                  for (p, cs, ce, fname, lo, hi) in citations if p == pi]
    if not para_cites:
        continue
    for spi, ss, se, content in spans:
        if spi != pi:
            continue
        if is_numberish(content) or not has_operator(content):
            continue
        # the NEAREST citation in this paragraph -- a span is charged to ONE
        # citation, so the check is made once
        near = None
        for cs, ce, fname, lo, hi in para_cites:
            d = min(abs(ss - ce), abs(cs - se))
            if near is None or d < near[0]:
                near = (d, cs, ce, fname, lo, hi)
        if near is None or near[0] > SPAN_WINDOW:
            continue
        d, cs, ce, fname, lo, hi = near
        # a span is charged to a citation only when the two are in the SAME
        # SENTENCE
        if sentence_of(para, ss) != sentence_of(para, cs):
            continue
        if (pi, cs) not in cited_text:
            continue
        nf, nlo, nhi, ntext = cited_text[(pi, cs)]
        check("the span %r is in %s:%d-%d" % (content, nf, nlo, nhi),
              norm(content) in ntext,
              "the cited range does not contain it")

# ---------------------------------------------------------------------------
# C2 -- a citation that names a configuration must sit in that configuration
# ---------------------------------------------------------------------------

print("")
print("== C2 -- a citation naming a configuration must sit in it ==")

for pi, cs, ce, fname, lo, hi in citations:
    para = paragraphs[pi]
    # the sentence-ish text immediately before the citation
    before = para[max(0, cs - 120):cs]
    for qual in sorted(QUALIFIERS):
        if not re.search(r"\b%s\b" % re.escape(qual), before):
            continue
        lines = load_source(fname)
        if lines is None:
            break
        block = doc_block(lines, lo)
        if block is not None:
            check("%s:%d -- the doc comment names %r" % (fname, lo, qual),
                  qual in block,
                  "the doc comment does not mention it")
            continue
        extents = branch_extents(lines, qual)
        if not extents:
            # the file has no branch for this configuration -- nothing to check
            check("%s:%d -- %r is selectable here" % (fname, lo, qual), True)
            continue
        inside = any(a <= lo <= b for a, b in extents)
        check("%s:%d -- the cited line is in the %r branch" % (fname, lo, qual),
              inside,
              "the %r branch spans %s" % (qual, extents))

print("")
print("%d checks, %d failed" % (NCHECK, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
