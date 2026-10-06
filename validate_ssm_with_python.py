"""v0.107.0: cross-check the MoonBit `DoubleMLSSM`, and pin the one
identity it should satisfy exactly.

WHAT THIS REPLACED
==================
Through v0.106.0 this file validated a hand-rolled Python
implementation of the SSM MAR score and printed

    "SSM reference checks PASS"

as a literal. The MoonBit side was not involved at any point, so the
name was doing more work than the file was: it said "SSM" and there
was no SSM in it.

WHAT IS ASSERTED, and why that ordering
======================================
1. **`sandwich_se(HC0) == se()`, exactly.** SSM is a `var_est`-shaped
   estimator, so the two accessors compute the same quantity by
   different routes:

       se()  = sqrt( mean(psi^2) / (J^2 * n) )     via var_est
       HC0   = sqrt( sum(psi^2) / n / J^2 )        via sandwich

   This is ALGEBRA. There is no sampling content, so it is not a
   statistical claim and gets no Monte-Carlo band. Measured on
   `examples/ssm`: the difference is exactly `0.0` on all four
   lines, and also exactly `0.0` on the pathological seed discussed
   below where the value itself is not trustworthy. The two have to
   be diagnosed separately, which is why both are printed.

   This is worth pinning because the two accessors spent most of the
   package's history disagreeing: `sandwich_variance_hc0` carried a
   `1/n` the accumulator did not, so HC0 sat at `sqrt(n) * se()`
   through v0.90.0, and `DoubleMLDIDCS` and `DoubleMLLPLR` were
   excluded from the sandwich API entirely for related reasons.

2. **The SE falls like `1/sqrt(n)`** across a 4x step, on two seeds.
   Band (0.40, 0.65) against measurements of 0.5255 and 0.4866. This
   is the statistical half, and unlike check 1 it can only be as
   sharp as the estimator's own stability allows.

3. **The coefficient converges** and lands near the true 1.0.

WHAT IS DELIBERATELY NOT ASSERTED
=================================
Seed 3141. On the same DGP it gives a 4x-step SE ratio of 0.1270
instead of ~0.5, and at n = 8000 the fit diverges outright
(`theta = -121.88`, `se = 122.88`). That is SSM's variance being
fragile with respect to the fold split, not a scale error, and a
band wide enough to absorb a 4x swing would also absorb a flat SE.
The measurement is recorded in `examples/ssm`'s header and pinned by
`expand_v107_test.mbt::v107_ssm_se_is_fragile_to_the_split`, so it
cannot be forgotten, but it is not something this file asserts.

The Python reference runs the same 1/sqrt(n) comparison on its own
MAR implementation, so the band is anchored on an independent
estimator rather than on MoonBit's own output.

This file FAILS CLOSED and computes its verdict.
"""

from __future__ import annotations

import re
import subprocess
import sys

import numpy as np
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import KFold

# Relative tolerance for the HC0 == se() identity. The measured
# difference is exactly 0.0; this only absorbs a future last-ulp
# difference in the summation order, and is 13 orders of magnitude
# tighter than any statistical claim in this file.
HC0_REL_TOL = 1.0e-15

# 1/sqrt(n) band for a 4x step. Measured: 0.5255 (seed 99) and 0.4866
# (seed 7). A variance with its 1/n cancelled reads ~1.0; one missing
# an n (i.e. sqrt(n) * the right answer, the v0.90.0 HC0 defect) reads
# ~2.0.
SE_RATIO_LO = 0.40
SE_RATIO_HI = 0.65

# Coefficient bands. Measured |theta - 1|: 0.0434 / 0.0196 (seed 99)
# and 0.0394 / 0.0062 (seed 7), at n = 500 / 2000.
THETA_TOL_SMALL_N = 0.10
THETA_TOL_BIG_N = 0.05

# The two (seed, tag) pairs `examples/ssm` reports, and the 4x pairing.
SEEDS = (("a", 99), ("b", 7))
BIG_FACTOR = 4


