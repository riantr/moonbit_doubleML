#!/usr/bin/env python3
"""Round 76 verifier: the UPSTREAM `file:line` pointers, resolved.

THE PROBLEM
===========
The house verifier `_verify/_verify_file_line_refs_1650.py` checks every
`file:line` pointer in the documents a reader is pointed at.  Its own
docstring says, in so many words, that UPSTREAM Python pointers are a
different class:

    Pointers that name an UPSTREAM Python module (`irm.py:157`, `pq.py:378`,
    `lplr.py:401-418`) are a different class -- they name a file in the
    vendored upstream tree, not in this repository -- and they are counted
    and reported, but they are not resolved against this tree.

So: 37 upstream pointers, and not one of them was ever resolved.  That
matters because upstream MOVED.  Round 75 re-anchored this repository from
upstream 0.11.3 to 0.11.4, and upstream's own line numbers move with its
releases.  A pointer that says "go to `plm/lplr.py:326` and you will find
the Newton start value" is a promise about a file that lives in somebody
else's repository -- and nobody was keeping it.

There is a second gap, and it is the same one from the other side.  The
records the README NAMES -- `_verify/UPSTREAM_PROVENANCE.md` and
`_verify/LPLR_GATE_BLINDNESS_1680.md` -- are not in that verifier's scope
at all.  Between them they carry 34 of the 37 upstream pointers.  So the
records the README points at were doubly unchecked: their pointers were
upstream (unresolved) AND they were outside the scope that checks pointers.

THE RULE
========
  U1  the source of truth is upstream itself, and the SOURCE IS CHOSEN, not
      assumed: the pinned 0.11.4 sdist, else the tree named by
      DOUBLEML_UPSTREAM_TREE, else the INSTALLED `doubleml` package (CI
      installs it).  A source is accepted only when its version is one the
      cited records actually name in their headers -- so this check keeps
      measuring the release the records were written against instead of
      silently re-anchoring itself to whatever upstream shipped yesterday.
      With no source at all this is a reported SKIP, never a pass.
  U2  a pointer that names a PYTHON file which does not resolve in THIS
      repository is an UPSTREAM pointer.  The file type decides, because the
      vendored upstream trees under `_verify/` are DOWNLOADED copies: their
      absence cannot prove a pointer broken, and a rule that consulted them
      would fail in CI while passing in the working tree.
  U3  every upstream pointer must name a file upstream HAS, a line that is
      INSIDE that file, and a line that is not BLANK.
  U4  the cited line must land where the pointer says it does: the window
      around it must carry an identifier the citing paragraph names.  The
      identifier is matched as FRAGMENTS, because a code span is not always
      one identifier -- it can be an EXPRESSION
      (`root_scalar(score, x0=..., fprime=..., method="newton")`), and
      matching the span literally would make the check fire on its own
      quotes.
  U5  the "at lines 110, 445, 451, ..." form is the same promise written
      differently, and the house pointer regex does not see it at all (it
      wants a colon).  Every listed line must exist and be non-blank.

WHY THE WINDOW, AND WHY FRAGMENTS
=================================
The window is the house's own (25 lines around the citation), because it is
deliberately generous: a check that fires spuriously is worse than no check
at all, because a rule that cries wolf teaches its reader to ignore it.
The fragments are the same idea applied one level down.  Calibrated against
the whole population -- 37 upstream pointers in 16 documents -- this rule
fires on NOTHING, and the control arm below proves it fires on something
when something is wrong.

THE CONTROL ARM
================
A checker that has never been shown to fail is a comment.  Six synthetic
cases, and the rule has to get every one of them right -- four defects it
must CATCH, and two good pointers it must ACCEPT:
  C1  a pointer to a line past the end of the upstream file
  C2  a pointer to a file upstream does not have
  C3  a pointer whose cited line carries none of the named identifier
  C4  a "at lines" list naming a line past the end of the file
  C5  a paragraph naming an identifier upstream does not have ANYWHERE --
      that identifier belongs to the PORT, and saying so is not a broken
      promise
  C6  a well-formed pointer

Run: python _verify/_verify_upstream_line_refs_1680.py
"""
import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")

PTR = re.compile(r"`?([A-Za-z0-9_./-]+\.(?:mbt|md|py|yml|yaml|toml|json|mod|ps1))"
                 r":(\d+)(?:-(\d+))?`?")
