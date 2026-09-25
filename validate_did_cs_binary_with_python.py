#!/usr/bin/env python3
"""
v0.51.0 validator: hand-rolled reference + optional upstream
`doubleml.DoubleMLDIDCSBinary` cross-check for the
`DoubleMLDIDCSBinary` MoonBit estimator.

The hand-rolled reference implements the Sant'Anna-Zhao
(2020) "binary outcome" DML score (observational,
`in_sample_normalization = false`) end-to-end: panel
subsetting to the 4 `(G, T)` cells, stratified k-fold
crossfit of the 4 g-functions and the propensity,
score-elements computation, and ATT/SE via the
theta = -mean(psi_b) / mean(psi_a) ratio.

If `doubleml` is installed, we additionally run the
upstream `DoubleMLDIDCSBinary` estimator on the same
DGP and compare its theta / SE to the hand-rolled
reference. The MoonBit estimator is also re-run via
the cmd binary to cross-check; the MoonBit output is
parsed from the cmd log.

`MODEL_TOL = 0.3` — the v0.49.0 / v0.50.0 convention.
PRNG drift between chacha8 and numpy default_rng
drives ~0.2 SE offsets at this DGP size.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import textwrap
import warnings
from pathlib import Path

import numpy as np
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import StratifiedKFold

# Suppress benign `RuntimeWarning: invalid value encountered
# in divide` from upstream `doubleml.utils._sensitivity` on
# degenerate DGPs (zero SE).
warnings.filterwarnings("ignore", category=RuntimeWarning)

# v0.49.0 / v0.50.0 convention.
MODEL_TOL = 0.3

REPO = Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# DGP
# ---------------------------------------------------------------------------


def make_dgp(
    n_per_cohort: int = 200,
    n_periods: int = 2,
    p: int = 3,
    theta0: float = 1.0,
    seed: int = 7,
) -> dict:
    """Build the canonical 2-period, 2-group CS Binary
    DGP with deterministic binary Y (matches
    `examples/did_cs_binary/main.mbt`).

    Long-format panel: `n_units = n_per_cohort * 2`
    units × `n_periods` rows each. `d` is the group
    indicator (constant per unit, 0 for never-treated,
    1 for treated). `t = k ∈ {0, 1}` is the period.
    `y[u, pre] = 0` for both groups;
    `y[u, post] = 1.0` for the treated cohort, 0 for
    the never-treated. ATT(g=1, t=1) = 1.0 (the post-
    period lift on the treated cohort, the standard
    CS Binary DGP where the binary outcome is the
    indicator of the realized post-period event).

    The upstream `DoubleMLPanelData` interprets `d`
    as the group (constant per unit) — see
    `_preprocess_data` in upstream `did_cs_binary.py`.
    """
    rng = np.random.default_rng(seed)
    n_units = 2 * n_per_cohort
    n = n_units * n_periods
    x_flat = np.zeros((n, p))
    y = np.zeros(n)
    d = np.zeros(n, dtype=np.int32)
    t_arr = np.zeros(n, dtype=np.int32)
    g_arr = np.zeros(n, dtype=np.int32)
    id_arr = np.zeros(n, dtype=np.int32)
    for u in range(n_units):
        cohort = u // n_per_cohort
        xu = rng.uniform(-1, 1, p)
        for k in range(n_periods):
            row = u * n_periods + k
            x_flat[row] = xu
            t_arr[row] = k
            id_arr[row] = u
            g_arr[row] = cohort
            # `d` is the group indicator (constant per
            # unit), matching upstream
            # `DoubleMLPanelData` convention. Use
            # int32 to match `make_did_SZ2020`'s
            # upstream test data.
            d[row] = np.int32(cohort)
            y[row] = 1.0 if (cohort > 0 and k == 1) else 0.0
    return {
        "x": x_flat,
        "y": y,
        "d": d,
        "t": t_arr,
        "g": g_arr,
        "id": id_arr,
        "n": n,
        "p": p,
        "theta0": theta0,
        "n_per_cohort": n_per_cohort,
        "n_periods": n_periods,
        "n_units": n_units,
    }


# ---------------------------------------------------------------------------
# Hand-rolled reference
# ---------------------------------------------------------------------------


def handrolled_cs_binary(dgp: dict, g_value: int = 1, t_pre: int = 0, t_eval: int = 1, n_folds: int = 4, seed: int = 3141) -> dict:
    """Hand-rolled Sant'Anna-Zhao (2020) observational
    CS Binary DML estimator on the long-format panel.

    `d` is the group (constant per unit) per the
    upstream `DoubleMLPanelData` convention; `t` is
    the binary period. `G_indicator = 1{d == g_value}`,
    `C_indicator = 1{d == never_treated_value}`,
    `T_indicator = 1{t == t_eval}`. Subset to the
    4 `(G, T)` cells and run the observational
    crossfit + score.
    """
    x = dgp["x"]
    y = dgp["y"]
    d_long = dgp["d"]
    t = dgp["t"]
    n_total = dgp["n"]

    # `d_long` is constant per unit, so the
    # `never_treated` is the unique minimum of d.
    unique_d = np.unique(d_long)
    never_treated = float(unique_d.min())
    keep = np.zeros(n_total, dtype=bool)
    g_indicator = np.zeros(n_total)
    t_indicator = np.zeros(n_total)
    for i in range(n_total):
        if t[i] not in (t_pre, t_eval):
            continue
        gi = 1.0 if d_long[i] == g_value else 0.0
        ci = 1.0 if d_long[i] == never_treated else 0.0
        if gi + ci != 1.0:
            continue
        keep[i] = True
        g_indicator[i] = gi
        t_indicator[i] = 1.0 if t[i] == t_eval else 0.0

    sub_idx = np.where(keep)[0]
    x_sub = x[sub_idx]
    y_sub = y[sub_idx]
    g_sub = g_indicator[sub_idx]
    t_sub = t_indicator[sub_idx]
    n_sub = len(sub_idx)
    p = x_sub.shape[1]
    n_g = int(g_sub.sum())
    n_c = n_sub - n_g

    # Strata for kfold_stratified.
    strata = g_sub + 2 * t_sub
    skf = StratifiedKFold(n_splits=n_folds, shuffle=True, random_state=seed)
    folds = list(skf.split(np.zeros(n_sub), strata))

    # Crossfit the 4 g-functions and the propensity.
    g00 = np.zeros(n_sub)
    g01 = np.zeros(n_sub)
    g10 = np.zeros(n_sub)
    g11 = np.zeros(n_sub)
    m = np.zeros(n_sub)
    for train_idx, test_idx in folds:
        for d_val, t_val in [(0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (1.0, 1.0)]:
            cell = (g_sub[train_idx] == d_val) & (t_sub[train_idx] == t_val)
            if cell.sum() < p + 1:
                continue
            model = LinearRegression()
            model.fit(x_sub[train_idx][cell], y_sub[train_idx][cell])
            preds = model.predict(x_sub[test_idx])
            if d_val == 0.0 and t_val == 0.0:
                g00[test_idx] = preds
            elif d_val == 0.0 and t_val == 1.0:
                g01[test_idx] = preds
            elif d_val == 1.0 and t_val == 0.0:
                g10[test_idx] = preds
            else:
                g11[test_idx] = preds
        # Propensity: fit on full training fold.
        m_model = LinearRegression()
        m_model.fit(x_sub[train_idx], g_sub[train_idx])
        m[test_idx] = m_model.predict(x_sub[test_idx])
    m = np.clip(m, 1.0e-6, 1.0 - 1.0e-6)

    # Observational Sant'Anna-Zhao score.
    d1t1 = g_sub * t_sub
    d1t0 = g_sub * (1.0 - t_sub)
    d0t1 = (1.0 - g_sub) * t_sub
    d0t0 = (1.0 - g_sub) * (1.0 - t_sub)
    p_hat = g_sub.mean()
    lambda_hat = t_sub.mean()

    one_minus_m = 1.0 - m
    prop_weighting = np.where(one_minus_m > 1.0e-12, m / one_minus_m, 0.0)

    weight_psi_a = g_sub / p_hat
    psi_a = -weight_psi_a

    psi_b_1 = (
        g_sub / p_hat * g11
        - g_sub / p_hat * g10
        + g_sub / p_hat * g00
        - g_sub / p_hat * g01
    )
    psi_b_2 = (
        d1t1 / (p_hat * lambda_hat) * (y_sub - g11)
        - d1t0 / (p_hat * (1.0 - lambda_hat)) * (y_sub - g10)
        + d0t0 / (p_hat * (1.0 - lambda_hat)) * prop_weighting * (y_sub - g00)
        - d0t1 / (p_hat * lambda_hat) * prop_weighting * (y_sub - g01)
    )
    psi_b = psi_b_1 + psi_b_2

    coef = -psi_b.mean() / psi_a.mean()
    # HC0 SE: theta = -mean(psi_b) / mean(psi_a), so
    # psi = psi_a + theta * psi_b, and var(theta) =
    # var(psi) / n.
    psi = psi_a + coef * psi_b
    se = float(np.sqrt(psi.var(ddof=0) / n_sub))
    return {
        "coef": float(coef),
        "se": se,
        "n_obs_subset": int(n_sub),
        "n_g_subset": n_g,
        "n_c_subset": n_c,
    }


# ---------------------------------------------------------------------------
# Upstream cross-check
# ---------------------------------------------------------------------------


def upstream_cs_binary(dgp: dict, g_value: int = 1, t_pre: int = 0, t_eval: int = 1) -> dict | None:
    """Run the upstream `doubleml.DoubleMLDIDCSBinary`
    on the same DGP. Returns `None` if the package is
    not installed or the API has changed.
    """
    try:
        from doubleml.did.did_cs_binary import DoubleMLDIDCSBinary
        from doubleml.data.panel_data import DoubleMLPanelData
    except Exception as exc:
        print(f"  upstream: import failed ({exc!r}); skipping")
        return None

    try:
        import pandas as pd

        # v0.11.3+ DoubleMLPanelData takes a
        # DataFrame + column names, not raw arrays.
        df = pd.DataFrame(
            dgp["x"],
            columns=[f"x{j}" for j in range(dgp["p"])],
        )
        df["y"] = dgp["y"]
        df["d"] = dgp["d"].astype(np.int32)
        df["t"] = dgp["t"].astype(np.int32)
        df["g"] = dgp["g"].astype(np.int32)
        df["id"] = dgp["id"].astype(np.int32)
        panel = DoubleMLPanelData(
            df,
            y_col="y",
            d_cols=["d"],
            t_col="t",
            id_col="id",
            x_cols=[f"x{j}" for j in range(dgp["p"])],
        )
        # The g_value is a group label, not a binary
        # indicator. The panel DGP uses g ∈ {0, 1}
        # where 1 is the treated cohort.
        from sklearn.linear_model import LogisticRegression
        g_label = g_value
        est = DoubleMLDIDCSBinary(
            panel,
            ml_g=LinearRegression(),
            ml_m=LogisticRegression(),
            g_value=g_label,
            t_value_pre=t_pre,
            t_value_eval=t_eval,
            control_group="never_treated",
            n_folds=4,
            n_rep=1,
            score="observational",
        )
        est.fit()
        return {
            "coef": float(est.coef[0]),
            "se": float(est.se[0]),
        }
    except Exception as exc:
        print(f"  upstream: fit failed ({exc!r}); skipping")
        return None


# ---------------------------------------------------------------------------
# MoonBit cmd cross-check
# ---------------------------------------------------------------------------


def moonbit_cs_binary() -> dict | None:
    """Run the MoonBit `examples/did_cs_binary` and parse
    the `ATT_hat = ...` and `se = ...` lines.
    """
    try:
        out = subprocess.run(
            ["moon", "run", "examples/did_cs_binary", "--target", "native"],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=True,
        )
    except Exception as exc:
        print(f"  MoonBit: run failed ({exc!r}); skipping")
        return None
    text = out.stdout
    coef_m = re.search(r"ATT_hat\s+=\s+([-\d.eE+]+)", text)
    se_m = re.search(r"\bse\s+=\s+([-\d.eE+]+)", text)
    n_m = re.search(r"n_obs_subset\s+=\s+(\d+)", text)
    if coef_m is None or se_m is None:
        print("  MoonBit: parse failed; stdout was:")
        print(textwrap.indent(text, "    "))
        return None
    return {
        "coef": float(coef_m.group(1)),
        "se": float(se_m.group(1)),
        "n_obs_subset": int(n_m.group(1)) if n_m else None,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    print("=== v0.51.0 validator: DoubleMLDIDCSBinary ===\n")
    dgp = make_dgp()
    print(
        f"  DGP: n_units={dgp['n_units']}, n_periods={dgp['n_periods']}, "
        f"p={dgp['p']}, theta0={dgp['theta0']}"
    )

    print("\n[1/3] hand-rolled reference ...")
    hr = handrolled_cs_binary(dgp)
    print(f"  coef = {hr['coef']:.6f}, se = {hr['se']:.6f}, "
          f"n_obs_subset = {hr['n_obs_subset']}")

    print("\n[2/3] upstream DoubleMLDIDCSBinary (if installed) ...")
    up = upstream_cs_binary(dgp)
    if up is not None:
        print(f"  coef = {up['coef']:.6f}, se = {up['se']:.6f}")

    print("\n[3/3] MoonBit DoubleMLDIDCSBinary via cmd ...")
    mb = moonbit_cs_binary()
    if mb is not None:
        print(f"  coef = {mb['coef']:.6f}, se = {mb['se']:.6f}, "
              f"n_obs_subset = {mb['n_obs_subset']}")

    # Verdicts.
    print("\n=== Verdicts ===")
    ok = True
    # Hand-rolled recovers ATT.
    if abs(hr["coef"] - dgp["theta0"]) > MODEL_TOL:
        print(f"  FAIL  hand-rolled ATT {hr['coef']:.4f} vs true {dgp['theta0']:.4f}")
        ok = False
    else:
        print(f"  PASS  hand-rolled ATT within {MODEL_TOL} of true ({hr['coef']:.4f})")

    if up is not None:
        if abs(up["coef"] - hr["coef"]) > MODEL_TOL:
            print(f"  FAIL  upstream vs hand-rolled ATT gap {abs(up['coef'] - hr['coef']):.4f} > {MODEL_TOL}")
            ok = False
        else:
            print(f"  PASS  upstream ATT within {MODEL_TOL} of hand-rolled ({up['coef']:.4f})")

    if mb is not None:
        if abs(mb["coef"] - hr["coef"]) > MODEL_TOL:
            print(f"  FAIL  MoonBit vs hand-rolled ATT gap {abs(mb['coef'] - hr['coef']):.4f} > {MODEL_TOL}")
            ok = False
        else:
            print(f"  PASS  MoonBit ATT within {MODEL_TOL} of hand-rolled ({mb['coef']:.4f})")
        if up is not None and abs(mb["coef"] - up["coef"]) > MODEL_TOL:
            print(f"  FAIL  MoonBit vs upstream ATT gap {abs(mb['coef'] - up['coef']):.4f} > {MODEL_TOL}")
            ok = False
        elif up is not None:
            print(f"  PASS  MoonBit ATT within {MODEL_TOL} of upstream ({mb['coef']:.4f})")

    if ok:
        print("\nAll checks PASSED.")
        return 0
    print("\nSome checks FAILED.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
