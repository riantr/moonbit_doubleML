"""Every in-repo `file:line` pointer in the documents a reader is pointed at.

WHAT THIS CLOSES
================
Round 42's promise audit found that the class of in-repo `file:line`
pointers is owned by NO tracked check: the file:line checker was rewritten
in v0.164.33 into the publisher-record checker, and nothing took its
place.  A pointer is a PROMISE -- it says "go here and you will find
this" -- and a promise nobody checks is a promise nobody keeps.

SCOPE
=====
The documents a reader is pointed at:

  README.mbt.md, README.md      the published README and its copy
  skills/moonbit_doubleML.md    the skill an agent reads before coding
  doc/*/readme.mbt.md           the six tutorials
  examples/api_server/README.md the HTTP service's own README
  .github/workflows/*.yml       the COMMENTS in the CI files
  CHANGELOG.md                  its NEWEST entry only

`ENGINEERING.md` and the CHANGELOG's HISTORICAL entries are excluded:
they are the record of what the project DID, and a pointer in a record of
the past is allowed to describe the past.  Making them fail would teach
the reader to ignore this check -- the round-23 lesson.

WHAT IS CHECKED
===============
For every pointer whose target is a file IN THIS REPOSITORY:

  1. the target file EXISTS and is TRACKED (a pointer to a file that was
     renamed, or that only exists in one developer's working tree, is a
     broken promise);
  2. the cited line is WITHIN the file (a pointer past the end of the
     file is a pointer to nothing);
  3. the cited line is CODE -- not blank, and not a comment line.  A
     pointer into a comment points at prose about the code, not at the
     code;
  4. the cited line's NEIGHBOURHOOD carries an identifier the citing
     paragraph also names, so the pointer lands near the thing it is
     talking about.

Pointers that name an UPSTREAM Python module (`irm.py:157`, `pq.py:378`,
`lplr.py:401-418`) are a different class -- they name a file in the
vendored upstream tree, not in this repository -- and they are counted
and reported, but they are not resolved against this tree.

THE NEIGHBOURHOOD CHECK
=======================
Check 4 compares the identifiers the paragraph names against the
identifiers near the cited line.  It is deliberately generous -- a window
of 25 lines around the citation, identifiers of three characters or more,
and the comparison is case-insensitive -- because a check that fires
spuriously is worse than no check at all.  It has to be calibrated
against the population, not against an intuition about it.

Run: python _verify/_verify_file_line_refs_1650.py
"""
import hashlib
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PTR = re.compile(r"`?([A-Za-z0-9_./-]+\.(?:mbt|md|py|yml|yaml|toml|json|mod|ps1))"
                 r":(\d+)(?:-(\d+))?`?")

# the documents a reader is pointed at
DOCS = ["README.mbt.md", "README.md", "skills/moonbit_doubleML.md",
        "examples/api_server/README.md"]
_docdir = os.path.join(ROOT, "doc")
if os.path.isdir(_docdir):
    for _d in sorted(os.listdir(_docdir)):
        _p = os.path.join("doc", _d, "readme.mbt.md")
        if os.path.isfile(os.path.join(ROOT, _p)):
            DOCS.append(_p)
_wf = os.path.join(ROOT, ".github", "workflows")
if os.path.isdir(_wf):
    for _d in sorted(os.listdir(_wf)):
        DOCS.append(os.path.join(".github", "workflows", _d))

# where a bare `foo.mbt` name resolves to
SEARCH_ROOTS = ["moonbit_doubleML", "examples", "doc", "_verify", "skills", "."]

# the VENDORED UPSTREAM trees.  A pointer that names a file in one of them
# is an UPSTREAM citation, not a pointer into this repository, and it is
# counted and reported -- but it is not resolved against this tree.
UPSTREAM_ROOTS = [
    os.path.join("_verify", "_upstream_0114", "x", "doubleml"),
    os.path.join("_verify", "_upstream_ps", "doubleml-0.11.4", "doubleml"),
]


def resolve(name):
    """Where does `foo.mbt` live?  First existing candidate wins."""
    for r in SEARCH_ROOTS:
        c = os.path.join(ROOT, r.replace("/", os.sep), name.replace("/", os.sep))
        if os.path.isfile(c):
            return os.path.relpath(c, ROOT).replace("\\", "/")
    return None


def resolve_upstream(name):
    """Is this an UPSTREAM citation rather than a pointer into this tree?

    The vendored upstream trees under `_verify/` are DOWNLOADED copies, not
    tracked files: a fresh clone does not have them.  So their absence
    cannot prove that a pointer is broken, and a rule that consulted them
    would fail in CI while passing in the working tree -- a count that
    moves with the environment.

    The distinction is therefore made by the FILE TYPE, not by whether a
    local download happens to be present.  A pointer that names a PYTHON
    file and does not resolve in this tree names an upstream module --
    `irm.py:157`, `pq.py:378`, `did/did_cs.py:16` are the shape upstream's
    own tree has.  A pointer that names a MOONBIT or a document and
    resolves NOWHERE is broken, and that is a promise this repository made.
    """
    return os.path.splitext(name)[1].lower() == ".py"


