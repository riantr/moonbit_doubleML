"""
Numerical cross-check of the MoonBit DML DID port.

Compares three implementations on the same DGP and K-fold split:

  1. A hand-rolled Python implementation that mirrors the MoonBit
     port exactly (closed-form OLS for g0/g1/m, ATT-style
     observational DID score, propensity clipping).
  2. The MoonBit port itself, via `moon run examples/main` and stdout
     parsing.

The upstream `DoubleMLDID` requires `ml_m` to be a classifier with
`predict_proba`, so we skip the upstream comparison here for the
same reason as IRM.

TODO #7 additionally cross-checks n_rep=5:
  * `reference_did_mimic_moonbit_n_rep5` runs the hand-rolled algorithm
    R=5 times (each rep uses an independent
    `KFold(n_splits=2, shuffle=True, random_state=3141 + r)`) and
    aggregates via the MoonBit formula
    `theta_hat = median(theta_1..R)`,
    `se_hat = (median(theta + 1.96*se) - theta_hat) / 1.96`
    (see `aggregator.mbt:32-60`).
  * The MoonBit side is parsed from the section
    `=== MoonBit DML DID (..., n_rep=5) ===` that moonbit-coder adds
    to `examples/main/main.mbt`.

(There is no upstream n_rep=5 comparison for DID — the existing
validator skips the upstream entirely because the upstream
`DoubleMLDID` requires a classifier for `ml_m` while the MoonBit
port uses `LinearRegression` + clipping.)
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import numpy as np
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import KFold


def make_dgp(n: int, p: int, theta: float, seed: int):
    """Reproduce the MoonBit DID DGP: y = theta * d + noise,
    d ~ Bernoulli(p_x)."""
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(size=(n, p))
    p_x = np.clip(0.3 + 0.2 * x[:, 0], 0.05, 0.95)
    d = (rng.uniform(size=n) < p_x).astype(np.float64)
    y = theta * d + 0.3 * rng.standard_normal(size=n)
    return x, y, d


def reference_did_mimic_moonbit(
    x: np.ndarray, y: np.ndarray, d: np.ndarray,
    folds: list[tuple[np.ndarray, np.ndarray]],
    propensity_clip: float = 1e-6,
):
    n = len(y)
    g0 = np.zeros(n)
    g1 = np.zeros(n)
    m = np.zeros(n)
    for tr, te in folds:
        tr0 = tr[d[tr] == 0]
        tr1 = tr[d[tr] == 1]
        if len(tr0) > 0:
            ml = LinearRegression().fit(x[tr0], y[tr0])
            g0[te] = ml.predict(x[te])
        if len(tr1) > 0:
            ml = LinearRegression().fit(x[tr1], y[tr1])
            g1[te] = ml.predict(x[te])
        mlm = LinearRegression().fit(x[tr], d[tr])
        m[te] = mlm.predict(x[te])
    m = np.clip(m, propensity_clip, 1.0 - propensity_clip)
    p_hat = d.mean()
    resid_d0 = y - g0
    psi_a = -d / p_hat
    psi_b = (d - m) / (p_hat * (1.0 - m)) * resid_d0
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


def reference_did_mimic_moonbit_n_rep5(
    x: np.ndarray, y: np.ndarray, d: np.ndarray,
    n_rep: int = 5, propensity_clip: float = 1e-6,
):
    """Hand-rolled DID aggregated over `n_rep` K-fold reps.

    See the IRM validator for the aggregation contract. Each rep r
    uses an independent `KFold(n_splits=2, shuffle=True,
    random_state=3141 + r)`.
    """
    coefs: list[float] = []
    ses: list[float] = []
    for r in range(n_rep):
        kf = KFold(n_splits=2, shuffle=True, random_state=3141 + r)
        folds = list(kf.split(x))
        c, s = reference_did_mimic_moonbit(x, y, d, folds, propensity_clip)
        coefs.append(c)
        ses.append(s)
    return moonbit_aggregate_coef_se(coefs, ses)


# Regex used to locate the n_rep=5 section in `moon run examples/main` output.
# Contract: a section header `=== MoonBit DML DID ... n_rep=5 ... ===`
# followed by `estimated theta (n_rep=5) = ...` and `se (n_rep=5) = ...`.
_NREP5_SECTION_HEADER_RE = re.compile(
    r"===\s*MoonBit DML DID[^\n]*n_rep=5[^\n]*==="
)
_NREP5_THETA_RE = re.compile(
    r"estimated\s+theta\s*\(n_rep=5\)\s*=\s*([0-9.eE+-]+)"
)
_NREP5_SE_RE = re.compile(
    r"se\s*\(n_rep=5\)\s*=\s*([0-9.eE+-]+)"
)


def main() -> None:
    n, p, theta0 = 1000, 5, 1.0
    x, y, d = make_dgp(n=n, p=p, theta=theta0, seed=1111)
    kf = KFold(n_splits=2, shuffle=True, random_state=3141)
    folds = list(kf.split(x))

    ref_coef, ref_se = reference_did_mimic_moonbit(x, y, d, folds)
    print("=" * 70)
    print("DID comparison (observational score, ATT-style)  (n_rep=1)")
    print("=" * 70)
    print(f"Python (hand-rolled, matches MoonBit exactly)")
    print(f"                                    theta = {ref_coef:.12f}  se = {ref_se:.12f}")
    print()

    # ---- n_rep=5 cross-check (TODO #7) ----
    ref_n5_coef, ref_n5_se = reference_did_mimic_moonbit_n_rep5(x, y, d, n_rep=5)
    print("=" * 70)
    print("DID comparison  (n_rep=5, TODO #7)")
    print("=" * 70)
    print(f"python_handrolled_nrep5  theta = {ref_n5_coef:.12f}  se = {ref_n5_se:.12f}")
    print(f"python_upstream_nrep5    theta = N/A (DID validator skips upstream; see header docstring)")
    print()

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
    section = stdout.split("=== MoonBit DML DID (observational score) ===")[1]
    if "=== MoonBit DML DID" in section:
        section = section.split("=== MoonBit DML DID")[0]
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
    print()
    print("Sanity check: true theta = 1.0 should be inside every CI.")
    print()

    # ---- n_rep=5 parse (TODO #7) ----
    m = _NREP5_SECTION_HEADER_RE.search(stdout)
    if m is None:
        print("=" * 70)
        print("ERROR: MoonBit `n_rep=5` DID section not found in `moon run` output.")
        print("Expected a section header matching:")
        print("    === MoonBit DML DID ... n_rep=5 ... ===")
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
        print(f"ERROR: could not parse n_rep=5 DID section: {e}")
        print("Section content was:")
        print(n5_section)
        print("=" * 70)
        sys.exit(2)
    # ---- spec-mandated n_rep=5 summary block ----
    diff_mb_hr_theta = abs(mb_n5_coef - ref_n5_coef)
    diff_mb_hr_se = abs(mb_n5_se - ref_n5_se)
    print("=" * 70)
    print("=== DID n_rep=5 ===")
    print(f"python_handrolled_nrep5  theta = {ref_n5_coef:.12f}  se = {ref_n5_se:.12f}")
    print(f"python_upstream_nrep5    theta = N/A (DID validator skips upstream; see header docstring)")
    print(f"moonbit_nrep5            theta = {mb_n5_coef:.12f}  se = {mb_n5_se:.12f}")
    print(f"|moonbit - handrolled_nrep5| (theta) = {diff_mb_hr_theta:.6e} ")
    print(f"|moonbit - handrolled_nrep5| (se)    = {diff_mb_hr_se:.6e}")
    print(f"|upstream  - handrolled_nrep5| (theta) = N/A (no upstream comparison for DID)")
    print("=" * 70)
    # PASS: |mb - handrolled| (theta) < max(MODEL_TOL, 2.0 * handrolled_n5_se)
    model_tol = 0.1  # DID: clean observational ATT, finite-sample noise is small
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