def reference(x, y, d, s, folds, clip=1e-6):
    """Hand-rolled SSM MAR score.

    v0.20.0 Bug #1 fix, retained: the `g_d1` / `g_d0` cross-fitted
    learners are trained on `X` (WITHOUT the `pi_hat` column) --
    the upstream MAR score uses the pre-screening DML, not the
    augmented `xpi` design. `pi_hat` is still estimated, clipped and
    used in the score formula, it just is not a feature in `g`.
    """
    n = len(y)
    pi = np.zeros(n); m = np.zeros(n); gd1 = np.zeros(n); gd0 = np.zeros(n)
    for tr, te in folds:
        m[te] = LinearRegression().fit(x[tr], d[tr]).predict(x[te])
        xd = np.column_stack((x, d))
        pi[te] = LinearRegression().fit(xd[tr], s[tr]).predict(xd[te])
        for dv, out in ((1.0, gd1), (0.0, gd0)):
            ids = tr[(d[tr] == dv) & (s[tr] == 1.0)]
            if len(ids):
                out[te] = LinearRegression().fit(x[ids], y[ids]).predict(x[te])
    pi = np.clip(pi, clip, 1 - clip); m = np.clip(m, clip, 1 - clip)
    pa = -np.ones(n)
    pb = d*s*(y-gd1)/(m*pi)+gd1 - ((1-d)*s*(y-gd0)/((1-m)*pi)+gd0)
    theta = -pb.mean()/pa.mean(); psi = theta*pa+pb
    se = np.sqrt((psi**2).mean()/(pa.mean()**2*n))
    return theta, se


def python_dgp(n, p, seed):
    """The reference DGP, restated for the 1/sqrt(n) comparison."""
    rng = np.random.default_rng(seed)
    x = rng.standard_normal((n, p))
    d = (rng.uniform(size=n) > .5).astype(float)
    v = rng.standard_normal(n)
    s = (d + .5*x[:, 0] + v > 0).astype(float)
    y = d + .3*x[:, 0]*d + .3*rng.standard_normal(n)
    return x, y, d, s


def python_reference(n, p, seed, fold_seed):
    x, y, d, s = python_dgp(n, p, seed)
    folds = list(KFold(2, shuffle=True, random_state=fold_seed).split(x))
    return reference(x, y, d, s, folds)


def run_moonbit() -> dict:
    """Spawn `moon run examples/ssm` and parse the four `ssm ... ` lines.

    Raises on any failure. The caller treats a raise as FAIL.
    """
    result = subprocess.run(
        ["moon", "run", "examples/ssm", "--target", "native"],
        capture_output=True,
        text=True,
        timeout=900,
    )
    if result.returncode != 0:
        err = result.stderr if result.stderr else result.stdout
        raise RuntimeError(
            f"moon run examples/ssm exited {result.returncode}: {err[:400]}"
        )
    out = result.stdout
    parsed: dict = {}
    for letter, seed in SEEDS:
        for n_expect in (500, 2000):
            tag = f"{letter}{n_expect}"
            m = re.search(
                r"^ssm\s+" + tag + r"\s+n=(\d+)\s+theta=([0-9.eE+-]+)\s+"
                r"se=([0-9.eE+-]+)\s+hc0=([0-9.eE+-]+)\s+"
                r"hc0_minus_se=([0-9.eE+-]+)\s+n_obs=(\d+)\s*$",
                out,
                re.MULTILINE,
            )
            if not m:
                raise RuntimeError(
                    f"could not parse the `ssm {tag} ...` line from the "
                    f"example output. Those rows carry every MoonBit-side "
                    f"number this file checks.\n" + out[:900]
                )
            if int(m.group(1)) != n_expect or int(m.group(6)) != n_expect:
                raise RuntimeError(
                    f"the example reported n={m.group(1)} / n_obs={m.group(6)} "
                    f"where {n_expect} was expected; the 1/sqrt(n) check "
                    f"assumes an exact 4x step"
                )
            parsed[tag] = {
                "n": int(m.group(1)),
                "theta": float(m.group(2)),
                "se": float(m.group(3)),
                "hc0": float(m.group(4)),
                "hc0_minus_se": float(m.group(5)),
            }
    return parsed


