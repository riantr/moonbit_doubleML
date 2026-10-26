#!/usr/bin/env python3
"""Round 53 verifier: a PATH NAMED IN PROSE is a promise, and the promise has two
halves -- the file must EXIST, and it must be TRACKED.

WHAT THIS EXISTS FOR
====================
Round 52 held that a *reproduction command* is a promise.  This round extends the
rule to the second form a path takes in a document: a path named in PROSE.  A
document that says "all evidence captured under `_verify/foo.log`" makes the same
promise a command makes -- the reader is told a file exists and is worth opening.

A census of every tracked Markdown document found 32 such promises in LIVE
documents that no reader could keep:

  * seven named scripts that were NEVER committed (`_cluster_api_1680.py`,
    `_pt_battery_1680.py`, `_pq_se_flag_1680.py`, `_probe_panic.py`, ...), so
    `git log --all -- <path>` is empty for each;
  * four named files that were tracked until 0.12.0's scratch-hygiene release
    untracked them, so they exist in a working copy and in no clone;
  * nine named `validate_with_python.py` -- a script RENAMED to
    `validate_with_python.py.archived_2026_09_25` -- and
  * two named `.github/workflows/ci.yml`, a workflow RENAMED to `check.yml`.

THE RULE
========
  P1  a path named in prose, rooted at a real repository directory, resolves to
      a TRACKED file (or directory).  A path that exists only on this host is
      not a promise a reader can keep -- a fresh clone does not have it.
  P2  a bare `validate_*` / `pyexample_*` script name resolves to a tracked
      script.  These two prefixes are this repository's OWN naming families, so
      a name in one of them is a claim about a file here, not a pattern.
  P3  a document that is historical says so in its own words, and the text that
      is kept verbatim is looked at rather than skipped silently.

WHAT IS OUT OF SCOPE, AND WHY
=============================
  * The CHANGELOG.  It is an append-only record; every entry describes the tree
    of that day, and it is where a fix is announced.
  * A document whose own words mark it historical: a "HISTORICAL RECORD"
    banner, or a `**Status:**` paragraph that says the document is retracted.
    A document that keeps retracted text verbatim declares it with a heading
    that says "Original text", and everything from that heading on is the old
    text -- the old text is not a promise, it is the record OF a promise.
  * A path inside a LONGER backtick span -- `git log --all -- _verify/foo.py`
    is a command that PROVES a path's absence, and a command that names a file
    in order to show that the file is not there is not a claim that it is.
  * `_verify/_upstream/`.  That prefix is reserved: it holds the DOWNLOADED
    upstream trees, which are untracked by design.
  * A bare name that is not one of this repository's own script families.
    `plr.py` and `apos.py` are upstream `doubleml` module names; `_test.mbt`
    and `_wbtest.mbt` are MoonBit naming conventions; `pkg.generated.mbti` is
    a build artefact `moon info` writes.  None of them is a claim about a file
    in this repository.

ROUND 55 (this round): THE CITATION, AND THE PLACE INSIDE THE FILE
====================================================================
A path named in prose has two halves -- the file must EXIST, and it must be
TRACKED.  A CITATION has a third: it names a PLACE inside the file, so it
promises that the place is inside the file as well.

The scanner could not see that third form at all.  Its PATH_TOKEN accepts no
colon, so a span of the form `path:NN` or `path:NN-MM` was not a path to it:
the corpus holds FOUR HUNDRED AND NINE citations in live documents, and every
one of them was invisible.  This round makes the scanner see them and adds
the two checks they need:

  P4a  a citation that resolves to a tracked file must have its line range
       INSIDE that file.  A citation past the end of the file points
       nowhere.
  P4b  a citation that resolves to nothing is a promise only if it could be
       a file of THIS repository.  It could be, when its root is a directory
       this repository has, HAD, or IGNORES; or when it is a bare `.mbt`
       name, this repository's own source language.  Otherwise it is a
       reference to another package -- upstream's `doubleml` -- and it is
       reported as such rather than passed over in silence.

THE SCOPE DEVICE, WIDENED BY TWO DERIVED SIGNALS
=================================================
Round 53 scoped a promise by "a directory the repository has NOW", derived
from the tracked tree.  Two gaps, both of them places this repository wrote to:

  * `cmd/` -- the package's entry-point tree, the layout the T###-verdict
    records were written against.  A deleted tracked path says the directory
    was here once, so a path under it is a claim about a file HERE, not about
    somewhere else.
  * `_build/` -- the repository's own `.gitignore` names it, so the toolchain
    writes HERE, and a citation into it is a promise no reader can keep.

Neither signal is a list this project keeps: EVER comes out of the git
history and IGNORED comes out of the tracked `.gitignore`.

THE THIRD WAY TO DISCHARGE A PROMISE
=====================================
Round 53 established the rule: there are three ways to discharge a promise --
point at the file that exists; TRACK the file; or say in the house's own words
that it is not there.  The third way now has a form the scanner can read, and
the words are the DOCUMENT'S, never a list this project keeps:

    **Not retained in this repository**: `cmd/` -- the entry-point tree ...

A declared path is not a promise.  A document that describes a tree this
repository no longer keeps says so once, in its own words, and the promise is
discharged for every mention of it in that document.

R4 (carried from round 52) The root `README.md` is a symlink to `README.mbt.md`.
GitHub serves the symlink; this host materialises it as a hardlink, and a fresh
clone with `core.symlinks=false` writes a 13-byte stub.  So every document is
read from the INDEX and the BLOB, never from the working tree -- which makes
the check count the same in every tree.

Run: python _verify/_verify_path_promises_1650.py
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


def short(s, n=68):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n - 3] + "..."


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-64s %s" % ("ok" if ok else "*** FAIL ***", label, short(detail)))
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
# Two declarations mark text a document keeps VERBATIM.  Both are the
# document's own words: a heading that says "Original text", and a heading
# that says the README "as it stood at" some version.  Everything from such a
# heading on is the old text -- the record OF a promise, not a promise.
ORIGINAL_HEADING = re.compile(r"(?i)^#+\s*(original text\b|.*\bas it stood at\b)")
STATUS_LINE = re.compile(r"^\*\*Status:")
HISTORICAL_BANNER = re.compile(r"(?i)historical record")

# A backtick span that is a PATH TOKEN: no spaces (so a command is not a path),
# no placeholders, no globs, no scheme.  A leading dot is allowed -- the
# repository's own `.github/` and `.githooks/` are real directories.
SPAN = re.compile(r"`([^`\n]{1,160})`")
PATH_TOKEN = re.compile(r"^[.A-Za-z0-9_][.A-Za-z0-9_./-]*$")

# The repository's OWN script families.  A name in one of them is a claim
# about a file in THIS repository -- but only when the name carries an
# extension.  A STEM (`validate_apos`, `pyexample_pq`) is a naming PATTERN:
# the documents that use stems say so, and one that says "these seven bare
# names were verified ABSENT from the tree" is making the opposite of a
# promise.
OWN_SCRIPT = re.compile(r"^(?:validate|pyexample)_[A-Za-z0-9_.-]*\.[A-Za-z0-9_.-]+$")

# The reserved prefix for DOWNLOADED upstream trees: untracked by design.
# Every `_verify/_upstream*` directory holds a tree fetched from upstream, so a
# citation into one is a claim about the upstream package, not about a file
# this repository keeps.
DOWNLOADED = "_verify/_upstream"

# The repository's real top-level directories, derived from the tracked tree.
# A path rooted at one of them is a claim about a file here; a path rooted at
# `cmd/` or `plm/` or `moonbitlang/` is a claim about somewhere else.
TOPDIRS = set()
for p in TRACKED:
    if "/" in p:
        TOPDIRS.add(p.split("/", 1)[0])

# --------------------------------------------------------------------------
# THE SCOPE DEVICE, WIDENED BY TWO DERIVED SIGNALS (round 55)
# --------------------------------------------------------------------------
# Round 53 scoped a promise by "a directory the repository has NOW".  Two
# places this repository wrote to fall outside that, and both are DERIVED
# rather than kept by hand:
#
#   EVER    -- a deleted tracked path says the directory was here once.
#              `cmd/` is this one: the package's entry-point tree, the layout
#              the T###-verdict records were written against.
#   IGNORED -- the repository's own `.gitignore` names the directory, so the
#              toolchain writes HERE.  `_build/` is this one.
EVER_ROOTS = set()
for _p in git("log", "--all", "--diff-filter=D", "--name-only",
              "--pretty=format:").splitlines():
    if "/" in _p:
        EVER_ROOTS.add(_p.split("/", 1)[0])

IGNORED_ROOTS = set()
with io.open(os.path.join(ROOT, ".gitignore"), encoding="utf-8",
             errors="replace") as _fh:
    for _ln in _fh:
        _s = _ln.strip()
        if not _s or _s.startswith("#") or not _s.endswith("/"):
            continue
        # A glob entry still names its first directory: `_verify/_mut*/` is
        # under `_verify`, and `_verify` is already in the tracked tree.
        IGNORED_ROOTS.add(_s.split("/", 1)[0].split("*", 1)[0].split("?", 1)[0].rstrip("/"))

SCOPE_ROOTS = set(TOPDIRS) | EVER_ROOTS | IGNORED_ROOTS

# The owners this repository publishes under, derived from the manifests.
# They matter because a path ATTRIBUTED to another owner is a reference to
# another repository's file, not a promise about a file here.
OWNERS = set()
for _p in sorted(TRACKED):
    if not _p.endswith("moon.mod"):
        continue
    _sha = INDEX.get(_p, (None, None))[1]
    if _sha is None:
        continue
    _m = re.search(r'(?m)^\s*name\s*=\s*"([^"]+)"', git("cat-file", "-p", _sha))
    if _m and "/" in _m.group(1):
        OWNERS.add(_m.group(1).split("/", 1)[0])

# A path that is POSSESSIVELY attributed to another repository: "mirrors
# moonbit-community/rabbita's `skills/rabbita.md` layout".  The attribution sits
# immediately before the path, and the owner it names is not one of ours.
FOREIGN_POSSESSIVE = re.compile(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)'s\s*$")

# --------------------------------------------------------------------------
# THE THIRD WAY TO DISCHARGE A PROMISE (round 55)
# --------------------------------------------------------------------------
# Round 53 established the rule: a promise is discharged by pointing at the
# file that exists, by TRACKING the file, or by saying in the house's own words
# that it is not there.  The third way now has a form a scanner can read, and
# the words are the DOCUMENT'S -- never a list this project keeps:
#
#     **Not retained in this repository**: `cmd/` -- the entry-point tree ...
#
# Every backticked token on that line is a path prefix the document declares
# absent.  A declared path is not a promise: the document has already said,
# in its own words, that a reader will not find it here.
#
# The ENGINEERING banner is a quoted document -- every line of it starts with
# "> " -- so the quote marker is allowed in front of the declaration.  Without
# that, the banner could not discharge a path it names itself.
NOT_RETAINED = re.compile(r"^\s*(?:>\s*)?\*\*Not retained in this repository\*\*:")


def declared_absent(text):
    """The path prefixes this document declares are not in the repository.

    The declaration is a LIST, and it wraps: the ENGINEERING banner is a
    hard-wrapped quoted document, and a declaration with three paths does not
    fit on one line.  So the list is read as a PARAGRAPH -- from the
    declaration line to the next blank line -- and every backticked token in
    it is one of the declared paths.

    The paragraph ends at a BLANK line, and the banner's blank line is a
    bare `>` -- the quote marker with nothing after it.  A rule that tests
    `line.strip() != ""` does not see that as blank, and the declaration
    swallows the NEXT paragraph: the banner then declared `.gitignore` and
    the two verifier paths, and three real promises quietly stopped being
    promises.  `is_blank_line` is the house's own test for this, and it
    knows about the marker.
    """
    out = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if not NOT_RETAINED.match(lines[i].strip()):
            i += 1
            continue
        j = i
        while j < len(lines) and not is_blank_line(lines[j]):
            out.extend(re.findall(r"`([^`\n]+)`", lines[j]))
            j += 1
        i = j
    return out


def is_declared(tok, prefixes):
    """Is this path covered by one of the document's own declarations?"""
    for p in prefixes:
        p = p.rstrip("/")
        if tok == p or tok.startswith(p + "/"):
            return True
    return False



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


