"""v0.105.0: cross-check the MoonBit `DoubleMLLPLR` against BOTH the
upstream `doubleml.plm.DoubleMLLPLR` (doubleml >= 0.11) and an
independent hand-rolled Python reference of the Newton path.

WHAT THIS FILE USED TO BE, and why it had to be rewritten rather
than extended. Through v0.104.0 this file printed

    "MoonBit reference (lplr_test.mbt, seed=3141, n_folds=2):
       theta_hat = 0.46403803, se = 0.26968752"

as a hand-copied literal. It never ran `moon`, never compared that
literal against anything, and that literal had been stale since at
least v0.92 (the example printed 0.46411015764901836). So the one
check that looked like it compared MoonBit to upstream compared a
constant to nothing.

WHAT IT FOUND WHEN IT ACTUALLY RAN `moon`. The two scores it prints
side by side were bit-for-bit equal. That is not an identity:
`DoubleMLLPLR::new` validated `score` and stored it, and nothing
downstream ever read the field, so `score="instrument"` silently
returned the `nuisance_space` answer. Upstream branches in four
places (`plm/lplr.py:244-252`, `:450-455`, `:521-530`, `:532-540`)
and the two `_compute_score` formulas share nothing but `r_hat` and
`d_tilde`. v0.105.0 implemented the missing branch.

WHAT IS ASSERTED HERE, and what is deliberately NOT:

  1. The two MoonBit scores differ. Exact, zero Monte-Carlo error.
     This is the regression that shipped for many versions, and it
     is the only check on this page that could not have passed by
     accident. Note the direction: the assertion is that they are
     NOT equal. An `assert psi_nuisance == psi_instrument` would
     have read as an elegant invariant and would have welded the
     unimplemented parameter in as a property of the estimator.
  2. The MoonBit SE falls like 1/sqrt(n) across a 4x sample size.
  3. The MoonBit estimates sit inside a Monte-Carlo band around this
     file's Python reference.

WHAT IS NOT ASSERTED, and why. Upstream's own run-to-run spread on
this DGP is enormous: with `draw_sample_splitting=True` and no
seeded split, seven refits gave a theta standard deviation of 0.198
on a true value near 0.5 -- and the `instrument` median came out at
0.186. MoonBit draws from `chacha8_rng`, Python from `default_rng`,
and the fold splits cannot be aligned. Any band tight enough to be
diagnostic would be tighter than upstream's own noise, so a
coefficient comparison at that width is a coin flip dressed as a
test. Check 3 therefore uses a band wide enough to absorb the noise
and says so out loud; checks 1 and 2 carry the weight.

This file FAILS CLOSED. If `moon run` cannot be executed or its
output cannot be parsed, the verdict is FAIL.
"""

import re
import subprocess
import sys
import warnings

import numpy as np
import pandas as pd
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.model_selection import KFold

# The example runs at n=500 and, in a `scale` block, at n=2000 on the
# same DGP. A consistent estimator gives se ratio 1/sqrt(4) = 0.5.
# The band is wide because the DGP is noisy at these sizes (measured
# se at n=500 is ~0.27), and because the 4x draw is a single sample.
# What this actually rules out is a variance with the 1/n cancelled:
# that reads as a ratio near 1.0. This is a "the SE is not flat"
# check, not a precision claim.
SE_RATIO_LO = 0.25
SE_RATIO_HI = 0.85

# Monte-Carlo band on the point estimate, in units of the reference
# SE. 3 SE is the usual "could easily happen by chance" width; see
# the docstring for why it cannot be much tighter on this DGP.
MC_SIGMA = 3.0

# The two scores must separate by at least this much. Measured on
# the example: |theta_instrument - theta_nuisance_space| = 0.047.
# The threshold is 10x under that and 1e6x above the 1e-12 band, so
# it neither hides a regression nor flakily fires.
SCORE_GAP_MIN = 1.0e-3


