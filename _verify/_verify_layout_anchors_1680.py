#!/usr/bin/env python3
"""Round 74: the tracked contract's PROSE ANCHORS, and whether they can see
the text they guard.

WHAT THIS EXISTS FOR
====================
On 2026-10-31 three checks died in one day, all for the same reason: they
matched a phrase in a document with LITERAL SPACES, and the README is
GENERATED -- its paragraphs are hard-wrapped in the builder, so an edit
anywhere near a phrase can move the line break and leave the anchor matching
NOTHING.

  * `_verify/_dryrun_round47_1650.py` -- its fifth anchor stopped matching
    after round 73 re-wrapped the upstream paragraph, and the driver ABORTED
    before it could apply its own mutation.  That one SHIPPED.
  * the round-73 pre-commit gate and committed-tree gate -- both reported a
    claim the README DOES make as absent, for the same reason.  Those two
    were scratch, and the release tail published over them because the tail
    driver recorded the failure and did not stop.

A check that cannot see the text it guards is worse than a check that fails
loudly: it reports GREEN while protecting nothing, and a stale number in the
README survives because the check that owns it is looking at a string that is
no longer there.

THE HOUSE RULE THIS ENFORCES
=============================
  A prose anchor must match WHITESPACE, not a layout.  A literal with spaces
  matched against the raw document is a promise about where the generator
  happened to break the line, not about what the document says.  The robust
  form is to read a whitespace-collapsed copy of the document and match the
  normalised phrase against it.

HOW THE CENSUS READS A CHECK
============================
The unit that matters is the COMPARISON -- one `literal in document` -- because
that is the thing whose verdict can change when the document is re-wrapped.
The BOOLEAN GROUP around it matters too, but only in one way: a group that
holds TWO literals of the SAME phrase in different wrappings accepts either,
so a re-wrap of one cannot break the group.  That is a deliberate safety net.

So each comparison is evaluated twice -- against the document as it stands
(RAW) and against the document with its whitespace collapsed (FLAT) -- and
the two verdicts are compared:

  DEAD     RAW says one thing, FLAT says the other, and RAW says "absent"
           where the text is there.  The check cries wolf: it goes RED over
           a claim that is true.  This is the failure above.
  BLIND    RAW says one thing, FLAT says the other, and RAW says "present"
           where the text is there.  The check reports GREEN while the text
           it guards is right there -- so it protects nothing.
  FRAGILE  RAW and FLAT agree, but the match is a coincidence of where the
           builder broke the line.  One edit away from DEAD or BLIND.
  SOUND    everything else.

WHAT IS NOT FRAGILE, AND WHY
============================
  * a literal that matches inside a FENCED CODE BLOCK -- a fence is emitted
    verbatim and is never re-wrapped;
  * a literal that matches inside INLINE CODE -- the builder never breaks
    inside backticks;
  * a literal that matches on a HEADING line -- a heading is one line by
    construction;
  * a literal that matches in the FROZEN part of ENGINEERING.md (the
    v0.164.11 snapshot the ledger carries) -- that body is never rewritten;
  * a group that holds TWO literals of the SAME phrase in different wrappings
    -- the group accepts either, which is a deliberate safety net;
  * a comparison that reads a WHITESPACE-COLLAPSED copy of the document --
    that is the robust form, by construction;
  * a literal of ONE word -- a re-wrap cannot put a break inside a word.

WHAT THE CENSUS CANNOT SEE
==========================
A comparison whose left-hand side is not a static literal -- a computed
string, a format, a name bound to something the census cannot resolve -- is
counted as UNCLASSIFIED and reported, so the numbers below are never read as
more than they are.

THE CONTROL ARM
===============
A census that cannot report a problem protects nothing.  So this verifier
builds verifiers OF ITS OWN -- synthetic sources with a DEAD anchor, a BLIND
anchor, a FRAGILE anchor and a robust anchor -- and asserts that the census
classifies each of them the way it must.  If that arm stops firing, the
census has stopped looking.

Run: python _verify/_verify_layout_anchors_1680.py
"""
import ast
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

# The documents the BUILDER writes, and the part of each it may re-wrap.
#   whole  -- the whole file is rewritten by the builder
#   banner -- only the banner above the marker is rewritten; the rest is the
#             frozen v0.164.11 snapshot the ledger carries
DOC_SPEC = [("README.mbt.md", "whole"), ("ENGINEERING.md", "banner")]
BANNER_CUT = "## The README as it stood at"

