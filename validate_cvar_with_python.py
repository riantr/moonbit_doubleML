"""CVaR on the deterministic alternating DGP, checked against MoonBit.

WHAT THIS USED TO BE
====================
The old `validate_cvar_with_python.py` compared a hand-rolled numpy re-run of
the estimator -- on its OWN `np.random.default_rng(3141)` -- against a truth
value, and never observed the port. Its `MODEL_TOL = 0.3` comment concedes the
point: "PRNG drift between chacha8 and numpy default_rng drives ~0.2 SE
offsets on the canonical DGP, so the 0.3 window is the right band". A tolerance
that wide cannot distinguish a correct port from a broken one.

It also imported `doubleml`, the upstream wheel, which is installed here -- so
the one validator in this family that COULD have talked to upstream did not
actually compare against it either.

WHAT IT IS NOW
==============
It runs `examples/parity` (section `cvar`). Three kinds of row:

* **Data** -- CPython rebuilds the closed-form DGP and requires bit equality
  with what MoonBit emitted. `Double::to_string` is shortest-round-trip, so
  this is IEEE-754 equality, not an approximation.
* **Population** -- `cvar_empirical_treated` is a mean of 100 exactly-known
  doubles, so the port and CPython must agree to ~1e-12.
* **Estimator** -- `cvar_coef` is a cross-fit estimate whose fold split comes
  from `chacha8`. CPython cannot reproduce the split, so this row is checked
  against the population target at the accuracy a 2-fold estimate on n=200
  reaches, and nothing more is claimed.

THE POPULATION TARGET, SPELLED OUT
==================================
`y[d == 1]` is `1 + r/100` for `r` in {0, 2, ..., 98}, each value repeated 4x:
200 rows, 50 distinct. The upper half (sorted indices 100..199) is exactly the
25 distinct values `k = 25..49`, four times each, so

    mean = 1 + 2 * mean(25..49) = 1 + 2 * 37/100 = 1.74

RUN
===
    python validate_cvar_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import parity_helper as ph  # noqa: E402

N = 400
TRUE_CVAR = 1.74
POP_TOL = 1e-12
EST_TOL = 0.02


def build_dgp():
    """Rebuild the DGP from `cvar_test.mbt`'s definition, independently."""
    i = np.arange(N)
    d = np.where(i % 2 == 0, 1.0, 0.0)
    y = d + (i % 100) / 100.0
    return d, y


def upper_half_mean(values):
    """Mean of the upper half of the SORTED values -- empirical CVaR at q=0.5."""
    s = np.sort(values)
    lo = s.size // 2
    return float(s[lo:].mean())


def main() -> int:
    sec = ph.section("cvar")
    d, y = build_dgp()

    treated = y[d == 1.0]
    cvar_pop = upper_half_mean(treated)
    assert abs(cvar_pop - TRUE_CVAR) < POP_TOL, (
        "python CVaR is %.17g, expected %.17g -- the DGP reconstruction is "
        "wrong, so a mismatch below would be meaningless" % (cvar_pop, TRUE_CVAR))

    rows = []
    for name, want in (("y", y), ("d", d)):
        got = ph.data(sec, name)
        same = len(got) == want.size and all(a == b for a, b in zip(got, want))
        rows.append(("data " + name, len(got), want.size, same))

    mb_pop = ph.val(sec, "cvar_empirical_treated")
    mb_coef = ph.val(sec, "cvar_coef")
    mb_se = ph.val(sec, "cvar_se")

    rows += [
        ("cvar_empirical_treated", mb_pop, cvar_pop, abs(mb_pop - cvar_pop) <= POP_TOL),
        ("cvar_coef", mb_coef, TRUE_CVAR, abs(mb_coef - TRUE_CVAR) <= EST_TOL),
        ("cvar_se", mb_se, "must be > 0", mb_se > 0.0),
    ]

    print("population CVaR rebuilt in CPython: %.17g (expected %.2f)"
          % (cvar_pop, TRUE_CVAR))
    print("population tolerance %g, estimator tolerance %g" % (POP_TOL, EST_TOL))
    print()

    return ph.report("CVaR parity", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
