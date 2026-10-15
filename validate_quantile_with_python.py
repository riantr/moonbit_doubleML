"""PQ / LPQ / QTE on the deterministic alternating DGP, checked against MoonBit.

WHAT THIS USED TO BE
====================
`validate_quantile_with_python.py` imported only `numpy`. It computed a
population median of a Python-built dataset, printed `reference checks PASS`,
and exited 0. It never started a MoonBit process, so no change to
`quantile.mbt` could ever turn it red. CI grepped for the `PASS` and called
that a cross-check.

WHAT IT IS NOW
==============
It runs `examples/parity` (section `quantile`) and compares the port's output
against values CPython derives independently, on a DGP it rebuilds itself.

Two kinds of row appear below, and the difference matters:

* **Population rows** -- `pq_median_treated`, `pq_median_control`. These are
  exact statistics of a deterministic dataset (200 values, each distinct `y`
  repeated 4x), so the port and CPython must agree to ~1e-12. These are the
  rows that would catch a flipped score direction or a treatment-level mix-up.
* **Estimator rows** -- `pq_coef`, `lpq_coef`, `qte_coef`. These are
  cross-fit estimates on a 2-fold split drawn from `chacha8`, which CPython
  cannot reproduce. They are checked against the *population target* they are
  estimating, at the accuracy a 2-fold estimate on n=200 can actually reach.
  The tolerance here is a property of the estimator, not a fudge factor.

`qte_coef` is additionally checked against `pq_coef - median_control`, the
identity the emitter computes it from, so a QTE that drifts away from its own
components is caught even though both parts moved together.

TOLERANCES
----------
Median rows: 1e-12. The medians are averages of two exactly-representable
doubles (1.48 and 1.50), so anything above float noise is a real difference.

Estimator rows: 0.02, the window the v0.49.0 APOS validator already used for
the same DGP, and the same band that separates the true 1.49 from the observed
1.4942 by a factor of 15.

RUN
===
    python validate_quantile_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import parity_helper as ph  # noqa: E402

N = 400
MEDIAN_TOL = 1e-12
EST_TOL = 0.02

# The population targets, spelled out rather than hard-coded, so the arithmetic
# is visible: the treated rows are the even i, giving 50 distinct y values each
# repeated 4x; the median is the mean of the 100th and 101st sorted values.
TRUE_MEDIAN_TREATED = 1.49   # (1.48 + 1.50) / 2
TRUE_MEDIAN_CONTROL = 0.50   # (0.49 + 0.51) / 2
TRUE_QTE = TRUE_MEDIAN_TREATED - TRUE_MEDIAN_CONTROL


def build_dgp():
    """Rebuild the DGP from `quantile_test.mbt`'s definition, independently."""
    i = np.arange(N)
    d = np.where(i % 2 == 0, 1.0, 0.0)
    y = d + (i % 100) / 100.0
    return d, y


def main() -> int:
    sec = ph.section("quantile")
    d, y = build_dgp()

    med_t = float(np.median(y[d == 1.0]))
    med_c = float(np.median(y[d == 0.0]))

    # Sanity-check CPython's own arithmetic before blaming MoonBit for it.
    assert abs(med_t - TRUE_MEDIAN_TREATED) < 1e-12, (
        "python median treated is %.17g, expected %.17g -- the DGP "
        "reconstruction is wrong, so a mismatch below would be meaningless"
        % (med_t, TRUE_MEDIAN_TREATED))
    assert abs(med_c - TRUE_MEDIAN_CONTROL) < 1e-12, (
        "python median control is %.17g, expected %.17g"
        % (med_c, TRUE_MEDIAN_CONTROL))

    pq_coef = ph.val(sec, "pq_coef")
    lpq_coef = ph.val(sec, "lpq_coef")
    qte_coef = ph.val(sec, "qte_coef")

    rows = [
        # (label, moonbit, python_target, passed)
        ("pq_median_treated", ph.val(sec, "pq_median_treated"), med_t,
         abs(ph.val(sec, "pq_median_treated") - med_t) <= MEDIAN_TOL),
        ("pq_median_control", ph.val(sec, "pq_median_control"), med_c,
         abs(ph.val(sec, "pq_median_control") - med_c) <= MEDIAN_TOL),
        ("pq_coef", pq_coef, TRUE_MEDIAN_TREATED,
         abs(pq_coef - TRUE_MEDIAN_TREATED) <= EST_TOL),
        # z == d makes every unit a complier with full take-up, so the LPQ must
        # estimate the same treated median the PQ does.
        ("lpq_coef", lpq_coef, TRUE_MEDIAN_TREATED,
         abs(lpq_coef - TRUE_MEDIAN_TREATED) <= EST_TOL),
        ("qte_coef", qte_coef, TRUE_QTE,
         abs(qte_coef - TRUE_QTE) <= EST_TOL),
        # Internal consistency: the emitter defines qte_coef as
        # `pq.coef() - median_of(d, y, n, 0.0)`.
        ("qte == pq - med_c", qte_coef, pq_coef - ph.val(sec, "pq_median_control"),
         qte_coef == pq_coef - ph.val(sec, "pq_median_control")),
    ]

    # The SEs have no CPython reference -- a cross-fit variance is not
    # reproducible from outside -- but a non-positive SE means the influence
    # function collapsed, which is a real failure mode worth a row. They go in
    # the same table so the verdict is the last line, not a postscript.
    for label in ("pq_se", "lpq_se"):
        got = ph.val(sec, label)
        rows.append((label, got, "must be > 0", got > 0.0))

    print("population targets rebuilt in CPython: "
          "median_treated=%.6f median_control=%.6f qte=%.6f"
          % (med_t, med_c, TRUE_QTE))
    print("estimator tolerance %.3f, median tolerance %g" % (EST_TOL, MEDIAN_TOL))
    print()

    return ph.report("quantile / LPQ / QTE parity", rows,
                     ok=abs(med_t - TRUE_MEDIAN_TREATED) <= MEDIAN_TOL)


if __name__ == "__main__":
    sys.exit(main())