LISTPTR = re.compile(r"`([A-Za-z0-9_./-]+\.py)`\s+at\s+lines\s+([\d,\s]+)")
NEIGH = 25
MINFRAG = 4

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %s  %-62s %s" % ("ok  " if ok else "*** FAIL ***", name, detail))
    if not ok:
        FAILS.append("%s -- %s" % (name, detail))


def read(p):
    with io.open(p, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def norm(s):
    return re.sub(r"\s+", "", s).lower()


def ids(text):
    """The identifiers the paragraph DELIBERATELY names (the house rule).

    Only CODE SPANS count.  POINTER-shaped spans are removed first: they
    name a FILE and a line, not a symbol in that file.
    """
    text = re.sub(r"[A-Za-z0-9_./-]+\.(?:mbt|md|py|yml|yaml|toml|json|mod|ps1)"
                  r":\d+(?:-\d+)?", " ", text)
    text = re.sub(r"[A-Za-z0-9_./-]+\.(?:mbt|md|py|yml|yaml|toml|json|mod|ps1)", " ", text)
    out = set()
    for tok in re.findall(r"`([^`\n]+)`", text):
        tok = tok.strip().strip(" .,:;()")
        if len(tok) < 3 or not re.search(r"[A-Za-z]", tok):
            continue
        out.add(tok.lower())
    return out


def fragments(token):
    """The identifier-ish fragments of a code span.

    `root_scalar(score, x0=..., fprime=..., method="newton")` names
    `root_scalar`, `score`, `fprime` and `newton` -- so the fragments are
    what the citation can be checked against, and a literal match against
    the whole span would fail on the ellipsis the author wrote on purpose.
    """
    out = set()
    for piece in re.split(r"[^A-Za-z0-9_]+", token):
        piece = piece.strip("_")
        if len(piece) >= MINFRAG and re.search(r"[A-Za-z]", piece):
            out.add(piece.lower())
    return out


BULLET = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")


def paragraph_of(lines, i, is_yml):
    """The block of prose the pointer sits in (the house rule)."""
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
    start = i
    while start > 0:
        prev = lines[start - 1]
        if not prev.strip() or prev.lstrip().startswith("#"):
            break
        start -= 1
        if BULLET.match(prev):
            break
    para = []
    j = start
    while j < len(lines) and lines[j].strip() and not lines[j].lstrip().startswith("#"):
        if j > start and BULLET.match(lines[j]) and not BULLET.match(lines[start]):
            break
        para.append(lines[j])
        j += 1
    return "\n".join(para)


SEARCH_ROOTS = ["moonbit_doubleML", "examples", "doc", "_verify", "skills", "."]


def resolve_repo(name):
    """Where does `foo.py` live in THIS repository?  First candidate wins."""
    for r in SEARCH_ROOTS:
        c = os.path.join(ROOT, r.replace("/", os.sep), name.replace("/", os.sep))
        if os.path.isfile(c):
            return os.path.relpath(c, ROOT).replace("\\", "/")
    return None


# --------------------------------------------------------------- the upstream source
class Source(object):
    """One upstream release, and the files it contains."""

    def __init__(self, kind, version, files):
        self.kind = kind
        self.version = version
        self.files = files          # relpath inside the package -> text

    def read(self, rel):
        return self.files.get(rel.replace("\\", "/"))


def from_sdist():
    """The pinned 0.11.4 sdist, if it is on disk.  It is a vendored upstream
    artefact and is deliberately NOT tracked, so its absence is a skip."""
    for base in (os.path.join(ROOT, "_verify"), ROOT):
        tar = os.path.join(base, "doubleml-0.11.4.tar.gz")
        if not os.path.isfile(tar):
            continue
        m = re.search(r"doubleml-(\d+\.\d+\.\d+)\.tar\.gz", tar)
        if not m:
            return None
        files = {}
        try:
            tf = tarfile.open(tar)
            for member in tf.getmembers():
                if not member.isfile() or not member.name.endswith(".py"):
                    continue
                parts = member.name.split("/")
                # doubleml-0.11.4/doubleml/irm/irm.py -> irm/irm.py
                if len(parts) < 3 or parts[1] != "doubleml":
                    continue
                rel = "/".join(parts[2:])
                fh = tf.extractfile(member)
                if fh is None:
                    continue
                files[rel] = fh.read().decode("utf-8", "replace")
            tf.close()
        except Exception:  # noqa: BLE001
            return None
        if files:
            return Source("the pinned 0.11.4 sdist", m.group(1), files)
    return None


def from_tree():
    """The tree the owner named, via DOUBLEML_UPSTREAM_TREE.

    The environment variable is the seam on purpose: a tracked file must not
    hard-code one developer's machine, and CI has no such tree anyway.
    """
    tree = os.environ.get("DOUBLEML_UPSTREAM_TREE")
    if not tree or not os.path.isdir(tree):
        return None
    pkg = os.path.join(tree, "doubleml")
    if not os.path.isdir(pkg):
        pkg = tree
    m = re.search(r"(\d+\.\d+\.\d+)", os.path.basename(os.path.abspath(tree)))
    version = m.group(1) if m else "unknown"
    files = {}
    for root, dirs, names in os.walk(pkg):
        if "__pycache__" in root:
            continue
        for f in names:
            if f.endswith(".py"):
                p = os.path.join(root, f)
                rel = os.path.relpath(p, pkg).replace("\\", "/")
                files[rel] = read(p)
    if files:
        return Source("the upstream tree at %s" % tree, version, files)
    return None


def from_installed():
    """The INSTALLED `doubleml` package.  CI installs it, so this is the
    source that works there."""
    try:
        import importlib.metadata
        import doubleml
    except Exception:  # noqa: BLE001
        return None
    try:
        version = importlib.metadata.version("doubleml")
    except Exception:  # noqa: BLE001
        version = "unknown"
    pkg = os.path.dirname(os.path.abspath(doubleml.__file__))
    files = {}
    for root, dirs, names in os.walk(pkg):
        if "__pycache__" in root:
            continue
        for f in names:
            if f.endswith(".py"):
                p = os.path.join(root, f)
                rel = os.path.relpath(p, pkg).replace("\\", "/")
                files[rel] = read(p)
    if files:
        return Source("the installed `doubleml` package", version, files)
    return None


# --------------------------------------------------------------- the document set
def canonical(path, candidates):
    """The path whose TEXT this document carries (the root README.md is a
    SYMLINK to README.mbt.md)."""
    p = path
    for _ in range(4):
        if os.path.islink(p):
            p = os.path.realpath(p)
            continue
        stripped = read(p).strip()
        if "\n" not in stripped and stripped:
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


def document_set():
    """Every document a reader is pointed at.

    The house scope (the README, the skill, the tutorials, the service's
    README, the CI files) PLUS the `_verify/*.md` records the README names
    -- which is the set the house verifier never covered.
    """
    docs = ["README.mbt.md", "README.md", "skills/moonbit_doubleML.md",
            "examples/api_server/README.md"]
    docdir = os.path.join(ROOT, "doc")
    if os.path.isdir(docdir):
        for d in sorted(os.listdir(docdir)):
            p = os.path.join("doc", d, "readme.mbt.md")
            if os.path.isfile(os.path.join(ROOT, p)):
                docs.append(p)
    wf = os.path.join(ROOT, ".github", "workflows")
    if os.path.isdir(wf):
        for d in sorted(os.listdir(wf)):
            docs.append(os.path.join(".github", "workflows", d))
    return docs


def cited_records():
    """The `_verify/*.md` records the published README names."""
    if not os.path.isfile(README):
        return []
    out = []
    for m in sorted(set(re.findall(r"_verify/[A-Za-z0-9_./-]+\.md", read(README)))):
        if os.path.isfile(os.path.join(ROOT, m.replace("/", os.sep))):
            out.append(m)
    return out


def header_versions(text):
    """The versions a record's leading blockquote names."""
    lines = text.split("\n")
    head = []
    started = False
    for line in lines:
        s = line.strip()
        if s.startswith(">"):
            started = True
            head.append(s)
            continue
        if started and not s:
            head.append("")
            continue
        if started:
            break
    return sorted(set(re.findall(r"\b\d+\.\d+\.\d+\b", "\n".join(head))))


# --------------------------------------------------------------- the checks
def upstream_pointer(name):
    """Is this an UPSTREAM pointer rather than a pointer into this tree?

    The house rule: the file type decides, because the vendored upstream
    trees are downloaded copies and their absence cannot prove a pointer
    broken.
    """
    if resolve_repo(name) is not None:
        return False
    return os.path.splitext(name)[1].lower() == ".py"


def audit_pointer(src, name, a, b, para, files):
    """The four checks for one upstream pointer.  Returns a list of problems."""
    problems = []
    # the file upstream must HAVE
    cands = [f for f in files if f == name or os.path.basename(f) == os.path.basename(name)]
    if not cands:
        return ["upstream has no file named %s" % name]
    rel = sorted(cands)[0]
    text = files[rel]
    tl = text.split("\n")
    # the cited line must be INSIDE the file
    if a < 1 or a > len(tl):
        problems.append("line %d is past the end of %s (%d lines)" % (a, rel, len(tl)))
        return problems
    if b > len(tl):
        problems.append("line %d is past the end of %s (%d lines)" % (b, rel, len(tl)))
        return problems
    # the cited line must not be BLANK
    if not tl[a - 1].strip():
        problems.append("line %d is blank in %s" % (a, rel))
        return problems
    # the cited line must LAND where the pointer says it does
    want = ids(para)
    frags = set()
    for t in want:
        frags |= fragments(t)
    # A name upstream does not have ANYWHERE is not evidence about upstream:
    # it is the PORT's name (the port calls it `_double_dml_cv_predict`, and
    # upstream calls it `_dml_cv_predict`), and saying what the port calls
    # something is not a broken promise.  Only names upstream HAS can say
    # anything about where upstream's line is.
    anywhere = norm(text)
    candidates = sorted(f for f in frags if norm(f) in anywhere)
    if candidates:
        lo = max(0, a - 1 - NEIGH)
        hi = min(len(tl), a + NEIGH)
        whole = norm("\n".join(tl[lo:hi]))
        hits = sorted(f for f in candidates if norm(f) in whole)
        if not hits:
            problems.append("the window around %s:%d carries none of %s"
                            % (name, a, ", ".join(candidates)[:60]))
    return problems


def audit_list(src, name, nums, files):
    """U5: the `at lines 110, 445, ...` form.

    The file is resolved against UPSTREAM first: the form is how a record
    writes "upstream's `did_cs.py` at lines 110, 445, ...".  This repository
    also carries a vendored copy of that file, so a name can resolve HERE --
    but the promise is about upstream's file, so upstream's is the one that
    has to answer.
    """
    problems = []
    cands = [f for f in files if f == name or os.path.basename(f) == os.path.basename(name)]
    if not cands:
        return None            # upstream does not have it: the caller's problem
    rel = sorted(cands)[0]
    tl = files[rel].split("\n")
    problems += line_problems(nums, tl, rel)
    return problems


def line_problems(nums, tl, label):
    """Every listed line must be inside the file and must not be blank."""
    problems = []
    for n in nums:
        if n < 1 or n > len(tl):
            problems.append("line %d is past the end of %s (%d lines)"
                            % (n, label, len(tl)))
        elif not tl[n - 1].strip():
            problems.append("line %d is blank in %s" % (n, label))
    return problems


# ================================================================== the run
print()
print("the upstream source")
src = from_sdist() or from_tree() or from_installed()
if src is None:
    print("SKIP: no upstream source is available here (no pinned sdist, no "
          "DOUBLEML_UPSTREAM_TREE, no installed `doubleml`).")
    print()
    print("=" * 74)
    print("%d checks, 0 failed" % N)
    sys.exit(0)

records = cited_records()
headers = set()
for rel in records:
    headers |= set(header_versions(read(os.path.join(ROOT, rel.replace("/", os.sep)))))
print("   %s  (version %s, %d python files)" % (src.kind, src.version, len(src.files)))

if src.version != "unknown" and headers and src.version not in headers:
    print("SKIP: this source is upstream %s, and the records the README names "
          "are anchored to %s.  A pointer check against a different release "
          "would measure the wrong thing."
          % (src.version, ", ".join(sorted(headers))))
    print()
    print("=" * 74)
    print("%d checks, 0 failed" % N)
    sys.exit(0)
print("   the records name: %s" % ", ".join(sorted(headers)))

DOCS = document_set()
used = []
seen = set()
for rel in DOCS + records:
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    body = read(p)
    key = hashlib.sha256(body.encode("utf-8", "replace")).hexdigest()
    if key in seen:
        continue
    seen.add(key)
    used.append((rel, p))

print()
print("the documents")
for rel, p in used:
    print("   %s" % rel)

N_UP = 0
N_LIST = 0
print()
print("A. the upstream pointers, resolved")
for rel, path in used:
    body = read(path)
    lines = body.split("\n")
    is_yml = rel.endswith((".yml", ".yaml"))
    for i, line in enumerate(lines, 1):
        for m in PTR.finditer(line):
            name, a = m.group(1), int(m.group(2))
            b = int(m.group(3)) if m.group(3) else a
            if not upstream_pointer(name):
                continue
            N_UP += 1
            para = paragraph_of(lines, i - 1, is_yml)
            problems = audit_pointer(src, name, a, b, para, src.files)
            for p in problems:
                print("   *** FAIL *** %s:%d  %s:%d -- %s" % (rel, i, name, a, p))
            check("%s:%d  %s:%d resolves upstream" % (rel, i, name, a),
                  not problems, "" if not problems else "%d problem(s)" % len(problems))
        for m in LISTPTR.finditer(line):
            name = m.group(1)
            nums = [int(x) for x in re.findall(r"\d+", m.group(2))]
            if not nums:
                continue
            N_LIST += 1
            problems = audit_list(src, name, nums, src.files)
            if problems is None:
                # upstream does not have that file: it is a pointer into THIS
                # repository, and the house rule does not see this form, so it
                # is checked here instead.
                repo_rel = resolve_repo(name)
                if repo_rel is None:
                    problems = ["names no file in this tree and none upstream"]
                else:
                    tl = read(os.path.join(ROOT, repo_rel.replace("/", os.sep))).split("\n")
                    problems = line_problems(nums, tl, repo_rel)
            for p in problems:
                print("   *** FAIL *** %s:%d  %s at lines %s -- %s"
                      % (rel, i, name, ",".join(str(n) for n in nums), p))
            check("%s:%d  %s at lines %s resolves"
                  % (rel, i, name, ",".join(str(n) for n in nums)),
                  not problems, "" if not problems else "%d problem(s)" % len(problems))

print()
print("   upstream pointers: %d   'at lines' lists: %d" % (N_UP, N_LIST))

# --------------------------------------------------------------- the control arm
print()
print("B. the control arm: synthetic defects, and what the rule does with them")
FAKE = {
    # a fake upstream file: the name the paragraph uses is at line 100, and
    # the cited line 5 carries something else.  That is what a citation that
    # has DRIFTED looks like.
    "plm/lplr.py": "\n".join(
        ["# an upstream file"] +
        ["    weights = M_hat[\"preds\"] * (1 - M_hat[\"preds\"])" if i == 5
         else ("    self._coef_start_val = np.average(beta)" if i == 100
               else "    filler %d" % i)
         for i in range(1, 301)]),
}
PARA = "the Newton start value is `np.average(beta)` at `plm/lplr.py:5`."
PARA_PORT_ONLY = "the port calls it `_double_dml_cv_predict` at `plm/lplr.py:5`."

check("C1 a pointer past the end of the upstream file is REJECTED",
      bool(audit_pointer(src, "plm/lplr.py", 9999, 9999, PARA, FAKE)),
      "the rule must catch it")
check("C2 a pointer to a file upstream does not have is REJECTED",
      bool(audit_pointer(src, "plm/nope.py", 5, 5, PARA, FAKE)),
      "the rule must catch it")
check("C3 a pointer whose line carries none of the named identifier is REJECTED",
      bool(audit_pointer(src, "plm/lplr.py", 5, 5, PARA, FAKE)),
      "the rule must catch it")
check("C4 an 'at lines' list naming a line past the end is REJECTED",
      bool(audit_list(src, "plm/lplr.py", [5, 9999], FAKE)),
      "the rule must catch it")
check("C5 a name that is the PORT's, not upstream's, is ACCEPTED",
      not audit_pointer(src, "plm/lplr.py", 5, 5, PARA_PORT_ONLY, FAKE),
      "saying what the port calls it is not a broken promise")
check("C6 a well-formed pointer is ACCEPTED",
      not audit_pointer(src, "plm/lplr.py", 100, 100, PARA, FAKE),
      "the rule must not fire on a good pointer")

print()
print("=" * 74)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
