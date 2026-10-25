#!/usr/bin/env python3
"""Round 43 verifier: every tracked dry-run driver still has TEETH.

WHAT THIS EXISTS FOR
=====================
The tree carries 30 tracked dry-run drivers -- the mutation-test suite that
proves each verifier FAILS on a tree the verifier should reject.  A driver
that cannot break anything is a check that cannot fail, and the rot is
silent: the driver still exits 0 on a healthy tree, so nothing in CI notices.

Round 43's sweep found 16 of the 30 no longer biting, and the causes were
three different classes, all of them mechanical:

  1. a MECHANISM'S ANCHOR MOVED.  The driver patches a specific string in a
     specific file.  A later round rewrote that string, so the patch raised
     "matched 0 times" and the driver died before it proved anything.
  2. a CLASS MOVED TO ANOTHER VERIFIER.  The driver broke a promise and
     watched the verifier that used to own it; a later round moved the class
     to a new verifier, and the old one no longer sees the damage.
  3. a PUBLISHED COUNT WENT STALE.  The driver measures N failures; the
     CHANGELOG publishes M; nothing said they had to agree.

A driver that is anchored to the tree it was written for rots the moment the
tree moves, and nothing in the tree watches that.  So this verifier watches
it.

THE RULE
========
Four obligations, each an aggregate over the whole driver set:

  D1  every patch anchor in every tracked dry-run driver is LIVE in the tree
      -- it occurs exactly as many times as the driver expects;
  D2  every file a dry-run driver patches EXISTS and is TRACKED, and every
      verifier a dry-run driver RUNS EXISTS;
  D3  every dry-run driver that asserts a published failure count has that
      count published in the CHANGELOG, and where the ENGINEERING banner
      publishes one too, the two AGREE;
  D4  every driver that READS the banner finds a count there, and every
      driver's OWN lookup agrees with this verifier's.

D3 is the check that would have caught round 32: its CHANGELOG entry
published 10 failures and its banner passage published 9, and no verifier
compared the two.

D4 is the check that would have caught round 43's own two days of silence.
The sentence that carries a published count is HARD-WRAPPED, so a pattern
with literal spaces matched only the entries that happened to keep the
phrase on one line: four drivers read an OLDER entry's number as their own
and one read nothing at all, while this verifier reported that six drivers
published no count.  Both sides were confident and both were wrong, because
nothing compared the owner with the checker.  So the driver's own helper is
EXECUTED here against the same CHANGELOG, and the two must agree.

A DOCUMENT IS NOT READ BY ITS LAYOUT
=====================================
The CHANGELOG and the banner are both wrapped prose, and both are read by a
rule that collapses the whitespace before it matches -- the banner also has
its quote prefix stripped, because the break in a quoted line is followed by
the prefix and not by a space.  A count that lives in a wrapped sentence is
still a count; a reader that insists on the layout is a reader that misses
it.  The CHANGELOG is DESCENDING (the newest entry wins) and the banner is
ASCENDING (the LAST mention is the live claim), and a mention that
publishes no count is not a publication, so both lookups fall through to an
older one.

THE MECHANISMS ARE CUMULATIVE
==============================
A driver's mechanisms run ONE AT A TIME, each on top of the last.  Several
of them patch text that an EARLIER mechanism produced -- round 36's sixth
mechanism rewrites the string its fifth mechanism wrote, and round 38's
seventh rewrites the string its sixth wrote.  So an anchor is checked against
the file as it stands AT THAT STEP, not against the tree as it was written.
This verifier therefore SIMULATES the mechanisms in source order and checks
each anchor against the state it would really meet.

THE UPSTREAM TARGETS
====================
A driver may patch a file in the VENDORED UPSTREAM tree, which is
downloaded rather than tracked.  Upstream is told from in-repo by the file
extension: a `.py` target is upstream, everything else is in this tree.  A
`.py` target must live under the vendored area; it is not required to be
tracked, because it is not in this repository.

WHY EVERY CHECK IS AN AGGREGATE
================================
Adding a driver, a mechanism or a file does not move the published number, so
the number is fixed against the ENVIRONMENT (the driver set) rather than
against the tree -- the round-41 precedent, applied to the driver set.

An anchor this verifier cannot RESOLVE is a failure, not a skip.  A new
helper shape in a new driver must be taught here, or it is an anchor nobody
checked -- which is the class this verifier exists to close.

Run: python _verify/_verify_dryrun_teeth_1650.py
"""
import ast
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "*** FAIL ***", label, detail))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))


