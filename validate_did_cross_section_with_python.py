"""v0.103.0: cross-check the MoonBit `DoubleMLDIDCrossSection`
against upstream doubleml-for-py.

WHAT THIS REPLACED, and why it matters: through v0.102.0 this
file claimed to "replicate the upstream `DoubleMLDIDCS._score_elements`
algorithm" and then went on to estimate with

    theta = -<psi_a, psi_b> / ||psi_b||^2
    se    = sqrt(sum(psi^2) / (n^2 * mean(psi_b)^2))

which is NOT upstream. Upstream `DoubleMLDIDCS` is a
`LinearScoreMixin` subclass, so the estimator is the closed-form
moment root and the variance carries the usual 1/n:

    theta = -mean(psi_b) / mean(psi_a)                # _est_coef
    psi   = theta * psi_a + psi_b                     # _compute_score
    dpsi  = psi_a                                     # _compute_score_deriv
    var   = mean(psi^2) / (mean(psi_a)^2 * n)         # _var_est

Those two lines are why the MoonBit port could ship a -15%
persistent bias and a standard error that did not shrink with n
for a dozen versions: this validator mirrored the bug instead
of contradicting it. The score-element transcription below
(`compute_score_upstream`, unchanged since v0.20.0) was always
faithful -- the bug was one layer above it, in the step that
turns score elements into an estimate.

The estimator and variance are now taken from the upstream
convention above, and three checks are enforced rather than
printed:

  1. The MoonBit estimate matches this file's reference within
     Monte-Carlo error. (Needs the tolerance to be tight: the
     example DGP has near-zero noise, so a ~0.003 SE makes this
     a sharp check, not a rubber stamp.)
  2. The MoonBit estimate recovers the true ATT.
  3. The MoonBit SE falls like 1/sqrt(n). This is the
     decisive one. A coefficient comparison across two
     different RNG streams cannot separate a 0.15 bias from
     sampling noise at any reasonable tolerance, but a
     variance formula whose 1/n has been algebraically
     cancelled gives a FLAT SE: the pre-v0.102.0 code read
     0.3654 / 0.3708 / 0.3613 at n = 300 / 600 / 2400. The
     correct ratio at 4x the sample size is ~0.5.

This file FAILS CLOSED. If `moon run` cannot be executed or its
output cannot be parsed, the verdict is FAIL, not a warning --
several validators in this directory skip the MoonBit side and
still print PASS, which is a check that cannot fail.
"""

import re
import subprocess
import sys

import numpy as np

# Tolerance on |moonbit - reference| for the point estimate. The
# example DGP's noise term is 0.05 * U(-1, 0.5), i.e. a standard
# deviation near 0.021, so both estimates land within ~0.01 of the
# truth. 0.05 is roughly 15x the observed spread and still less
# than a third of the 0.15 bias the v0.102.0 predecessor reported.
THETA_TOL = 0.05

# Same tolerance on the noisy DGP. Measured spread between the
# two sides is ~0.01; the pre-v0.102.0 argmin fit sat 0.104
# away, so this is a 10x margin on both sides.
NOISY_THETA_TOL = 0.05

# The SE at 4x the sample size, relative to the SE at 1x. A
# consistent estimator gives 1/sqrt(4) = 0.5. The band is wide
# because n=2000 still has 2-fold cross-fitting noise, but it is
# nowhere near the ~0.97 a 1/n-free variance produces.
SE_RATIO_LO = 0.35
SE_RATIO_HI = 0.70

# The example DGP, restated here so the two sides model the same
# data even though the RNG streams differ (MoonBit uses chacha8,
# numpy uses PCG64 -- they cannot be aligned).
EXAMPLE_N = 500
EXAMPLE_P = 3
EXAMPLE_THETA = 1.0


def fit_g_subset(x, y, d, t, d_value, t_value):
    """Fit a linear regression on the (d == d_value)
    AND (t == t_value) subset, then predict on the
    full sample. Returns the predictions array.
    """
    mask = (d == d_value) & (t == t_value)
    if mask.sum() < x.shape[1] + 1:
        return np.zeros(x.shape[0])
    model = np.linalg.lstsq(
        np.column_stack([np.ones(mask.sum()), x[mask]]), y[mask], rcond=None,
    )[0]
    X_full = np.column_stack([np.ones(x.shape[0]), x])
    return X_full @ model