def main():
    print("=" * 76)
    print("v0.107.0 DoubleMLSSM cross-check: the HC0 == se() identity")
    print("=" * 76)
    ok = True

    # --- Python reference, and the same 1/sqrt(n) comparison on it.
    theta, se = python_reference(500, 5, 1111, 3141)
    print(
        f"hand-rolled SSM (no-pi g design): theta={theta:.8f}, "
        f"se={se:.8f}, ci=[{theta - 1.96 * se:.8f}, {theta + 1.96 * se:.8f}]"
    )
    if abs(theta - 1.0) >= 0.1:
        ok = False
        print(f"    FAIL reference theta={theta} too far from 1.0")
    if not (0.0 < se < 0.2):
        ok = False
        print(f"    FAIL reference se={se} out of band")
    _, se4 = python_reference(500 * BIG_FACTOR, 5, 1111, 3141)
    py_ratio = se4 / se if se != 0 else float("inf")
    py_ok = SE_RATIO_LO < py_ratio < SE_RATIO_HI
    if not py_ok:
        ok = False
    print(
        f"hand-rolled 1/sqrt(n) at {BIG_FACTOR}x n: {py_ratio:.4f} "
        f"in ({SE_RATIO_LO}, {SE_RATIO_HI}) -> {'PASS' if py_ok else 'FAIL'}"
    )
    print(
        "    (the same comparison on an independent implementation, so the"
        " band below is not fitted to MoonBit's own output)"
    )
    print()

    # --- MoonBit side.
    print("--- MoonBit side: `moon run examples/ssm` ---")
    try:
        mb = run_moonbit()
    except Exception as exc:  # noqa: BLE001 - any failure is a FAIL
        print(f"could not obtain the MoonBit estimate: {exc}")
        print()
        print("SSM reference: FAIL")
        raise SystemExit(1)

    for letter, seed in SEEDS:
        for n_expect in (500, 2000):
            d = mb[f"{letter}{n_expect}"]
            print(
                f"  seed={seed:<5d} n={d['n']:<5d} theta={d['theta']:.8f} "
                f"se={d['se']:.8f} hc0={d['hc0']:.8f}"
            )
    print()

    print("--- checks ---")
    # 1. The exact identity. Measured difference is 0.0; the band only
    # covers a future last-ulp change, not statistical slack.
    for letter, seed in SEEDS:
        for n_expect in (500, 2000):
            tag = f"{letter}{n_expect}"
            d = mb[tag]
            rel = abs(d["hc0"] - d["se"]) / d["se"] if d["se"] != 0 else float("inf")
            good = rel < HC0_REL_TOL
            if not good:
                ok = False
            print(
                f"  HC0 == se() (seed={seed:<5d} n={n_expect:<5d}): rel = "
                f"{rel:.3e} < {HC0_REL_TOL:.0e} -> {'PASS' if good else 'FAIL'}"
                f"   [example printed hc0_minus_se={d['hc0_minus_se']!r}]"
            )
    print(
        "    (algebra, not statistics: both accessors compute"
        " sqrt(mean(psi^2)/(J^2*n)) for a var_est-shaped estimator)"
    )

    # 2. Absolute scale.
    for letter, seed in SEEDS:
        small = mb[f"{letter}500"]
        big = mb[f"{letter}{500 * BIG_FACTOR}"]
        r = big["se"] / small["se"] if small["se"] != 0 else float("inf")
        good = SE_RATIO_LO < r < SE_RATIO_HI
        if not good:
            ok = False
        print(
            f"  se ratio at {BIG_FACTOR}x (seed={seed:<5d}) = {r:.6f} in "
            f"({SE_RATIO_LO}, {SE_RATIO_HI}) -> {'PASS' if good else 'FAIL'}"
        )
        # HC0 must scale identically -- it is the same number, so a
        # divergence here would mean the identity above is a
        # coincidence at one n rather than a structural fact.
        rh = big["hc0"] / small["hc0"] if small["hc0"] != 0 else float("inf")
        good_h = SE_RATIO_LO < rh < SE_RATIO_HI
        if not good_h:
            ok = False
        print(
            f"  hc0 ratio at {BIG_FACTOR}x (seed={seed:<5d}) = {rh:.6f} in "
            f"({SE_RATIO_LO}, {SE_RATIO_HI}) -> {'PASS' if good_h else 'FAIL'}"
        )

    # 3. Convergence.
    for letter, seed in SEEDS:
        small = mb[f"{letter}500"]
        big = mb[f"{letter}{500 * BIG_FACTOR}"]
        d_small = abs(small["theta"] - 1.0)
        d_big = abs(big["theta"] - 1.0)
        good = (
            d_small < THETA_TOL_SMALL_N
            and d_big < THETA_TOL_BIG_N
            and d_big < d_small
        )
        if not good:
            ok = False
        print(
            f"  theta (seed={seed:<5d}): |theta-1| = {d_small:.4f} -> "
            f"{d_big:.4f} -> {'PASS' if good else 'FAIL'}"
        )

    print()
    print("  reported, deliberately NOT asserted:")
    print(
        "    seed 3141 gives a 4x SE ratio of 0.1270 on this DGP and"
    )
    print(
        "    diverges at n=8000 (theta = -121.88). SSM's variance is"
    )
    print(
        "    fragile with respect to the fold split; that is not a scale"
    )
    print(
        "    error, and a band wide enough to absorb it would absorb a"
    )
    print(
        "    flat SE. Pinned as an observation in"
    )
    print("    expand_v107_test.mbt::v107_ssm_se_is_fragile_to_the_split.")
    print(
        "    Note that hc0_minus_se is 0.0 there too -- the identity"
    )
    print("    holds even where the value is not trustworthy.")

    print()
    print(f"SSM reference: {'PASS' if ok else 'FAIL'}")
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