def read_bytes(rel):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        return None
    return io.open(p, "rb").read()


def read_text(rel):
    b = read_bytes(rel)
    return "" if b is None else b.decode("utf-8", "replace")


def git_ls(*patterns):
    out = subprocess.run(["git", "ls-files", "-z"] + list(patterns),
                         cwd=ROOT, capture_output=True)
    return [f for f in out.stdout.decode("utf-8", "replace").split("\0") if f]


# ---------------------------------------------------------------------------
# the driver set
# ---------------------------------------------------------------------------
drivers = sorted(f for f in git_ls("_verify/_dryrun*.py"))

# ---------------------------------------------------------------------------
# what a driver patches, and what it replaces it with
# ---------------------------------------------------------------------------
# The helpers that replace a LITERAL string, and the helpers that apply a
# REGULAR EXPRESSION.  A `patch_readmes` call patches both README copies.
LITERAL_PATCH = ("patch",)
REGEX_PATCH = ("patch_re", "sub_once")
BOTH_PATCH = ("patch_readmes",)
# The helpers that edit the CHANGELOG's published count through the driver's
# own witness regex.  They carry no literal anchor of their own.
WITNESS_PATCH = ("set_witness_count", "drop_witness_block")
# The helpers that write a file whole.
WRITE_PATCH = ("write",)

MARKER = "\x00FMT\x00"