def fit_m(x, d):
    """Fit the propensity `m(x) = E[D=1 | X]` via OLS.
    Returns the predictions array.
    """
    model = np.linalg.lstsq(
        np.column_stack([np.ones(x.shape[0]), x]), d, rcond=None,
    )[0]
    X_full = np.column_stack([np.ones(x.shape[0]), x])
    return X_full @ model


def compute_score_upstream(
    y, d, t, g00, g01, g10, g11, m, score="observational",
    in_sample_normalization=False,
):
    """Replicate the upstream
    `doubleml.DoubleMLDIDCS._score_elements` formula.

    This part was faithful from v0.20.0 and is unchanged: the
    v0.102.0 defect lived in the estimation step that consumed
    its output, not here.
    """
    n = len(y)
    d1t1 = d * t
    d1t0 = d * (1.0 - t)
    d0t1 = (1.0 - d) * t
    d0t0 = (1.0 - d) * (1.0 - t)
    mean_d = np.mean(d)
    mean_t = np.mean(t)
    p_hat = mean_d
    lambda_hat = mean_t
    mean_d1t1 = np.mean(d1t1)
    mean_d1t0 = np.mean(d1t0)
    mean_d0t1 = np.mean(d0t1)
    mean_d0t0 = np.mean(d0t0)
    one_minus_m = 1.0 - m
    # Mean d0t{0,1} * prop_weighting (only used in observational).
    if score == "observational":
        pw = np.where(one_minus_m > 1e-12, m / one_minus_m, 0.0)
        mean_d0t1_pw = np.mean(d0t1 * pw)
        mean_d0t0_pw = np.mean(d0t0 * pw)
    # Weights.
    if score == "observational":
        if in_sample_normalization:
            weight_psi_a = d / mean_d
        else:
            weight_psi_a = np.where(p_hat > 0, d / p_hat, 0.0)
        weight_g_d1_t1 = np.where(p_hat > 0, d / p_hat, 0.0)
        weight_g_d1_t0 = np.where(p_hat > 0, -d / p_hat, 0.0)
        weight_g_d0_t1 = np.where(p_hat > 0, -d / p_hat, 0.0)
        weight_g_d0_t0 = np.where(p_hat > 0, d / p_hat, 0.0)
    else:
        weight_psi_a = np.ones_like(y)
        weight_g_d1_t1 = np.ones_like(y)
        weight_g_d1_t0 = -np.ones_like(y)
        weight_g_d0_t1 = -np.ones_like(y)
        weight_g_d0_t0 = np.ones_like(y)
    # Residuals.
    resid_d0_t0 = y - g00
    resid_d0_t1 = y - g01
    resid_d1_t0 = y - g10
    resid_d1_t1 = y - g11
    # Residual weights.
    if score == "observational":
        if in_sample_normalization:
            weight_resid_d1_t1 = np.where(
                mean_d1t1 > 0, d1t1 / mean_d1t1, 0.0
            )
            weight_resid_d1_t0 = np.where(
                mean_d1t0 > 0, -d1t0 / mean_d1t0, 0.0
            )
            weight_resid_d0_t1 = np.where(
                mean_d0t1_pw > 0, -d0t1 * pw / mean_d0t1_pw, 0.0
            )
            weight_resid_d0_t0 = np.where(
                mean_d0t0_pw > 0, d0t0 * pw / mean_d0t0_pw, 0.0
            )
        else:
            weight_resid_d1_t1 = np.where(
                p_hat * lambda_hat > 1e-12, d1t1 / (p_hat * lambda_hat), 0.0
            )
            weight_resid_d1_t0 = np.where(
                p_hat * (1 - lambda_hat) > 1e-12,
                -d1t0 / (p_hat * (1 - lambda_hat)),
                0.0,
            )
            weight_resid_d0_t1 = np.where(
                p_hat * lambda_hat > 1e-12,
                -d0t1 / (p_hat * lambda_hat) * pw,
                0.0,
            )
            weight_resid_d0_t0 = np.where(
                p_hat * (1 - lambda_hat) > 1e-12,
                d0t0 / (p_hat * (1 - lambda_hat)) * pw,
                0.0,
            )
    else:
        if in_sample_normalization:
            weight_resid_d1_t1 = np.where(
                mean_d1t1 > 0, d1t1 / mean_d1t1, 0.0
            )
            weight_resid_d1_t0 = np.where(
                mean_d1t0 > 0, -d1t0 / mean_d1t0, 0.0
            )
            weight_resid_d0_t1 = np.where(
                mean_d0t1 > 0, -d0t1 / mean_d0t1, 0.0
            )
            weight_resid_d0_t0 = np.where(
                mean_d0t0 > 0, d0t0 / mean_d0t0, 0.0
            )
        else:
            weight_resid_d1_t1 = np.where(
                p_hat * lambda_hat > 1e-12, d1t1 / (p_hat * lambda_hat), 0.0
            )
            weight_resid_d1_t0 = np.where(
                p_hat * (1 - lambda_hat) > 1e-12,
                -d1t0 / (p_hat * (1 - lambda_hat)),
                0.0,
            )
            weight_resid_d0_t1 = np.where(
                (1 - p_hat) * lambda_hat > 1e-12,
                -d0t1 / ((1 - p_hat) * lambda_hat),
                0.0,
            )
            weight_resid_d0_t0 = np.where(
                (1 - p_hat) * (1 - lambda_hat) > 1e-12,
                d0t0 / ((1 - p_hat) * (1 - lambda_hat)),
                0.0,
            )
    psi_a = -weight_psi_a
    psi_b_1 = (
        weight_g_d1_t1 * g11
        + weight_g_d1_t0 * g10
        + weight_g_d0_t0 * g00
        + weight_g_d0_t1 * g01
    )
    psi_b_2 = (
        weight_resid_d1_t1 * resid_d1_t1
        + weight_resid_d1_t0 * resid_d1_t0
        + weight_resid_d0_t0 * resid_d0_t0
        + weight_resid_d0_t1 * resid_d0_t1
    )
    psi_b = psi_b_1 + psi_b_2
    return psi_a, psi_b


