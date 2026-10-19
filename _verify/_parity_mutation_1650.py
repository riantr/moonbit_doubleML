"""Mutation battery: prove each rewritten validator can go RED.

A validator that has never been observed failing is not known to be able to
fail. This applies one targeted perturbation to `examples/parity/main.mbt` per
validator, runs that validator, and requires a non-zero exit. A mutation that
SURVIVES is reported, not excused.

RESTORE SAFETY
==============
Three things this script gets wrong on purpose would be catastrophic:

1. The restore lives in `finally` AND is verified by sha256, not assumed.
2. A clean-hash sidecar is checked BEFORE any backup is written, so a
   previously-dirty file can never be promoted into this run's baseline.
3. Every path is absolute. `[System.IO.File]` and PowerShell's `cd` disagree
   about the current directory; Python's `open` does not, but the lesson
   stands and absolute paths cost nothing.

Expect = 'KILLED' for all of them. Any SURVIVED is a real finding: either the
mutation was equivalent (removed and documented, never "fixed") or that
validator has a blind spot.

RUN
===
    python _verify/_parity_mutation_1650.py
"""
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "examples", "parity", "main.mbt")
SIDECAR = os.path.join(ROOT, "_verify", "_parity_clean.sha256")
BACKUP = os.path.join(ROOT, "_verify", "_parity_main.mbt.bak")

# (mutation name, exact old text, exact new text, validator to run)
MUTATIONS = [
    ("quantile: pq_coef nudged +0.05",
     'val("pq_coef", pq.coef())',
     'val("pq_coef", pq.coef() + 0.05)',
     "validate_quantile_with_python.py"),

    ("rdd: sharp_coef nudged +0.01",
     'val("sharp_coef", sharp.coef())',
     'val("sharp_coef", sharp.coef() + 0.01)',
     "validate_rdd_with_python.py"),

    ("cvar: empirical treated nudged +0.01",
     'val("cvar_empirical_treated", cvar_upper_half_mean(d, y, n, 1.0))',
     'val("cvar_empirical_treated", cvar_upper_half_mean(d, y, n, 1.0) + 0.01)',
     "validate_cvar_with_python.py"),

    ("blp_policy: coef_x0 nudged +0.01",
     'val("blp_coef_x0", bc[1])',
     'val("blp_coef_x0", bc[1] + 0.01)',
     "validate_blp_policy_with_python.py"),

    ("bootstrap: variance nudged +0.5",
     'val(m + "_var", wvar(w))',
     'val(m + "_var", wvar(w) + 0.5)',
     "validate_bootstrap_with_python.py"),

    ("bootstrap: m4 replaced by m3 (kills branch separation)",
     'val(m + "_m4", wmoment(w, 4))',
     'val(m + "_m4", wmoment(w, 3))',
     "validate_bootstrap_with_python.py"),

    ("did_binary: att nudged +0.1",
     'val("att", fitted.coef())',
     'val("att", fitted.coef() + 0.1)',
     "validate_did_binary_with_python.py"),

    ("did_cs: att_g0_t1 sign flipped",
     'val("att_g0_t1", fitted.coef_at(0, 1))',
     'val("att_g0_t1", -fitted.coef_at(0, 1))',
     "validate_did_cs_with_python.py"),

    ("cv_repeated: n_rep1_coef nudged +0.1",
     'val("n_rep1_coef", one.coef())',
     'val("n_rep1_coef", one.coef() + 0.1)',
     "validate_cv_repeated_with_python.py"),

    ("gain_statistics: cf_y replaced by 1 - cf_y",
     'val("cf_y_" + c.to_string(), res.cf_y[c])',
     'val("cf_y_" + c.to_string(), 1.0 - res.cf_y[c])',
     "validate_gain_statistics_with_python.py"),

    # Emitter-level, not value-level: if the PARSER silently ignored a `val`
    # line, every validator above would pass on a stale/absent number.
    ("emitter: val() prints a constant instead of its argument",
     'println("val " + label + " " + v.to_string())',
     'println("val " + label + " " + "0.0")',
     "validate_quantile_with_python.py"),
]

# Mutations that are EXPECTED TO SURVIVE, each with the reason it is
# equivalent. A survivor whose premise was wrong gets moved here and
# documented -- never "fixed" by weakening the validator it defeated.
#
# This is not a wish list. `REQUIRED_JUSTIFICATION` below makes an entry
# without a non-empty reason an error, so a mutation cannot be quietly
# retired by listing it.
EQUIVALENT = [
    ("padjust: first p-value 0.001 -> 0.003",
     'let p = [0.001, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9]',
     'let p = [0.003, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9]',
     "validate_padjust_with_python.py",
     "The validator reads the p-vector FROM the emitter and runs it through "
     "statsmodels itself, so both sides move together and the comparison is "
     "unaffected. The vector is the check's INPUT, not its expected value: "
     "the contract under test is 'p_adjust implements multipletests on "
     "whatever vector it is given', which this mutation does not violate. "
     "Also verified that TSBH_STATS_RATIO is invariant to it -- 0.003 is "
     "still < 0.05, so `#{p > alpha}` stays 3 and both m0_hat values are "
     "unchanged. Pinning the vector would test the fixture, not the port."),
]

