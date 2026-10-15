"""p-adjustment checked against statsmodels, which IS the upstream library.

WHAT THIS USED TO BE
====================
The old file built a Romano-Wolf reference from a `np.random.default_rng`
bootstrap, printed the seven adjusted p-values for six methods, and then
printed:

    print("Cross-check passes if the MoonBit p_adjust (tested in")
    print("did_multi_test.mbt) matches these references within")
    print("the per-cell Monte-Carlo error (O(1/n_boot)).")
    print("Romano-Wolf / BH / BY / TSBH / TSBY reference matches: PASS")

No MoonBit ran, and the MoonBit `p_adjust` was never invoked -- the pass
message refers to a unit test in another file. Notably, this validator DID
import `statsmodels`, the same library upstream `p_adjust` delegates to. It was
one import away from a real comparison and did not make it.

WHAT IT IS NOW
==============
`examples/parity` feeds a FIXED p-value vector through the port's
`p_adjust`, and this script runs the identical vector through
`statsmodels.stats.multitest.multipletests` -- the exact function upstream
`DoubleMLFramework.p_adjust` falls back to. One comparison per
(method, p-value) cell, on identical inputs. No RNG is involved anywhere, so
any difference is a difference in the algorithms.

The vector is `[0.001, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9]`: it spans three
orders of magnitude and crosses BH's rejection threshold, so `bh` is not
trivially the identity and the monotone step-down structure is actually
exercised.

A structural row is added on top of the per-cell ones: adjusted p-values must
be non-decreasing in the unadjusted p-value for every step-down method, and
every value must lie in [0, 1]. Those hold independently of statsmodels, so
they survive a statsmodels version change.

TSBH NOW MATCHES STATSMODELS
=============================
This file is what found the one real gap, and the gap has since been closed.

`tsbh` used to run BH and then a global rescale by the Storey 2002
null-count `m0_hat = #{p > 0.05} / (1 - 0.05) = 3 / 0.95`, while
statsmodels' `fdr_tsbh` re-levels `alpha` from its own stage-1 rejection
count. `statsmodels / port` was the CONSTANT 1.2666666666666667 on every
cell, and `p_adjust.mbt` claimed byte-compatibility it did not have.

`tsbh_p_adjust` now runs statsmodels' lambda search:

    r1       = stage-1 BH rejections at alpha
    n0       = m - r1
    alpha*   = alpha * m / n0
    p_adj    = clip(BH(p, alpha*) * n0 / m, 0, 1)

and returns stage 1 unchanged when `r1 == 0` or `r1 == m`, matching
statsmodels' own short-circuit. On this vector `r1 = 3` and `n0 = 4`, so
cell 0 moves 0.0031578947368421056 -> 0.004 and the constant ratio is gone.

So `tsbh` is gated like the other four exact methods: per-cell against
statsmodels, AND against `port_tsbh` below, a line-by-line transcription of
the MoonBit source. Those are two independent implementations of the same
specification, so they disagree if either one drifts -- the statsmodels row
catches a drift in the port, the transcription row catches a drift in the
transcription of it.

`tsby` IS STILL GATEED BY NOTHING
=================================
`tsby_p_adjust` keeps the old estimator and remains divergent: measured
`max |port - statsmodels fdr_tsbky| = 0.1595`, and NOT by a constant factor
(the ratio spans 0.5129 ... 1.1970). It was left alone because the fix was
scoped to `tsbh`. There are no `tsby` rows here, so nothing in CI would
catch a drift in it. See the `tsby_p_adjust` docstring in `p_adjust.mbt`.

RUN
===
    python validate_padjust_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parity_helper as ph  # noqa: E402

import numpy as np  # noqa: E402
from statsmodels.stats.multitest import multipletests  # noqa: E402

# statsmodels spells two of these differently from the port. The port accepts
# the short names; the mapping is recorded here rather than hidden.
METHODS = ("holm", "bonferroni", "bh", "by", "tsbh")
SM_METHOD = {
    "holm": "holm",
    "bonferroni": "bonferroni",
    "bh": "fdr_bh",
    "by": "fdr_by",
    "tsbh": "fdr_tsbh",
}
# All five agree with statsmodels. `tsbh` joined this tuple when it adopted
# statsmodels' lambda search; before that it was gated on a pinned ratio
# constant instead, which is why the module docstring above is so long.
STATS_EXACT = ("holm", "bonferroni", "bh", "by", "tsbh")

# Tolerance per method, MEASURED across BOTH fixture vectors rather than
# assumed. A method is gated at 0.0 only when it came out of the comparison
# bit-identical on both; that is what lets `p_adjust.mbt` claim
# bit-compatibility instead of merely "close".
#
# Safe to demand at 0.0 because every one of these algorithms is built from
# +, -, * and / on the input p-values only: no transcendentals, therefore no
# libm, therefore correctly-rounded IEEE-754 arithmetic that is identical on
# every platform CI runs.
#
# `bh` and `by` are the exceptions, and for a reason worth recording:
#   * `by` accumulates a harmonic sum, and the port and statsmodels sum it in
#     a different order -> 1.11e-16 on both vectors.
#   * `bh` is exact on vector `a` but 1.11e-16 off on vector `b`, because
#     `bh_fdr_p_adjust` applies the step-up factor as `p * n / (k + 1)` while
#     statsmodels divides by `((k + 1) / n)`. The two are algebraically equal
#     and differ only in rounding. `tsbh_p_adjust` was changed to statsmodels'
#     form and is exact on both; `bh` still carries the old form. That
#     remainder is not fixed here because this change was scoped to `tsbh`.
TOL_BY_METHOD = {
    "holm": 0.0,         # exact on a and b
    "bonferroni": 0.0,   # exact on a and b
    "bh": 1e-12,         # exact on a, 1.11e-16 on b (old *n/(k+1) form)
    "by": 1e-12,         # 1.11e-16 on a and b (harmonic-sum order)
    "tsbh": 0.0,         # exact on a and b
}
TOL = 1e-12  # default for the checks below that are not per-method

ALPHA = 0.05

# The two p-value vectors, tagged to match the emitter's `unadjusted_pa` /
# `unadjusted_pb`. See `sec_padjust` in `examples/parity/main.mbt` for why
# vector `b` exists at all.
VECTORS = (
    ("a", [0.001, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9]),
    ("b", [0.07, 0.11, 0.19, 0.23, 0.41, 0.53, 0.71]),
)


def _bh_step_up_sorted(p_sorted, alpha):
    """statsmodels `fdrcorrection(method='indep', is_sorted=True)`."""
    n = len(p_sorted)
    corrected = [0.0] * n
    rejectmax = -1
    for i in range(n):
        # ECDF factor is a DIVISION target, not a multiplier:
        # statsmodels does `p / ((i+1)/n)`, and the algebraically equal
        # `p * n / (i+1)` differs by up to 1 ULP.
        ecdf = float(i + 1) / float(n)
        if p_sorted[i] <= ecdf * alpha:
            rejectmax = i
        v = p_sorted[i] / ecdf
        corrected[i] = 1.0 if v > 1.0 else v
    n_rejected = 0 if rejectmax < 0 else rejectmax + 1
    for k in range(n - 2, -1, -1):
        if corrected[k] > corrected[k + 1]:
            corrected[k] = corrected[k + 1]
    return corrected, n_rejected


def port_tsbh(unadjusted):
    """`tsbh_p_adjust` transcribed from `p_adjust.mbt` (bh_step_up_sorted +
    the lambda search)."""
    n = len(unadjusted)
    order = sorted(range(n), key=lambda i: unadjusted[i])
    p_sorted = [unadjusted[order[i]] for i in range(n)]
    stage1, r1 = _bh_step_up_sorted(p_sorted, ALPHA)
    if r1 == 0 or r1 == n:
        adjusted = stage1
    else:
        n0 = 1.0 * float(n) - float(r1)
        alpha_star = ALPHA * float(n) / n0
        stage2, _ri = _bh_step_up_sorted(p_sorted, alpha_star)
        scale = n0 * 1.0 / float(n)
        adjusted = [1.0 if v * scale > 1.0 else v * scale for v in stage2]
    ro = [0] * n
    for i in range(n):
        ro[order[i]] = i
    return np.array([adjusted[ro[i]] for i in range(n)]), float(n - r1), r1


def main() -> int:
    sec = ph.section("padjust")

    rows = []
    got_all = {}     # (tag, method) -> what MoonBit emitted
    sm_all = {}      # (tag, method) -> what statsmodels returned
    r1_all = {}      # tag -> (r1, n0)

    for tag, expect_p in VECTORS:
        p = np.array(ph.data(sec, "unadjusted_p" + tag))
        if p.size != len(expect_p):
            print("vector %s: expected %d p-values, emitter sent %d"
                  % (tag, len(expect_p), p.size))
            return 1
        if not np.array_equal(p, np.array(expect_p)):
            # The emitter is what actually ran. If it drifts from this file,
            # the Python side would be grading a different vector than the one
            # it believes it is grading.
            print("vector %s: emitter sent %s, this file expects %s"
                  % (tag, np.array2string(p, precision=17),
                     np.array2string(np.array(expect_p), precision=17)))
            return 1
        rows.append(("data unadjusted_p%s" % tag, len(p), len(expect_p), True))

        for m in STATS_EXACT:
            _, adj, _, _ = multipletests(p, method=SM_METHOD[m])
            adj = np.asarray(adj, dtype=float)
            got = np.array([ph.val(sec, "%s%s_%d" % (m, tag, i))
                            for i in range(p.size)])
            sm_all[(tag, m)] = adj
            got_all[(tag, m)] = got
            tol = TOL_BY_METHOD[m]
            for i in range(p.size):
                if tol == 0.0:
                    ok = bool(got[i] == adj[i])
                else:
                    ok = abs(got[i] - adj[i]) <= tol
                rows.append(("%s[%d] on %s" % (m, i, tag),
                             float(got[i]), float(adj[i]), ok))

        # Second witness for tsbh: a transcription of the MoonBit source,
        # independent of the statsmodels rows above. Measured exactly equal on
        # both vectors, so gated at exact equality.
        port_adj, n0, r1 = port_tsbh(list(p))
        r1_all[tag] = (r1, n0, len(p))
        for i in range(p.size):
            got = float(got_all[(tag, "tsbh")][i])
            rows.append(("tsbh[%d] on %s (port spec)" % (i, tag), got,
                         float(port_adj[i]), got == float(port_adj[i])))

        # Method-independent properties. These never reference statsmodels, so
        # they survive a statsmodels version change.
        for m in METHODS:
            got = got_all[(tag, m)]
            mono = bool(np.all(np.diff(got) >= -1e-15))
            rows.append(("%s monotone on %s" % (m, tag), mono, "True", mono))
            inrange = bool(np.all((got >= 0) & (got <= 1)))
            rows.append(("%s in [0,1] on %s" % (m, tag), inrange, "True", inrange))

        # Bonferroni's closed form: multiply every p by the number of
        # hypotheses and take the running minimum from the largest rank down,
        # then clip to 1. Note the multiplier is the CONSTANT n, not Holm's
        # (n - i) -- an earlier draft of this file used (n - i) and was wrong
        # by 0.4 on vector a, which is Holm's first stage rather than
        # Bonferroni's.
        manual = np.array([float(p.size) * float(p[i]) for i in range(p.size)])
        for i in range(p.size - 2, -1, -1):
            manual[i] = min(manual[i], manual[i + 1])
        manual = np.minimum(1.0, manual)
        bonf = got_all[(tag, "bonferroni")]
        rows.append(("bonferroni closed form (n*p) on %s" % tag,
                     float(np.max(np.abs(manual - bonf))), 0.0,
                     bool(np.all(np.abs(manual - bonf) <= TOL))))

    print("statsmodels-exact methods: %s" % (STATS_EXACT,))
    for tag, p in VECTORS:
        print("vector %s: %s" % (tag, np.array2string(np.array(p), precision=6)))
    print()
    for m in STATS_EXACT:
        for tag, _ in VECTORS:
            d = float(np.max(np.abs(got_all[(tag, m)] - sm_all[(tag, m)])))
            print("  %-11s on %s   max |moonbit - statsmodels| = %-10.3g"
                  "  gated at %g" % (m, tag, d, TOL_BY_METHOD[m]))
    print()
    print("tsbh lambda search:")
    for tag, _ in VECTORS:
        r1, n0, m = r1_all[tag]
        if r1 == 0 or r1 == m:
            note = "stage 1 returned unchanged (statsmodels' short-circuit)"
        else:
            note = "stage 2 ran at alpha* = alpha*m/n0 = %.17g" % (
                ALPHA * m / n0)
        print("  vector %s: r1 = %-2d  n0 = %.1f  %s" % (tag, r1, n0, note))
    print()
    print("NOT GATED HERE: tsby_p_adjust still uses the old Storey estimator.")
    print("  measured max |port - statsmodels fdr_tsbky| = 0.1595, ratio span")
    print("  0.5129...1.1970 (not a constant factor). No tsby rows exist, so")
    print("  CI cannot see a drift there.")
    print()

    return ph.report("p_adjust parity vs statsmodels", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