def upstream_estimate(psi_a, psi_b):
    """Upstream's `LinearScoreMixin` estimate for DIDCS.

    Mirrors `DoubleML._est_causal_pars_and_se` for a linear
    score `psi = theta * psi_a + psi_b`:
      `_est_coef`           -> -mean(psi_b) / mean(psi_a)
      `_compute_score`      -> theta * psi_a + psi_b
      `_compute_score_deriv`-> psi_a, so J = mean(psi_a)
      `_var_est`            -> mean(psi^2) / (J^2 * n)

    Returns (theta, se). The `1 / n` is not optional: without
    it the SE is invariant to the sample size, which is the
    defect this whole file exists to catch.
    """
    n = len(psi_a)
    j = np.mean(psi_a)
    if j == 0.0:
        raise ValueError("mean(psi_a) is zero; cannot form J")
    theta = -np.mean(psi_b) / j
    psi = theta * psi_a + psi_b
    var = np.mean(psi ** 2) / (j ** 2 * n)
    return theta, np.sqrt(var)


def make_example_dgp(n, p, theta0, seed, noise_amp=0.05):
    """The `examples/did_cross_section` DGP, restated in numpy.

    `y = sum_j x_j + theta0 * 1[d=1 & t=1] + noise_amp * (U(-1,1) - 0.5)`.
    Same model as the MoonBit example, different RNG stream.

    `noise_amp` matters. At 0.05 the outcome is nearly a
    deterministic function of the regressors, and on such data
    several wrong point estimates coincide with the right one:
    the pre-v0.102.0 argmin fit read ATT_hat = 1.0024 here
    against 0.9961 for the moment root. At 0.5 the two separate
    by ~0.10 (0.8567 vs 0.9612), which is what makes a
    coefficient comparison diagnostic instead of decorative.
    """
    rng = np.random.default_rng(seed)
    x = rng.uniform(-1.0, 1.0, size=(n, p))
    d = (rng.uniform(size=n) < 0.5).astype(float)
    t = (rng.uniform(size=n) < 0.5).astype(int)
    noise = noise_amp * (rng.uniform(size=n) - 0.5)
    y = x.sum(axis=1) + theta0 * d * t + noise
    return x, y, d, t


