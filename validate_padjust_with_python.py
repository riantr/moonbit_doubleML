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
`DoubleMLFramework.p_adjust` falls back to. Thirty-five comparisons, one per
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

TSBH IS A KNOWN, MEASURED DIVERGENCE -- AND THIS SCRIPT IS WHAT FOUND IT
======================================================================
Four of the five methods agree with statsmodels to 1e-12. `tsbh` does not,
and it never did:

    i  moonbit                statsmodels fdr_tsbh
    0  0.0031578947368421056   0.004
    6  0.406015037593985       0.5142857142857142

`statsmodels / moonbit` is the CONSTANT 1.2666666666666667 on every cell. A
constant factor means both implementations run the same algorithm -- BH, then a
global `m0_hat / m` rescale -- and pick different `m0_hat`:

    port:          m0_hat = #{p > 0.05} / (1 - 0.05) = 3 / 0.95 = 3.1579...
    statsmodels:   m0_hat = 4  (Storey's lambda-optimisation, which picks a
                    different lambda rather than fixing alpha = 0.05)
    ratio:         (4 / 7) / (3.1579... / 7) = 4 * 0.95 / 3 = 1.26666...

The port is internally exact: reimplementing its documented algorithm in
CPython reproduces its output to 0.0 on all seven cells
(`_verify/_tsbh_probe_1650.py`). So this is a specification difference in the
`m0_hat` estimator, not an arithmetic bug.

It is nonetheless a real parity gap, because `p_adjust.mbt`'s header claims the
outputs are "byte-comparable to `statsmodels` reference" and `tsbh_p_adjust`'s
own docstring claims it "matches `multipletests(method='fdr_tsbh')`". Neither
claim holds for this method.

So tsbh is gated on TWO rows instead of one:
  * against the port's own documented algorithm, at 1e-12 (catches a drift);
  * against the EXACT constant 4 * 0.95 / 3 vs statsmodels (catches a drift in
    EITHER implementation, and goes red the moment someone fixes the port to
    match statsmodels -- at which point this row and the two comments in
    `p_adjust.mbt` need updating together).

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
# The four that match statsmodels exactly.
STATS_EXACT = ("holm", "bonferroni", "bh", "by")

# Both sides compute the same closed-form ratios on the same 7 inputs; the only
# freedom is the order of operations, and nothing here is ill-conditioned.
TOL = 1e-12

ALPHA = 0.05
# See the module docstring: measured, constant on all 7 cells, and equal to
# the ratio of the two m0_hat estimates.
TSBH_STATS_RATIO = 4.0 * (1.0 - ALPHA) / 3.0  # = 1.2666666666666667


def port_tsbh(unadjusted):
    """`tsbh_p_adjust` transcribed from `p_adjust.mbt`:343-399."""
    n = len(unadjusted)
    n_above = sum(1 for p in unadjusted if p > ALPHA)
    m0 = min(max(n_above / (1.0 - ALPHA), 1.0), float(n))
    order = sorted(range(n), key=lambda i: unadjusted[i])
    p_sorted = [min(1.0, unadjusted[order[i]] * n / (i + 1)) for i in range(n)]
    scale = m0 / n
    p_sorted = [min(1.0, v * scale) for v in p_sorted]
    for k in range(n - 2, -1, -1):
        if p_sorted[k] > p_sorted[k + 1]:
            p_sorted[k] = p_sorted[k + 1]
    ro = [0] * n
    for i in range(n):
        ro[order[i]] = i
    return np.array([p_sorted[ro[i]] for i in range(n)]), m0


