"""Round 11 verifier: the dated handoff/audit records must be labelled as
records, and the numbers they state must match the artefacts.

The class of defect this pins
-----------------------------
A file that records a past session and does not say so is a document that
describes a tree that no longer exists. Five tracked documents had that
shape, and one live source comment contradicted its own sibling document.
The checks below are DERIVED wherever a derivation exists:

  * the commit that introduced each document comes from `git log`, so the
    banner's date and commit id are checked against history, not against a
    literal in this file;
  * the predicate count comes from counting the `predicate` declarations in
    `kfold_view_proof.mbtp`, and the handoff's enumeration is compared with
    the file as a SET, so a missing predicate is a failure even if the prose
    count agrees with the prose list;
  * the main package's `proof-enabled` state is read from
    `moonbit_doubleML/moon.pkg`, and the pilot's comment is checked against
    it;
  * the pre-commit hook's tracked file mode comes from `git ls-files -s`.
"""
from __future__ import annotations

import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = []


def ok(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print("  %s  %s%s" % ("PASS" if cond else "FAIL", name,
                         ("   [%s]" % detail) if detail else ""))


def read(rel):
    with io.open(os.path.join(ROOT, rel.replace("/", os.sep)),
                 encoding="utf-8", errors="replace") as fh:
        return fh.read()


def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True,
                       text=True, encoding="utf-8", errors="replace", timeout=300)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def first_commit_that_added(rel):
    rc, out = git("log", "--diff-filter=A", "--format=%H", "--", rel)
    if rc != 0 or not out.strip():
        return None
    return out.strip().splitlines()[-1]


def commit_date(sha):
    rc, out = git("show", "-s", "--format=%ad", "--date=short", sha)
    return out.strip() if rc == 0 else ""


# --- the document set ------------------------------------------------------ #
# rel -> the path whose history dates the document
DOCS = {
    "_probe/TODO-9-handoff.md": "_probe/TODO-9-handoff.md",
    "_probe/TODO-10-handoff.md": "_probe/TODO-10-handoff.md",
    "_prove_pilot/HANDOFF.md": "_prove_pilot/HANDOFF.md",
    "_prove_pilot/VERIFIER_AUDIT.md": "_prove_pilot/VERIFIER_AUDIT.md",
    "_prove_pilot/VERIFIER_AUDIT_v2.md": "_prove_pilot/VERIFIER_AUDIT_v2.md",
}


