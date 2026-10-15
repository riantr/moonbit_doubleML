"""The multiplier-bootstrap weight draw, checked against distribution theory.

WHAT THIS USED TO BE
====================
The old file generated weights with `np.random.default_rng(2024)`, printed
their mean and variance, and then printed:

    print("Cross-check passes if all three methods show mean ~ 0 and "
          "variance ~ 1. The MoonBit implementation uses a chacha8 RNG "
          "(different stream) so the absolute values will not match; "
          "the empirical moments should be close.")
    print("Multipliers match: PASS")

It said "Cross-check passes IF" and then printed PASS unconditionally. No
MoonBit process ran. The moments it displayed were numpy's, not the port's.

WHAT IS ACTUALLY BEING TESTED
=============================
CPython cannot reproduce `chacha8`, so the individual weights are not
comparable. What IS comparable is the DISTRIBUTION the port draws from, and
that has exact theoretical moments:

    normal   w = N(0, 1)                      E=0  Var=1  m3= 0  m4= 3
    Bayes    w = Exp(1) - 1                   E=0  Var=1  m3= 2  m4= 9
    wild     w = x/sqrt(2) + (y^2 - 1)/2      E=0  Var=1  m3= 1  m4= 6

(The wild `m3` is 1, not 0: expanding `(a+b)^3` with `a = x/sqrt(2)`,
`b = (y^2-1)/2`, the `a^3`, `a^2 b` and `a b^2` terms all vanish by symmetry
or by `E[y^2-1] = 0`, leaving `E[b^3] = E[(y^2-1)^3]/8 = (15-9+3-1)/8 = 1`.)

WHY m3 AND m4, NOT JUST MEAN AND VARIANCE
==========================================
All three methods have E[w] = 0 and Var[w] = 1. A validator that checked only
those two would pass even if `draw_bootstrap_weights` returned N(0,1) for every
method name -- the check could not tell a correct implementation from a stub
that ignores its argument. m3 and m4 do tell them apart, and they are the rows
that carry the weight.

THE SAMPLE SIZE IS PART OF THE TEST
===================================
Bayes draws are `Exp(1) - 1`, whose 4th central moment has standard error
`sqrt(8!/n)`. At n = 10_000 that is 2.0 -- WIDER than the 3-unit gap between
Bayes's m4 (9) and wild's (6). The emitter therefore draws 500 x 200 = 100_000
weights, putting the error at 0.63.

TOLERANCES -- measured, then rounded up
=======================================
MoonBit vs theory at n = 100_000, largest absolute deviation over the three
methods:

    mean  0.0075   -> tol 0.05
    var   0.0161   -> tol 0.05
    m3    0.0806   -> tol 0.30
    m4    0.5250   -> tol 1.00

Each is 2-3x the measured deviation, and none of the windows overlap: the
tightest gap between two methods is m3's 1.087 (Bayes 2.006 vs wild 0.919),
so a 0.30 window still separates them. A validator that cannot distinguish the
three methods is not testing the thing it names.

RUN
===
    python validate_bootstrap_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parity_helper as ph  # noqa: E402

METHODS = ("normal", "Bayes", "wild")

# theory: E[w], Var[w], central m3, central m4
THEORY = {
    "normal": (0.0, 1.0, 0.0, 3.0),
    "Bayes":  (0.0, 1.0, 2.0, 9.0),
    "wild":   (0.0, 1.0, 1.0, 6.0),
}

TOL = {"mean": 0.05, "var": 0.05, "m3": 0.30, "m4": 1.00}

# The smallest gap between two methods' values for any quantity below. If the
# tolerance ever reached this, the test would stop discriminating.
SEPARATION = {"mean": 0.0, "var": 0.0, "m3": 1.0, "m4": 2.6}


def main() -> int:
    sec = ph.section("bootstrap")

    n_draws = int(ph.val(sec, "n_draws"))
    n_rep = int(ph.val(sec, "n_rep"))
    n_obs = int(ph.val(sec, "n_obs"))

    rows = [
        ("n_rep", n_rep, 500, n_rep == 500),
        ("n_obs", n_obs, 200, n_obs == 200),
        ("n_draws", n_draws, 100000, n_draws == 100000),
    ]

    for m in METHODS:
        e_mean, e_var, e_m3, e_m4 = THEORY[m]
        for key, want in (("mean", e_mean), ("var", e_var),
                          ("m3", e_m3), ("m4", e_m4)):
            got = ph.val(sec, "%s_%s" % (m, key))
            rows.append(("%s %s" % (m, key), got, want,
                         abs(got - want) <= TOL[key]))

    # `_first` is a single draw from a stream CPython cannot reproduce, so it
    # has no target. It is checked only for being a finite number of plausible
    # magnitude -- a NaN or an uninitialised 0.0 here means the draw is broken
    # in a way the moments might survive.
    for m in METHODS:
        first = ph.val(sec, "%s_first" % m)
        rows.append(("%s first" % m, first, "|.| < 12",
                     first == first and abs(first) < 12.0))

    print("theory: " + "  ".join(
        "%s E=%.0f Var=%.0f m3=%g m4=%g" % ((m,) + THEORY[m]) for m in METHODS))
    print("n_draws = %d (SE of Bayes m4 ~ %.3f)"
          % (n_draws, (40320.0 / n_draws) ** 0.5))
    print("tolerances: %s" % TOL)
    print("tightest method separation: %s" % SEPARATION)
    for key in ("m3", "m4"):
        if TOL[key] >= SEPARATION[key]:
            print("WARNING: the %s tolerance (%.3f) is not smaller than the "
                  "method separation (%.3f) -- this check cannot tell the "
                  "methods apart" % (key, TOL[key], SEPARATION[key]))
    print()

    return ph.report("bootstrap weight draw parity", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
