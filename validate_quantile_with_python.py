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
  exact statistics of a deterministic dataset -- 400 rows with `d` alternating,
  so each half is 200 rows carrying 50 distinct `y` values, each repeated 4x
  -- and the port and CPython must agree to ~1e-12. These are the rows that
  would catch a flipped score direction or a treatment-level mix-up.
* **Estimator rows** -- `pq_coef`, `lpq_coef`, `qte_coef`. These are
  cross-fit estimates on a 2-fold split drawn from `chacha8`, which CPython
  cannot reproduce. They are checked against the *population target* they are
  estimating, at the accuracy a 2-fold estimate on n=400 can actually reach.
  The tolerance here is a property of the estimator, not a fudge factor.

`qte_coef` is additionally checked against `pq_coef - median_control`, the
identity the emitter computes it from, so a QTE that drifts away from its own
components is caught even though both parts moved together.

TOLERANCES
----------
Median rows: 1e-12. The median of an even-length sample is the mean of two
doubles -- 1.48 and 1.50 on the treated side -- and 1.48 is not a binary
fraction, so the two sides' means are not guaranteed bit-equal a priori.
The validator prints the measured gap on every run; the 1e-12 window is a
MARGIN against that gap, not a band doing any work, and the validator
fails if the gap ever comes within 1000x of the tolerance.

Estimator rows: 0.02. This used to be described as "the window the v0.49.0
APOS validator already used for the same DGP", which was wrong twice over:
the APOS validator has no 0.02 window -- it uses
`max(MODEL_TOL=0.3, 2 * handrolled_se)` -- and its DGP is not this one (a
randomised 2-level IRM DGP at n = 500, p = 3, against this deterministic
alternating panel). The band's real justification is the margin over the
observed cross-fit deviation: the validator prints the largest observed
deviation and the margin (band / deviation) on every run, and fails if the
margin ever falls below 1.5x -- at which point the band would be tighter
than the noise it is meant to absorb.

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

    # Both tolerances are MARGINS, and the margin is measured, not assumed.
    # Measuring it here is what lets the docstring justify the two windows
    # without quoting a number that can quietly go stale: the live output
    # carries the number, and the two checks below carry the relationship.
    #
    # Median rows: the gap between the port and CPython must stay far below
    # the tolerance, or the tolerance is a band rather than a margin.
    median_gap = max(
        abs(ph.val(sec, "pq_median_treated") - med_t),
        abs(ph.val(sec, "pq_median_control") - med_c),
    )
    median_margin_ok = median_gap <= MEDIAN_TOL / 1000.0

    # Estimator rows: the band must be several times the largest observed
    # deviation, or it is tighter than the noise it is meant to absorb.
    est_devs = {
        "pq_coef": abs(pq_coef - TRUE_MEDIAN_TREATED),
        "lpq_coef": abs(lpq_coef - TRUE_MEDIAN_TREATED),
        "qte_coef": abs(qte_coef - TRUE_QTE),
    }
    worst_label, est_dev = max(est_devs.items(), key=lambda kv: kv[1])
    est_margin = (EST_TOL / est_dev) if est_dev > 0.0 else float("inf")
    est_margin_ok = est_margin >= 1.5

    if not median_margin_ok:
        print("  FAIL median gap %.3e is within 1000x of the %.0e tolerance"
              % (median_gap, MEDIAN_TOL))
    if not est_margin_ok:
        print("  FAIL estimator band margin %.2fx is below the 1.5x floor"
              % est_margin)

    print("population targets rebuilt in CPython: "
          "median_treated=%.6f median_control=%.6f qte=%.6f"
          % (med_t, med_c, TRUE_QTE))
    print("estimator tolerance %.3f, median tolerance %g" % (EST_TOL, MEDIAN_TOL))
    print("median rows: measured gap %.3e, tolerance %.0e, margin %s"
          % (median_gap, MEDIAN_TOL,
             "ok" if median_margin_ok else "TOO TIGHT"))
    print("estimator rows: largest deviation %.6f (%s), band margin %.2fx "
          "(floor 1.50x)" % (est_dev, worst_label, est_margin))
    print()

    return ph.report("quantile / LPQ / QTE parity", rows,
                     ok=(abs(med_t - TRUE_MEDIAN_TREATED) <= MEDIAN_TOL
                         and median_margin_ok
                         and est_margin_ok))


if __name__ == "__main__":
    sys.exit(main())