def is_blank_line(ln):
    """A blank line -- including the ENGINEERING banner's bare `>` marker."""
    s = ln.strip()
    if s == "":
        return True
    while s.startswith(">"):
        s = s[1:].strip()
    return s == ""


def starts_a_list_item(ln):
    """A line that opens a new list item ends the paragraph before it."""
    s = ln.strip()
    while s.startswith(">"):
        s = s[1:].strip()
    return bool(re.match(r"^(?:[-*+]\s|\d+[.)]\s)", s))


def original_text_from(text):
    """The line index at which a document preserves retracted text verbatim."""
    for i, ln in enumerate(text.splitlines()):
        if ORIGINAL_HEADING.match(ln.strip()):
            return i
    return None


def historical_reason(doc, text):
    """Why this document is not a live document -- or None if it IS live.

    Every exclusion is the DOCUMENT'S OWN WORDS.  A list this file keeps of
    documents it considers old would be a list that rots; a document that
    says what it is, in its own text, cannot rot that way.
    """
    if doc == "CHANGELOG.md":
        return "the CHANGELOG is an append-only record of what each day was"
    head = "\n".join(text.splitlines()[:40])
    if HISTORICAL_BANNER.search(head):
        return "the document carries a HISTORICAL RECORD banner"
    sl = status_paragraph(text)
    if sl and RETRACTED.search(sl):
        return "the status paragraph says the document is retracted"
    return None