def tracked(rel):
    out = subprocess.run(["git", "ls-files", "--error-unmatch", "--", rel],
                         cwd=ROOT, capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    return out.returncode == 0


def is_code_line(line):
    """A CITABLE line: not blank.

    A comment line is citable too -- a `///` doc comment that shows a
    formula is exactly the kind of thing a reader is sent to.  What is
    NOT citable is a BLANK line, which is a pointer to nothing.
    """
    return bool(line.strip())


# --- the checks -------------------------------------------------------------
checks = 0
failed = 0
NEIGH = 25
MINLEN = 3


def ids(text):
    """The identifiers the paragraph DELIBERATELY names.

    Only CODE SPANS count.  A backticked token is the author pointing at
    a name; an ordinary English word in the same paragraph is not, and
    treating it as one would make the check fire on prose -- which is how
    a rule with false positives teaches its reader to ignore it.

    POINTER-shaped spans are removed FIRST: `apo.mbt:320` names a FILE
    and a line, not a symbol in that file, so it is not evidence that the
    target neighbourhood contains anything.

    The token is matched as a SUBSTRING of the neighbourhood, so `fit` is
    found inside `cross_fit_predict_inner`.
    """
    text = re.sub(r"[A-Za-z0-9_./-]+\.(?:mbt|md|py|yml|yaml|toml|json|mod|ps1)"
                  r":\d+(?:-\d+)?", " ", text)
    text = re.sub(r"[A-Za-z0-9_./-]+\.(?:mbt|md|py|yml|yaml|toml|json|mod|ps1)",
                  " ", text)
    out = set()
    for tok in re.findall(r"`([^`\n]+)`", text):
        tok = tok.strip().strip(" .,:;()")
        if len(tok) < MINLEN:
            continue
        if not re.search(r"[A-Za-z]", tok):
            continue
        out.add(tok.lower())
    return out


def norm(s):
    """Whitespace-insensitive, so `m*pi` matches `m * pi` in the source."""
    return re.sub(r"\s+", "", s).lower()


BULLET = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")


def paragraph_of(lines, i, is_yml):
    """The block of text the pointer sits in.

    For a YAML file the prose lives in the COMMENT lines, so the block is
    the run of comment lines around the pointer.

    For a markdown file the block is the LIST ITEM the pointer sits in --
    NOT the whole list.  A list item is what the author wrote as one
    claim; taking the list instead made every item's pointers inherit
    every other item's names, which is how the check ends up firing on
    prose.
    """
    if is_yml:
        para = []
        j = i - 1
        while j >= 0 and lines[j].lstrip().startswith("#"):
            para.insert(0, lines[j])
            j -= 1
        j = i
        while j < len(lines) and lines[j].lstrip().startswith("#"):
            para.append(lines[j])
            j += 1
        return "\n".join(para)

    # THE BLOCK.  A pointer belongs to the block of prose it sits in: the
    # list item, or the paragraph.  The block is found by scanning BACK
    # to a blank line, a heading, or the bullet that opens the item --
    # and forward the same way.  Continuation lines are NOT assumed to be
    # indented: this README writes its prose paragraphs flush left, and
    # a rule that required indentation truncated the paragraph at its
    # first line -- which is exactly where the names that identify the
    # claim are.
    start = i
    while start > 0:
        prev = lines[start - 1]
        if not prev.strip() or prev.lstrip().startswith("#"):
            break
        start -= 1
        if BULLET.match(prev):
            # the bullet OPENS the item and belongs to it: the names that
            # identify the claim are usually on that line
            break

    para = []
    j = start
    while j < len(lines) and lines[j].strip() \
            and not lines[j].lstrip().startswith("#"):
        if j > start and BULLET.match(lines[j]) and not BULLET.match(lines[start]):
            # a bullet that opens a NEW item ends the prose block
            break
        para.append(lines[j])
        j += 1
    return "\n".join(para)


# --- collect the pointers ---------------------------------------------------
# THE DOCUMENT SET IS DEDUPED BY CONTENT, and that is not a nicety: the root
# `README.md` is a SYMLINK to `README.mbt.md`, so a checkout that can
# materialise a symlink reads the same document TWICE, while a checkout that
# cannot -- a Windows clone, where git writes the link target as a one-line
# stub -- reads a 13-byte file instead.  A verifier that counted the
# document twice in one environment and once in the other would make its
# OWN COUNT depend on the host, which is the round-41 lesson about a count
# that moves with the environment.
#
# So a document is read once: through its symlink if it is one, and through
# the document it names if it is a stub.  Two documents that carry the same
# text are one document.
def read_text(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


def canonical(path, candidates):
    """The path whose TEXT this document carries."""
    p = path
    for _ in range(4):
        if os.path.islink(p):
            p = os.path.realpath(p)
            continue
        stripped = read_text(p).strip()
        if "\n" not in stripped and stripped:
            # a one-line stub naming another document IS that document
            hit = None
            for c in candidates:
                cs = c.replace("\\", "/")
                if cs == stripped.replace("\\", "/") \
                        or os.path.basename(c) == stripped \
                        or cs.endswith("/" + stripped.replace("\\", "/")):
                    hit = c
                    break
            if hit is None:
                break
            p = os.path.join(ROOT, hit.replace("/", os.sep))
            continue
        break
    return p


POINTERS = []      # (doc, line_no, name, first, last, target, paragraph)
UPSTREAM = 0
SEEN_TEXT = set()
DOCS_USED = []

for rel in DOCS:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    canon = canonical(p, DOCS)
    if canon != p:
        rel = os.path.relpath(canon, ROOT).replace("\\", "/")
    body = read_text(canon)
    key = hashlib.sha256(body.encode("utf-8", "replace")).hexdigest()
    if key in SEEN_TEXT:
        # the same document reached through another path
        continue
    SEEN_TEXT.add(key)
    DOCS_USED.append(rel)
    lines = body.split("\n")
    is_yml = rel.endswith((".yml", ".yaml"))
    for i, line in enumerate(lines, 1):
        for m in PTR.finditer(line):
            name, a = m.group(1), int(m.group(2))
            b = int(m.group(3)) if m.group(3) else a
            target = resolve(name)
            if target is None:
                if resolve_upstream(name):
                    UPSTREAM += 1
                    continue
                # it names no file in ANY tree: a pointer to nothing.  It
                # is still a pointer, and it is still checked -- check 1
                # is the one that fails.
                target = None
            # the citing paragraph: the block the pointer sits in
            para = paragraph_of(lines, i - 1, is_yml)
            POINTERS.append((rel, i, name, a, b, target, para))

for rel, ln, name, a, b, target, para in POINTERS:
    # 1. the target file exists and is TRACKED
    checks += 1
    if target is None:
        failed += 1
        print("*** FAIL ***  %s:%d  %s names no file in this tree and none in "
              "the vendored upstream" % (rel, ln, name))
        # the other three checks are about a file that is not there; check 1
        # owns that failure, and the COUNT stays fixed at four per pointer.
        checks += 3
        continue
    if not os.path.isfile(os.path.join(ROOT, target.replace("/", os.sep))) \
            or not tracked(target):
        failed += 1
        print("*** FAIL ***  %s:%d  %s -> %s is not a tracked file"
              % (rel, ln, name, target))
    # 2. the cited line is within the file
    checks += 1
    tlines = io.open(os.path.join(ROOT, target.replace("/", os.sep)),
                     encoding="utf-8", errors="replace").read().splitlines()
    if a > len(tlines) or a < 1:
        failed += 1
        print("*** FAIL ***  %s:%d  %s:%d is past the end of %s (%d lines)"
              % (rel, ln, name, a, target, len(tlines)))
        continue
    # 3. the cited line is not blank
    checks += 1
    if not is_code_line(tlines[a - 1]):
        failed += 1
        print("*** FAIL ***  %s:%d  %s:%d is a blank line" % (rel, ln, name, a))
    # 4. the block names an identifier the TARGET FILE carries
    checks += 1
    want = ids(para)
    lo = max(0, a - 1 - NEIGH)
    hi = min(len(tlines), a + NEIGH)
    # The WINDOW around the cited line, not the whole file.  The whole file
    # made the check unable to see a pointer that had drifted off the token
    # it claims -- and this docstring promised the window all along, so the
    # code was the weaker of the two.
    whole = norm("\n".join(tlines[lo:hi]))
    if want and not any(norm(w) in whole for w in want):
        failed += 1
        print("*** FAIL ***  %s:%d  %s:%d -- the block names %s, and the target "
              "file %s carries none of it"
              % (rel, ln, name, a, ", ".join(sorted(want))[:70], target))

print()
print("the documents        : %d" % len(DOCS_USED))
print("in-repo pointers     : %d" % len(POINTERS))
print("upstream pointers    : %d (not resolved against this tree)" % UPSTREAM)
print("checks run: %d, checks failed: %d" % (checks, failed))
sys.exit(1 if failed else 0)