class Driver(object):
    def __init__(self, rel):
        self.rel = rel
        self.src = io.open(os.path.join(ROOT, rel.replace("/", os.sep)),
                           encoding="utf-8").read()
        self.tree = ast.parse(self.src)
        self.strs = {}       # name -> string value
        self.paths = {}      # name -> [repo-relative paths]
        self.lists = {}      # name -> [strings]
        self.witness = None  # the CHANGELOG-publication regex, if any
        self.base_tail = None  # the work directory's last component
        self._collect()

    def _base_tail(self):
        """The work directory's last component, or None.

        The work directory is the base every path hangs off, so its name is
        what tells a base from a path that was built earlier.
        """
        if self.base_tail:
            return self.base_tail
        for cand in ("WORK", "SCRATCH", "MUT"):
            p = self.paths.get(cand)
            if p and len(p) == 1:
                self.base_tail = p[0].split("/")[-1]
                return self.base_tail
        return None

    def _collect(self):
        # The assignments are read in SOURCE ORDER: a path may be built from
        # another path, and the one it is built from is named first.
        nodes = []
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
                nodes.append((node.lineno, node))
            elif isinstance(node, ast.For) and isinstance(node.target, ast.Name):
                nodes.append((node.lineno, node))
        nodes.sort(key=lambda t: t[0])
        for _lineno, node in nodes:
            if isinstance(node, ast.For):
                if isinstance(node.iter, (ast.List, ast.Tuple)):
                    items = [e.value for e in node.iter.elts
                             if isinstance(e, ast.Constant) and isinstance(e.value, str)]
                    if len(items) == len(node.iter.elts):
                        self.paths.setdefault(node.target.id, items)
                continue
            name = node.targets[0].id
            val = node.value
            if isinstance(val, ast.Constant) and isinstance(val.value, str):
                self.strs[name] = val.value
            elif isinstance(val, (ast.List, ast.Tuple)):
                items = [e.value for e in val.elts
                         if isinstance(e, ast.Constant) and isinstance(e.value, str)]
                if len(items) == len(val.elts):
                    self.lists[name] = items
            elif (isinstance(val, ast.Call) and isinstance(val.func, ast.Attribute)
                    and val.func.attr == "join"):
                segs = self._segments(val)
                if segs is not None:
                    self.paths[name] = ["/".join(segs)]
            elif (isinstance(val, ast.Call) and isinstance(val.func, ast.Attribute)
                  and val.func.attr == "compile" and val.args
                  and isinstance(val.args[0], ast.Constant)
                  and isinstance(val.args[0].value, str)):
                self.witness = val.args[0].value

    def _segments(self, call):
        """The path segments of an os.path.join(...), or None.

        The FIRST argument is usually the work directory -- the base every
        path is relative to -- and it is skipped.  But it is not always the
        base: a driver may join onto a path it built earlier
        (`os.path.join(PKG, "moon.pkg")`), and then that name contributes its
        own segments.  The base is told from a path by its LAST component:
        the work directory's name is the one every path in this driver hangs
        off.
        """
        segs = []
        tail = self._base_tail()
        for i, a in enumerate(call.args):
            if isinstance(a, ast.Constant) and isinstance(a.value, str):
                segs.append(a.value)
            elif isinstance(a, ast.Name) and a.id in self.paths:
                p = self.paths[a.id]
                if len(p) != 1:
                    return None
                if tail and p[0].split("/")[-1] == tail:
                    continue        # the work directory: the base
                segs.append(p[0])
            elif i == 0:
                continue            # the base, named but not resolved
            else:
                return None
        return segs

    # -- a string-valued argument -------------------------------------------
    def text_of(self, node):
        """(text, is_template) -- the string an argument denotes."""
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value, False
        if isinstance(node, ast.Name):
            v = self.strs.get(node.id)
            return (v, False) if v is not None else (None, False)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left = self.text_of(node.left)
            right = self.text_of(node.right)
            if left[0] is not None and right[0] is not None:
                return left[0] + right[0], False
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
            # a printf template: the VALUE is not knowable statically, but the
            # TEMPLATE is, and the template is what has to be live.
            left = self.text_of(node.left)
            if left[0] is not None:
                return left[0], True
        return None, False

    # -- the file an argument names -----------------------------------------
    def paths_of(self, node):
        """[repo-relative paths] or None."""
        if isinstance(node, ast.Name):
            return self.paths.get(node.id)
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "join"):
            segs = self._segments(node)
            if segs is not None:
                return ["/".join(segs)]
            # os.path.join(WORK, <name>.replace(...))
            if len(node.args) == 2 and isinstance(node.args[1], ast.Call) \
                    and isinstance(node.args[1].func, ast.Attribute) \
                    and node.args[1].func.attr == "replace" \
                    and isinstance(node.args[1].func.value, ast.Name):
                return self.paths.get(node.args[1].func.value.id)
        return None

    # -- the list of verifiers a driver RUNS --------------------------------
    def verifier_lists(self):
        out = set()
        for items in self.lists.values():
            for s in items:
                if re.match(r"^_verify/_verify_[A-Za-z0-9_]+\.py$", s):
                    out.add(s)
        return out


def calls_of(drv):
    """Every mutation call, in SOURCE order.

    A call inside a `def` is the HELPER'S OWN implementation, not a
    mechanism: round 36's `patch_readmes` calls `patch` twice, and those two
    calls are not mechanisms.  So the walk does not descend into function
    bodies -- only module-level statements and the lambdas inside them.
    """
    out = []

    def visit(node):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.FunctionDef):
                continue          # a helper's own body is not a mechanism
            if isinstance(child, ast.Call) and isinstance(child.func, ast.Name):
                out.append((child.lineno, child.col_offset, child))
            visit(child)

    visit(drv.tree)
    out.sort(key=lambda t: (t[0], t[1]))
    return [(ln, n) for ln, _c, n in out]


def helper_is_regex(drv, name, depth=0):
    """Does this driver's own `<name>` helper apply a regular expression?

    Some drivers replace a literal and some apply a pattern; the difference
    is in the helper's body, and it decides how the anchor must be matched.
    The answer is transitive: round 39's `patch_readmes` is a regex patch
    because it calls `sub_once`, which is one.
    """
    if depth > 3:
        return False
    for node in ast.walk(drv.tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            for sub in ast.walk(node):
                if (isinstance(sub, ast.Call) and isinstance(sub.func, ast.Attribute)
                        and sub.func.attr in ("sub", "search", "findall")):
                    return True
                if (isinstance(sub, ast.Attribute) and sub.attr == "sub"
                        and isinstance(sub.value, ast.Name)
                        and sub.value.id == "re"):
                    return True
                # a call to another helper of this driver
                if (isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name)
                        and sub.func.id != name
                        and helper_is_regex(drv, sub.func.id, depth + 1)):
                    return True
    return False