def main() -> int:
    sec = ph.section("padjust")
    p = np.array(ph.data(sec, "unadjusted_p"))

    if p.size != 7:
        print("expected 7 p-values, emitter sent %d" % p.size)
        return 1

    rows = [("data unadjusted_p", len(p), 7, True)]

    per_method = {}
    for m in STATS_EXACT:
        _, adj, _, _ = multipletests(p, method=SM_METHOD[m])
        per_method[m] = adj
        for i in range(p.size):
            got = ph.val(sec, "%s_%d" % (m, i))
            want = float(adj[i])
            rows.append(("%s[%d]" % (m, i), got, want,
                         abs(got - want) <= TOL))

    # tsbh, row 1 of 2: against the port's OWN documented algorithm.
    port_adj, m0 = port_tsbh(list(p))
    moon_tsbh = np.array([ph.val(sec, "tsbh_%d" % i) for i in range(p.size)])
    for i in range(p.size):
        got = ph.val(sec, "tsbh_%d" % i)
        rows.append(("tsbh[%d] (port spec)" % i, got, float(port_adj[i]),
                     abs(got - float(port_adj[i])) <= TOL))

    # tsbh, row 2 of 2: the statsmodels gap, pinned as an exact constant. This
    # goes red the moment either side drifts, INCLUDING the day someone fixes
    # the port to match statsmodels -- at which point this constant, the module
    # docstring, and the two comments in `p_adjust.mbt` all need updating
    # together.
    _, sm_tsbh, _, _ = multipletests(p, method="fdr_tsbh")
    ratios = []
    for i in range(p.size):
        r = float(sm_tsbh[i]) / float(moon_tsbh[i])
        ratios.append(r)
        rows.append(("tsbh[%d] ratio to sm" % i, r, TSBH_STATS_RATIO,
                     abs(r - TSBH_STATS_RATIO) <= TOL))

    # Method-independent properties. These do not reference statsmodels, so
    # they remain meaningful if the dependency's behaviour ever shifts.
    for m in METHODS:
        got = np.array([ph.val(sec, "%s_%d" % (m, i)) for i in range(p.size)])
        rows.append(("%s monotone" % m, bool(np.all(np.diff(got) >= -1e-15)),
                     "True", bool(np.all(np.diff(got) >= -1e-15))))
        rows.append(("%s in [0,1]" % m, bool(np.all((got >= 0) & (got <= 1))),
                     "True", bool(np.all((got >= 0) & (got <= 1)))))

    # Bonferroni's closed form: multiply every p by the number of hypotheses
    # and take the running minimum from the largest rank down, then clip to 1.
    # Note the multiplier is the CONSTANT n, not Holm's (n - i) -- an earlier
    # draft of this file used (n - i) and was wrong by 0.4 on this vector,
    # which is Holm's first stage rather than Bonferroni's.
    bonf = np.array([ph.val(sec, "bonferroni_%d" % i) for i in range(p.size)])
    manual = np.array([float(p.size) * float(p[i]) for i in range(p.size)])
    for i in range(p.size - 2, -1, -1):
        manual[i] = min(manual[i], manual[i + 1])
    manual = np.minimum(1.0, manual)
    rows.append(("bonferroni closed form (n*p)",
                 float(np.max(np.abs(manual - bonf))), 0.0,
                 bool(np.all(np.abs(manual - bonf) <= TOL))))

    print("p-vector: %s" % np.array2string(p, precision=6))
    print("statsmodels-exact methods: %s" % (STATS_EXACT,))
    print("tolerance %g" % TOL)
    for m in STATS_EXACT:
        got = np.array([ph.val(sec, "%s_%d" % (m, i)) for i in range(p.size)])
        print("  %-11s max |moonbit - statsmodels| = %.3g"
              % (m, float(np.max(np.abs(got - per_method[m])))))
    print()
    print("DIVERGENCE -- see the module docstring before touching this:")
    print("  tsbh port m0_hat     = #{p > %.2f} / (1 - %.2f) = %d / %.2f = %.17g"
          % (ALPHA, ALPHA, int((p > ALPHA).sum()), 1.0 - ALPHA, m0))
    print("  port vs its own spec = %.3g   (the port implements what it "
          "documents)" % float(np.max(np.abs(moon_tsbh - port_adj))))
    print("  statsmodels / port   = min %.17g, max %.17g (pinned constant %r)"
          % (min(ratios), max(ratios), TSBH_STATS_RATIO))
    print("  port vs statsmodels  = %.3g   (a REAL parity gap: p_adjust.mbt "
          "claims byte-compatibility that does not hold here)"
          % float(np.max(np.abs(moon_tsbh - sm_tsbh))))
    print()

    return ph.report("p_adjust parity vs statsmodels", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