def reference_estimate(n, p, theta0, seed, noise_amp):
    """Score elements + upstream `LinearScoreMixin` estimate."""
    x, y, d, t = make_example_dgp(n, p, theta0, seed, noise_amp)
    g00 = fit_g_subset(x, y, d, t, 0.0, 0)
    g01 = fit_g_subset(x, y, d, t, 0.0, 1)
    g10 = fit_g_subset(x, y, d, t, 1.0, 0)
    g11 = fit_g_subset(x, y, d, t, 1.0, 1)
    m = np.clip(fit_m(x, d), 1e-6, 1 - 1e-6)
    psi_a, psi_b = compute_score_upstream(
        y, d, t, g00, g01, g10, g11, m, score="observational",
        in_sample_normalization=False,
    )
    theta, se = upstream_estimate(psi_a, psi_b)
    return psi_a, psi_b, theta, se


def run_moonbit():
    """Spawn `moon run examples/did_cross_section` and parse.

    Returns (att_hat, se, att_hat_big, se_big) or raises. The
    caller treats a raise as FAIL; this function never reports a
    partial result as success.
    """
    result = subprocess.run(
        ["moon", "run", "examples/did_cross_section", "--target", "native"],
        capture_output=True,
        text=True,
        timeout=900,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "moon run examples/did_cross_section exited "
            f"{result.returncode}: {result.stderr[:400]}"
        )
    out = result.stdout
    main = re.search(
        r"^ATT_hat\s*=\s*([0-9.eE+-]+)\s*,\s*se\s*=\s*([0-9.eE+-]+)\s*$",
        out,
        re.MULTILINE,
    )
    if not main:
        raise RuntimeError(
            "could not parse 'ATT_hat = ..., se = ...' from example output:\n"
            + out[:600]
        )
    scale = re.search(
        r"^scale n=\d+\s+ATT_hat\s*=\s*([0-9.eE+-]+)\s*,\s*"
        r"se\s*=\s*([0-9.eE+-]+)\s*$",
        out,
        re.MULTILINE,
    )
    if not scale:
        raise RuntimeError(
            "could not parse the 'scale n=...' line from example output.\n"
            "That line carries the 1/sqrt(n) check; without it this file "
            "cannot see a 1/n-free variance.\n" + out[:600]
        )
    noisy = re.search(
        r"^noisy ATT_hat\s*=\s*([0-9.eE+-]+)\s*,\s*se\s*=\s*([0-9.eE+-]+)\s*$",
        out,
        re.MULTILINE,
    )
    if not noisy:
        raise RuntimeError(
            "could not parse the 'noisy ATT_hat = ...' line from example "
            "output.\nThat line carries the noisy-DGP coefficient check; "
            "on the near-noise-free DGP a wrong point estimate is "
            "indistinguishable from the right one.\n" + out[:600]
        )
    return (
        float(main.group(1)),
        float(main.group(2)),
        float(scale.group(1)),
        float(scale.group(2)),
        float(noisy.group(1)),
        float(noisy.group(2)),
    )


