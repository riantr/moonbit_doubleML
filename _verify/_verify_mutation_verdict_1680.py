#!/usr/bin/env python3
"""Round 76 verifier: the README's claim about the `mutation` check.

WHAT THIS EXISTS FOR
====================
The README says:

    `mutation` kills three mutants on one kernel, not a whole-codebase
    surviving-mutant ledger, and no CI workflow runs it.

"Three", "one kernel" and "no CI workflow runs it" were three claims with no
witness.  The check is scope=full, no workflow invokes it, and its verdict
lived only in a console scrollback -- so a reader could not tell whether it
ever killed anything.

Round 76 MEASURED it (`python .github/scripts/qa_loop/run.py --only mutation
--full`): 3/3 killed on `ps_processor.mbt` in 54.97s, and that verdict is now
a tracked record, `_verify/_mutation_verdict_1680.json`.

WHAT IS DERIVED AND WHAT IS WITNESSED
=====================================
  * DERIVED from `.github/scripts/qa_loop/checks.py`: the check's target file
    and the mutants it defines -- their names and the source fragments each
    one rewrites.  The README's "three" has to equal the number of mutants the
    check actually defines, so a fourth mutant makes the document go RED
    rather than stale.
  * DERIVED from the target file: every mutant's anchor fragment must still
    occur in it.  A mutant whose anchor is gone cannot be applied, so the
    record's verdict would not describe the tree.
  * DERIVED from `.github/workflows/`: no workflow may run the QA loop with
    `--full` or `--only mutation`.  That is what makes the README's "no CI
    workflow runs it" true, and it is true by derivation rather than by
    memory.
  * WITNESSED by the record: the verdict itself, and the names of the mutants
    it covers.  The record and the derived set must agree on both.

THE CONTROL ARM
================
Three synthetic sources, and the rule has to disagree with each:

  1. a check that defines FOUR mutants -- the README's "three" is then wrong;
  2. a record that says 2 of 3 killed -- the claim is then wrong;
  3. a mutant whose anchor fragment no longer occurs in the target -- the
     record cannot describe the tree.

Run: python _verify/_verify_mutation_verdict_1680.py
"""
import ast
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
CHECKS = os.path.join(ROOT, ".github", "scripts", "qa_loop", "checks.py")
RECORD = os.path.join(ROOT, "_verify", "_mutation_verdict_1680.json")
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")

FAILS = []
N = 0


def check(name, ok, detail=""):
    global N
    N += 1
    print("  %s  %-64s %s" % ("ok  " if ok else "*** FAIL ***", name, detail))
    if not ok:
        FAILS.append(name)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def parse_mutation_check(src):
    """(target, [(name, anchor)]) from the QA loop's `c_mutation`."""
    tree = ast.parse(src)
    targets = []
    muts = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef) or node.name != "c_mutation":
            continue
        for sub in ast.walk(node):
            if isinstance(sub, ast.Assign):
                for t in sub.targets:
                    if isinstance(t, ast.Name) and t.id == "tgt":
                        if isinstance(sub.value, ast.Constant):
                            targets.append(sub.value.value)
                    if isinstance(t, ast.Name) and t.id == "MUTS":
                        for elt in getattr(sub.value, "elts", []):
                            if not isinstance(elt, ast.Tuple) or len(elt.elts) != 2:
                                continue
                            name = elt.elts[0]
                            if not (isinstance(name, ast.Constant)
                                    and isinstance(name.value, str)):
                                continue
                            anchor = None
                            for c in ast.walk(elt.elts[1]):
                                if (isinstance(c, ast.Call)
                                        and isinstance(c.func, ast.Attribute)
                                        and c.func.attr == "replace"
                                        and c.args
                                        and isinstance(c.args[0], ast.Constant)
                                        and isinstance(c.args[0].value, str)):
                                    anchor = c.args[0].value
                            if anchor is not None:
                                muts.append((name.value, anchor))
    return (targets[0] if targets else None), muts, targets


def yaml_commands(text):
    """The workflow's COMMANDS, with comment lines dropped.

    A YAML comment is not an invocation: `check.yml` explains in a comment
    that the full scope is NOT a release-time scope, and a scan that reads
    comments would conclude the opposite.  Continuation lines (`\\`, and the
    `|` block scalar) are joined, so a flag on the next line is seen.
    """
    out = []
    buf = ""
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith("#"):
            continue
        buf = (buf + " " + s).strip() if buf else s
        if buf.endswith("\\"):
            buf = buf[:-1].strip()
            continue
        if buf.endswith(("|", ">")):
            continue
        out.append(buf)
        buf = ""
    if buf:
        out.append(buf)
    return out


