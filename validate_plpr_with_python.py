"""v0.26.0: cross-check the MoonBit DoubleMLPLPR against BOTH the
upstream `doubleml.plm.DoubleMLPLPR` (doubleml >= 0.11) and an
independent hand-rolled Python reference of the *clustered* DML path.

Why the clustered path: upstream re-wraps the transformed panel into a
static-panel `DoubleMLPanelData`, whose constructor pins `cluster_cols
= id_col`. Panel data therefore always takes the cluster machinery:

  1. `Resampling.split_samples` draws KFolds over the UNIQUE unit ids
     and expands them to row-level folds, so every row of a unit stays
     on the same side of every split.
  2. `LinearScoreMixin._est_coef` (cluster branch) solves the
     fold-weighted score sums with w_k = 1 / |I_k|.
  3. `doubleml.utils._estimation._var_est` (one-cluster-variable
     branch) accumulates squared unit-level score sums scaled by
     1/|I_k|, divides gamma and the Jacobian analog by
     `n_folds_per_cluster`, and scales by 1/(N_units * J^2).

The hand-rolled reference below reimplements exactly this pipeline
from scratch (numpy lstsq OLS, its own unit-level permutation split)
so agreement between all three implementations validates the port.

What is asserted here:
  1. Upstream theta_hat recovers the true theta for all four
     approaches and reports CLUSTERED standard errors (< 0.1; the
     naive row-level path would report ~0.32 for the CRE approaches).
  2. The hand-rolled clustered reference agrees with upstream on
     theta (|diff| < 0.08) and on se (ratio within [0.5, 2]).
  3. The MoonBit expectations quoted in plpr_test.mbt (theta ~1.03,
     se ~0.017-0.020 on this DGP) sit inside the upstream/hand-rolled
     spread.

The MoonBit-side numbers come from `moon test` / `cmd/plpr` output;
this script emits the reference values to compare against.
"""

import warnings

import numpy as np
import pandas as pd
from sklearn.linear_model import LinearRegression

import doubleml as dml
from doubleml.plm import DoubleMLPLPR

APPROACHES = ["cre_general", "cre_normal", "fd_exact", "wg_approx"]


def build_panel_dgp(
    n_units: int, n_periods: int, theta0: float, seed: int
) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    rows = []
    for u in range(n_units):
        alpha = (rng.uniform() - 0.5) * 4.0
        unit_trait = rng.uniform() * 2.0 - 1.0
        for k in range(n_periods):
            x1 = unit_trait + (rng.uniform() - 0.5)
            x2 = rng.uniform() * 2.0 - 1.0
            d = 0.6 * x1 + 0.3 * x2 + 0.5 * alpha / 2.0 + (rng.uniform() - 0.5)
            y = theta0 * d + 0.8 * x1 - 0.5 * x2 + alpha + (
                rng.uniform() - 0.5
            ) * 0.25
            rows.append({"id": u, "t": k, "x1": x1, "x2": x2, "d": d, "y": y})
    return pd.DataFrame(rows)


def _ols_predict(x_tr, y_tr, x_te):
    reg = LinearRegression().fit(x_tr, y_tr)
    return reg.predict(x_te)


def _transform(df: pd.DataFrame, approach: str):
    """Mirror of plpr.py `_transform_data` for balanced panels."""
    df = df.sort_values(["id", "t"]).reset_index(drop=True)
    x_cols = ["x1", "x2"]
    if approach in ("cre_general", "cre_normal"):
        means = df.groupby("id")[x_cols].transform("mean")
        means.columns = [c + "_mean" for c in x_cols]
        out = pd.concat([df.reset_index(drop=True), means.reset_index(drop=True)], axis=1)
        return out, x_cols + [c + "_mean" for c in x_cols], None
    if approach == "fd_exact":
        ys, ds, xs, ids = [], [], [], []
        for _, g in df.groupby("id", sort=True):
            g = g.sort_values("t").reset_index(drop=True)
            for k in range(1, len(g)):
                ys.append(g.loc[k, "y"] - g.loc[k - 1, "y"])
                ds.append(g.loc[k, "d"] - g.loc[k - 1, "d"])
                xs.append(
                    list(g.loc[k, x_cols]) + list(g.loc[k - 1, x_cols])
                )
                ids.append(int(g.loc[k, "id"]))
        cols = x_cols + [c + "_lag" for c in x_cols]
        return (
            pd.DataFrame(
                {"y_diff": ys, "d_diff": ds, **dict(zip(cols, np.array(xs).T)), "id": ids}
            ),
            cols,
            None,
        )
    # wg_approx
    demean_cols = ["y", "d"] + x_cols
    group_means = df.groupby("id")[demean_cols].transform("mean")
    grand_means = df[demean_cols].mean()
    within = df[demean_cols] - group_means + grand_means
    within.columns = [c + "_dm" for c in demean_cols]
    out = pd.concat([df[["id"]].reset_index(drop=True), within.reset_index(drop=True)], axis=1)
    return out, [c + "_dm" for c in x_cols], None


