#!/usr/bin/env python3
"""Gate: every TRACKED verifier must be able to fail.

Round 19 found a script that printed a verdict and then returned 0
unconditionally.  It had been reporting "static and runtime counts DISAGREE
-- investigate before trusting either" inside a GREEN ROW of the suite for
months.  It was found by reading a transcript, which is luck, and the same
defect class can recur in any script at any time.

So the suite gets a check on ITSELF.  For every verifier the repository
tracks, this asks two questions:

  1. does it have a failure notion at all -- a check helper, a failure list,
     or a printed verdict?
  2. can it be made to exit non-zero -- through `sys.exit(<non-zero>)`,
     `raise SystemExit`, an `assert`, or an uncaught exception?

A verifier that has a failure notion and CANNOT exit non-zero is worse than
no verifier: it occupies a green row in the suite while its own message
says the opposite, and nothing in a pass/fail summary reveals that.  This
gate fails on exactly that combination.

WHAT IS EXEMPT, AND WHY
=======================
A script with NO failure notion is not a defect: it is a measurement.  It
reports; it does not gate.  Such a script is not flagged, and the table
below says which ones they are.

Untracked scripts are reported but NOT gated.  They are the local scratch
space, and a gate that failed on scratch would be a gate that gets
disabled.  What the table makes visible is the fact that a scratch script
cannot fail -- which is how round 19's script was noticed in the first
place.

Run: python _verify/_verify_suite_bites_1650.py
"""
import ast
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VD = os.path.join(ROOT, "_verify")

# the same set the suite runner uses
SKIP = re.compile(r"_verify_published_readme_16\d\d\.py$"
                  r"|_verify_typos_pinned"
                  r"|^_final_1600_verify\.py$"
                  r"|^_release_verify_1590\.py$")

# words that mark a script as having a verdict to report
VERDICT = re.compile(r"VERDICT|ALL PASS|DISAGREE|\bFAIL\b|RESULT:|OK:|PASSED|"
                      r"NOT VERIFIED|MISMATCH|VERIFIED|PARTIAL", re.I)

# names that mark a script as having a failure notion
FAILNAME = re.compile(r"^(fail|fails|failed|FAILS|bad|errors|problems|"
                      r"violations|mismatches)$")


def suite_scripts():
    return [f for f in sorted(os.listdir(VD))
            if f.endswith(".py")
            and re.search(r"verify", f)
            and not SKIP.search(f)]


def tracked_set():
    r = subprocess.run(["git", "ls-files", "_verify"], cwd=ROOT,
                       capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return set(r.stdout.split())


class Analysis(ast.NodeVisitor):
    """What can this script do when its check fails?"""

    def __init__(self):
        self.const_names = {}      # name -> set of int constants assigned to it
        self.exit_args = []        # the argument of every sys.exit()/exit()
        self.verbatim = False      # sys.exit(<int literal>)
        self.raises = 0            # raise SystemExit / raise <exc>
        self.asserts = 0           # assert statements
        self.verdict_strings = []
        self.failure_names = []
        self.has_check_helper = False

    def visit_Call(self, node):
        f = node.func
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) \
                and f.value.id == "sys" and f.attr == "exit":
            self._record_exit(node)
        elif isinstance(f, ast.Name) and f.id == "exit":
            self._record_exit(node)
        elif isinstance(f, ast.Name) and f.id == "print":
            for a in node.args:
                for sub in ast.walk(a):
                    if isinstance(sub, ast.Constant) and isinstance(sub.value, str):
                        if VERDICT.search(sub.value):
                            self.verdict_strings.append(sub.value[:60])
        elif isinstance(f, ast.Name) and f.id in ("check", "must", "verify",
                                                 "assert_true", "require"):
            self.has_check_helper = True
        self.generic_visit(node)

    def _record_exit(self, node):
        if not node.args:
            self.exit_args.append("<none>")
            return
        a = node.args[0]
        if isinstance(a, ast.Constant) and isinstance(a.value, int):
            self.verbatim = True
            self.exit_args.append(a.value)
        elif isinstance(a, ast.Name):
            self.exit_args.append(a.id)
        else:
            # an expression: it may be non-zero
            self.exit_args.append("<expr>")

    def visit_Assign(self, node):
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, int):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    self.const_names.setdefault(t.id, set()).add(node.value.value)
        self.generic_visit(node)

    def visit_Raise(self, node):
        self.raises += 1
        self.generic_visit(node)

    def visit_Assert(self, node):
        self.asserts += 1
        self.generic_visit(node)

    def visit_Name(self, node):
        if isinstance(node.ctx, ast.Store) and FAILNAME.match(node.id):
            self.failure_names.append(node.id)
        self.generic_visit(node)


def can_fail(a):
    """Can this script be made to exit non-zero?"""
    if a.asserts:
        return True, "assert"
    if a.raises:
        return True, "raise"
    if a.verbatim:
        return True, "sys.exit(<literal>)"
    for arg in a.exit_args:
        if arg == "<expr>":
            return True, "sys.exit(<expression>)"
        if arg == "<none>":
            return True, "sys.exit()"
        vals = a.const_names.get(arg)
        if vals is None:
            return True, "sys.exit(%s) -- value not a literal" % arg
        if any(v != 0 for v in vals):
            return True, "sys.exit(%s)" % arg
    return False, "NO non-zero exit path"


def has_failure_notion(a):
    if a.has_check_helper:
        return True, "a check() helper"
    if a.failure_names:
        return True, "a failure list"
    if a.verdict_strings:
        return True, "a printed verdict"
    return False, "-"


scripts = suite_scripts()
tracked = tracked_set()
print("suite scripts: %d   tracked: %d   scratch: %d"
      % (len(scripts),
         len([f for f in scripts if "_verify/" + f in tracked]),
         len([f for f in scripts if "_verify/" + f not in tracked])))
print()
print("%-46s %-8s %-22s %s" % ("script", "tracked", "failure notion", "can fail"))
print("-" * 116)

flagged_tracked = []
flagged_scratch = []
parse_errors = []

for f in scripts:
    src = open(os.path.join(VD, f), encoding="utf-8", errors="replace").read()
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        parse_errors.append((f, str(e)))
        print("%-46s PARSE ERROR: %s" % (f, e))
        continue
    a = Analysis()
    a.visit(tree)
    notion, _ = has_failure_notion(a)
    ok, how = can_fail(a)
    is_tracked = "_verify/" + f in tracked
    if notion and not ok:
        if is_tracked:
            flagged_tracked.append(f)
        else:
            flagged_scratch.append(f)
    print("%-46s %-8s %-22s %s"
          % (f, "yes" if is_tracked else "scratch",
             notion if notion else "(none)",
             how if notion else "-"))

print()
print("=" * 116)
print("TRACKED verifiers that have a failure notion but CANNOT exit non-zero: %d"
      % len(flagged_tracked))
for f in flagged_tracked:
    print("  *** %s" % f)
print("scratch scripts that have a failure notion but cannot exit non-zero: %d"
      % len(flagged_scratch))
for f in flagged_scratch:
    print("  (scratch) %s" % f)
print("scripts that do not parse: %d" % len(parse_errors))
for f, e in parse_errors:
    print("  *** %s -- %s" % (f, e))

fails = []
if flagged_tracked:
    fails.append("%d tracked verifier(s) cannot fail" % len(flagged_tracked))
if parse_errors:
    fails.append("%d script(s) do not parse" % len(parse_errors))
if not scripts:
    fails.append("the suite is empty -- the runner would find nothing to run")

print()
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
sys.exit(1 if fails else 0)
