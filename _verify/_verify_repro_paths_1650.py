#!/usr/bin/env python3
"""Round 52 verifier: a REPRODUCTION COMMAND is a promise, and so is a STATUS LINE.

WHAT THIS EXISTS FOR
====================
Ten reproduction commands in tracked Markdown named scripts that are not in the
repository.  Not one of the nine scripts was EVER committed -- `git log --all --
_verify/_cluster_formula_1680.py` is empty -- so a reader could not have run any
of them, and the documents that carried them said so in words that read as
evidence.

Three of the ten sat in documents that no verifier opened:

  * `_verify/CLUSTER_UPSTREAM_PARITY_1680.md` cited `_cluster_formula_1680.py`,
    `_cluster_cols_1680.py` and `_cluster_api_1680.py`.  The document's own
    later section says these "pointed at nothing", that "a reproduction command
    that cannot be run is worse than none, because it reads as evidence", and
    that they were "Replaced with the two scripts that do exist" -- and then
    listed three.  The block it claimed to replace was never touched, so the
    CHANGELOG published "the block now cites the three scripts that do" while
    the block still cited none of them.
  * `_verify/PQ_QTE_GATE_DESIGN_1680.md` cited `_pq_tol_1680.py` and
    `_qte_shape_1680.py`, and its status line said "gate not yet built" a year
    and a half of commits after `pyexample_pq.py` landed.
  * `_verify/RDD_PARITY_1680.md` said of a docstring "Not yet corrected ...
    Logged, not fixed" -- in the SAME commit that corrected it, whose own
    message says "Also corrects a docstring stating an identity its own test
    cannot see".  The note also quoted a test name that does not exist: the
    test is `v116_tau_bc_equals_the_collapsed_form_only_when_b_equals_h`, and
    the note said `..._when_b_equals_h`.

THE RULE
========
  R1  a reproduction command names a file that is IN the repository.  A path in
      prose is a promise, and the promise is that the reader can run it.
  R2  a status line that names a file names one that is in the repository --
      so a status line cannot be TRUE by pointing at a file that is gone.
  R3  a count that names a set is the size of that set.  "the three scripts
      that do exist" followed by two names is a count with no owner, and the
      count is what rots.
  R4  the root `README.md` is a symlink to `README.mbt.md`.  GitHub serves the
      symlink; this host materialises it as a hardlink, and a fresh clone with
      `core.symlinks=false` writes a 13-byte stub.  So the claim is read from
      the INDEX and the BLOB, never from the working tree -- which makes it the
      same in every clone.

WHAT IS HISTORICAL
==================
A document may keep its original text -- that is how a retraction stays
auditable.  Two declarations mark such text, and BOTH are the document's own
words, not this file's list:

  * a `**Status:` line that says the document is retracted -- the whole
    document is a record of a claim that was withdrawn;
  * a heading that says "Original text" -- everything from that heading on is
    kept verbatim.

A document in either state is not silent about it: this check MAKES a check
for it and it PASSES, with the reason in the detail line.  That is what keeps
the check count the same in every tree while still showing that the excluded
text was looked at.

Run: python _verify/_verify_repro_paths_1650.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NCHECK = 0
FAILS = []


def short(s, n=70):
    """A detail line, kept short.  A detail that dumps a whole document into
    the output is a context bomb, and the check that produced it has already
    said what matters.
    """
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n - 3] + "..."


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "*** FAIL ***", label, short(detail)))
    if not ok:
        FAILS.append(label)


def git(*args):
    r = subprocess.run(["git", "-C", ROOT, *args], capture_output=True)
    return r.stdout.decode("utf-8", "replace")


TRACKED = set(git("ls-files").splitlines())
MD = sorted(p for p in TRACKED if p.lower().endswith(".md"))

# The INDEX is the authority on what a tracked path IS.  A symlink's content is
# its target, not the file it points at -- and on this host the working tree
# materialises `README.md` as a HARDLINK to `README.mbt.md`, while a fresh clone
# with `core.symlinks=false` writes a 13-byte stub.  Reading the working tree
# would make the check count depend on the CLONE, so a symlinked document is
# read from its blob and the count is the same in every tree.
INDEX = {}
for e in git("ls-files", "-s").splitlines():
    meta, path = e.split("\t", 1)
    mode, sha, _stage = meta.split()
    INDEX[path] = (mode, sha)

# --------------------------------------------------------------------------
# 1.  CLASSIFICATION -- read out of the documents' own words
# --------------------------------------------------------------------------

RETRACTED = re.compile(r"(?i)\bretract(?:ed|ion|ing)\b")
ORIGINAL_HEADING = re.compile(r"(?i)^#+\s*original text\b")
STATUS_LINE = re.compile(r"^\*\*Status:")
CMD = re.compile(r"^\s*(?:\$|>)?\s*python[ ]+(?:-[A-Za-z]+[ ]+)*([^\s]+\.py)\b")
SPAN = re.compile(r"`([^`\n]{1,120})`")
COUNT_PHRASE = re.compile(
    r"\bthe (one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"
    r"\s+(scripts?|files?|commands?)\s+that\s+(do|does)\s+exist\b", re.I)
NUMWORD = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
           "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
           "twelve": 12}


def read(rel):
    """A document's text.  A symlink is read from its blob, never the file it
    points at, so the result does not depend on how the clone materialised it.
    """
    mode, sha = INDEX.get(rel, ("100644", None))
    if mode == "120000":
        return git("cat-file", "-p", sha)
    with io.open(os.path.join(ROOT, rel.replace("/", os.sep)), encoding="utf-8",
                 errors="replace") as fh:
        return fh.read()


def status_paragraph(text):
    """The paragraph a document opens its STATUS with.

    A status is a PARAGRAPH, not a line: the house's own documents wrap it
    mid-sentence, and a check that read only the first line would miss a file
    name on the second.
    """
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if not STATUS_LINE.match(ln.strip()):
            continue
        end = i
        while end < len(lines):
            if is_blank_line(lines[end]) or (
                    end > i and starts_a_list_item(lines[end])):
                break
            end += 1
        return "\n".join(lines[i:end])
    return None


def original_text_from(text):
    """The line index at which a document preserves retracted text verbatim."""
    for i, ln in enumerate(text.splitlines()):
        if ORIGINAL_HEADING.match(ln.strip()):
            return i
    return None


def whole_is_historical(text):
    sl = status_paragraph(text)
    return bool(sl and RETRACTED.search(sl))


def resolve(tok, doc):
    """Where does this cited path live?  tracked / untracked / missing."""
    tok = tok.replace("\\", "/")
    base = os.path.basename(tok)
    if "/" in tok:
        cands = [tok, "_verify/" + tok]
        d = os.path.dirname(doc)
        if d:
            cands.append(d + "/" + tok)
    else:
        hits = sorted(p for p in TRACKED if os.path.basename(p) == base)
        cands = hits if hits else [tok]
    for c in cands:
        if c in TRACKED:
            return "tracked", c
    for c in cands:
        if os.path.exists(os.path.join(ROOT, c.replace("/", os.sep))):
            return "untracked", c
    return "missing", None


def py_names(text):
    out = []
    for m in SPAN.finditer(text):
        t = m.group(1).strip()
        if t.lower().endswith(".py"):
            out.append(t)
    return out


def is_blank_line(ln):
    """A blank line -- including the ENGINEERING banner's bare `>` marker."""
    s = ln.strip()
    if s == "":
        return True
    while s.startswith(">"):
        s = s[1:].strip()
    return s == ""


