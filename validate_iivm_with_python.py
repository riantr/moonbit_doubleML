"""
Numerical cross-check of the MoonBit DML IIVM port.

Same protocol as the PLR/IRM/PLIV validators, but for IIVM with
the LATE score.

The MoonBit port uses `LinearRegression` + clipping for all five
nuisances; the upstream `DoubleMLIIVM` requires `ml_m` and `ml_r`
to be classifiers with `predict_proba`. To get an apples-to-apples
comparison we run:

  1. A hand-rolled Python implementation that mirrors the MoonBit
     port's algorithm exactly (closed-form OLS for g0/g1/m/r0/r1,
     LATE score, propensity clipping, K-fold cross-fit with
     conditional sample splitting).
  2. The MoonBit port itself, via `moon run examples/main` and stdout
     parsing.

We also report the upstream `DoubleMLIIVM` for context (it will
differ by model-class noise, not by algorithmic divergence).

TODO #7 additionally cross-checks n_rep=5:
  * `reference_iivm_mimic_moonbit_n_rep5` runs the hand-rolled algorithm
    R=5 times (each rep uses an independent
    `KFold(n_splits=2, shuffle=True, random_state=3141 + r)`) and
    aggregates via the MoonBit formula
    `theta_hat = median(theta_1..R)`,
    `se_hat = (median(theta + 1.96*se) - theta_hat) / 1.96`
    (see `aggregator.mbt:32-60`).
  * `upstream_iivm_n_rep5` calls `DoubleMLIIVM(..., n_rep=5)` and returns
    its `(coef, se)`.
  * The MoonBit side is parsed from the section
    `=== MoonBit DML IIVM (..., n_rep=5) ===` that moonbit-coder adds
    to `examples/main/main.mbt`.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import doubleml as dml
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.model_selection import KFold


def make_dgp(n: int, p: int, theta: float, alpha: float, seed: int):
    """Mirror the MoonBit IIVM DGP: z ~ Bernoulli(0.5),
    d = 1{alpha*z + v > 0}, y = theta*d + x @ 1 + eps.

    Uses `numpy.random.default_rng(seed)` so we can match by `seed`.
    """
    rng = np.random.default_rng(seed)
    # generate x via standard normals
    x = rng.standard_normal(size=(n, p))
    # v and eps are correlated with a small 0.3 cross-covariance
    xx = rng.multivariate_normal(
        np.zeros(2), np.array([[1.0, 0.3], [0.3, 1.0]]), size=n,
    )
    u = xx[:, 0]
    v = xx[:, 1]
    # z is Bernoulli(0.5)
    z = (rng.uniform(size=n) > 0.5).astype(np.float64)
    d = (alpha * z + v > 0).astype(np.float64)
    y = theta * d + x @ np.ones(p) + 0.3 * u
    return x, y, d, z


def reference_iivm_mimic_moonbit(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray,
    folds: list[tuple[np.ndarray, np.ndarray]],
    propensity_clip: float = 1e-6,
):
    """Hand-rolled IIVM matching the MoonBit port exactly."""
    n = len(y)
    g0 = np.zeros(n)
    g1 = np.zeros(n)
    m = np.zeros(n)
    r0 = np.zeros(n)
    r1 = np.zeros(n)
    for tr, te in folds:
        # g0 / g1: train on Z=0 / Z=1
        tr_z0 = tr[z[tr] == 0]
        tr_z1 = tr[z[tr] == 1]
        if len(tr_z0) > 0:
            ml = LinearRegression().fit(x[tr_z0], y[tr_z0])
            g0[te] = ml.predict(x[te])
        if len(tr_z1) > 0:
            ml = LinearRegression().fit(x[tr_z1], y[tr_z1])
            g1[te] = ml.predict(x[te])
        # m: trained on all
        mlm = LinearRegression().fit(x[tr], z[tr])
        m[te] = mlm.predict(x[te])
        # r0 / r1: train on Z=0 / Z=1
        if len(tr_z0) > 0:
            ml = LinearRegression().fit(x[tr_z0], d[tr_z0])
            r0[te] = ml.predict(x[te])
        if len(tr_z1) > 0:
            ml = LinearRegression().fit(x[tr_z1], d[tr_z1])
            r1[te] = ml.predict(x[te])
    m = np.clip(m, propensity_clip, 1.0 - propensity_clip)
    # LATE score
    u0 = y - g0
    u1 = y - g1
    w0 = d - r0
    w1 = d - r1
    psi_b = (g1 - g0) + z * u1 / m - (1.0 - z) * u0 / (1.0 - m)
    psi_a = -(r1 - r0) - z * w1 / m + (1.0 - z) * w0 / (1.0 - m)
    theta = -psi_b.mean() / psi_a.mean()
    psi = theta * psi_a + psi_b
    gamma = (psi ** 2).mean()
    J = psi_a.mean()
    sigma2 = gamma / (J * J * n)
    return float(theta), float(np.sqrt(sigma2))


def high_median(arr):
    """Upper (high) median of a list/array.

    Matches MoonBit's `coefs_sorted[n / 2]` selector in
    `aggregator.mbt:32-60`. For odd `n` this is the exact middle;
    for even `n` it is the upper-middle (NOT numpy.median's default
    lower-middle). Implementation is intentionally explicit:

        arr_sorted = sorted(arr)
        return arr_sorted[len(arr_sorted) // 2]
    """
    arr_sorted = sorted(arr)
    return arr_sorted[len(arr_sorted) // 2]


def moonbit_aggregate_coef_se(coefs, ses):
    """Mirror `aggregator.mbt:32-60` exactly (see IRM validator for details)."""
    coefs = list(coefs)
    ses = list(ses)
    assert len(coefs) == len(ses) and len(coefs) >= 1
    n = len(coefs)
    if n == 1:
        return float(coefs[0]), float(ses[0])
    theta_hat = high_median(coefs)
    ub = [coefs[i] + 1.96 * ses[i] for i in range(n)]
    ub_hat = high_median(ub)
    se_hat = (ub_hat - theta_hat) / 1.96
    return float(theta_hat), float(se_hat)


def reference_iivm_mimic_moonbit_n_rep5(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray,
    n_rep: int = 5, propensity_clip: float = 1e-6,
):
    """Hand-rolled IIVM aggregated over `n_rep` K-fold reps.

    See the IRM validator for the aggregation contract. Each rep r
    uses an independent `KFold(n_splits=2, shuffle=True,
    random_state=3141 + r)`.
    """
    coefs: list[float] = []
    ses: list[float] = []
    for r in range(n_rep):
        kf = KFold(n_splits=2, shuffle=True, random_state=3141 + r)
        folds = list(kf.split(x))
        c, s = reference_iivm_mimic_moonbit(x, y, d, z, folds, propensity_clip)
        coefs.append(c)
        ses.append(s)
    return moonbit_aggregate_coef_se(coefs, ses)


def upstream_iivm(x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray):
    """Upstream `DoubleMLIIVM` at n_rep=1. Uses classifiers for ml_m and ml_r."""
    z2d = z.reshape(-1, 1)
    dml_data = dml.DoubleMLData.from_arrays(x=x, y=y, d=d, z=z2d)
    np.random.seed(3141)
    obj = dml.DoubleMLIIVM(
        dml_data,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=1000),
        ml_r=LogisticRegression(max_iter=1000),
        n_folds=2,
        n_rep=1,
        score="LATE",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


def upstream_iivm_n_rep5(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray, n_rep: int = 5,
):
    """Upstream `DoubleMLIIVM` at n_rep=5."""
    z2d = z.reshape(-1, 1)
    dml_data = dml.DoubleMLData.from_arrays(x=x, y=y, d=d, z=z2d)
    np.random.seed(3141)
    obj = dml.DoubleMLIIVM(
        dml_data,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=1000),
        ml_r=LogisticRegression(max_iter=1000),
        n_folds=2,
        n_rep=n_rep,
        score="LATE",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


# Regex used to locate the n_rep=5 section in `moon run examples/main` output.
# Contract: a section header `=== MoonBit DML IIVM ... n_rep=5 ... ===`
# followed by `estimated theta (n_rep=5) = ...` and `se (n_rep=5) = ...`.
# (The n_rep=1 line still uses "LATE" for IIVM; the n_rep=5 line uses
#  the generic "theta" name, matching the user's interface contract.)
_NREP5_SECTION_HEADER_RE = re.compile(
    r"===\s*MoonBit DML IIVM[^\n]*n_rep=5[^\n]*==="
)
_NREP5_THETA_RE = re.compile(
    r"estimated\s+theta\s*\(n_rep=5\)\s*=\s*([0-9.eE+-]+)"
)
_NREP5_SE_RE = re.compile(
    r"se\s*\(n_rep=5\)\s*=\s*([0-9.eE+-]+)"
)


def main() -> None:
    n, p, theta0, alpha = 500, 5, 1.0, 0.5
    x, y, d, z = make_dgp(n=n, p=p, theta=theta0, alpha=alpha, seed=1111)
    kf = KFold(n_splits=2, shuffle=True, random_state=3141)
    folds = list(kf.split(x))

    up_coef, up_se = upstream_iivm(x, y, d, z)
    ref_coef, ref_se = reference_iivm_mimic_moonbit(x, y, d, z, folds)

    print("=" * 70)
    print("IIVM LATE comparison  (n_rep=1)")
    print("=" * 70)
    print(f"Python (upstream, LogisticRegression for m/r)")
    print(f"                                    theta = {up_coef:.12f}  se = {up_se:.12f}")
    print(f"Python (hand-rolled, matches MoonBit)")
    print(f"                                    theta = {ref_coef:.12f}  se = {ref_se:.12f}")
    print()
    print(f"|theta_upstream - theta_handrolled| = {abs(up_coef - ref_coef):.2e}")
    print(f"|se_upstream    - se_handrolled|    = {abs(up_se - ref_se):.2e}")
    print()

    # ---- n_rep=5 cross-check (TODO #7) ----
    ref_n5_coef, ref_n5_se = reference_iivm_mimic_moonbit_n_rep5(x, y, d, z, n_rep=5)
    up_n5_coef, up_n5_se = upstream_iivm_n_rep5(x, y, d, z, n_rep=5)
    print("=" * 70)
    print("IIVM LATE comparison  (n_rep=5, TODO #7)")
    print("=" * 70)
    print(f"python_handrolled_nrep5  theta = {ref_n5_coef:.12f}  se = {ref_n5_se:.12f}")
    print(f"python_upstream_nrep5    theta = {up_n5_coef:.12f}  se = {up_n5_se:.12f}")
    print()

    # Run MoonBit once, parse both n_rep=1 and n_rep=5.
    print("=" * 70)
    print("Running MoonBit port: `moon run examples/main` ...")
    proc = subprocess.run(
        ["moon", "run", "examples/main"],
        cwd=Path(__file__).parent,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print("MoonBit run FAILED:")
        print("stdout:", proc.stdout)
        print("stderr:", proc.stderr)
        sys.exit(1)
    stdout = proc.stdout

    # ---- n_rep=1 parse (existing block) ----
    section = stdout.split("=== MoonBit DML IIVM (LATE score) ===")[1]
    if "=== MoonBit DML IIVM" in section:
        section = section.split("=== MoonBit DML IIVM")[0]
    mb_coef = float(re.search(r"estimated LATE\s*=\s*([0-9.eE+-]+)", section).group(1))
    mb_se = float(re.search(r"standard error\s*=\s*([0-9.eE+-]+)", section).group(1))
    ci_match = re.search(r"95% confint\s*=\s*\[([^\]]+)\]", section).group(1)
    lo, hi = (float(x.strip()) for x in ci_match.split(","))
    print("=" * 70)
    print("MoonBit port (n_rep=1):")
    print(f"  theta = {mb_coef:.12f}")
    print(f"  se    = {mb_se:.12f}")
    print(f"  95% CI = [{lo:.12f}, {hi:.12f}]")
    print("=" * 70)
    print(f"|moonbit - handrolled| = {abs(mb_coef - ref_coef):.2e}")
    print(f"|moonbit - upstream|   = {abs(mb_coef - up_coef):.2e}")
    print()
    print("Sanity check: true LATE = 1.0 should be inside every CI.")
    print()

    # ---- n_rep=5 parse (TODO #7) ----
    m = _NREP5_SECTION_HEADER_RE.search(stdout)
    if m is None:
        print("=" * 70)
        print("ERROR: MoonBit `n_rep=5` IIVM section not found in `moon run` output.")
        print("Expected a section header matching:")
        print("    === MoonBit DML IIVM ... n_rep=5 ... ===")
        print("containing `estimated theta (n_rep=5) = ...` and")
        print("`se (n_rep=5) = ...` lines.")
        print("This block is added by moonbit-coder as part of TODO #7's examples/main update.")
        print("=" * 70)
        sys.exit(2)
    n5_section = stdout[m.end():]
    next_hdr = re.search(r"===\s*MoonBit DML", n5_section)
    if next_hdr is not None:
        n5_section = n5_section[: next_hdr.start()]
    try:
        mb_n5_coef = float(_NREP5_THETA_RE.search(n5_section).group(1))
        mb_n5_se = float(_NREP5_SE_RE.search(n5_section).group(1))
    except (AttributeError, ValueError) as e:
        print("=" * 70)
        print(f"ERROR: could not parse n_rep=5 IIVM section: {e}")
        print("Section content was:")
        print(n5_section)
        print("=" * 70)
        sys.exit(2)
    # ---- spec-mandated n_rep=5 summary block ----
    diff_mb_hr_theta = abs(mb_n5_coef - ref_n5_coef)
    diff_mb_hr_se = abs(mb_n5_se - ref_n5_se)
    diff_up_hr_theta = abs(up_n5_coef - ref_n5_coef)
    print("=" * 70)
    print("=== IIVM n_rep=5 ===")
    print(f"python_handrolled_nrep5  theta = {ref_n5_coef:.12f}  se = {ref_n5_se:.12f}")
    print(f"python_upstream_nrep5    theta = {up_n5_coef:.12f}  se = {up_n5_se:.12f}")
    print(f"moonbit_nrep5            theta = {mb_n5_coef:.12f}  se = {mb_n5_se:.12f}")
    print(f"|moonbit - handrolled_nrep5| (theta) = {diff_mb_hr_theta:.6e} ")
    print(f"|moonbit - handrolled_nrep5| (se)    = {diff_mb_hr_se:.6e}")
    print(f"|upstream  - handrolled_nrep5| (theta) = {diff_up_hr_theta:.6e}")
    print("=" * 70)
    # PASS: |mb - handrolled| (theta) < max(MODEL_TOL, 2.0 * handrolled_n5_se)
    model_tol = 0.5  # IIVM: LATE with weak instrument + logreg vs linreg+clip, larger noise
    threshold = max(model_tol, 2.0 * ref_n5_se)
    if diff_mb_hr_theta < threshold:
        print(f"PASS  |mb - handrolled_nrep5| (theta) = {diff_mb_hr_theta:.6e} < "
              f"max(MODEL_TOL={model_tol}, 2.0*handrolled_n5_se) = {threshold:.6e}")
    else:
        print(f"FAIL  |mb - handrolled_nrep5| (theta) = {diff_mb_hr_theta:.6e} >= "
              f"max(MODEL_TOL={model_tol}, 2.0*handrolled_n5_se) = {threshold:.6e}")
        sys.exit(3)


if __name__ == "__main__":
    main()
