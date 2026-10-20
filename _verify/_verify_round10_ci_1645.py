"""Round 10 verifier: the QA LOOP / CI coverage claims must match the code.

WHAT THIS PINS
--------------
The shipped README describes what the CI gates and the QA LOOP actually cover.
That description is a set of falsifiable claims, and this verifier derives
each one from the artefact and compares it with the prose:

  1. the registry's size, its fast/full split, and the fast/full name sets;
  2. the "N required activities" count, derived from `qa_process` itself;
  3. how many of the nine CI-table gates run on a push to master, derived by
     probing each workflow for the commands that implement the gate;
  4. which full-scope checks no CI workflow runs, derived by applying
     run.py's OWN scope semantics to each workflow's `run.py` invocations;
  5. the number of job instances the master CI run has, derived from
     check.yml's job list and its matrix width.

Every number on the README's side is matched against the derived value, so the
check cannot rot into a literal.

THE PROBE SET IS PART OF THIS FILE'S CONTRACT
---------------------------------------------
Step 3 maps a table row to a workflow by searching for the command that
implements it. Two rules make that mapping sound, and both were learned the
hard way:

  * A probe matches only inside a step's `run:` BODY. A YAML comment that
    mentions a command proves nothing about what CI executes -- and the first
    version of this file matched `moon check` inside a COMMENT in check.yml and
    concluded that check.yml runs `moon check`. It does not. The comment was
    added by this very round, to say the opposite.
  * A probe match is ignored when the matching line is a shell comment
    (`# ...`). publish.yml's publish step is full of them.

If a gate is re-implemented, the probe has to change with it -- and until it
does, this verifier reports a DEFECT, which is the intended behaviour: a gate
that moves must not silently stop being measured.
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, ".github", "workflows")
README = os.path.join(ROOT, "README.mbt.md")
# round 18: the PROJECT document -- the CI harness, the QA registry and
# the release history.  The LIBRARY document is `README.mbt.md`.
PROJ = os.path.join(ROOT, "ENGINEERING.md")
CHECKS_PY = os.path.join(ROOT, ".github", "scripts", "qa_loop", "checks.py")

RESULTS = []


def ok(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print("  %s  %s%s" % ("PASS" if cond else "FAIL", name,
                         ("   [%s]" % detail) if detail else ""))


def read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def load_registry():
    spec = importlib.util.spec_from_file_location("qa_checks_r10", CHECKS_PY)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["qa_checks_r10"] = mod
    spec.loader.exec_module(mod)
    return mod


# --- number rendering ------------------------------------------------------ #
WORDS = {0: "zero", 1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
         6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten"}


def num_re(n):
    """A number written either as a digit or as an English word."""
    w = WORDS.get(n)
    return "(?:%d|%s)" % (n, w) if w else str(n)


def claim_mentions(txt, n, pattern, flags=re.S):
    """Does `txt` contain `pattern` with an @N@ slot filled by n (digit or word)?"""
    rx = pattern.replace("@N@", num_re(n))
    return bool(re.search(rx, txt, flags))


# --- run.py scope semantics ------------------------------------------------ #
def qa_invocations(txt):
    """Every `run.py` invocation in a workflow, with its flags.

    A `run:` body may wrap with a trailing backslash, so the flags can live on
    the NEXT line. Reading only the first line silently dropped `--only
    api_test,security_dast` and made the invocation look like a whole-registry
    run -- the same class of bug as the gherkin continuation-join.
    """
    joined = re.sub(r"\\\s*\n", " ", txt)
    inv = []
    for m in re.finditer(r"python3?\s+\.github/scripts/qa_loop/run\.py([^\n]*)", joined):
        flags = m.group(1)
        only = re.search(r"--only\s+([A-Za-z0-9_,]+)", flags)
        inv.append({"only": [x.strip() for x in only.group(1).split(",")] if only else None,
                    "full": "--full" in flags})
    return inv


def checks_run_by(txt, fast, full):
    ran, skipped = set(), set()
    for inv in qa_invocations(txt):
        if inv["only"] is None:
            for c in fast:
                ran.add(c)
            for c in full:
                (ran if inv["full"] else skipped).add(c)
        else:
            for c in inv["only"]:
                if c in fast:
                    ran.add(c)
                elif c in full:
                    (ran if inv["full"] else skipped).add(c)
    return ran, skipped


# --- YAML step extraction (no yaml dependency) ----------------------------- #
def run_bodies(txt):
    """Every step's `run:` body, verbatim, in order.

    A body is either the text after `run:` on the same line, or the block that
    follows it at a deeper indentation. Only the BODIES are returned: a
    step's `name:` and the YAML comments above it are not commands.
    """
    bodies = []
    lines = txt.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)(?:-\s+)?run:\s*(.*)$", lines[i])
        if not m:
            i += 1
            continue
        indent, rest = m.group(1), m.group(2).strip()
        if rest and rest not in ("|", ">", "|-", ">-", "|+", ">+"):
            bodies.append(rest)
            i += 1
            continue
        j, block = i + 1, []
        while j < len(lines):
            ln = lines[j]
            if not ln.strip():
                block.append("")
                j += 1
                continue
            cur = len(ln) - len(ln.lstrip())
            if cur <= len(indent):
                break
            block.append(ln.strip())
            j += 1
        bodies.append("\n".join(block))
        i = j
    return bodies


def body_executes(txt, pattern):
    """Does any step's run body actually invoke `pattern`?

    A match on a shell-comment line is not an execution.
    """
    rx = re.compile(pattern)
    for body in run_bodies(txt):
        for ln in body.splitlines():
            s = ln.strip()
            if not s or s.startswith("#"):
                continue
            if rx.search(s):
                return True
    return False


# --- gate probes (part of this file's contract) ---------------------------- #
# gate label -> regex that must appear in a step's run body for the gate to run.
GATE_PROBES = [
    ("readme-sync",     r"check_readme_sync\.py"),
    ("build+test",      r"\bmoon test\b"),
    ("fmt",             r"moon fmt --check"),
    ("moon check",      r"\bmoon check\b"),
    ("interface drift", r"\bmoon info\b"),
    ("validators",      r"validate_\*_with_python\.py"),
    ("pyexample",       r"\bpyexample_"),
    ("qa loop",         r"qa_loop/run\.py"),
]

# Gates that a workflow can also reach INDIRECTLY, through the QA LOOP.
# The mapping is derived from the registry, not typed: the fast scope holds
# every `pyexample_*` check and the `static_code_check` check, so a workflow
# that runs the fast scope runs those gates too.
def indirect_gates(qa_ran):
    gates = set()
    if "static_code_check" in qa_ran:
        gates.add("typos")
    if any(c.startswith("pyexample") for c in qa_ran):
        gates.add("pyexample")
    return gates


def main():
    mod = load_registry()
    checks = mod.CHECKS
    ids = [c["id"] for c in checks]
    fast = [c["id"] for c in checks if c["scope"] == "fast"]
    full = [c["id"] for c in checks if c["scope"] == "full"]
    other = [c["id"] for c in checks if c["scope"] not in ("fast", "full")]

    # Round 18 split the documentation in two: `README.mbt.md` is the LIBRARY
    # document and `ENGINEERING.md` is the PROJECT document.  Everything this
    # verifier checks -- the QA registry, the CI gate table, the full-scope
    # coverage, the master run's job count -- describes this repository, so it
    # lives in the project document and the checks below read that.  The
    # numbers are still derived from `checks.py` / `check.yml` / `publish.yml`
    # above, so nothing here can rot.
    txt = read(PROJ)
    readme = read(README)
    both = txt + "\n" + readme
    check_txt = read(os.path.join(WF, "check.yml"))
    pub_txt = read(os.path.join(WF, "publish.yml"))

    print("=" * 78)
    print("ROUND 10 -- QA LOOP / CI COVERAGE CLAIMS")
    print("=" * 78)

    # -- 1. the registry itself ------------------------------------------- #
    print("\n[1] registry")
    ok("no check has a scope other than fast/full", not other, repr(other))
    ok("check ids are unique", len(ids) == len(set(ids)))
    ok("fast + full accounts for every registered check",
       len(fast) + len(full) == len(checks),
       "%d + %d vs %d" % (len(fast), len(full), len(checks)))

    src = read(CHECKS_PY)
    m = re.search(r"required\s*=\s*\{(.*?)\}", src, re.S)
    required = sorted({x.strip().strip('"\'') for x in m.group(1).replace("\n", " ").split(",")
                       if x.strip()})
    ok("every required activity has a registered check",
       not [r for r in required if r not in ids],
       repr([r for r in required if r not in ids]))

    # -- 2. the README's registry description ----------------------------- #
    print("\n[2] the README's registry description")
    bullet = {}
    for scope in ("fast", "full"):
        mm = re.search(r"^-\s*%s\s*\((\d+)\)\s*:(.*?)(?=^-\s|\n\n)" % scope, txt, re.S | re.M)
        if not mm:
            ok("the project document has a %s bullet" % scope, False)
            continue
        bullet[scope] = {"n": int(mm.group(1)), "names": re.findall(r"`([^`]+)`", mm.group(2))}
    ok("the project document's fast bullet lists exactly the fast scope",
       set(bullet.get("fast", {}).get("names", [])) == set(fast),
       "sym-diff %r" % sorted(set(bullet.get("fast", {}).get("names", [])) ^ set(fast)))
    ok("the project document's full bullet lists exactly the full scope",
       set(bullet.get("full", {}).get("names", [])) == set(full),
       "sym-diff %r" % sorted(set(bullet.get("full", {}).get("names", [])) ^ set(full)))
    ok("the project document's fast bullet count is the derived fast count",
       bullet.get("fast", {}).get("n") == len(fast),
       "%s vs %d" % (bullet.get("fast", {}).get("n"), len(fast)))
    ok("the project document's full bullet count is the derived full count",
       bullet.get("full", {}).get("n") == len(full),
       "%s vs %d" % (bullet.get("full", {}).get("n"), len(full)))
    ok("the project document states the derived total check count",
       claim_mentions(txt, len(checks), r"registers\s*\*\*@N@\s*checks\*\*"))
    ok("the project document states the derived required-activity count",
       claim_mentions(txt, len(required),
                      r"over the \*\*@N@\*\*\s*\n?required activities"),
       "required=%d" % len(required))

    # -- 3. the nine CI gates --------------------------------------------- #
    print("\n[3] the CI gate table")
    tm = re.search(r"^\|\s*Gate\s*\|\s*Where\s*\|\s*Scope\s*\|\s*\n\|[^\n]*\|\n"
                   r"((?:\|[^\n]*\|\n)+)", txt, re.M)
    rows = []
    if tm:
        for line in tm.group(1).splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) == 3:
                rows.append(cells)
    ok("the CI table has nine rows", len(rows) == 9, "rows=%d" % len(rows))

    check_qa = checks_run_by(check_txt, fast, full)[0]
    pub_qa = checks_run_by(pub_txt, fast, full)[0]

    def gate_runs(wf_txt, qa_ran, label, pat):
        if body_executes(wf_txt, pat):
            return True
        return label in indirect_gates(qa_ran)

    push_gates, pub_gates = [], []
    for label, pat in GATE_PROBES:
        c = gate_runs(check_txt, check_qa, label, pat)
        p = gate_runs(pub_txt, pub_qa, label, pat)
        if c:
            push_gates.append(label)
        if p:
            pub_gates.append(label)
    # `typos` has no direct probe of its own: it is a `run: typos` line in
    # publish.yml and, in check.yml, the QA LOOP's static_code_check.
    for label, wf_txt, qa_ran, acc in (("typos", check_txt, check_qa, push_gates),
                                        ("typos", pub_txt, pub_qa, pub_gates)):
        if body_executes(wf_txt, r"^\s*typos\s*$") or "typos" in indirect_gates(qa_ran):
            if label not in acc:
                acc.append(label)

    n_push, n_pub = len(push_gates), len(pub_gates)
    print("    push to master : %d  %s" % (n_push, ", ".join(sorted(push_gates))))
    print("    before publish : %d  %s" % (n_pub, ", ".join(sorted(pub_gates))))
    ok("the project document states the derived 'run on push' count",
       claim_mentions(txt, n_push, r"gates,\s*\*\*@N@ of which run on push"),
       "derived %d" % n_push)
    ok("the project document states the derived 'run before publishing' count",
       claim_mentions(txt, n_pub, r"\*\*@N@ of the nine also run"), "derived %d" % n_pub)

    for label, pat in (("moon check", r"moon check"), ("interface drift", r"interface")):
        row = next((r for r in rows if pat.lower() in " ".join(r).lower()), None)
        ok("the table marks the publish-only gate '%s'" % label,
           row is not None and "publish-only" in " ".join(row),
           (" ".join(row)[:70] if row else "row not found"))

    row = next((r for r in rows if "typos" in " ".join(r)), None)
    ok("the table's typos row names both workflows",
       row is not None and "publish.yml" in row[1] and "check.yml" in row[1],
       (row[1][:70] if row else "row not found"))

    # -- 4. the full scope ------------------------------------------------- #
    print("\n[4] the full scope")
    ran_any = check_qa | pub_qa
    full_in_ci = [c for c in full if c in ran_any]
    full_nowhere = [c for c in full if c not in ran_any]
    print("    full-scope checks that run in CI   : %d  %s"
          % (len(full_in_ci), ", ".join(full_in_ci)))
    print("    full-scope checks that run NOWHERE: %d  %s"
          % (len(full_nowhere), ", ".join(full_nowhere)))
    ok("no workflow runs the full scope as a scope",
       not any(inv["full"] and inv["only"] is None
               for inv in qa_invocations(check_txt) + qa_invocations(pub_txt)))
    ok("the project document states the derived 'full-scope checks that run in CI' count",
       claim_mentions(txt, len(full_in_ci), r"\*\*@N@\s*\n?run in CI\*\*"),
       "derived %d" % len(full_in_ci))
    ok("the project document states the derived 'full-scope checks that run nowhere' count",
       claim_mentions(txt, len(full_nowhere), r"\*\*@N@\s*\n?run in\s*\n?no CI workflow at all\*\*"),
       "derived %d" % len(full_nowhere))
    for cid in full_nowhere:
        ok("the project document names the uncovered full-scope check '%s'" % cid,
           ("`%s`" % cid) in txt)

    # -- 5. the master CI run's job instances ------------------------------ #
    print("\n[5] the master CI run")
    jm = re.search(r"^jobs:\s*$(.*?)(?=^\S|\Z)", check_txt, re.S | re.M)
    jobs_block = jm.group(1) if jm else ""
    jobs = re.findall(r"^  ([A-Za-z0-9_.-]+):\s*$", jobs_block, re.M)
    instances = 0
    for j in jobs:
        blk = re.search(r"^  %s:\s*$(.*?)(?=^  [A-Za-z0-9_.-]+:\s*$|\Z)" % re.escape(j),
                        jobs_block, re.S | re.M)
        width = 1
        if blk:
            mv = re.search(r"target:\s*\[([^\]]*)\]", blk.group(1))
            if mv:
                width = len([x for x in mv.group(1).split(",") if x.strip()])
        instances += width
    ok("the derived job-instance count is the one the project document states",
       claim_mentions(txt, instances, r"\*\*@N@ jobs\*\*"),
       "derived %d from %d job definitions" % (instances, len(jobs)))

    # -- 6. the retracted phrases must stay retracted ---------------------- #
    print("\n[6] retracted claims")
    for phrase, where in (("all of which run on push", "both documents"),
                          ("which is release-time", "both documents"),
                          ("The 21 QA activities", "publish.yml"),
                          # the `contract` check's own evidence string said the
                          # script "no workflow runs it" -- printed BY the
                          # fast-scope run that executes it.
                          ("so no workflow runs it", "checks.py")):
        if where == "both documents":
            body = both
        elif where == "publish.yml":
            body = pub_txt
        else:
            body = src
        ok("'%s' is absent from %s" % (phrase, where), phrase not in body)

    # -- 7. the publish workflow's own count ------------------------------- #
    print("\n[7] publish.yml")
    ok("publish.yml states the derived required-activity count",
       claim_mentions(pub_txt, len(required), r"The @N@ QA activities"),
       "required=%d" % len(required))

    bad = [n for n, o, _ in RESULTS if not o]
    print("\n" + "=" * 78)
    print("%d/%d checks passed" % (len(RESULTS) - len(bad), len(RESULTS)))
    if bad:
        print("FAILED: " + ", ".join(bad))
    print("=" * 78)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