N = 0
FAILS = []


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %-70s %s" % (name[:70], "OK" if ok else "*** FAIL ***"))
    if not ok:
        FAILS.append(name)
        if detail:
            print("        %s" % detail)


def git_ls(path):
    p = subprocess.run(["git", "-C", ROOT, "ls-files", path],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return [l.strip() for l in (p.stdout or "").splitlines() if l.strip()]


def read(rel):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        return None
    return io.open(p, encoding="utf-8", errors="replace").read()


def norm(s):
    """Whitespace-normalised, so a phrase can span a line break."""
    return re.sub(r"\s+", " ", s)


# ---------------------------------------------------------------- the docs
DOC_NAMES = set()
DOCS = {}
for _rel, _mode in DOC_SPEC:
    _text = read(_rel)
    if _text is None:
        continue
    DOC_NAMES.add(os.path.basename(_rel))
    if _mode == "banner" and BANNER_CUT in _text:
        _cut = _text.index(BANNER_CUT)
    else:
        _cut = len(_text)
    DOCS[_rel] = {"text": _text, "cut": _cut}


# ------------------------------------------------------------- the helpers
DOC_READERS = {"read", "show", "open", "read_text", "text", "body", "doc"}


def is_flattening_call(node):
    """re.sub(r"\\s+", " ", x) -- the direct form."""
    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
        return False
    if node.func.attr != "sub":
        return False
    if not isinstance(node.func.value, ast.Name) or node.func.value.id != "re":
        return False
    if not node.args:
        return False
    a = node.args[0]
    return (isinstance(a, ast.Constant) and isinstance(a.value, str)
            and bool(re.search(r"\\s\+", a.value)))


def flattening_helpers(tree):
    """Names of module-level functions whose body collapses whitespace."""
    out = set()
    for node in tree.body:
        if not isinstance(node, ast.FunctionDef):
            continue
        for sub in ast.walk(node):
            if is_flattening_call(sub):
                out.add(node.name)
                break
    return out


def const_string(node, consts):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return consts.get(node.id)
    return None


def module_bindings(tree):
    """module-level string constants, and module-level lists of strings."""
    consts, lists = {}, {}
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        val = node.value
        cv = None
        if isinstance(val, ast.Constant) and isinstance(val.value, str):
            cv = val.value
        elif isinstance(val, ast.Call):
            parts = [b.value for b in val.args
                     if isinstance(b, ast.Constant) and isinstance(b.value, str)]
            if parts:
                cv = "/".join(parts)
        if cv is not None:
            for t in node.targets:
                if isinstance(t, ast.Name):
                    consts[t.id] = cv
            continue
        if isinstance(val, (ast.List, ast.Tuple)):
            items = [e.value for e in val.elts
                     if isinstance(e, ast.Constant) and isinstance(e.value, str)]
            if items and len(items) == len(val.elts):
                for t in node.targets:
                    if isinstance(t, ast.Name):
                        lists[t.id] = items
    return consts, lists


def basename_doc(s):
    if not s:
        return None
    b = os.path.basename(s.replace("\\", "/"))
    return b if b in DOC_NAMES else None


def doc_path_of(node, consts):
    """The document a call reads, if it reads one of the generated files."""
    if not isinstance(node, ast.Call):
        return None
    cands = list(node.args) + [k.value for k in node.keywords]
    if isinstance(node.func, ast.Attribute):
        cands.append(node.func.value)
    for a in cands:
        b = basename_doc(const_string(a, consts))
        if b:
            return b
        if isinstance(a, ast.Call):
            for c in list(a.args) + [k.value for k in a.keywords]:
                if isinstance(c, ast.Constant) and isinstance(c.value, str):
                    b = basename_doc(c.value)
                    if b:
                        return b
    return None


def looks_like_a_document_read(node):
    if not isinstance(node, ast.Call):
        return False
    f = node.func
    if isinstance(f, ast.Name):
        return f.id in DOC_READERS
    if isinstance(f, ast.Attribute):
        return f.attr in ("read", "read_text", "open")
    return False


def fenced_spans(text):
    spans, in_fence, start = [], False, 0
    for m in re.finditer(r"(?m)^```", text):
        if not in_fence:
            in_fence, start = True, m.end()
        else:
            spans.append((start, m.start()))
            in_fence = False
    return spans


def inline_code_spans(text):
    return [(m.start(), m.end()) for m in re.finditer(r"`[^`\n]*`", text)]


def doc_var_of(node, consts, flattens, docvars):
    """(path, is_flattened) for an assignment that produces a document copy."""
    path = doc_path_of(node, consts)
    if path is None and isinstance(node, ast.Call):
        for a in node.args:
            if isinstance(a, ast.Name) and a.id in docvars:
                path = docvars[a.id][0]
                break
    if path is None:
        return None
    is_flat = is_flattening_call(node)
    if not is_flat and isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        if node.func.id in flattens:
            is_flat = True
        else:
            for a in node.args:
                if isinstance(a, ast.Name) and a.id in docvars and docvars[a.id][1]:
                    is_flat = True
                    break
    return path, is_flat


def collect_doc_vars(tree, consts):
    flattens = flattening_helpers(tree)
    docvars = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        info = doc_var_of(node.value, consts, flattens, docvars)
        if info is None:
            continue
        for t in node.targets:
            if isinstance(t, ast.Name):
                docvars[t.id] = info
    return docvars, flattens


def parent_map(tree):
    parent = {}
    for node in ast.walk(tree):
        for ch in ast.iter_child_nodes(node):
            parent[ch] = node
    return parent


def group_of(node, parent):
    p = parent.get(node)
    while isinstance(p, ast.BoolOp):
        return p
    return node


def loop_list_for(node, parent, lists):
    """The list a loop variable stands for, resolved in SCOPE.

    `for lit in USER_FACING:` and `[lit for lit in USER_FACING]` both bind
    `lit`; a name bound elsewhere in the file must not leak in.
    """
    name = node.left.id
    p = parent.get(node)
    while p is not None:
        if isinstance(p, ast.For) and isinstance(p.target, ast.Name) \
                and p.target.id == name and isinstance(p.iter, ast.Name) \
                and p.iter.id in lists:
            return lists[p.iter.id]
        if isinstance(p, (ast.ListComp, ast.SetComp, ast.GeneratorExp, ast.DictComp)):
            for gen in p.generators:
                if isinstance(gen.target, ast.Name) and gen.target.id == name \
                        and isinstance(gen.iter, ast.Name) and gen.iter.id in lists:
                    return lists[gen.iter.id]
        p = parent.get(p)
    return None


# --------------------------------------------------------- the evaluation
def group_compares(group):
    return [c for c in ast.walk(group)
            if isinstance(c, ast.Compare)
            and any(isinstance(o, (ast.In, ast.NotIn)) for o in c.ops)]


def resolve_literals(compare, consts, parent, lists):
    """The candidate literals of one comparison.

    Returns (literals, resolved) where `resolved` is False when the left
    hand side is something the census cannot read.
    """
    lit = const_string(compare.left, consts)
    if lit is not None:
        return [lit], True
    if isinstance(compare.left, ast.Name):
        items = loop_list_for(compare, parent, lists)
        if items is not None:
            return list(items), True
    return [], False


def layout_dependent(lit, doc, spans, ticks):
    """Does this literal's match depend on where the builder broke the line?"""
    raw = doc["text"]
    pos = raw.find(lit)
    if pos < 0:
        return False
    if pos >= doc["cut"]:
        # the frozen snapshot is never rewritten
        return False
    if any(a <= pos <= b for a, b in spans):
        return False
    if any(a <= pos <= b for a, b in ticks):
        return False
    ls = raw.rfind("\n", 0, pos) + 1
    le = raw.find("\n", pos)
    line = raw[ls:le] if le > 0 else raw[ls:]
    if line.lstrip().startswith("#"):
        return False
    return True


# --------------------------------------------------------- the census core
def census_source(rel, src):
    """Classify every comparison in one verifier source."""
    out = {"dead": [], "blind": [], "fragile": [], "unclassified": [],
           "groups": 0, "anchors": 0, "flat": 0, "_seen": set(),
           "_unclassified": set()}
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return out
    consts, lists = module_bindings(tree)
    docvars, _flattens = collect_doc_vars(tree, consts)
    parent = parent_map(tree)

    for node in ast.walk(tree):
        if not isinstance(node, ast.Compare):
            continue
        if not any(isinstance(o, (ast.In, ast.NotIn)) for o in node.ops):
            continue
        target = node.comparators[0]
        if not isinstance(target, ast.Name):
            continue
        info = docvars.get(target.id)
        if not info:
            continue
        path, is_flat = info
        doc = DOCS.get(path)
        if doc is None:
            continue
        if is_flat:
            # the robust form: a whitespace-collapsed copy.  Wrap-proof.
            out["flat"] += 1
            continue

        g = group_of(node, parent)
        if id(g) not in out["_seen"]:
            out["_seen"] = out.get("_seen", set()) | {id(g)}
            out["groups"] += 1

        literals, resolved = resolve_literals(node, consts, parent, lists)
        if not resolved:
            if id(g) not in out["_unclassified"]:
                out["_unclassified"] = out.get("_unclassified", set()) | {id(g)}
                out["unclassified"].append((rel, getattr(g, "lineno", 0), path))
            continue

        # the group's literals, for the safety net
        group_cands = []
        for c in group_compares(g):
            cands, _ok = resolve_literals(c, consts, parent, lists)
            group_cands.extend(cands)

        raw = doc["text"]
        flattext = norm(raw)
        spans = fenced_spans(raw)
        ticks = inline_code_spans(raw)
        negated = isinstance(node.ops[0], ast.NotIn)

        for lit in literals:
            if len(lit.strip().split()) < 2:
                # a re-wrap cannot put a break inside a single word
                continue
            others = [o for o in group_cands if o != lit]
            if any(norm(o) == norm(lit) for o in others):
                # a safety net: the group accepts another wrapping of the
                # same phrase, so a re-wrap of this one cannot break it
                continue
            out["anchors"] += 1

            raw_hit = lit in raw
            flat_hit = norm(lit) in flattext
            if raw_hit == flat_hit:
                if raw_hit and layout_dependent(lit, doc, spans, ticks):
                    out["fragile"].append((rel, getattr(node, "lineno", 0), path, lit))
                continue

            # RAW and FLAT disagree: the verdict depends on the layout.
            if not raw_hit:
                # the text IS there, in another wrapping
                if negated:
                    out["blind"].append((rel, getattr(node, "lineno", 0), path, lit))
                else:
                    out["dead"].append((rel, getattr(node, "lineno", 0), path, lit))
            else:
                # the match needs the exact spacing; a re-wrap would break it
                if layout_dependent(lit, doc, spans, ticks):
                    out["fragile"].append((rel, getattr(node, "lineno", 0), path, lit))
    return out


# ==============================================================================
print()
print("=" * 78)
print("A. the census itself")
print("=" * 78)
files = [f for f in git_ls("_verify")
         if "verify" in os.path.basename(f) and f.endswith(".py")]
check("the tracked verifier set was found", len(files) > 0, "%d files" % len(files))
check("both generated documents were read", len(DOCS) == len(DOC_SPEC),
      "read %d of %d" % (len(DOCS), len(DOC_SPEC)))

dead, blind, fragile, unclassified = [], [], [], []
groups = anchors = flat_reads = 0
for rel in files:
    src = read(rel)
    if src is None:
        continue
    r = census_source(rel, src)
    dead.extend(r["dead"])
    blind.extend(r["blind"])
    fragile.extend(r["fragile"])
    unclassified.extend(r["unclassified"])
    groups += r["groups"]
    anchors += r["anchors"]
    flat_reads += r["flat"]

print("   %d tracked verifiers" % len(files))
print("   %d boolean groups read a generated document RAW" % groups)
print("   %d comparisons carry a phrase of two or more words" % anchors)
print("   %d comparisons read a whitespace-collapsed copy (wrap-proof)" % flat_reads)

print()
print("=" * 78)
print("B. no tracked check has died against a generated document")
print("=" * 78)
for rel, line, path, lit in dead:
    print("   DEAD  %s:%d -> %s" % (rel, line, path))
    print("         %r" % lit[:84])
check("no tracked check is DEAD against a generated document", not dead,
      "%d dead" % len(dead))

print()
print("=" * 78)
print("C. no tracked check is BLIND against a generated document")
print("=" * 78)
for rel, line, path, lit in blind:
    print("   BLIND %s:%d -> %s" % (rel, line, path))
    print("         %r" % lit[:84])
check("no tracked check is BLIND against a generated document", not blind,
      "%d blind" % len(blind))

print()
print("=" * 78)
print("D. no tracked check depends on where the builder broke the line")
print("=" * 78)
for rel, line, path, lit in fragile:
    print("   FRAGILE  %s:%d -> %s" % (rel, line, path))
    print("            %r" % lit[:84])
check("no tracked check is FRAGILE against a generated document", not fragile,
      "%d fragile" % len(fragile))

print()
print("=" * 78)
print("E. what the census could not read")
print("=" * 78)
for rel, line, path in unclassified:
    print("   UNCLASSIFIED  %s:%d -> %s" % (rel, line, path))
print("   %d groups carry a left-hand side that is not a static literal"
      % len(unclassified))

# ============================================================== control arm
print()
print("=" * 78)
print("F. the control arm -- the census can still tell the four apart")
print("=" * 78)

# A phrase the README breaks across a line: its words are adjacent only in
# the whitespace-collapsed text, so a literal with a space cannot match the
# raw document.
_split = None
for m in re.finditer(r"([A-Za-z][A-Za-z'-]+)\n([A-Za-z][A-Za-z'-]+)",
                      DOCS["README.mbt.md"]["text"]):
    if m.start() < 400:
        continue
    _split = (m.group(1), m.group(2))
    break
_prose = None
for m in re.finditer(r"(?m)^([A-Za-z][A-Za-z'-]+) ([A-Za-z][A-Za-z'-]+)",
                     DOCS["README.mbt.md"]["text"]):
    if not m.group(0).startswith("#"):
        _prose = (m.group(1), m.group(2))
        break

print("   the split phrase      : %r" % (_split,))
print("   the prose phrase      : %r" % (_prose,))

SYNTH_HEAD = (
    'import io, os, re\n'
    'ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))\n'
    'README = os.path.join(ROOT, "README.mbt.md")\n'
    'def read(p):\n'
    '    return io.open(p, encoding="utf-8", errors="replace").read()\n'
    'readme = read(README)\n'
    'readme_flat = re.sub(r"\\s+", " ", readme)\n'
    'def check(name, ok):\n'
    '    if not ok:\n'
    '        print("FAIL", name)\n'
)


def synth(body):
    return SYNTH_HEAD + body


SYNTH_DEAD = synth(
    'check("a phrase split across a line", "%s %s" in readme)\n'
    % (_split[0], _split[1]))
SYNTH_BLIND = synth(
    'check("a phrase split across a line", "%s %s" not in readme)\n'
    % (_split[0], _split[1]))
SYNTH_FRAGILE = synth(
    'check("a phrase on one line", "%s %s" in readme)\n'
    % (_prose[0], _prose[1]))
SYNTH_ROBUST = synth(
    'check("a phrase read flat", "%s %s" in readme_flat)\n'
    % (_split[0], _split[1]))

r_dead = census_source("<synthetic:dead>", SYNTH_DEAD)
r_blind = census_source("<synthetic:blind>", SYNTH_BLIND)
r_frag = census_source("<synthetic:fragile>", SYNTH_FRAGILE)
r_rob = census_source("<synthetic:robust>", SYNTH_ROBUST)

for name, r in (("DEAD", r_dead), ("BLIND", r_blind),
                 ("FRAGILE", r_frag), ("ROBUST", r_rob)):
    print("   the %-8s synthetic -> dead=%d blind=%d fragile=%d flat=%d"
          % (name, len(r["dead"]), len(r["blind"]), len(r["fragile"]), r["flat"]))

check("the census reports the DEAD synthetic as DEAD",
      len(r_dead["dead"]) == 1 and not r_dead["blind"] and not r_dead["fragile"])
check("the census reports the BLIND synthetic as BLIND",
      len(r_blind["blind"]) == 1 and not r_blind["dead"] and not r_blind["fragile"])
check("the census reports the FRAGILE synthetic as FRAGILE",
      len(r_frag["fragile"]) == 1 and not r_frag["dead"] and not r_frag["blind"])
check("the census leaves the ROBUST synthetic alone",
      not r_rob["dead"] and not r_rob["blind"] and not r_rob["fragile"])
check("the census sees the ROBUST synthetic's collapsed copy",
      r_rob["flat"] >= 1)

print()
print("=" * 78)
print("%d checks, %d failed" % (N, len(FAILS)))
print("=" * 78)
if FAILS:
    for f in FAILS:
        print("   FAILED: %s" % f)
sys.exit(1 if FAILS else 0)