def build_simplified_lzz2020(
    n_obs: int, alpha: float, seed: int
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Mirror of `lplr_test.mbt::build_lzz2020_dgp` for Python.

    Returns (x, y, d) so both the MoonBit port and the Python
    reference can drive from the same numpy state.
    """
    rng = np.random.default_rng(seed)
    p = 6
    x = rng.standard_normal((n_obs, p))
    r0 = (
        0.25 * x[:, 0] * x[:, 1]
        + 0.25 * x[:, 2] ** 2
        + 0.25 * np.cos(x[:, 3])
        - 0.5 * np.sin(x[:, 4])
        + (x[:, 5] > 0).astype(float)
        - 0.5
    )
    a0 = 0.5 * np.sin(x[:, 0]) + 0.5 * np.cos(x[:, 1]) + 0.5 * rng.standard_normal(n_obs)
    p_t = 1.0 / (1.0 + np.exp(-a0))
    d = (rng.uniform(size=n_obs) < p_t).astype(float)
    prob = 1.0 / (1.0 + np.exp(-(alpha * d + r0)))
    y = (rng.uniform(size=n_obs) < prob).astype(float)
    return x, y, d


def upstream_lplr(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, score: str, trials: int = 5
) -> tuple[float, float, float]:
    """Reference: upstream `DoubleMLLPLR` with sklearn defaults.

    Returns (median theta, median se, theta std) over `trials` refits.
    The spread is returned rather than discarded on purpose: upstream
    draws a fresh unseeded split per fit, and the caller needs to see
    how wide that is before trusting any comparison against it.
    """
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        from doubleml.plm import DoubleMLLPLR
        from doubleml.data import DoubleMLData

    df = pd.DataFrame(
        np.column_stack([x, y, d]),
        columns=[f"x{j + 1}" for j in range(x.shape[1])] + ["y", "d"],
    )
    obj = DoubleMLData(df, "y", "d", [f"x{j + 1}" for j in range(x.shape[1])])
    coef_samples: list[float] = []
    se_samples: list[float] = []
    for _ in range(trials):
        model = DoubleMLLPLR(
            obj,
            ml_M=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
            ml_t=LinearRegression(),
            ml_m=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
            ml_a=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
            n_folds=2,
            score=score,
            draw_sample_splitting=True,
        )
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            model.fit()
        coef_samples.append(float(model.coef[0]))
        se_samples.append(float(model.se[0]))
    return (
        float(np.median(coef_samples)),
        float(np.median(se_samples)),
        float(np.std(coef_samples)),
    )


def handrolled_lplr(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, seed: int, score: str
) -> tuple[float, float]:
    """Independent re-implementation of upstream LPLR's score with
    `root_scalar(method="newton")` for the solve.

    The two `_compute_score` / `_compute_score_deriv` formulas are
    transcribed from `plm/lplr.py:521-540` and branch on `score` the
    way upstream does. The `m_hat` nuisance is aliased to the
    propensity `a_hat`, matching this port's `m_pred = a_pred`; see
    the `fit` body in `lplr.mbt` for why, and what it costs.
    """
    n_obs, _ = x.shape
    kf = KFold(n_splits=2, shuffle=True, random_state=seed)
    M_outer = np.zeros(n_obs)
    a_outer = np.zeros(n_obs)
    for tr, te in kf.split(x):
        M = LogisticRegression(C=1e6, max_iter=500, solver="lbfgs").fit(
            np.column_stack([d[tr], x[tr]]), y[tr]
        )
        M_outer[te] = M.predict_proba(np.column_stack([d[te], x[te]]))[:, 1]
        a = LogisticRegression(C=1e6, max_iter=500, solver="lbfgs").fit(x[tr], d[tr])
        a_outer[te] = a.predict_proba(x[te])[:, 1]
    M_outer = np.clip(M_outer, 1e-8, 1 - 1e-8)
    a_outer = np.clip(a_outer, 1e-8, 1 - 1e-8)
    W = np.log(M_outer / (1.0 - M_outer))
    t_hat = np.zeros(n_obs)
    for tr, te in kf.split(x):
        t_hat[te] = LinearRegression().fit(x[tr], W[tr]).predict(x[te])
    dt = d - a_outer
    beta = (dt * W).sum() / (dt**2).sum()
    r_hat = t_hat - beta * a_outer
    psi_hat = 1.0 / (1.0 + np.exp(-r_hat))
    score_const = dt * (1.0 - y) * np.exp(r_hat)

    def psi(theta: float) -> np.ndarray:
        if score == "instrument":
            return (y - 1.0 / (1.0 + np.exp(-(theta * d + r_hat)))) * dt
        score_1 = y * np.exp(-theta * d) * dt
        return psi_hat * (score_1 - score_const)

    def psi_deriv(theta: float) -> np.ndarray:
        if score == "instrument":
            e = 1.0 / (1.0 + np.exp(-(theta * d + r_hat)))
            return -d * e * (1.0 - e) * dt
        return psi_hat * y * (-d) * np.exp(-theta * d) * dt

    from scipy.optimize import root_scalar

    theta0 = float((d * t_hat).sum() / (d * d).sum())
    res = root_scalar(
        lambda t: psi(t).mean(),
        x0=theta0,
        fprime=lambda t: psi_deriv(t).mean(),
        method="newton",
    )
    theta = float(res.root)
    psi_t = psi(theta)
    psi_a = psi_deriv(theta)
    psi_b = psi_t - theta * psi_a
    J = float(psi_a.mean())
    gamma = float(((theta * psi_a + psi_b) ** 2).mean())
    return theta, float(np.sqrt(gamma / (J * J * n_obs)))


def run_moonbit() -> dict:
    """Spawn `moon run examples/lplr` and parse.

    Raises on any failure -- a missing binary, a non-zero exit, a
    missing line. The caller treats a raise as FAIL; this function
    never reports a partial result as success.
    """
    result = subprocess.run(
        ["moon", "run", "examples/lplr", "--target", "native"],
        capture_output=True,
        text=True,
        timeout=900,
    )
    if result.returncode != 0:
        err = result.stderr if result.stderr else result.stdout
        raise RuntimeError(
            f"moon run examples/lplr exited {result.returncode}: {err[:400]}"
        )
    out = result.stdout
    # Each score is printed in its own `--- <name> ... ---` block, so
    # anchor on the block headers rather than matching positionally.
    blocks = re.split(r"^--- ", out, flags=re.MULTILINE)
    ns_block = next((b for b in blocks if b.startswith("nuisance_space")), None)
    inst_block = next((b for b in blocks if b.startswith("instrument")), None)
    if not ns_block or not inst_block:
        raise RuntimeError(
            "could not find both `--- nuisance_space ---` and "
            "`--- instrument ---` blocks in the example output. If the "
            "example stops printing both scores, this file can no longer "
            "check the regression it exists for.\n" + out[:600]
        )
    ns_theta, ns_se = _block_pair(ns_block, "nuisance_space")
    in_theta, in_se = _block_pair(inst_block, "instrument")

    # The `scale` block prints `scale n=<N> theta_hat = X` and
    # `scale n=<N> se        = Y` -- both carry the `scale n=` prefix,
    # so they do not go through `_block_pair`.
    sc = re.search(
        r"^scale n=\d+\s+theta_hat\s*=\s*([0-9.eE+-]+)\s*$\s*^scale n=\d+"
        r"\s+se\s*=\s*([0-9.eE+-]+)\s*$",
        out,
        re.MULTILINE,
    )
    if not sc:
        raise RuntimeError(
            "could not parse the `scale n=...` theta_hat/se pair from the "
            "example output. Those two lines carry the 1/sqrt(n) check; "
            "without them this file cannot see a 1/n-free variance.\n"
            + out[:600]
        )
    return {
        "ns_theta": ns_theta,
        "ns_se": ns_se,
        "in_theta": in_theta,
        "in_se": in_se,
        "sc_theta": float(sc.group(1)),
        "sc_se": float(sc.group(2)),
    }


def _block_pair(text: str, what: str) -> tuple[float, float]:
    """Pull `theta_hat = X` and `se = Y` out of one example block."""
    th = re.search(r"theta_hat\s*=\s*([0-9.eE+-]+)", text)
    se = re.search(r"^se\s*=\s*([0-9.eE+-]+)\s*$", text, re.MULTILINE)
    if not th or not se:
        raise RuntimeError(
            f"could not parse theta_hat/se for {what} from the example "
            f"output. Those are what this file checks; without them the "
            f"verdict would be vacuous.\n" + text[:600]
        )
    return float(th.group(1)), float(se.group(1))


def main() -> None:
    print("=" * 76)
    print("v0.105.0 DoubleMLLPLR cross-check vs upstream + hand-rolled Newton ref")
    print("=" * 76)
    n_obs, alpha, seed = 500, 0.5, 3141
    x, y, d = build_simplified_lzz2020(n_obs, alpha, seed)

    ref = {}
    for sc in ("nuisance_space", "instrument"):
        th_up, se_up, sd_up = upstream_lplr(x, y, d, sc)
        th_hr, se_hr = handrolled_lplr(x, y, d, seed, sc)
        ref[sc] = (th_up, se_up, sd_up, th_hr, se_hr)
        print(f"{sc}:")
        print(f"  upstream DoubleMLLPLR  theta={th_up:10.4f} se={se_up:10.4f} (sd {sd_up:.4f})")
        print(f"  handrolled Newton ref  theta={th_hr:10.4f} se={se_hr:10.4f}")
    print()
    print("  Upstream's own theta spread is the reason no tight coefficient")
    print("  check appears below; a band narrower than that would be a coin flip.")
    print()

    ok = True
    print("--- MoonBit side: `moon run examples/lplr` ---")
    try:
        mb = run_moonbit()
    except Exception as exc:  # noqa: BLE001 - any failure is a FAIL
        print(f"could not obtain the MoonBit estimate: {exc}")
        print("")
        print("LPLR reference: FAIL")
        raise SystemExit(1)

    print(f"  moonbit nuisance_space  theta={mb['ns_theta']:10.6f} se={mb['ns_se']:.6f}")
    print(f"  moonbit instrument      theta={mb['in_theta']:10.6f} se={mb['in_se']:.6f}")
    print(f"  moonbit scale n=2000    theta={mb['sc_theta']:10.6f} se={mb['sc_se']:.6f}")

    theta_gap = abs(mb["in_theta"] - mb["ns_theta"])
    se_gap = abs(mb["in_se"] - mb["ns_se"])
    se_ratio = mb["sc_se"] / mb["ns_se"]
    print("")
    print("--- checks ---")
    print(
        f"  the two scores differ: |dtheta|={theta_gap:.6f}, |dse|={se_gap:.6f} "
        f"> {SCORE_GAP_MIN} -> {'PASS' if theta_gap > SCORE_GAP_MIN else 'FAIL'}"
    )
    print(
        "    (through v0.104.0 `score` was validated and then never read;"
        " this gap was exactly 0.0)"
    )
    ratio_ok = SE_RATIO_LO < se_ratio < SE_RATIO_HI
    print(
        f"  {SE_RATIO_LO} < se ratio (4x n) = {se_ratio:.6f} < {SE_RATIO_HI} -> "
        f"{'PASS' if ratio_ok else 'FAIL'}"
    )
    print("    (catches a variance with the 1/n cancelled: that reads ~1.0)")

    for sc, mb_theta, mb_se in (
        ("nuisance_space", mb["ns_theta"], mb["ns_se"]),
        ("instrument", mb["in_theta"], mb["in_se"]),
    ):
        th_up, se_up, sd_up, th_hr, se_hr = ref[sc]
        band = max(MC_SIGMA * max(se_up, se_hr, mb_se), 0.10)
        d_up = abs(mb_theta - th_up)
        d_hr = abs(mb_theta - th_hr)
        band_ok = d_up < band and d_hr < band
        print(
            f"  {sc:<14s} |mb - upstream|={d_up:.4f} |mb - handrolled|={d_hr:.4f} "
            f"< {band:.4f} -> {'PASS' if band_ok else 'FAIL'}"
        )
        print(
            f"    (band is {MC_SIGMA} x the reference SE, floored at 0.10; "
            f"upstream's own theta sd here is {sd_up:.4f})"
        )
        if not band_ok:
            ok = False

    if theta_gap <= SCORE_GAP_MIN:
        ok = False
    if not ratio_ok:
        ok = False

    print("")
    print(f"LPLR reference: {'PASS' if ok else 'FAIL'}")
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()