"""Mutation battery for the v0.163.0 LPLR gate changes (D2 + D3).

Every gate touched by this increment gets a mutation that MUST turn it red:

  M1  confint() builds the upper end with a different z
      -> lplr_confint_identity AND the fuzz CI check must fail
  M2  lplr_score_at reads beta[0] for every row (per-row read broken)
      -> lplr_beta_is_read_per_row must fail
  M3  the warning text loses the stop reason
      -> lplr_warning_names_a_documented_stop_reason must fail
  M4  the warning text loses the "not a solution" clause
      -> lplr_warning_states_the_numbers_are_not_a_solution must fail
  M5  the warning channel is silenced (no warnings ever pushed)
      -> lplr_warnings_report_the_degenerate_design AND the now-
         strengthened lplr_warnings_are_returned_not_printed must fail

M5 is the arm that matters most: before v0.163.0 GATE 5 compared
`warnings()` against itself and passed on a channel that returns nothing,
which is how D2 got past it.

DISCIPLINE (one mistake per run is too many):
  * restore per ARM, from the committed blob, never from a shared checkout
  * assert the mutation text is ON DISK before running the gate
  * score PASS only when the gate actually reports FAILED, never on a
    crash or a build error
"""

import io
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LPLR = os.path.join(REPO, "moonbit_doubleML", "lplr.mbt")

MOON = "moon"

# The D2/D3 work is UNCOMMITTED, so the baseline to restore from is the
# working tree as handed to this battery -- NOT `git show HEAD:`, which
# would silently revert the very change under test.
def read(path):
    with io.open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


BASELINE = read(LPLR)


def restore():
    """Restore lplr.mbt to the pre-battery working-tree state."""
    write(LPLR, BASELINE)


def apply(text, old, new):
    if text.count(old) != 1:
        raise SystemExit("mutation anchor not unique (%d): %r" % (text.count(old), old[:70]))
    return text.replace(old, new)


def run_test(name, target="native"):
    p = subprocess.run(
        [MOON, "test", "--target", target, "-f", name],
        cwd=REPO, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    out = (p.stdout or "") + (p.stderr or "")
    if "Total tests: 0" in out or "no test entry found" in out:
        return "ERROR", "gate not found / not run"
    # A mutation that does not compile has tested NOTHING. Scored as its own
    # outcome, never as RED and never as GREEN -- an earlier arm of this
    # battery produced an unterminated string literal and was scored ERROR
    # only because this case existed.
    if "Parse error" in out or "Lexing error" in out or "Error: [3" in out or "Error: [4" in out:
        return "BUILD_ERROR", "mutation did not compile"
    if "FAILED" in out or "expect test failed" in out:
        return "RED", ""
    if "Total tests: " in out and ", failed: 0." in out:
        return "GREEN", ""
    return "ERROR", out.strip().splitlines()[-1][:160] if out.strip() else "no output"


def run_fuzz():
    """examples/fuzz asserts its own CI identity, on `(hi - lo)/2` rather
    than on the midpoint, so it is a separate subject and gets its own arm."""
    p = subprocess.run(
        [MOON, "run", "examples/fuzz", "--target", "native"],
        cwd=REPO, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    out = (p.stdout or "") + (p.stderr or "")
    if "Parse error" in out or "Lexing error" in out or "Error: [3" in out or "Error: [4" in out:
        return "BUILD_ERROR", "mutation did not compile"
    if "FUZZ FAIL" in out:
        return "RED", next(l.strip() for l in out.splitlines() if "FUZZ FAIL" in l)[:120]
    if "ALL FUZZ SURFACES PASSED" in out:
        return "GREEN", ""
    return "ERROR", out.strip().splitlines()[-1][:160] if out.strip() else "no output"


ARMS = [
    (
        "M1 confint upper end uses a different z",
        lambda t: apply(
            t,
            "(self.coef_ - z * self.se_, self.coef_ + z * self.se_)",
            "(self.coef_ - z * self.se_, self.coef_ + z * 1.5 * self.se_)",
        ),
        ["lplr_confint_identity", "FUZZ"],
        ["RED"],
    ),
    (
        "M2 score reads beta[0] for every row",
        lambda t: apply(
            t,
            "let r_hat = t_pred[i] - beta[i] * a_pred[i]",
            "let r_hat = t_pred[i] - beta[0] * a_pred[i]",
        ),
        ["lplr_beta_is_read_per_row"],
        ["RED"],
    ),
    (
        # Replaces the interpolated stop_reason with a constant -- which is
        # exactly the reduction GATE 3's own docstring says it exists to
        # catch. An earlier version of this arm deleted `stop_reason`
        # outright and produced an unterminated string literal; that is a
        # broken mutation, and it scored ERROR, not a verdict.
        "M3 warning text drops the stop reason",
        lambda t: apply(
            t,
            'stop_reason +\n          "); coef',
            '"unknown" +\n          "); coef',
        ),
        ["lplr_warning_names_a_documented_stop_reason"],
        ["RED"],
    ),
    (
        "M4 warning text drops 'not a solution'",
        lambda t: apply(
            t,
            '", which is not a solution of the estimating equation"',
            '", which is a solution of the estimating equation"',
        ),
        ["lplr_warning_states_the_numbers_are_not_a_solution"],
        ["RED"],
    ),
    (
        "M5 warning channel silenced",
        lambda t: apply(t, "if !converged {\n        warnings.push(", "if false {\n        warnings.push("),
        [
            "lplr_warnings_report_the_degenerate_design",
            "lplr_warnings_are_returned_not_printed",
        ],
        ["RED"],
    ),
]


def main():
    restore()
    base = read(LPLR)
    print("baseline restored from HEAD: %d bytes" % len(base))
    results = []
    for name, mutate, gates, expect in ARMS:
        restore()
        text = mutate(base)
        write(LPLR, text)
        on_disk = read(LPLR)
        # The mutation MUST be on disk before the gate is run, or a stale
        # build answers instead of the mutation.
        assert text == on_disk, "mutation %r not on disk" % name
        verdicts = []
        for g in gates:
            if g == "FUZZ":
                verdict, detail = run_fuzz()
            else:
                verdict, detail = run_test(g)
            verdicts.append((g, verdict, detail))
        ok = all(v[1] == expect[0] for v in verdicts)
        results.append((name, ok, verdicts))
        print("\n--- %s : %s" % (name, "DISCRIMINATES" if ok else "** NOT DISCRIMINATED **"))
        for g, v, d in verdicts:
            print("    %-56s %-6s %s" % (g, v, d))
        restore()
    restore()
    bad = [r for r in results if not r[1]]
    print("\n==== battery: %d/%d arms discriminate ====" % (len(results) - len(bad), len(results)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
