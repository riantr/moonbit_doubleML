"""Run every `validate_*_with_python.py` and report a one-line verdict each.

CHECKS BOTH HALVES OF CI'S CONTRACT
===================================
`check.yml`'s `python-cross-check` step does two things per script:

  1. run it, require exit 0; and
  2. require the script's **TRAILING line** to contain `PASS`.

Checking only the exit code is how `validate_rdd_with_python.py` shipped a
build that failed on ubuntu while passing locally: every row matched, the exit
code was 0, and the last line printed was `MATCH fuzzy_se ...` because two rows
were appended after the verdict. Nothing local could see it. So this script
reproduces BOTH conditions, and reports which half failed.
"""
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REWRITTEN = {
    "validate_blp_policy_with_python.py",
    "validate_bootstrap_with_python.py",
    "validate_cvar_with_python.py",
    "validate_cv_repeated_with_python.py",
    "validate_did_binary_with_python.py",
    "validate_did_cs_with_python.py",
    "validate_gain_statistics_with_python.py",
    "validate_padjust_with_python.py",
    "validate_quantile_with_python.py",
    "validate_rdd_with_python.py",
}


def main():
    scripts = sorted(glob.glob(os.path.join(ROOT, "validate_*_with_python.py")))
    results = []
    for path in scripts:
        name = os.path.basename(path)
        proc = subprocess.run(
            [sys.executable, path], cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=2400,
        )
        out = proc.stdout or ""
        lines = [ln for ln in out.splitlines() if ln.strip()]
        n_rows = sum(1 for ln in lines
                     if ln.strip().startswith(("MATCH ", "DIFFER ")))
        last = lines[-1].strip() if lines else "<no output>"
        rc_ok = proc.returncode == 0
        tail_ok = "PASS" in last
        tag = "REWRITTEN" if name in REWRITTEN else "pre-existing"
        verdict = "PASS" if (rc_ok and tail_ok) else "FAIL"
        results.append((name, verdict, proc.returncode, n_rows, tag, tail_ok, last))
        note = "" if tail_ok else "   <-- trailing line lacks PASS"
        print("%-4s %-46s rc=%-4d rows=%-4d %s%s"
              % (verdict, name, proc.returncode, n_rows, tag, note), flush=True)

    failed = [r for r in results if r[1] != "PASS"]
    print()
    print("=" * 70)
    print("%d/%d pass (exit 0 AND trailing line contains PASS)"
          % (len(results) - len(failed), len(results)))
    for name, verdict, rc, rows, tag, tail_ok, last in failed:
        print("  FAIL %s (rc=%d, trailing-line PASS=%s)" % (name, rc, tail_ok))
        print("        last line: %r" % last[:100])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