def main():
    print("=" * 70)
    print("DoubleMLDIDCrossSection vs upstream LinearScoreMixin")
    print("=" * 70)

    n = EXAMPLE_N
    p = EXAMPLE_P
    theta_true = EXAMPLE_THETA

    psi_a, psi_b, theta_ref, se_ref = reference_estimate(
        n, p, theta_true, seed=11, noise_amp=0.05
    )
    print(f"reference DGP: n={n} p={p} true ATT={theta_true} noise_amp=0.05")
    print(f"  mean(psi_a) = {np.mean(psi_a):.6f}  (J = dE[psi]/d theta)")
    print(f"  reference theta_hat = {theta_ref:.6f}")
    print(f"  reference se        = {se_ref:.6f}")
    print(
        f"  reference 95% CI    = "
        f"[{theta_ref - 1.96 * se_ref:.6f}, {theta_ref + 1.96 * se_ref:.6f}]"
    )

    # The same DGP at 10x the noise. This is the variant that
    # separates a correct point estimate from a wrong one; see
    # `make_example_dgp`.
    _, _, theta_noisy, se_noisy = reference_estimate(
        n, p, theta_true, seed=11, noise_amp=0.5
    )
    print("")
    print(f"reference DGP: n={n} p={p} true ATT={theta_true} noise_amp=0.5")
    print(f"  reference theta_hat = {theta_noisy:.6f}")
    print(f"  reference se        = {se_noisy:.6f}")

    # Multiplier bootstrap sanity on the reference score.
    n_boot = 1000
    rng_boot = np.random.default_rng(2024)
    weights = rng_boot.normal(size=(n_boot, n))
    psi = theta_ref * psi_a + psi_b
    se_psi = np.sqrt(np.sum(psi ** 2) / n)
    boot_t_stat = (weights @ psi) / (np.sqrt(n) * se_psi)
    boot_mean = np.mean(boot_t_stat)
    boot_sd = np.std(boot_t_stat)
    print("")
    print(f"reference bootstrap t-stat: mean={boot_mean:.4f} sd={boot_sd:.4f}")
    boot_ok = abs(boot_mean) < 0.1 and abs(boot_sd - 1.0) < 0.1
    print(
        f"  |mean| < 0.1 and |sd - 1| < 0.1 -> "
        f"{'PASS' if boot_ok else 'FAIL'}"
    )

    print("")
    print("--- MoonBit side: `moon run examples/did_cross_section` ---")
    try:
        (
            mb_att,
            mb_se,
            mb_att_big,
            mb_se_big,
            mb_att_noisy,
            mb_se_noisy,
        ) = run_moonbit()
    except Exception as exc:  # noqa: BLE001 - any failure is a FAIL
        print(f"could not obtain the MoonBit estimate: {exc}")
        print("")
        print("Cross-section DID reference: FAIL")
        return 1

    print(f"  moonbit n=500  ATT_hat = {mb_att:.6f}  se = {mb_se:.6f}")
    print(f"  moonbit n=2000 ATT_hat = {mb_att_big:.6f}  se = {mb_se_big:.6f}")
    print(
        f"  moonbit noisy ATT_hat = {mb_att_noisy:.6f}  "
        f"se = {mb_se_noisy:.6f}"
    )
    se_ratio = mb_se_big / mb_se
    print(f"  se ratio (4x n)          = {se_ratio:.6f}  (1/sqrt(4) = 0.5)")

    d_ref = abs(mb_att - theta_ref)
    d_true = abs(mb_att - theta_true)
    d_noisy = abs(mb_att_noisy - theta_noisy)
    d_noisy_true = abs(mb_att_noisy - theta_true)
    print("")
    print("--- checks ---")
    print(
        f"  |moonbit - reference| = {d_ref:.6f} < {THETA_TOL} -> "
        f"{'PASS' if d_ref < THETA_TOL else 'FAIL'}"
        "   (low noise: sanity only, see note below)"
    )
    print(
        f"  |noisy moonbit - noisy reference| = {d_noisy:.6f} < "
        f"{NOISY_THETA_TOL} -> {'PASS' if d_noisy < NOISY_THETA_TOL else 'FAIL'}"
    )
    print(
        f"  |noisy moonbit - true ATT| = {d_noisy_true:.6f} < "
        f"{NOISY_THETA_TOL} -> "
        f"{'PASS' if d_noisy_true < NOISY_THETA_TOL else 'FAIL'}"
    )
    ratio_ok = SE_RATIO_LO < se_ratio < SE_RATIO_HI
    print(
        f"  {SE_RATIO_LO} < se ratio < {SE_RATIO_HI} -> "
        f"{'PASS' if ratio_ok else 'FAIL'}"
    )
    print(
        "  (the 1/n check: a variance formula with the 1/n cancelled "
        "gives a flat SE, ratio ~1.0)"
    )
    print(
        "  (the noisy coefficient check: the pre-v0.102.0 argmin fit read "
        "0.8567 here, this estimator reads ~0.96)"
    )

    all_ok = (
        boot_ok
        and d_ref < THETA_TOL
        and d_noisy < NOISY_THETA_TOL
        and d_noisy_true < NOISY_THETA_TOL
        and ratio_ok
    )
    print("")
    print(
        "Cross-section DID reference: " + ("PASS" if all_ok else "FAIL")
    )
    if not all_ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