REQUIRED_JUSTIFICATION = 60


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def verify_clean():
    """Refuse to run against an already-modified tree."""
    cur = sha256(TARGET)
    if os.path.exists(SIDECAR):
        with open(SIDECAR) as fh:
            want = fh.read().strip()
        if want != cur:
            print("REFUSING TO RUN: examples/parity/main.mbt does not match "
                  "the recorded clean hash.")
            print("  expected %s" % want)
            print("  actual   %s" % cur)
            print("Restore it first, e.g.:")
            print("  git checkout -- examples/parity/main.mbt")
            return False
    shutil.copyfile(TARGET, BACKUP)
    with open(SIDECAR, "w") as fh:
        fh.write(cur)
    return True


def restore():
    shutil.copyfile(BACKUP, TARGET)
    if sha256(TARGET) != sha256(BACKUP):
        raise RuntimeError("restore FAILED: file differs from backup")
    return True


def run_validator(name):
    proc = subprocess.run(
        [sys.executable, os.path.join(ROOT, name)], cwd=ROOT,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=2400,
    )
    return proc.returncode, (proc.stdout or "")


def main():
    for entry in EQUIVALENT:
        if len(entry[4].strip()) < REQUIRED_JUSTIFICATION:
            print("ERROR: equivalent mutation %r has no justification long "
                  "enough to justify retiring it (%d chars, need %d)."
                  % (entry[0], len(entry[4].strip()),
                     REQUIRED_JUSTIFICATION))
            return 3

    if not verify_clean():
        return 3

    results = []
    try:
        for label, old, new, validator in MUTATIONS:
            _run_one(label, old, new, validator, results, expect_killed=True)
        for label, old, new, validator, why in EQUIVALENT:
            print("-- %s\n   expected to SURVIVE: %s\n"
                  % (label, why[:400]), flush=True)
            _run_one(label, old, new, validator, results, expect_killed=False)
    finally:
        restore()

    killed = [r for r in results if r[2].startswith("KILLED")]
    survived = [r for r in results if r[2] == "SURVIVED"]
    other = [r for r in results if not r[2].startswith("KILLED")
             and r[2] != "SURVIVED"]
    equivalent_names = {e[0] for e in EQUIVALENT}

    unexpected_survivors = [r for r in survived if r[0] not in equivalent_names]
    expected_survivors = [r for r in survived if r[0] in equivalent_names]

    print()
    print("=" * 78)
    print("%d killed, %d survived (%d expected), %d inconclusive (of %d)"
          % (len(killed), len(survived), len(expected_survivors), len(other),
             len(results)))
    for label, validator, verdict, detail in unexpected_survivors + other:
        print("  UNEXPECTED %-11s %s  [%s: %s]" % (verdict, label, validator, detail))
    for label, validator, verdict, detail in expected_survivors:
        print("  as-documented  %s survived (equivalent mutation)" % label)
    print()
    print("tree restored: %s" % ("verified" if sha256(TARGET) == sha256(BACKUP)
                                 else "MISMATCH"))
    return 0 if not unexpected_survivors and not other else 1


def _run_one(label, old, new, validator, results, expect_killed):
    with open(TARGET, encoding="utf-8", newline="") as fh:
        text = fh.read()
    if text.count(old) != 1:
        results.append((label, validator, "AMBIGUOUS",
                        "anchor matched %d times" % text.count(old)))
        print("AMBIGUOUS %-52s (anchor matched %d times)"
              % (label, text.count(old)), flush=True)
        return
    mutated = text.replace(old, new)
    try:
        with open(TARGET, "w", encoding="utf-8", newline="") as fh:
            fh.write(mutated)
        rc, out = run_validator(validator)
    finally:
        restore()

    verdict = "KILLED" if rc != 0 else "SURVIVED"
    # A compile error also counts as killed, but say so -- it is a weaker
    # signal than a genuine comparison failure.
    if rc != 0 and ("Parse error" in out or "Error:" in out
                    or "error[" in out):
        verdict = "KILLED(compile)"
    results.append((label, validator, verdict, "rc=%d" % rc))
    want = "KILLED" if expect_killed else "SURVIVED"
    flag = "" if verdict.split("(")[0] == want else "   <-- UNEXPECTED"
    print("%-11s %-52s %-40s rc=%d%s"
          % (verdict, label, validator, rc, flag), flush=True)


if __name__ == "__main__":
    sys.exit(main())