def main():
    print("=" * 78)
    print("ROUND 11 -- THE DATED HANDOFF / AUDIT RECORDS")
    print("=" * 78)

    # -- 1. each dated record is labelled as one --------------------------- #
    print("\n[1] historical-record banners")
    for rel in DOCS:
        txt = read(rel)
        sha = first_commit_that_added(rel)
        date = commit_date(sha) if sha else ""
        short = sha[:7] if sha else ""
        ok("%s is labelled a HISTORICAL RECORD" % rel,
           "HISTORICAL RECORD" in txt)
        ok("%s names the commit that introduced it (%s)" % (rel, short),
           bool(short) and short in txt,
           "git says %s (%s)" % (short, date))
        ok("%s carries a 'What has changed since' table" % rel,
           "What has changed since" in txt)

    # -- 2. the pilot's own comment vs the main package -------------------- #
    print("\n[2] the pilot package's comment vs the real main package")
    pilot = read("_prove_pilot/moon.pkg")
    main_pkg = read("moonbit_doubleML/moon.pkg")
    ok("the main package's moon.pkg is NOT proof-enabled",
       "proof-enabled" not in main_pkg)
    ok("the pilot's comment no longer claims the main package is proof-enabled",
       "remains proof-enabled" not in pilot)
    ok("the pilot's comment states the main package's real state",
       "NOT proof-enabled" in pilot)
    ok("the pilot's comment warns that the package is not a workspace member",
       "moon.work" in pilot and "not a member" in pilot.lower())

    # the SECOND pilot package, tracked but mentioned by no handoff document
    pilot2 = read("_prove_pilot2/moon.pkg")
    ok("the second pilot's comment carries a dated status",
       "STATUS (measured" in pilot2)
    ok("the second pilot's comment says its claim is NOT re-verified",
       "re-verified" in pilot2 and "NOT been" in pilot2)
    ok("the second pilot's comment says it is not a workspace member",
       "moon.work" in pilot2 and "not a member" in pilot2.lower())
    ok("the second pilot's comment names the false-green -p form",
       "EXITS 0 while" in pilot2)

    # -- 3. the predicate count, derived from the file --------------------- #
    print("\n[3] the .mbtp predicate count")
    mbtp = read("_prove_pilot/kfold_view_proof.mbtp")
    preds = re.findall(r"^predicate\s+(\w+)", mbtp, re.M)
    ok("the .mbtp declares at least one predicate", preds, "%d found" % len(preds))
    handoff = read("_prove_pilot/HANDOFF.md")
    audit = read("_prove_pilot/VERIFIER_AUDIT.md")
    audit2 = read("_prove_pilot/VERIFIER_AUDIT_v2.md")

    m = re.search(r"\*\*(\d+)\*\*\s*named predicates", handoff)
    ok("the handoff states the DERIVED predicate count",
       m is not None and int(m.group(1)) == len(preds),
       "handoff says %s, file has %d" % (m.group(1) if m else "?", len(preds)))
    ok("the handoff does not still say 11 named predicates",
       "11 named predicates" not in handoff)
    # The v1 audit's Finding #5 RECOMMENDATION must carry the derived count.
    # Its "12 predicates (not 11)" string survives only as a QUOTATION inside
    # the correction, so the check is on the recommendation, not on the
    # absence of a substring.
    ok("the v1 audit's Finding #5 recommendation carries the derived count",
       ("%d predicates (not 11)" % len(preds)) in audit,
       "looking for '%d predicates (not 11)'" % len(preds))
    for label, doc in (("v1 audit", audit), ("v2 audit", audit2)):
        ok("the %s states the derived predicate count" % label,
           bool(re.search(r"(\*\*%d\*\*|\b%d\b)\s+named predicates"
                          % (len(preds), len(preds)), doc)),
           "looking for '%d named predicates'" % len(preds))

    # the enumeration, as a SET
    items = re.findall(r"^\d+\.\s+`(\w+)\(", handoff, re.M)
    listed = set(items)
    missing = sorted(set(preds) - listed)
    extra = sorted(listed - set(preds))
    ok("the handoff's predicate enumeration names every predicate in the file",
       not missing, "missing %r" % (missing or "none"))
    ok("the handoff's enumeration names nothing that is not in the file",
       not extra, "extra %r" % (extra or "none"))
    ok("the enumeration is numbered to the derived count",
       len(items) == len(preds),
       "%d numbered items vs %d predicates" % (len(items), len(preds)))

    # -- 4. the reproduce block is honest about what it does --------------- #
    print("\n[4] the reproduce block")
    ok("the handoff says the recorded commands no longer do what it says",
       "no longer do what this" in handoff)
    ok("the handoff names the 'not inside any known module' failure",
       "not inside any known module" in handoff)
    ok("the handoff flags the zero-test false green",
       "false green" in handoff and "Total tests: 0" in handoff)
    ok("the handoff records that moon prove does not run on native Windows",
       "moon prove` does not run on native Windows" in handoff
       or "does not run on native Windows" in handoff)
    ok("the v2 audit records that moon prove does not run on native Windows",
       "does not run on native Windows" in audit2)
    ok("the handoff records the pilot's 4 runtime tests still pass",
       "Total tests: 4, passed: 4, failed: 0" in handoff)

    # -- 5. the pre-commit hook README ------------------------------------- #
    print("\n[5] .githooks/README.md")
    rc, out = git("ls-files", "-s", ".githooks/pre-commit")
    mode = out.split()[0] if out.split() else "?"
    readme = read(".githooks/README.md")
    ok("the pre-commit hook is tracked as %s (not executable)" % mode,
       mode == "100644", "git says %s" % mode)
    ok("the README states the tracked mode", mode in readme,
       "looking for %s" % mode)
    ok("the README says the chmod step is always needed",
       "chmod +x" in readme and "not executable" in readme.lower())
    ok("the README says core.hooksPath is a local setting",
       "local" in readme.lower() and "cannot be committed" in readme.lower())
    ok("the README says what the hook actually runs",
       "moon check" in readme and "one" in readme)
    # Round 58: this check used to REQUIRE the sentence "does **not** check
    # `_test.mbt` files" -- it held the FALSEHOOD, not the truth.  `moon
    # check`'s own plan type-checks the `_test.mbt` files and the
    # `readme.mbt.md` doctests; only `moon test` RUNS them.
    ok("the README says moon check type-checks the test files but does not run them",
       "type-checks the `_test.mbt` files" in readme
       and "only `moon test` runs them" in readme)

    # -- 6. the artefact pointers these documents name --------------------- #
    print("\n[6] artefact pointers")
    missing = []
    for rel in list(DOCS) + ["_prove_pilot/moon.pkg", ".githooks/README.md"]:
        txt = read(rel)
        for path in set(re.findall(r"`(_probe/[A-Za-z0-9_.-]+)`", txt)):
            if not os.path.isfile(os.path.join(ROOT, path.replace("/", os.sep))):
                missing.append((rel, path))
    ok("every _probe/ artefact these documents name exists", not missing,
       repr(missing or "none"))

    bad = [n for n, o, _ in RESULTS if not o]
    print("\n" + "=" * 78)
    print("%d/%d checks passed" % (len(RESULTS) - len(bad), len(RESULTS)))
    if bad:
        print("FAILED: " + ", ".join(bad))
    print("=" * 78)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
