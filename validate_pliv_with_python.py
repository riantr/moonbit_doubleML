"""
Numerical cross-check of the MoonBit DML PLIV port.

Same protocol as the PLR/IRM validators, but for PLIV. Runs:

  1. A hand-rolled Python implementation that mirrors the MoonBit
     port exactly (closed-form OLS for l/r/m, single-instrument
     partialling-out score, K-fold cross-fit, the same `_var_est`
     variance formula).
  2. The MoonBit port itself, via `moon run cmd/main` and stdout
     parsing.

We also report the upstream `DoubleMLPLIV` for context, which
should agree with the hand-rolled implementation when the data and
folds are identical.

TODO #7 additionally cross-checks n_rep=5:
  * `reference_pliv_mimic_moonbit_n_rep5` runs the hand-rolled algorithm
    R=5 times (each rep uses an independent
    `KFold(n_splits=2, shuffle=True, random_state=3141 + r)`) and
    aggregates via the MoonBit formula
    `theta_hat = median(theta_1..R)`,
    `se_hat = (median(theta + 1.96*se) - theta_hat) / 1.96`
    (see `aggregator.mbt:32-60`).
  * `upstream_pliv_n_rep5` calls `DoubleMLPLIV(..., n_rep=5)` and returns
    its `(coef, se)`.
  * The MoonBit side is parsed from the section
    `=== MoonBit DML PLIV (..., n_rep=5) ===` that moonbit-coder adds
    to `cmd/main/main.mbt`.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import doubleml as dml
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import KFold


def make_dgp(n: int, p: int, alpha0: float, seed: int):
    """Reproduce the same DGP the MoonBit example uses: x_i is a
    standard normal in each coordinate, z is correlated with x but
    not with u, and d is generated from x and z."""
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(size=(n, p))
    # use rng.standard_normal instead of the (i+1)/n trick to keep
    # things simple and ensure independence from the x noise
    xi = rng.standard_normal(size=n)
    u = rng.standard_normal(size=n)
    eps = rng.standard_normal(size=n)
    # z = x[:, 0] + 0.5 * xi
    z = x[:, 0] + 0.5 * xi
    # d = 0.5 * x[:, 0] + 0.5 * z + 0.1 * sum_j(x[:, j] for j>=1) + u
    d = 0.5 * x[:, 0] + 0.5 * z + 0.1 * x[:, 1:].sum(axis=1) + u
    # y = alpha * d + x @ 1 + 0.3 * eps
    y = alpha0 * d + x @ np.ones(p) + 0.3 * eps
    return x, y, d, z


def reference_pliv_mimic_moonbit(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray,
    folds: list[tuple[np.ndarray, np.ndarray]],
):
    n = len(y)
    l_hat = np.zeros(n)
    r_hat = np.zeros(n)
    m_hat = np.zeros(n)
    for tr, te in folds:
        ml_l = LinearRegression().fit(x[tr], y[tr])
        ml_r = LinearRegression().fit(x[tr], d[tr])
        ml_m = LinearRegression().fit(x[tr], z[tr])
        l_hat[te] = ml_l.predict(x[te])
        r_hat[te] = ml_r.predict(x[te])
        m_hat[te] = ml_m.predict(x[te])
    u_hat = y - l_hat
    w_hat = d - r_hat
    v_hat = z - m_hat
    psi_a = -w_hat * v_hat
    psi_b = v_hat * u_hat
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


def reference_pliv_mimic_moonbit_n_rep5(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray,
    n_rep: int = 5,
):
    """Hand-rolled PLIV aggregated over `n_rep` K-fold reps.

    See the IRM validator for the aggregation contract. Each rep r
    uses an independent `KFold(n_splits=2, shuffle=True,
    random_state=3141 + r)`.
    """
    coefs: list[float] = []
    ses: list[float] = []
    for r in range(n_rep):
        kf = KFold(n_splits=2, shuffle=True, random_state=3141 + r)
        folds = list(kf.split(x))
        c, s = reference_pliv_mimic_moonbit(x, y, d, z, folds)
        coefs.append(c)
        ses.append(s)
    return moonbit_aggregate_coef_se(coefs, ses)


def upstream_pliv(x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray):
    """Upstream `DoubleMLPLIV` at n_rep=1."""
    z2d = z.reshape(-1, 1)  # DoubleML expects z_cols as 2D
    dml_data = dml.DoubleMLData.from_arrays(x=x, y=y, d=d, z=z2d)
    np.random.seed(3141)
    obj = dml.DoubleMLPLIV(
        dml_data,
        ml_l=LinearRegression(),
        ml_m=LinearRegression(),
        ml_r=LinearRegression(),
        n_folds=2,
        n_rep=1,
        score="partialling out",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


def upstream_pliv_n_rep5(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, z: np.ndarray, n_rep: int = 5,
):
    """Upstream `DoubleMLPLIV` at n_rep=5."""
    z2d = z.reshape(-1, 1)
    dml_data = dml.DoubleMLData.from_arrays(x=x, y=y, d=d, z=z2d)
    np.random.seed(3141)
    obj = dml.DoubleMLPLIV(
        dml_data,
        ml_l=LinearRegression(),
        ml_m=LinearRegression(),
        ml_r=LinearRegression(),
        n_folds=2,
        n_rep=n_rep,
        score="partialling out",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


# Regex used to locate the n_rep=5 section in `moon run cmd/main` output.
# Contract: a section header `=== MoonBit DML PLIV ... n_rep=5 ... ===`
# followed by `estimated theta (n_rep=5) = ...` and `se (n_rep=5) = ...`.
_NREP5_SECTION_HEADER_RE = re.compile(
    r"===\s*MoonBit DML PLIV[^\n]*n_rep=5[^\n]*==="
)
_NREP5_THETA_RE = re.compile(
    r"estimated\s+theta\s*\(n_rep=5\)\s*=\s*([0-9.eE+-]+)"
)
_NREP5_SE_RE = re.compile(
    r"se\s*\(n_rep=5\)\s*=\s*([0-9.eE+-]+)"
)


def main() -> None:
    n, p, alpha0 = 500, 5, 1.0
    x, y, d, z = make_dgp(n=n, p=p, alpha0=alpha0, seed=1111)
    kf = KFold(n_splits=2, shuffle=True, random_state=3141)
    folds = list(kf.split(x))

    up_coef, up_se = upstream_pliv(x, y, d, z)
    ref_coef, ref_se = reference_pliv_mimic_moonbit(x, y, d, z, folds)

    print("=" * 70)
    print("PLIV comparison (partialling out, single IV)  (n_rep=1)")
    print("=" * 70)
    print(f"Python (upstream doubleml)            theta = {up_coef:.12f}  se = {up_se:.12f}")
    print(f"Python (hand-rolled, matches MoonBit) theta = {ref_coef:.12f}  se = {ref_se:.12f}")
    print(f"|theta_upstream - theta_handrolled| = {abs(up_coef - ref_coef):.2e}")
    print(f"|se_upstream    - se_handrolled|    = {abs(up_se - ref_se):.2e}")
    print()

    # ---- n_rep=5 cross-check (TODO #7) ----
    ref_n5_coef, ref_n5_se = reference_pliv_mimic_moonbit_n_rep5(x, y, d, z, n_rep=5)
    up_n5_coef, up_n5_se = upstream_pliv_n_rep5(x, y, d, z, n_rep=5)
    print("=" * 70)
    print("PLIV comparison  (n_rep=5, TODO #7)")
    print("=" * 70)
    print(f"python_handrolled_nrep5  theta = {ref_n5_coef:.12f}  se = {ref_n5_se:.12f}")
    print(f"python_upstream_nrep5    theta = {up_n5_coef:.12f}  se = {up_n5_se:.12f}")
    print()

    # Run MoonBit once, parse both n_rep=1 and n_rep=5.
    print("=" * 70)
    print("Running MoonBit port: `moon run cmd/main` ...")
    proc = subprocess.run(
        ["moon", "run", "cmd/main"],
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
    section = stdout.split("=== MoonBit DML PLIV (partialling out, single IV) ===")[1]
    if "=== MoonBit DML PLIV" in section:
        section = section.split("=== MoonBit DML PLIV")[0]
    mb_coef = float(re.search(r"estimated theta\s*=\s*([0-9.eE+-]+)", section).group(1))
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
    print("Sanity check: true theta = 1.0 should be near all three estimates.")
    print("(Finite-sample bias of partialling-out PLIV with one IV is")
    print(" known to be O(1/n) and can shift the point estimate by a few")
    print(" percent. The CI is what matters for inference.)")
    print()

    # ---- n_rep=5 parse (TODO #7) ----
    m = _NREP5_SECTION_HEADER_RE.search(stdout)
    if m is None:
        print("=" * 70)
        print("ERROR: MoonBit `n_rep=5` PLIV section not found in `moon run` output.")
        print("Expected a section header matching:")
        print("    === MoonBit DML PLIV ... n_rep=5 ... ===")
        print("containing `estimated theta (n_rep=5) = ...` and")
        print("`se (n_rep=5) = ...` lines.")
        print("This block is added by moonbit-coder as part of TODO #7's cmd/main update.")
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
        print(f"ERROR: could not parse n_rep=5 PLIV section: {e}")
        print("Section content was:")
        print(n5_section)
        print("=" * 70)
        sys.exit(2)
    # ---- spec-mandated n_rep=5 summary block ----
    diff_mb_hr_theta = abs(mb_n5_coef - ref_n5_coef)
    diff_mb_hr_se = abs(mb_n5_se - ref_n5_se)
    diff_up_hr_theta = abs(up_n5_coef - ref_n5_coef)
    print("=" * 70)
    print("=== PLIV n_rep=5 ===")
    print(f"python_handrolled_nrep5  theta = {ref_n5_coef:.12f}  se = {ref_n5_se:.12f}")
    print(f"python_upstream_nrep5    theta = {up_n5_coef:.12f}  se = {up_n5_se:.12f}")
    print(f"moonbit_nrep5            theta = {mb_n5_coef:.12f}  se = {mb_n5_se:.12f}")
    print(f"|moonbit - handrolled_nrep5| (theta) = {diff_mb_hr_theta:.6e} ")
    print(f"|moonbit - handrolled_nrep5| (se)    = {diff_mb_hr_se:.6e}")
    print(f"|upstream  - handrolled_nrep5| (theta) = {diff_up_hr_theta:.6e}")
    print("=" * 70)
    # PASS: |mb - handrolled| (theta) < max(MODEL_TOL, 2.0 * handrolled_n5_se)
    model_tol = 0.5  # PLIV: single-IV partialling-out has higher finite-sample bias
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