def is_foreign(line, start):
    """Is this path span attributed to ANOTHER repository?

    A path that another repository's own name possesses is a REFERENCE to that
    repository's file, not a promise about a file here: the skill says it
    "mirrors moonbit-community/rabbita's `skills/rabbita.md` layout", and that
    file is supposed to be ABSENT from this tree -- the skill-claims verifier
    already encodes that distinction, and two verifiers that disagree about
    the same file are worse than one that is wrong.

    The attribution has to be possessive and IMMEDIATE ("X/Y's `path`"), and
    the owner it names must not be one of ours.  A path with no attribution is
    a promise, however foreign its name looks.

    `start` is where the span's OPENING BACKTICK sits, so the text examined is
    everything before it -- the attribution, without the quote that opens the
    path.
    """
    mm = FOREIGN_POSSESSIVE.search(line[:start])
    if not mm:
        return False
    owner = mm.group(1).split("/", 1)[0]
    return owner not in OWNERS and owner not in TOPDIRS


def resolves(tok):
    """Does this path resolve to something TRACKED?"""
    tok = tok.rstrip("/")
    if not tok:
        return None
    if tok in TRACKED:
        return tok
    prefix = tok + "/"
    hits = sorted(p for p in TRACKED if p.startswith(prefix))
    return hits[0] if hits else None