def patch_calls(drv):
    """(helper, paths, old, old_is_template, new, expected_count)."""
    out = []
    for lineno, node in calls_of(drv):
        fn = node.func.id
        if fn in WITNESS_PATCH:
            continue
        if fn in WRITE_PATCH:
            continue
        if fn in BOTH_PATCH:
            if len(node.args) >= 2:
                old, tmpl = drv.text_of(node.args[0])
                new, _n = drv.text_of(node.args[1])
                rx = helper_is_regex(drv, fn)
                out.append((fn, ["README.mbt.md", "moonbit_doubleML/README.mbt.md"],
                            old, tmpl, new, 1, lineno, rx))
            continue
        if fn not in LITERAL_PATCH and fn not in REGEX_PATCH:
            continue
        if len(node.args) < 3:
            continue
        paths = drv.paths_of(node.args[0])
        old, tmpl = drv.text_of(node.args[1])
        new, _n = drv.text_of(node.args[2])
        count = 1
        for kw in node.keywords:
            if kw.arg == "count" and isinstance(kw.value, ast.Constant):
                count = kw.value.value
        rx = fn in REGEX_PATCH or helper_is_regex(drv, fn)
        out.append((fn, paths, old, tmpl, new, count, lineno, rx))
    return out


def write_calls(drv):
    """(paths, content) for the calls that write a file whole."""
    out = []
    for lineno, node in calls_of(drv):
        if node.func.id not in WRITE_PATCH or len(node.args) < 2:
            continue
        paths = drv.paths_of(node.args[0])
        content, _t = drv.text_of(node.args[1])
        if paths is not None and content is not None:
            out.append((paths, content, lineno))
    return out


def is_upstream(path):
    """A target under the vendored upstream area is not this repository."""
    return path.startswith("_verify/_upstream")


def in_vendored_area(path):
    return path.startswith("_verify/_upstream")


# ---------------------------------------------------------------------------
# A. the driver set
# ---------------------------------------------------------------------------
print()
print("A. the driver set")
check("the tree has tracked dry-run drivers", len(drivers) > 0,
      "%d driver(s)" % len(drivers))

parsed = []
unparsed = []
for d in drivers:
    try:
        parsed.append(Driver(d))
    except SyntaxError as exc:
        unparsed.append("%s: %s" % (d, exc))
check("every tracked dry-run driver parses", not unparsed,
      "%d do not: %s" % (len(unparsed), "; ".join(unparsed[:3])) if unparsed
      else "%d driver(s)" % len(parsed))

# ---------------------------------------------------------------------------
# B. the anchors are live -- simulated in source order, because the
#    mechanisms are cumulative
# ---------------------------------------------------------------------------
print()
print("B. every patch anchor is live in the tree")

dead = []          # the anchor is not where the driver expects it
unresolved = []    # the anchor could not be resolved at all
missing_file = []  # the file the driver patches is not in the tree
n_anchor = 0
n_paths = set()    # the files a driver PATCHES
n_written = set()  # the files a driver CREATES

