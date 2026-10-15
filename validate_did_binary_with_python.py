"""Binary DID on a two-period panel, checked against CPython on the emitted data.

WHAT THIS USED TO BE
====================
The old file ran a hand-rolled numpy re-implementation of the estimator on its
OWN `np.random.default_rng(7)` / `(13)` draw, compared that against the true
ATT, printed

    print("Reference: run `moon run examples/did_binary` for the MoonBit output.")
    print("PASS: did_binary reference")

and exited 0. The instruction to run MoonBit was text in a print statement.
The script never ran it. It was a reference for a human to check by eye, wired
into CI as if it were an automated comparison.

WHY THE DATA IS EMITTED RATHER THAN REGENERATED
===============================================
The DGP is drawn from `chacha8`, which CPython cannot reproduce -- it is a
different cipher from `default_rng`, and the port's `box_muller_pair` uses
`ln`/`cos`/`sin`, which are not correctly rounded (measured in
`validate_bitexact_with_python.py`: `ln(3.0)` differs from CPython by exactly
1 ULP). So Python cannot rebuild the panel.

What it CAN do is take the outcome data the port actually used and compute the
estimand on it by a different route. That is stronger than regenerating
similar data: it removes the PRNG as a confounder entirely.

THE INDEPENDENT ESTIMATE
========================
For each unit, `y_diff = y_post - y_pre`. The unit-level term `base` is
time-invariant, so it cancels, and

    y_diff = theta0 * (d_post - d_pre) + (noise_post - noise_pre)

A treated unit has `d_pre = 0, d_post = 1`; a never-treated unit has both 0.
So the difference in mean `y_diff` between the two groups IS the ATT, with no
model needed at all. MoonBit's estimate comes from a 2-fold cross-fit with
regression adjustment, so the two should agree closely but not identically --
the gap between them is the cross-fitting's contribution, and is reported.

RUN
===
    python validate_did_binary_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parity_helper as ph  # noqa: E402

import numpy as np  # noqa: E402

N_PER_COHORT = 120
N_UNITS = N_PER_COHORT
P = 3
N = N_UNITS * 2
TRUE_ATT = 1.0

ATT_TOL = 0.05


def build_structure():
    """Rebuild the documented panel structure: id, period t, group g, and d.

    The emitter's DGP is, row by row:
        u  = row // 2            (unit index)
        k  = row % 2             (period)
        g  = 1 if u % 2 == 0 else 0
        d  = 1 if (g == 1 and k == 1) else 0

    Rebuilding it here is a real check, not a formality: the emitted `d` must
    equal the `d` this rule implies, so changing the panel structure in the
    emitter without changing this file turns the validator red.
    """
    unit = np.empty(N, dtype=int)
    t = np.empty(N, dtype=int)
    g = np.empty(N, dtype=int)
    d = np.empty(N)
    for row in range(N):
        u = row // 2
        k = row % 2
        unit[row] = u
        t[row] = k
        g[row] = 1 if u % 2 == 0 else 0
        d[row] = 1.0 if (g[row] == 1 and k == 1) else 0.0
    return unit, t, g, d


def wide_panel(y, unit, t, g):
    """Long -> wide: one row per unit with y_diff and the G indicator."""
    diffs = np.zeros(N_UNITS)
    g_ind = np.zeros(N_UNITS)
    seen = np.zeros(N_UNITS, dtype=int)
    for row in range(N):
        u = unit[row]
        if t[row] == 0:
            diffs[u] = -y[row]
        else:
            diffs[u] += y[row]
        g_ind[u] = g[row]
        seen[u] += 1
    return diffs, g_ind, seen


def main() -> int:
    sec = ph.section("did_binary")
    y = np.array(ph.data(sec, "did_binary_y"))
    d_emit = np.array(ph.data(sec, "did_binary_d"))

    unit, t, g, d_rebuilt = build_structure()

    rows = [
        ("data did_binary_y", len(y), N, len(y) == N),
        ("data did_binary_d", len(d_emit), N, len(d_emit) == N),
        # The structure the panel actually used, bit-for-bit.
        ("d matches documented rule", float(np.max(np.abs(d_emit - d_rebuilt))),
         0.0, bool(np.all(d_emit == d_rebuilt))),
    ]

    diffs, g_ind, seen = wide_panel(y, unit, t, g)

    # Units usable for the ATT: both periods present, and a well-defined group.
    usable = seen == 2
    n_sub_expected = int(usable.sum())
    n_sub_reported = int(ph.val(sec, "n_obs_subset"))
    rows.append(("n_obs_subset", n_sub_reported, float(n_sub_expected),
                 n_sub_reported == n_sub_expected))

    treated = usable & (g_ind == 1)
    control = usable & (g_ind == 0)
    att_independent = float(diffs[treated].mean() - diffs[control].mean())

    att_mb = ph.val(sec, "att")
    se_mb = ph.val(sec, "att_se")

    rows += [
        ("att vs independent estimate", att_mb, att_independent,
         abs(att_mb - att_independent) <= ATT_TOL),
        ("att vs true 1.0", att_mb, TRUE_ATT,
         abs(att_mb - TRUE_ATT) <= ATT_TOL),
        ("independent vs true 1.0", att_independent, TRUE_ATT,
         abs(att_independent - TRUE_ATT) <= ATT_TOL),
        ("att_se > 0", se_mb, "> 0", se_mb > 0.0),
    ]

    print("panel: %d units x 2 periods, p = %d, half treated / half never"
          % (N_UNITS, P))
    print("units used for the ATT: %d (all have both periods)" % n_sub_expected)
    print()
    print("independent estimate, no model, on the port's own y:")
    print("  mean y_diff among treated  = %.15g  (n = %d)"
          % (diffs[treated].mean(), int(treated.sum())))
    print("  mean y_diff among controls = %.15g  (n = %d)"
          % (diffs[control].mean(), int(control.sum())))
    print("  ATT = %.15g" % att_independent)
    print()
    print("moonbit ATT = %.15g   se = %.15g" % (att_mb, se_mb))
    print("cross-fitting contribution (moonbit - independent) = %+.6g"
          % (att_mb - att_independent))
    print()

    return ph.report("binary DID parity", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