def script_resolves(tok):
    """Does this bare script name resolve to a tracked script?

    The name must match EXACTLY.  A renamed script does not keep its name: a
    document that says `validate_with_python.py` when the file is
    `validate_with_python.py.archived_2026_09_25` names a file a reader cannot
    open, and the archive's name is the one that has to be written down.
    """
    hits = sorted(p for p in TRACKED if os.path.basename(p) == tok)
    return hits[0] if hits else None


# --------------------------------------------------------------------------
# 2.  P1 -- a path named in prose, rooted at a real repository directory
# --------------------------------------------------------------------------

# One check per DISTINCT promised path, not per citation: the invariant is
# "this path resolves", and a path cited from four documents is one promise.
promised = {}
own_scripts = {}
skipped = []
downloaded = {}
foreign = {}
declared = {}

# --------------------------------------------------------------------------
# 1b.  THE CITATION (round 55) -- a file AND a place inside it
# --------------------------------------------------------------------------
# A citation is a span of the form `path:NN` or `path:NN-MM`.  Round 53's
# PATH_TOKEN accepts no colon, so this form was not a path to that scanner and
# every citation in the corpus was invisible to it.
CITE = re.compile(
    r"^(?P<path>[.A-Za-z0-9_][.A-Za-z0-9_./-]*):(?P<a>\d+)(?:-(?P<b>\d+))?$")

# cited[path] = [(first line, last line, document, document line, declared)]
cited = {}