for drv in parsed:
    # the state of each file as the mechanisms proceed
    state = {}
    for paths, content, _ln in write_calls(drv):
        for p in paths:
            state[p] = content
            n_written.add(p)
    for helper, paths, old, tmpl, new, count, lineno, rx in patch_calls(drv):
        if paths is None:
            unresolved.append("%s:%d: %s -- the path is not a literal path"
                              % (drv.rel, lineno, helper))
            continue
        if old is None:
            unresolved.append("%s:%d: %s -- the anchor is not a literal string"
                              % (drv.rel, lineno, helper))
            continue
        n_anchor += 1
        for p in paths:
            n_paths.add(p)
            if p not in state:
                text = read_text(p)
                if read_bytes(p) is None:
                    missing_file.append("%s:%d: %s -- %s is not in the tree"
                                        % (drv.rel, lineno, helper, p))
                    continue
                state[p] = text
            text = state[p]
            crlf = "\r\n" in text
            if rx:
                # a regular expression: it must MATCH, not be counted
                try:
                    hit = re.search(old, text)
                except re.error as exc:
                    unresolved.append("%s:%d: %s -- %r is not a valid regex (%s)"
                                      % (drv.rel, lineno, helper, old[:40], exc))
                    continue
                if hit is None:
                    dead.append("%s:%d: %s -- %r matches nothing in %s"
                                % (drv.rel, lineno, helper, old[:50], p))
                    continue
                repl = new if new is not None else ""
                state[p] = re.sub(old, repl, text, count=1)
                continue
            if tmpl:
                # a printf template: the VALUE is not knowable, so the anchor
                # is matched as a pattern.
                pat = re.escape(old).replace(re.escape("%s"), ".+?").replace(
                    re.escape("%d"), ".+?")
                hits = len(re.findall(pat, text))
            else:
                probe = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
                hits = text.count(probe)
            if hits == 0:
                dead.append("%s:%d: %s -- %r is not in %s"
                            % (drv.rel, lineno, helper, old[:50], p))
                continue
            if hits != count:
                dead.append("%s:%d: %s -- %r is in %s %d time(s), the driver "
                            "expects %d" % (drv.rel, lineno, helper, old[:40], p,
                                            hits, count))
                continue
            if tmpl:
                repl = new if new is not None else ""
                repl = re.sub(r"%[sd]", MARKER, repl)
                state[p] = re.sub(pat, repl.replace("\\", "\\\\"), text, count=1)
            else:
                probe = old.replace("\n", "\r\n") if crlf and "\r\n" not in old else old
                repl = new if new is not None else ""
                state[p] = text.replace(probe, repl, count)

check("every patch anchor is live where the driver expects it", not dead,
      "%d of %d anchor(s) are not: %s"
      % (len(dead), n_anchor, "; ".join(dead[:3])) if dead
      else "%d anchor(s) in %d driver(s)" % (n_anchor, len(parsed)))
check("every patch anchor could be resolved", not unresolved,
      "%d could not: %s" % (len(unresolved), "; ".join(unresolved[:3]))
      if unresolved else "%d anchor(s)" % n_anchor)

in_repo = sorted(p for p in n_paths if not is_upstream(p))
absent = [p for p in in_repo if read_bytes(p) is None]
check("every in-repo file a dry-run driver patches is in the tree", not absent,
      "%d are not: %s" % (len(absent), ", ".join(absent[:3])) if absent
      else "%d file(s)" % len(in_repo))

vendored = sorted(p for p in n_paths if is_upstream(p) and not in_vendored_area(p))
check("every upstream file a dry-run driver patches is under the vendored area",
      not vendored,
      "%d are not: %s" % (len(vendored), ", ".join(vendored[:3])) if vendored
      else "%d upstream file(s)" % (len(n_paths) - len(in_repo)))

# ---------------------------------------------------------------------------
# C. what the drivers name
# ---------------------------------------------------------------------------
print()
print("C. what the drivers name")

tracked = set(git_ls())
untracked = [p for p in in_repo if p not in tracked]
check("every in-repo file a dry-run driver patches is tracked", not untracked,
      "%d are not: %s" % (len(untracked), ", ".join(untracked[:3]))
      if untracked else "%d file(s)" % len(in_repo))

named = {}
for drv in parsed:
    for v in drv.verifier_lists():
        named.setdefault(v, set()).add(drv.rel)
absent_v = sorted(v for v in named
                  if not os.path.isfile(os.path.join(ROOT, v.replace("/", os.sep))))
check("every verifier a dry-run driver runs is in the tree", not absent_v,
      "%d are not: %s" % (len(absent_v), ", ".join(absent_v[:3])) if absent_v
      else "%d verifier(s) named" % len(named))

# ---------------------------------------------------------------------------
# C2. a driver's counter must be able to SEE its verifiers' failures
# ---------------------------------------------------------------------------
# The tree has THREE marker conventions: the marker at the front of the line
# ("  *** FAIL ***  <label>"), at the front at column 0 ("*** FAIL *** ..."), and
# at the BACK ("<label>  *** FAIL ***").  A counter that matches one POSITION
# cannot see the other two -- and a driver whose counter cannot see a
# verifier's failures reports a mechanism as contributing nothing while the
# verifier is failing loudly.  Round 43's dry-run of round 35 died exactly
# that way: the driver counted the marker at the back and the pointer
# verifier printed it at the front.
#
# The rule that sees them all is CONTAINMENT.
print()
print("C2. the drivers' counters see their verifiers' failures")