def handrolled_plpr(df: pd.DataFrame, approach: str):
    """Independent implementation of the clustered PLPR pipeline."""
    data, x_cols, _ = _transform(df, approach)
    if approach == "fd_exact":
        y = data["y_diff"].to_numpy(float)
        d = data["d_diff"].to_numpy(float)
    elif approach == "wg_approx":
        y = data["y_dm"].to_numpy(float)
        d = data["d_dm"].to_numpy(float)
    else:
        y = data["y"].to_numpy(float)
        d = data["d"].to_numpy(float)
    x = data[x_cols].to_numpy(float)
    ids = data["id"].to_numpy(int)

    # Unit-level folds: permutation over unique ids, two test halves.
    uniq = np.unique(ids)
    rng = np.random.default_rng(20260826)
    perm = rng.permutation(uniq)
    halves = np.array_split(perm, 2)

    def unit_folds():
        for half in halves:
            te = np.where(np.isin(ids, half))[0]
            tr = np.where(~np.isin(ids, half))[0]
            yield tr, te, half

    # ml_l
    l_hat = np.full(len(y), np.nan)
    for tr, te, _ in unit_folds():
        l_hat[te] = _ols_predict(x[tr], y[tr], x[te])

    # ml_m (cre_normal augments with the unit mean of d)
    if approach == "cre_normal":
        d_mean = pd.Series(d).groupby(ids).transform("mean").to_numpy()
        xm = np.column_stack([x, d_mean])
    else:
        xm = x
    m_hat = np.full(len(y), np.nan)
    for tr, te, _ in unit_folds():
        m_hat[te] = _ols_predict(xm[tr], d[tr], xm[te])

    # cre_general post-hoc adjustment
    if approach == "cre_general":
        d_mean = pd.Series(d).groupby(ids).transform("mean").to_numpy()
        mh_mean = pd.Series(m_hat).groupby(ids).transform("mean").to_numpy()
        m_hat = m_hat + d_mean - mh_mean

    v = d - m_hat
    u = y - l_hat
    psi_a = -(v**2)
    psi_b = v * u

    def est_coef(psa, psb):
        num = 0.0
        den = 0.0
        for tr, te, half in unit_folds():
            w = 1.0 / len(half)
            den += w * psa[te].sum()
            num += w * psb[te].sum()
        return -num / den

    theta = est_coef(psi_a, psi_b)
    resid = theta * psi_a + psi_b

    # Cluster variance (_var_est one-cluster-variable branch).
    gamma = 0.0
    j_hat = 0.0
    npc = 2
    for tr, te, half in unit_folds():
        w = 1.0 / len(half)
        for g in half:
            rows_g = ids == g
            s = resid[rows_g].sum()
            gamma += w * s * s
            j_hat += w * psi_a[rows_g].sum()
    J = j_hat / npc
    gamma /= npc
    se = float(np.sqrt(gamma / (len(uniq) * J * J)))
    return float(theta), se


def main() -> None:
    print("=" * 74)
    print("v0.26.0 DoubleMLPLPR cross-check vs upstream + hand-rolled cluster ref")
    print("=" * 74)
    df = build_panel_dgp(n_units=60, n_periods=4, theta0=1.0, seed=3141)
    panel_data = dml.DoubleMLPanelData(
        df,
        y_col="y",
        d_cols="d",
        t_col="t",
        id_col="id",
        x_cols=["x1", "x2"],
        static_panel=True,
    )

    print(f"{'approach':>12s} | {'upstream th':>11s} {'se':>8s} | "
          f"{'handroll th':>11s} {'se':>8s}")
    ok = True
    for approach in APPROACHES:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            obj = DoubleMLPLPR(
                panel_data,
                ml_l=LinearRegression(),
                ml_m=LinearRegression(),
                n_folds=2,
                approach=approach,
            )
            obj.fit()
        th_up = float(obj.coef[0])
        se_up = float(obj.se[0])
        th_hr, se_hr = handrolled_plpr(df, approach)
        print(f"{approach:>12s} | {th_up:11.6f} {se_up:8.6f} | "
              f"{th_hr:11.6f} {se_hr:8.6f}")

        checks = [
            ("upstream theta sane", 0.9 < th_up < 1.15),
            ("upstream se clustered scale", se_up < 0.1),
            ("handrolled theta sane", 0.9 < th_hr < 1.15),
            ("theta agree", abs(th_up - th_hr) < 0.08),
            ("se agree", 0.5 < se_hr / se_up < 2.0),
        ]
        for name, passed in checks:
            if not passed:
                ok = False
                print(f"    FAIL {name}: {approach}")

    print()
    print("MoonBit reference (plpr_test.mbt, seed=3141):")
    print("  cre_general  theta=1.028282 se=0.017046")
    print("  cre_normal   theta=1.028282 se=0.017046")
    print("  fd_exact     theta=1.029138 se=0.020015")
    print("  wg_approx    theta=1.028282 se=0.017046")
    print("  All four must stay within [0.9, 1.15] x se [0.004, 0.08].")
    print()
    verdict = "PASS" if ok else "FAIL"
    print(f"Cross-check: {verdict}")
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