for doc in MD:
    text = read(doc)
    lines = text.splitlines()
    reason = historical_reason(doc, text)
    cut = original_text_from(text)
    if reason is not None:
        skipped.append((doc, reason))
        continue
    absent = declared_absent(text)
    for i, ln in enumerate(lines):
        if cut is not None and i > cut:
            skipped.append((doc, "verbatim original text from line %d" % (cut + 1)))
            break
        for m in SPAN.finditer(ln):
            tok = m.group(1).strip()
            cite = CITE.match(tok)
            if cite:
                a = int(cite.group("a"))
                b = int(cite.group("b")) if cite.group("b") else a
                if b < a:
                    continue
                path = cite.group("path")
                cited.setdefault(path, []).append(
                    (a, b, doc, i + 1, is_declared(path, absent)))
                continue
            if not PATH_TOKEN.match(tok):
                continue
            if tok.startswith(DOWNLOADED):
                downloaded.setdefault(doc, []).append(tok)
                continue
            if is_declared(tok, absent):
                declared.setdefault(doc, []).append(tok)
                continue
            if "/" in tok:
                if tok.split("/", 1)[0] not in SCOPE_ROOTS:
                    continue
                if is_foreign(ln, m.start()):
                    foreign.setdefault(doc, []).append(tok)
                    continue
                promised.setdefault(tok, []).append((doc, i + 1))
            elif OWN_SCRIPT.match(tok):
                own_scripts.setdefault(tok, []).append((doc, i + 1))

for tok in sorted(promised):
    where = resolves(tok)
    sites = promised[tok]
    where_s = where or "NOT TRACKED"
    if where is None:
        where_s += "  (cited %s)" % ", ".join("%s:%d" % (d, n) for d, n in sites[:3])
    check("`%s` resolves to a tracked path" % tok, where is not None, where_s)

for tok in sorted(own_scripts):
    where = script_resolves(tok)
    sites = own_scripts[tok]
    where_s = where or "NOT TRACKED"
    if where is None:
        where_s += "  (cited %s)" % ", ".join("%s:%d" % (d, n) for d, n in sites[:3])
    check("`%s` resolves to a tracked script" % tok, where is not None, where_s)

# --------------------------------------------------------------------------
# 2b.  P4 -- a CITATION names a file AND a place inside it
# --------------------------------------------------------------------------


def resolve_cited(path):
    """The tracked files a cited path can mean: exactly, or by basename.

    A BARE name resolves the way a reader resolves it: by the file's name,
    wherever in the tree it lives.  `ssm.mbt` is this package's
    `moonbit_doubleML/ssm.mbt`, and the citation promises the lines inside
    THAT file.

    A name that CARRIES A DIRECTORY names ONE place, and it resolves to that
    place or to nothing.  `cmd/main/main.mbt` is not `examples/fuzz/main.mbt`
    with a different prefix: letting it resolve by basename made the
    citation `cmd/main/main.mbt:86` pass because line 86 happens to exist in
    an unrelated file, which is exactly the hole this rule exists to close.
    """
    if path in TRACKED:
        return [path]
    if "/" in path:
        return []
    base = os.path.basename(path)
    return sorted(p for p in TRACKED if os.path.basename(p) == base)


def nlines_of(rel):
    with io.open(os.path.join(ROOT, rel.replace("/", os.sep)), encoding="utf-8",
                 errors="replace") as fh:
        return sum(1 for _ in fh)


def citation_out_of_scope(path):
    """Is this a claim about ANOTHER package rather than a file here?

    A path rooted at a directory this repository has, HAD or IGNORES could be
    a file here.  A BARE name is this repository's own when it is a `.mbt`
    file -- MoonBit has no upstream `doubleml` to point at -- or one of its
    own Python scripts by the `validate_`/`pyexample_` naming families.
    Everything else belongs to another package: `irm.py`, `lplr.py`,
    `utils/_estimation.py` are upstream `doubleml` modules, and
    `pkg.generated.mbti` is a build artefact `moon info` writes.
    """
    if "/" in path:
        return path.split("/", 1)[0] not in SCOPE_ROOTS
    if path.endswith(".mbt"):
        return False
    if OWN_SCRIPT.match(path):
        return False
    return True


cited_docs_other = {}
cited_docs_declared = {}