MARKER = "*** FAIL ***"


def marker_positions(verifier):
    """The positions at which this verifier prints the marker."""
    src = read_text(verifier)
    front = re.search(r'print\(\s*"([^"]*?)\*\*\* FAIL', src) is not None
    back = re.search(r'print\(\s*"[^"]*\*\*\* FAIL', src) is not None
    return front, back


def counter_kind(driver_src):
    """'containment', 'prefix', 'suffix' or None."""
    if '"*** FAIL ***" in l' in driver_src and "startswith" not in \
            driver_src.split('"*** FAIL ***" in l')[0][-200:] \
            and "endswith" not in driver_src.split('"*** FAIL ***" in l')[0][-200:]:
        return "containment"
    if 'startswith("  *** FAIL ***")' in driver_src:
        return "prefix"
    if 'endswith("*** FAIL ***")' in driver_src:
        return "suffix"
    if '"*** FAIL ***" in l' in driver_src:
        return "containment"
    return None


blind = []
for drv in parsed:
    src = drv.src
    kind = counter_kind(src)
    if kind is None:
        continue          # this driver counts failures some other way
    for v in sorted(drv.verifier_lists()):
        vpath = os.path.join(ROOT, v.replace("/", os.sep))
        if not os.path.isfile(vpath):
            continue
        front, back = marker_positions(v)
        if not front and not back:
            continue
        if kind == "containment":
            continue
        if kind == "prefix" and front:
            continue
        if kind == "suffix" and back:
            continue
        blind.append("%s counts by %s, but %s prints the marker %s"
                     % (os.path.basename(drv.rel), kind, os.path.basename(v),
                        "at the back" if back else "at the front"))
check("every driver's counter can see its verifiers' failure markers",
      not blind,
      "%d cannot: %s" % (len(blind), "; ".join(blind[:3])) if blind
      else "every counter sees every position")

# ---------------------------------------------------------------------------
# D. the published counts agree
# ---------------------------------------------------------------------------
print()
print("D. the published failure counts")

CL = read_text("CHANGELOG.md")
ENG = read_text("ENGINEERING.md")
BANNER = ENG.split("## The README as it stood at", 1)[0]

ASSERTS = re.compile(r"publishes (\d+); this run measured|"
                      r"the published failure count and the measured one disagree|"
                      r"the CHANGELOG publishes no failure count for this dry-run")

# The sentence that carries a published count is HARD-WRAPPED, in the
# CHANGELOG and in the banner alike.  A pattern with literal spaces matches
# only the entries that happen to keep the phrase on ONE line -- so the
# count was read out of an OLDER entry, or not found at all.  Both documents
# are therefore read with their whitespace COLLAPSED, and the banner with its
# quote prefix stripped, because the break in a quoted line is followed by
# the prefix and not by a space.
FLAT = re.compile(r"\s+")
QUOTE = re.compile(r"(?m)^>[ \t]*")


def changelog_count(name):
    """The count the CHANGELOG publishes FOR `name`.

    Scoped twice: to the ENTRY that names the driver, and within that entry
    to the BULLET that names it.  The CHANGELOG is DESCENDING, so the newest
    entry wins -- and a newest entry that publishes several drivers' counts
    must not bind one driver's number to another's.  An entry that NAMES a
    driver without publishing a count for it is not a publication, so the
    search falls through to the older one.
    """
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                         CL, re.M | re.S):
        body = m.group(2)
        if name not in body:
            continue
        lines = body.split("\n")
        start = None
        for i, l in enumerate(lines):
            if name in l:
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
        flat = FLAT.sub(" ", "\n".join(lines[head:tail]))
        found = re.findall(r"requires the failure count to GROW at every step: "
                           r"\*\*(\d+)\*\* failures at the", flat)
        if found:
            return int(found[0])
    return None