def workflows_running_mutation():
    """The workflow commands that would run the `mutation` check."""
    hits = []
    if not os.path.isdir(WORKFLOWS):
        return hits
    for fn in sorted(os.listdir(WORKFLOWS)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        for cmd in yaml_commands(read(os.path.join(WORKFLOWS, fn))):
            if "qa_loop/run.py" not in cmd:
                continue
            m = re.search(r"--only\s+([A-Za-z0-9_,-]+)", cmd)
            if m:
                if "mutation" in m.group(1).split(","):
                    hits.append("%s: --only %s" % (fn, m.group(1)))
            elif "--full" in cmd:
                # the full scope, which includes `mutation`
                hits.append("%s: --full" % fn)
    return hits


def audit(checks_src, record, target_text, workflows_hits, readme_text):
    """The problems with the mutation claim, as a list of strings."""
    problems = []
    target, muts, targets = parse_mutation_check(checks_src)

    m = re.search(r"`mutation` kills (\w+) mutants on (\w+) kernel", readme_text)
    if not m:
        problems.append("the README's mutation sentence is not findable")
        return problems, target, muts
    said_count, said_kernel = m.group(1), m.group(2)

    words = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
             "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}
    if said_count not in words:
        problems.append("the README says %r mutants, which is not a number"
                        % said_count)
    elif words[said_count] != len(muts):
        problems.append("the README says %s mutants, the check defines %d"
                        % (said_count, len(muts)))
    if said_kernel != "one":
        problems.append("the README says %r kernel, not one" % said_kernel)
    if len(set(targets)) != 1:
        problems.append("the check does not name exactly one target file: %s"
                        % sorted(set(targets)))
    if not target or not target.endswith(".mbt"):
        problems.append("the check's target is not a .mbt file: %r" % (target,))

    if not record:
        problems.append("the verdict record is missing")
    else:
        if record.get("applied") != len(muts):
            problems.append("the record applied %s mutants, the check defines %d"
                            % (record.get("applied"), len(muts)))
        if record.get("killed") != record.get("applied"):
            problems.append("the record killed %s of %s"
                            % (record.get("killed"), record.get("applied")))
        rec_names = sorted(m.get("name") for m in record.get("mutants", []))
        src_names = sorted(n for n, _ in muts)
        if rec_names != src_names:
            problems.append("the record covers %s, the check defines %s"
                            % (rec_names, src_names))
        for mrec in record.get("mutants", []):
            if mrec.get("verdict") != "killed":
                problems.append("the record says %r is %r"
                                % (mrec.get("name"), mrec.get("verdict")))

    if target and target_text is not None:
        for name, anchor in muts:
            if anchor not in target_text:
                problems.append("the anchor of %r no longer occurs in %s"
                                % (name, target))
    if workflows_hits:
        problems.append("a workflow would run the mutation check: %s"
                        % "; ".join(workflows_hits))
    return problems, target, muts


# ------------------------------------------------------------------- the claim
readme = read(README)
checks_src = read(CHECKS)
record = json.loads(read(RECORD)) if os.path.isfile(RECORD) else None

target, muts, _targets = parse_mutation_check(checks_src)
print("the check's own definition: %d mutant(s) on %s"
      % (len(muts), target))
for n, _a in muts:
    print("   %s" % n)
print("the record: %s" % (("%d/%d killed" % (record["killed"], record["applied"]))
                           if record else "MISSING"))
print()

target_path = os.path.join(ROOT, "moonbit_doubleML", target) if target else None
target_text = read(target_path) if target_path and os.path.isfile(target_path) else None
if target_text is None:
    print("  *** FAIL ***  the mutation target file is missing")
    FAILS.append("the mutation target file exists")
    N += 1

problems, _t, _m = audit(checks_src, record, target_text,
                         workflows_running_mutation(), readme)
for p in problems:
    print("  *** FAIL ***  %s" % p)
check("the README's mutation claim agrees with the check and the record",
      not problems, "" if not problems else "; ".join(problems)[:110])

# ------------------------------------------------------------------ the control
print()
print("the control arm: three synthetic sources the rule has to disagree with")

# 1. the check defines FOUR mutants
C1 = checks_src.replace(
    '("flip comparison", lambda s: s.replace(">=", ">", 1)),',
    '("flip comparison", lambda s: s.replace(">=", ">", 1)),\n'
    '    ("a fourth mutant", lambda s: s.replace("let mut cur_sum = w[i] * y[i]",'
    ' "let mut cur_sum = w[i] * y[i]", 1)),')
p1, _t, _m = audit(C1, record, target_text, [], readme)
check("a FOURTH mutant is REJECTED", bool(p1),
      "the README's count no longer matches the check")

# 2. the record says one mutant survived
C2 = dict(record) if record else {}
C2["mutants"] = [dict(m) for m in (record or {}).get("mutants", [])]
if C2["mutants"]:
    C2["mutants"][0]["verdict"] = "SURVIVED"
C2["killed"] = 2
p2, _t, _m = audit(checks_src, C2, target_text, [], readme)
check("a record with a SURVIVING mutant is REJECTED", bool(p2),
      "the README says they are all killed")

# 3. a mutant whose anchor is gone
p3, _t, _m = audit(checks_src, record, "the target file no longer holds this\n",
                   [], readme)
check("a mutant whose anchor is GONE is REJECTED", bool(p3),
      "the record cannot describe the tree")

print()
print("=" * 78)
print("%d checks, %d failed" % (N, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
if FAILS:
    sys.exit(1)
print("ALL PASS")