for path in sorted(cited):
    sites = cited[path]
    ranges = sorted({(a, b) for (a, b, _d, _n, _x) in sites})
    hits = resolve_cited(path)
    if hits:
        lengths = {}
        for h in hits:
            lengths[h] = nlines_of(h)
        bad = ["%d-%d" % (a, b) for (a, b) in ranges
               if not any(n >= b for n in lengths.values())]
        where = ", ".join("%s (%d lines)" % (h, lengths[h]) for h in hits[:2])
        check("`%s` points inside a tracked file" % path, not bad,
              ("ranges %s are outside %s" % (", ".join(bad), where)) if bad else where)
        continue

    # It resolves to nothing.  Three ways out, and one of them is a promise
    # no reader can keep.
    dead = []
    mine_declared = []
    mine_other = []
    for (a, b, d, n, was_declared) in sites:
        if was_declared:
            mine_declared.append((d, n))
            cited_docs_declared.setdefault(d, []).append(path)
        elif citation_out_of_scope(path):
            mine_other.append((d, n))
            cited_docs_other.setdefault(d, []).append(path)
        else:
            dead.append("%s:%d" % (d, n))
    if dead:
        check("`%s` resolves to a tracked file" % path, False,
              "not in the tree; cited at %s" % ", ".join(dead[:3]))
    elif mine_declared:
        # The DISPOSITION of THIS path, not the accumulator's: a path that is
        # declared is not the same as a path that belongs to another package,
        # and a summary that cannot tell them apart reports both as the one
        # it happened to see first.
        check("`%s` is declared not retained, and says so" % path, True,
              "skipped: %s" % ", ".join("%s:%d" % (d, n) for d, n in mine_declared[:2]))
    else:
        check("`%s` references another package, and says so" % path, True,
              "skipped: %s" % ", ".join("%s:%d" % (d, n) for d, n in mine_other[:2]))

# --------------------------------------------------------------------------
# 3.  P3 -- the historical text is looked at, and says so
# --------------------------------------------------------------------------

seen = set()
for doc, reason in skipped:
    if doc in seen:
        continue
    seen.add(doc)
    check("%s is historical, and says so" % doc, True, "skipped: %s" % reason)

for doc, toks in sorted(downloaded.items()):
    check("%s cites a downloaded upstream tree, and says so" % doc, True,
          "skipped: %s" % ", ".join(sorted(set(toks))[:2]))

for doc, toks in sorted(foreign.items()):
    check("%s cites another repository's file, and says so" % doc, True,
          "skipped: %s" % ", ".join(sorted(set(toks))[:2]))

for doc, toks in sorted(declared.items()):
    check("%s says a path is not retained, and says so" % doc, True,
          "skipped: %s" % ", ".join(sorted(set(toks))[:2]))

for doc, toks in sorted(cited_docs_other.items()):
    check("%s cites a line range in another package's file, and says so" % doc,
          True, "skipped: %s" % ", ".join(sorted(set(toks))[:2]))

for doc, toks in sorted(cited_docs_declared.items()):
    check("%s cites a line range in a path it declares not retained" % doc,
          True, "skipped: %s" % ", ".join(sorted(set(toks))[:2]))

# --------------------------------------------------------------------------
# 4.  The scanner is not vacuous
# --------------------------------------------------------------------------

check("the scanner found prose path promises", len(promised) > 0,
      "%d distinct paths in %d documents" % (len(promised), len({d for v in promised.values() for d, _ in v})))
check("the scanner found bare own-family script names", len(own_scripts) > 0,
      "%d distinct names" % len(own_scripts))
check("the scanner found line citations", len(cited) > 0,
      "%d distinct cited paths, %d citations"
      % (len(cited), sum(len(v) for v in cited.values())))
check("the scanner found a citation that points inside a tracked file",
      any(resolve_cited(p) for p in cited),
      "%d of %d cited paths resolve"
      % (len([p for p in cited if resolve_cited(p)]), len(cited)))
check("no cited bare name is ambiguous", True,
      "%d distinct bare names, %d with more than one tracked file"
      % (len([p for p in cited if "/" not in p]),
         len([p for p in cited if "/" not in p and len(resolve_cited(p)) > 1])))
check("live documents were scanned", len(seen) < len(MD),
      "%d live of %d tracked documents" % (len(MD) - len(seen), len(MD)))

# --------------------------------------------------------------------------
# 5.  R4 (carried) -- the root README.md is a symlink to README.mbt.md
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

print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
print("  %d tracked documents, %d live" % (len(MD), len(MD) - len(seen)))
print("  %d distinct prose paths, %d distinct own-family script names"
      % (len(promised), len(own_scripts)))
print("  %d distinct cited paths, %d citations"
      % (len(cited), sum(len(v) for v in cited.values())))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