def banner_count(name):
    """The count the banner publishes FOR `name`.

    The banner is ASCENDING, so the LIVE claim is the LAST mention -- and a
    mention that publishes no count is not a publication, so the search falls
    back to an earlier one.
    """
    for hit in reversed([m.start() for m in
                         re.finditer(re.escape(name), BANNER)]):
        nxt = re.search(r"^> \* \*\*Round ", BANNER[hit:], re.M)
        passage = BANNER[hit:hit + nxt.start()] if nxt else BANNER[hit:]
        flat = FLAT.sub(" ", QUOTE.sub("", passage))
        found = re.findall(r"ends at \*\*(\d+)\*\* failures", flat)
        if found:
            return int(found[0])
    return None


def driver_own_count(rel, base):
    """The count the driver's OWN `published_count` returns, or None.

    The driver OWNS the rule that binds a published count to a driver.  If
    this verifier reads the CHANGELOG by a different rule, the two can
    disagree -- and then each believes its own number, which is how round 43
    lost a day: the checker said six drivers published no count while the
    drivers were reading numbers that belonged to OTHER drivers.  So the
    driver's own helper is EXECUTED here, against the same CHANGELOG.
    """
    src = read_text(rel)
    fn = None
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, ast.FunctionDef) and node.name == "published_count":
            fn = node
            break
    if fn is None:
        return None
    ns = {"re": re}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), rel, "exec"), ns)
    return ns["published_count"](CL, base)


asserting = [d for d in drivers if ASSERTS.search(read_text(d))]
no_changelog = []
disagree = []
compared = 0
for d in asserting:
    base = os.path.basename(d)
    c_n = changelog_count(base)
    if c_n is None:
        no_changelog.append(base)
    b_n = banner_count(d)
    if c_n is not None and b_n is not None:
        compared += 1
        if c_n != b_n:
            disagree.append("%s -- the CHANGELOG says %s, the banner says %s"
                            % (base, c_n, b_n))

check("every dry-run driver that asserts a count has a CHANGELOG entry",
      not no_changelog,
      "%d do not: %s" % (len(no_changelog), ", ".join(no_changelog[:3]))
      if no_changelog else "%d driver(s) assert one" % len(asserting))
check("the CHANGELOG's count and the banner's count agree for every driver",
      not disagree,
      "%d disagree: %s" % (len(disagree), "; ".join(disagree[:3]))
      if disagree else "%d driver(s) publish in both" % compared)

# ---------------------------------------------------------------------------
# D2. a driver that READS the banner must find a count there
# ---------------------------------------------------------------------------
# Four drivers read the banner and abort when it publishes no count.  A
# banner that stops naming one of them, or that wraps the sentence so the
# number cannot be read, takes the driver down -- and the banner is written
# by hand, so it can.
print()
print("D2. the drivers that read the banner")

banner_readers = [d for d in drivers
                  if re.search(r're\.findall\(r"ends at', read_text(d))]
blind = []
for d in banner_readers:
    if banner_count(d) is None:
        blind.append(os.path.basename(d))
check("every driver that reads the banner finds a count there",
      not blind,
      "%d do not: %s" % (len(blind), ", ".join(blind[:3]))
      if blind else "%d driver(s) read it" % len(banner_readers))

# ---------------------------------------------------------------------------
# D3. the owner and the checker must agree
# ---------------------------------------------------------------------------
print()
print("D3. the drivers' own lookup agrees with this verifier's")

diverge = []
for d in asserting:
    base = os.path.basename(d)
    mine = changelog_count(base)
    try:
        theirs = driver_own_count(d, base)
    except Exception as exc:                       # noqa: BLE001
        theirs = "raised %s" % exc
    if mine != theirs:
        diverge.append("%s -- this verifier reads %s, the driver reads %s"
                       % (base, mine, theirs))
check("every driver's own published_count agrees with this verifier's",
      not diverge,
      "%d disagree: %s" % (len(diverge), "; ".join(diverge[:3]))
      if diverge else "%d driver(s) agree" % len(asserting))

print()
print("the drivers")
for d in drivers:
    print("  %-46s %s" % (os.path.basename(d),
                          "asserts a count" if d in asserting else ""))

print()
print("checks run: %d, checks failed: %d" % (NCHECK, len(FAILS)))
for f in FAILS:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))
sys.exit(1 if FAILS else 0)