def starts_a_list_item(ln):
    """A line that opens a new list item ends the paragraph before it.

    A CHANGELOG bullet list has no blank line between its items, so without
    this a bullet's text runs on into the next bullet's and the names of one
    are counted against the count of the other.
    """
    s = ln.strip()
    while s.startswith(">"):
        s = s[1:].strip()
    return bool(re.match(r"^(?:[-*+]\s|\d+[.)]\s)", s))


def set_a_phrase_introduces(text, pos):
    """The set that "the N scripts that do exist" introduces.

    The names the phrase introduces are the ones that FOLLOW it: the rest of
    its paragraph, and -- when the phrase is followed by a colon -- the
    indented block that comes after that paragraph.

    The names BEFORE it are not the set.  A sentence that says "those three
    were replaced by the two scripts that do exist" names three files and then
    counts two; the three are what it talks ABOUT, not what the count is
    counting.  And a phrase inside a quotation introduces nothing at all.
    """
    lines = text.split("\n")
    start_line = text[:pos].count("\n")
    after_on_line = text[pos:].split("\n")[0]

    end = start_line
    while end < len(lines):
        if is_blank_line(lines[end]) or (
                end > start_line and starts_a_list_item(lines[end])):
            break
        end += 1
    scope_lines = list(lines[start_line:end])

    if after_on_line.lstrip().startswith(":"):
        block = []
        started = False
        for ln in lines[end:]:
            if is_blank_line(ln):
                if started:
                    break
                continue
            s = ln.strip()
            while s.startswith(">"):
                s = s[1:].strip()
            if ln.startswith("    ") or ln.startswith("\t") or s.startswith("```"):
                started = True
                block.append(ln)
                continue
            break
        scope_lines = scope_lines + block
    return "\n".join(scope_lines)


