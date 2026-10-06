"""v0.105.0: META-GATE over the cross-validator suite.

WHY THIS FILE EXISTS
====================
v0.103.0 audited the 23 `validate_*_with_python.py` files by hand and
wrote the result into the CHANGELOG as prose. Prose does not fail.
Three of the files in the audit's own "fails open" and "never runs"
categories -- `pava` (hard-coded PASS with a `subprocess` import it
never calls), `apos`, `did_cs_binary` -- kept their shape for a
release after that. An audit is only worth something if the next
refactor cannot quietly undo it, so the classification now lives here
as assertions over the source.

THE CI CONTRACT THIS PROTECTS
=============================
`.github/workflows/check.yml` runs each validator, takes the LAST line
of stdout, and requires it to contain `PASS` (case-sensitive). So a
validator's verdict is its last *printed* line, not its last source
line -- the file ends with `if __name__ == "__main__": main()`. This
gate checks the source shape that produces such a line.

WHAT IT CHECKS, mechanically
============================
For every `validate_*_with_python.py`:

  1. It emits a COMPUTED verdict -- some string in the file contains
     both `PASS` and `FAIL`, the `"... " + ("PASS" if ok else
     "FAIL")` shape. A file that emits neither cannot satisfy the CI
     contract at all.
  2. It contains no UNCONDITIONAL hard-coded verdict: a `print` whose
     argument is a bare string literal ending in `PASS`. That is the
     shape that let `validate_pava_with_python.py` report success for
     a cross-check it never performed, for many versions.
  3. It really spawns `moon`, if it is on MUST_READ_MOONBIT: an actual
     `subprocess.run` / `check_output` / `Popen` whose arguments
     contain a `"moon"` literal. An `import subprocess` that is never
     called does not count -- that is exactly the `pava` shape.
  4. It does NOT spawn `moon`, if it is on MUST_NOT_READ_MOONBIT.
  5. It can fail: a MUST_BE_FAIL_CLOSED file must contain a construct
     that produces a non-zero process exit.

KNOWN-HARDCODED-VERDICT
=======================
Eight reference-only validators still print a literal `PASS`. That
is a real defect and it is not this version's job to fix eight
files, so instead of hiding it, the set is written out here and
asserted against what is on disk. Fixing one means deleting it from
this list in the same commit, which puts the fix in the diff. The
point is that the defect is now a reviewable list rather than a
sentence in a changelog.

FAIL-CLOSED: any classification error exits non-zero.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# --------------------------------------------------------------------------
# The expectation table. Every one of the 23 files must appear, with its
# current classification. Editing a validator's wiring means editing this
# table in the same commit, and that diff is the review surface.
# --------------------------------------------------------------------------
# Spawn `moon`, parse its output, and exit non-zero if any of that fails.
MUST_READ_MOONBIT = {
    "validate_apos_with_python.py",
    "validate_cluster_iv_with_python.py",
    "validate_cluster_plr_with_python.py",
    "validate_did_with_python.py",
    "validate_did_cross_section_with_python.py",
    "validate_did_cs_binary_with_python.py",
    "validate_iivm_with_python.py",
    "validate_irm_with_python.py",
    "validate_lplr_with_python.py",
    "validate_pava_with_python.py",
    "validate_pliv_with_python.py",
    "validate_plpr_with_python.py",
    "validate_ssm_with_python.py",
}

MUST_BE_FAIL_CLOSED = MUST_READ_MOONBIT

# Reference-only: validate a Python re-implementation, never run MoonBit.
MUST_NOT_READ_MOONBIT = {
    "validate_blp_policy_with_python.py",
    "validate_bootstrap_with_python.py",
    "validate_cv_repeated_with_python.py",
    "validate_cvar_with_python.py",
    "validate_did_binary_with_python.py",
    "validate_did_cs_with_python.py",
    "validate_gain_statistics_with_python.py",
    "validate_padjust_with_python.py",
    "validate_quantile_with_python.py",
    "validate_rdd_with_python.py",
}

# Reference-only files whose verdict line is a typed literal. Known
# defect, tracked here rather than in prose. See the module docstring.
KNOWN_HARDCODED_VERDICT = {
    "validate_blp_policy_with_python.py",
    "validate_bootstrap_with_python.py",
    "validate_cv_repeated_with_python.py",
    "validate_gain_statistics_with_python.py",
    "validate_padjust_with_python.py",
    "validate_quantile_with_python.py",
    "validate_rdd_with_python.py",
}

SUBPROCESS_CALL = re.compile(r"subprocess\.(run|Popen|check_output|check_call)")
HARD_EXIT = re.compile(r"(sys\.exit\(\s*[1-9]|SystemExit\(\s*[1-9])")
HARD_EXIT_VIA_MAIN = re.compile(r"return\s+[1-9]")
SYS_EXIT_MAIN = re.compile(r"sys\.exit\(\s*main\(\)")


def spawns_moon(src: str) -> bool:
    """True only if the file ACTUALLY calls subprocess with a `moon` arg.

    Deliberately not `import subprocess`: `validate_pava` imported the
    module, defined `run_moonbit_pava` that raised NotImplementedError,
    never called it, and printed a hard-coded PASS. That file must fail
    this predicate, which is why the test is on the call site.
    """
    if not SUBPROCESS_CALL.search(src):
        return False
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return False
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if not (
            isinstance(func, ast.Attribute)
            and isinstance(func.value, ast.Name)
            and func.value.id == "subprocess"
        ):
            continue
        for arg in node.args:
            for sub in ast.walk(arg):
                if isinstance(sub, ast.Constant) and sub.value == "moon":
                    return True
    return False


def has_hard_coded_pass(src: str) -> bool:
    """True if a verdict line is a bare string literal ending in PASS.

    `"Cross-check: " + ("PASS" if ok else "FAIL")` is fine -- the
    literal is a fragment, not the verdict. `print("...: PASS")` is
    not: the verdict was typed, not computed.
    """
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return False
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)):
            continue
        if node.func.id != "print" or not node.args:
            continue
        arg = node.args[0]
        if not isinstance(arg, ast.Constant) or not isinstance(arg.value, str):
            continue
        if arg.value.rstrip().endswith("PASS"):
            return True
    return False


def emits_computed_verdict(src: str) -> bool:
    """True if the file carries both halves of a verdict expression.

    The shape is `"... " + ("PASS" if ok else "FAIL")` -- two separate
    literals, not one string mentioning both words, so this looks for a
    `PASS` literal and a `FAIL` literal anywhere in the source.
    """
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return False
    has_pass = has_fail = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if "PASS" in node.value:
                has_pass = True
            if "FAIL" in node.value:
                has_fail = True
    return has_pass and has_fail


def can_exit_nonzero(src: str) -> bool:
    return bool(HARD_EXIT.search(src) or (HARD_EXIT_VIA_MAIN.search(src) and SYS_EXIT_MAIN.search(src)))


def main() -> int:
    files = sorted(HERE.glob("validate_*_with_python.py"))
    problems: list[str] = []

    expected = MUST_READ_MOONBIT | MUST_NOT_READ_MOONBIT
    seen = {f.name for f in files}
    for missing in sorted(expected - seen):
        problems.append(f"{missing}: on the expectation table but not on disk")
    for extra in sorted(seen - expected):
        problems.append(f"{extra}: on disk but missing from the expectation table")

    print(f"meta-gate over {len(files)} cross-validators")
    print("-" * 78)
    print(
        f"{'validator':<44s} {'moon':>5s} {'verdict':>8s} "
        f"{'typed':>6s} {'exit':>5s}"
    )
    print("-" * 78)

    detected_typed: set[str] = set()

    for f in files:
        src = f.read_text(encoding="utf-8")
        spawns = spawns_moon(src)
        verdict = emits_computed_verdict(src)
        typed = has_hard_coded_pass(src)
        exits = can_exit_nonzero(src)
        if typed:
            detected_typed.add(f.name)

        print(
            f"{f.name:<44s} {('yes' if spawns else '-'):>5s} "
            f"{('ok' if verdict else 'MISSING'):>8s} "
            f"{('YES' if typed else '-'):>6s} "
            f"{('yes' if exits else '-'):>5s}"
        )

        if not verdict and f.name not in KNOWN_HARDCODED_VERDICT:
            problems.append(
                f"{f.name}: no string mentions both PASS and FAIL, so it "
                "cannot emit the verdict line CI greps for"
            )
        if f.name in MUST_READ_MOONBIT:
            if not spawns:
                problems.append(
                    f"{f.name}: MUST_READ_MOONBIT but never spawns `moon` via "
                    "subprocess (an unused `import subprocess` does not count)"
                )
            if typed:
                problems.append(
                    f"{f.name}: gate file prints a hard-coded '...PASS' "
                    "literal; its verdict must be computed"
                )
            if not exits:
                problems.append(
                    f"{f.name}: MUST_BE_FAIL_CLOSED but has no non-zero-exit "
                    "construct (`sys.exit(n>=1)`, `SystemExit(n>=1)`, or "
                    "`return n>=1` feeding `sys.exit(main())`)"
                )
        else:
            if spawns:
                problems.append(
                    f"{f.name}: MUST_NOT_READ_MOONBIT but spawns `moon`; "
                    "either wire it up or move it off the list deliberately"
                )
            if typed and f.name not in KNOWN_HARDCODED_VERDICT:
                problems.append(
                    f"{f.name}: prints a hard-coded '...PASS' literal and is "
                    "not on KNOWN_HARDCODED_VERDICT"
                )

    for stale in sorted(KNOWN_HARDCODED_VERDICT - detected_typed):
        problems.append(
            f"{stale}: on KNOWN_HARDCODED_VERDICT but no longer prints a "
            "hard-coded verdict -- remove it from the list (that is good news)"
        )

    print("-" * 78)
    print(
        f"gates (read MoonBit + fail-closed): {len(MUST_READ_MOONBIT)}   "
        f"reference-only: {len(MUST_NOT_READ_MOONBIT)}   "
        f"known typed verdicts: {len(detected_typed)}"
    )
    print()
    if problems:
        print(f"{len(problems)} problem(s):")
        for p in problems:
            print(f"  - {p}")
        print()
        print("Validator meta-gate: FAIL")
        return 1
    print("Validator meta-gate: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())