# --------------------------------------------------------------------------
# 2.  R1 -- a reproduction command names a file that is IN the repository
# --------------------------------------------------------------------------

CMDCOUNT = 0
for doc in MD:
    text = read(doc)
    lines = text.splitlines()
    cut = original_text_from(text)
    historical_whole = whole_is_historical(text)

    for i, ln in enumerate(lines):
        m = CMD.match(ln)
        if not m:
            continue
        in_verbatim = cut is not None and i > cut
        if historical_whole or in_verbatim:
            continue
        CMDCOUNT += 1
        tok = m.group(1)
        status, where = resolve(tok, doc)
        check("%s:%d cites a tracked script" % (doc, i + 1), status == "tracked",
              "%s -> %s" % (tok, where if where else "not in the repository"))

# --------------------------------------------------------------------------
# 3.  The historical text is looked at, and says so
# --------------------------------------------------------------------------

for doc in MD:
    text = read(doc)
    cut = original_text_from(text)
    if whole_is_historical(text):
        sl = status_paragraph(text)
        check("%s is historical, and says so" % doc, True,
              "skipped: %s" % (sl[:80] if sl else "retracted"))
    elif cut is not None:
        lines = text.splitlines()
        check("%s keeps original text, and says so" % doc, True,
              "skipped: from line %d, %s" % (cut + 1, lines[cut].strip()[:60]))

# --------------------------------------------------------------------------
# 4.  R2 -- a status line that names a file names one that is IN the repository
# --------------------------------------------------------------------------

for doc in MD:
    text = read(doc)
    if whole_is_historical(text):
        continue
    sl = status_paragraph(text)
    if not sl:
        continue
    names = py_names(sl)
    if not names:
        continue
    for nm in names:
        status, where = resolve(nm, doc)
        check("%s's status line names a tracked script" % doc, status == "tracked",
              "%s -> %s" % (nm, where if where else "not in the repository"))

# --------------------------------------------------------------------------
# 5.  R3 -- a count that names a set is the size of that set
# --------------------------------------------------------------------------

for doc in MD:
    text = read(doc)
    if whole_is_historical(text):
        continue
    for m in COUNT_PHRASE.finditer(text):
        want = NUMWORD[m.group(1).lower()]
        scope = set_a_phrase_introduces(text, m.end())
        got = len(set(py_names(scope)))
        if got == 0:
            # The phrase introduces no set -- it is inside a quotation, or it
            # is followed by prose.  There is no count to be wrong about, so
            # there is no check to make.
            continue
        check("%s: a count that names a set is its size" % doc, want == got,
              "'the %s %s that %s exist' but %d named"
              % (m.group(1).lower(), m.group(2).lower(), m.group(3).lower(), got))

# --------------------------------------------------------------------------
# 6.  R4 -- the root README.md is a symlink to README.mbt.md
# --------------------------------------------------------------------------

MODE = None
BLOB = None
for e in git("ls-files", "-s").splitlines():
    meta, path = e.split("\t", 1)
    mode, sha, _stage = meta.split()
    if path == "README.md":
        MODE = mode
        BLOB = git("cat-file", "-p", sha)
        break

check("the root README.md is a git symlink", MODE == "120000",
      "mode %s" % (MODE or "absent"))
check("the root README.md points at README.mbt.md",
      (BLOB or "").strip() == "README.mbt.md",
      "target %r" % ((BLOB or "").strip(),))

# --------------------------------------------------------------------------
# 7.  The tree's own facts
# --------------------------------------------------------------------------

check("README.mbt.md and its package copy are the same file",
      git("rev-parse", "HEAD:README.mbt.md").strip()
      == git("rev-parse", "HEAD:moonbit_doubleML/README.mbt.md").strip(),
      "the package copy is what the registry serves")

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
print("  %d tracked documents, %d live reproduction commands" % (len(MD), CMDCOUNT))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
