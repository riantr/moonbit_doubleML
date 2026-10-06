"""v0.106.0: cross-check the MoonBit DoubleMLPLR with cluster_vars
against BOTH the upstream `doubleml.plm.DoubleMLPLR` with
`cluster_cols` and an independent hand-rolled Python reference of
the clustered DML path.

The cluster-robust path runs when `cluster_cols` is non-empty
in upstream, or when `cluster_vars` is non-empty in MoonBit.
Folds are drawn over the unique cluster ids; rows of one
cluster stay on the same side of every split; the coefficient
is the fold-weighted ratio of cluster score sums; the SE is
unit-level cluster-robust.

WHAT CHANGED IN v0.106.0, and why
==================================
Through v0.105.0 this file never ran MoonBit. It printed

    "MoonBit reference (plr_cluster_test.mbt::plr_cluster_se_larger):
       cluster_se / row_se ~= 1.6"

as a hand-typed claim, compared it against nothing, and the claim
was about a ratio.

A ratio is the wrong instrument for the defect that matters here.
`cluster_sandwich_variance` returns `M_inv^2 * sum_c S_c^2 *
n_c/(n_c-1) / n^2`. Drop the `n^2` -- exactly the mistake
`DoubleMLDIDCrossSection` carried until v0.102.0, where the `1/n`
had been cancelled in the algebra -- and `cluster SE / row SE` is
UNCHANGED, because the row SE is wrong by the same factor. The
ratio still reads ~1.7 and the check still passes.

So v0.106.0 reads the MoonBit side and checks ABSOLUTE scale. Four
things are asserted, in decreasing order of sharpness:

  1. The singleton identity, which is algebra rather than
     statistics. With every observation in its own cluster,
     `sum_c S_c^2` collapses to `sum_i psi[i]^2` and
     `cluster_sandwich_se(singletons)` must reproduce `se()`. There
     is no sampling content in this claim at all, so it is asserted
     at a relative 1e-14 rather than a Monte-Carlo band. Measured
     on the example: bit-identical at n=800 and one ulp apart at
     n=200 (`0.08850001538500225` vs `0.08850001538500228`).
  2. Each of the three SEs falls by ~1/sqrt(4) when the unit count
     goes 50 -> 200. This is the check the ratio could not make.
  3. The cluster SE exceeds the row SE at BOTH sizes, which is the
     textbook claim and the reason the DGP has a unit random effect
     on both D and Y.
  4. `sandwich_se` and `cluster_dml_se` -- two independent
     implementations of the same idea, one via
     `cluster_sandwich_variance` and one via `var_est_cluster` --
     agree within a factor.

The Python side runs the same 1/sqrt(n) comparison on its own
hand-rolled reference, so the band is anchored on an independent
implementation instead of on MoonBit's own output.

This file FAILS CLOSED.
"""

import re
import subprocess
import sys
import warnings

import numpy as np
import pandas as pd
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import KFold

# Measured on `examples/cluster` (n_units 50 -> 200, n_periods 4):
#
#   row_se        0.08850001538500225 -> 0.04314159352022145   0.4875
#   cluster_dml_se 0.13359133763701572 -> 0.06997162346723808   0.5237
#   sandwich_se    0.1530737743491516  -> 0.0782291616278563    0.5110
#
# A consistent estimator gives 1/sqrt(4) = 0.5. The band is
# deliberately wider than the 0.5 that a textbook would quote: the
# clustered estimators carry a fold-level random component, and the
# n=200 point is a single draw. What the band rules out is a
# variance whose 1/n is gone, which reads as a ratio near 1.0 (or,
# for a variance with no 1/n^2, near 2.0).
SE_RATIO_LO = 0.40
SE_RATIO_HI = 0.65

# The singleton identity is exact algebra, not a statistical
# estimate, so the tolerance only has to absorb the last-ulp
# difference between the summation orders of `var_est` (a plain
# mean) and `cluster_sandwich_variance` (a Kahan-compensated loop
# over clusters).
SINGLETON_REL_TOL = 1.0e-14

# Cluster SE must exceed the row SE on this DGP: the unit random
# effect enters both D and Y, so the within-unit correlation
# deflates the row-level SE. Measured ratios: sandwich/row 1.730 and
# 1.813, cluster_dml/row 1.509 and 1.622.
CLUSTER_OVER_ROW_MIN = 1.2

# Two implementations of cluster-robust variance should not differ by
# more than a modest factor. Measured: 1.146 and 1.118.
TWO_IMPL_MAX_FACTOR = 1.5


def build_clustered_dgp(
    n_units: int, n_periods: int, theta0: float, seed: int
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Mirror of `examples/cluster/main.mbt::build_panel` for Python."""
    rng = np.random.default_rng(seed)
    p = 3
    n = n_units * n_periods
    x = rng.standard_normal((n, p))
    d = np.zeros(n)
    y = np.zeros(n)
    cluster = np.zeros(n, dtype=int)
    for u in range(n_units):
        alpha = (rng.uniform() - 0.5) * 4.0
        trait = rng.uniform() * 2.0 - 1.0
        for k in range(n_periods):
            row = u * n_periods + k
            x1 = trait + (rng.uniform() - 0.5)
            x2 = rng.uniform() * 2.0 - 1.0
            x[row, 0] = x1
            x[row, 1] = x2
            x[row, 2] = trait
            cluster[row] = u
            d[row] = (
                0.6 * x1 + 0.3 * x2 + 0.5 * alpha / 2.0 + (rng.uniform() - 0.5)
            )
            y[row] = (
                theta0 * d[row]
                + 0.8 * x1
                - 0.5 * x2
                + alpha
                + (rng.uniform() - 0.5) * 0.25
            )
    return x, y, d, cluster


def upstream_clustered_plr(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, cluster: np.ndarray
) -> tuple[float, float]:
    """Upstream `DoubleMLPLR` with `cluster_cols`."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import doubleml as dml
    df = pd.DataFrame(
        np.column_stack([x, y, d, cluster.astype(float)]),
        columns=["x1", "x2", "x3", "y", "d", "cluster"],
    )
    df["cluster"] = df["cluster"].astype(int)
    obj = dml.DoubleMLData(
        df, "y", "d", ["x1", "x2", "x3"], cluster_cols="cluster"
    )
    model = dml.DoubleMLPLR(
        obj, ml_l=LinearRegression(), ml_m=LinearRegression(), n_folds=2
    )
    model.fit()
    return float(model.coef[0]), float(model.se[0])


def upstream_row_plr(
    x: np.ndarray, y: np.ndarray, d: np.ndarray
) -> tuple[float, float]:
    """Same data, no cluster_cols -> row-level PLR."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import doubleml as dml
    df = pd.DataFrame(
        np.column_stack([x, y, d]),
        columns=["x1", "x2", "x3", "y", "d"],
    )
    obj = dml.DoubleMLData(df, "y", "d", ["x1", "x2", "x3"])
    model = dml.DoubleMLPLR(
        obj, ml_l=LinearRegression(), ml_m=LinearRegression(), n_folds=2
    )
    model.fit()
    return float(model.coef[0]), float(model.se[0])


def handrolled_clustered_plr(
    x: np.ndarray, y: np.ndarray, d: np.ndarray, cluster: np.ndarray
) -> tuple[float, float, float, float]:
    """Independent numpy re-implementation of the cluster-robust
    PLR pipeline (no sklearn dependence for variance)."""
    n = len(y)
    uniq, inv = np.unique(cluster, return_inverse=True)
    n_units = len(uniq)
    # unit-level 2-fold split (deterministic permutation)
    rng = np.random.default_rng(20260824)
    perm = rng.permutation(n_units)
    halves = np.array_split(perm, 2)

    def folds():
        for half in halves:
            te_mask = np.isin(cluster, half)
            tr_mask = ~te_mask
            tr = np.where(tr_mask)[0]
            te = np.where(te_mask)[0]
            yield tr, te, half

    l_hat = np.zeros(n)
    m_hat = np.zeros(n)
    for tr, te, _ in folds():
        l_hat[te] = LinearRegression().fit(x[tr], y[tr]).predict(x[te])
        m_hat[te] = LinearRegression().fit(x[tr], d[tr]).predict(x[te])

    v = d - m_hat
    u = y - l_hat
    psi_a = -(v**2)
    psi_b = v * u

    num = 0.0
    den = 0.0
    for tr, te, half in folds():
        w = 1.0 / len(half)
        den += w * psi_a[te].sum()
        num += w * psi_b[te].sum()
    theta = -num / den

    resid = theta * psi_a + psi_b
    gamma = 0.0
    j_hat = 0.0
    npc = 2
    for tr, te, half in folds():
        w = 1.0 / len(half)
        for g in half:
            ind = cluster == g
            s = resid[ind].sum()
            gamma += w * s * s
            j_hat += w * psi_a[ind].sum()
    J = j_hat / npc
    gamma /= npc
    se = float(np.sqrt(gamma / (n_units * J * J)))
    return theta, se, float(den), float(num)


def handrolled_row_plr(
    x: np.ndarray, y: np.ndarray, d: np.ndarray
) -> tuple[float, float]:
    """Row-level (non-cluster) PLR for comparison."""
    kf = KFold(n_splits=2, shuffle=True, random_state=3141)
    n = len(y)
    l_hat = np.zeros(n)
    m_hat = np.zeros(n)
    for tr, te in kf.split(x):
        l_hat[te] = LinearRegression().fit(x[tr], y[tr]).predict(x[te])
        m_hat[te] = LinearRegression().fit(x[tr], d[tr]).predict(x[te])
    v = d - m_hat
    u = y - l_hat
    psi_a = -(v**2)
    psi_b = v * u
    theta = -psi_b.mean() / psi_a.mean()
    J = psi_a.mean()
    gamma = ((theta * psi_a + psi_b) ** 2).mean()
    se = float(np.sqrt(gamma / (J * J * n)))
    return theta, se


def run_moonbit() -> dict:
    """Spawn `moon run examples/cluster` and parse the PLR lines.

    Raises on any failure. The caller treats a raise as FAIL.
    """
    result = subprocess.run(
        ["moon", "run", "examples/cluster", "--target", "native"],
        capture_output=True,
        text=True,
        timeout=900,
    )
    if result.returncode != 0:
        err = result.stderr if result.stderr else result.stdout
        raise RuntimeError(
            f"moon run examples/cluster exited {result.returncode}: {err[:400]}"
        )
    out = result.stdout
    plr = {}
    for tag in ("base", "big"):
        m = re.search(
            r"^plr\s+" + tag + r"\s+n=(\d+)\s+theta=([0-9.eE+-]+)\s+"
            r"row_se=([0-9.eE+-]+)\s+cluster_dml_se=([0-9.eE+-]+)\s+"
            r"sandwich_se=([0-9.eE+-]+)\s+singleton_se=([0-9.eE+-]+)\s*$",
            out,
            re.MULTILINE,
        )
        if not m:
            raise RuntimeError(
                f"could not parse the `plr {tag} ...` line from the example "
                f"output. Those rows carry every MoonBit-side number this "
                f"file checks.\n" + out[:900]
            )
        plr[tag] = {
            "n": int(m.group(1)),
            "theta": float(m.group(2)),
            "row_se": float(m.group(3)),
            "cluster_dml_se": float(m.group(4)),
            "sandwich_se": float(m.group(5)),
            "singleton_se": float(m.group(6)),
        }
    if plr["big"]["n"] != 4 * plr["base"]["n"]:
        raise RuntimeError(
            f"expected the big PLR panel to be 4x the base one, got "
            f"{plr['base']['n']} -> {plr['big']['n']}; the 1/sqrt(n) check "
            f"assumes a 4x step"
        )
    return plr


def main() -> None:
    print("=" * 76)
    print("v0.106.0 DoubleMLPLR cluster-robust cross-check")
    print("=" * 76)
    n_units, n_periods, theta0, seed = 50, 4, 1.0, 7
    x, y, d, cluster = build_clustered_dgp(
        n_units, n_periods, theta0, seed
    )
    th_c_up, se_c_up = upstream_clustered_plr(x, y, d, cluster)
    th_r_up, se_r_up = upstream_row_plr(x, y, d)
    th_hr, se_hr, _, _ = handrolled_clustered_plr(x, y, d, cluster)
    th_hr_row, se_hr_row = handrolled_row_plr(x, y, d)
    print(f"{'source':<28s} | {'theta_hat':>10s} | {'se':>10s}")
    print(
        f"{'upstream cluster':<28s} | {th_c_up:10.4f} | {se_c_up:10.4f}"
    )
    print(
        f"{'upstream row    ':<28s} | {th_r_up:10.4f} | {se_r_up:10.4f}"
    )
    print(
        f"{'handrolled cluster':<28s} | {th_hr:10.4f} | {se_hr:10.4f}"
    )
    print(
        f"{'handrolled row    ':<28s} | {th_hr_row:10.4f} | {se_hr_row:10.4f}"
    )
    print()

    ok = True
    # --- Python-side structural checks (unchanged in spirit from v0.28.0)
    if not (se_c_up > 1.2 * se_r_up):
        ok = False
        print(
            f"    FAIL upstream cluster SE / row SE = {se_c_up / se_r_up:.3f}, expected > 1.2"
        )
    if not (se_hr > 1.2 * se_hr_row):
        ok = False
        print(
            f"    FAIL handrolled cluster SE / row SE = {se_hr / se_hr_row:.3f}, expected > 1.2"
        )
    if not (0.0 < abs(th_hr) < 1.0e3):
        ok = False
        print(f"    FAIL handrolled cluster theta = {th_hr}")
    ratio_up_hr = se_c_up / se_hr if se_hr != 0 else float("inf")
    if not (0.3 < ratio_up_hr < 3.0):
        ok = False
        print(
            f"    FAIL upstream/handrolled cluster SE ratio = {ratio_up_hr:.3f}, expected in [0.3, 3.0]"
        )

    # --- The Python side runs the SAME 1/sqrt(n) comparison, so the band
    # the MoonBit side is held to is anchored on an independent
    # implementation rather than on MoonBit's own output.
    x4, y4, d4, c4 = build_clustered_dgp(
        4 * n_units, n_periods, theta0, seed
    )
    th_hr4, se_hr4, _, _ = handrolled_clustered_plr(x4, y4, d4, c4)
    th_row4, se_row4 = handrolled_row_plr(x4, y4, d4)
    py_cluster_ratio = se_hr4 / se_hr if se_hr != 0 else float("inf")
    py_row_ratio = se_row4 / se_hr_row if se_hr_row != 0 else float("inf")
    print(
        f"handrolled 1/sqrt(n) at 4x units: cluster {py_cluster_ratio:.4f}, "
        f"row {py_row_ratio:.4f}  (1/sqrt(4) = 0.5)"
    )
    for label, r in (("cluster", py_cluster_ratio), ("row", py_row_ratio)):
        if not (SE_RATIO_LO < r < SE_RATIO_HI):
            ok = False
            print(
                f"    FAIL handrolled {label} SE ratio {r:.4f} outside "
                f"[{SE_RATIO_LO}, {SE_RATIO_HI}]"
            )
    print()

    # --- MoonBit side.
    print("--- MoonBit side: `moon run examples/cluster` ---")
    try:
        mb = run_moonbit()
    except Exception as exc:  # noqa: BLE001 - any failure is a FAIL
        print(f"could not obtain the MoonBit estimate: {exc}")
        print()
        print("Clustered PLR reference: FAIL")
        raise SystemExit(1)

    base, big = mb["base"], mb["big"]
    print(
        f"  n={base['n']} row_se={base['row_se']:.6f} "
        f"cluster_dml_se={base['cluster_dml_se']:.6f} "
        f"sandwich_se={base['sandwich_se']:.6f}"
    )
    print(
        f"  n={big['n']} row_se={big['row_se']:.6f} "
        f"cluster_dml_se={big['cluster_dml_se']:.6f} "
        f"sandwich_se={big['sandwich_se']:.6f}"
    )
    print()

    print("--- checks on the MoonBit side ---")
    # 1. The singleton identity: algebra, not statistics.
    for tag in ("base", "big"):
        row_se = mb[tag]["row_se"]
        sing = mb[tag]["singleton_se"]
        rel = abs(sing - row_se) / row_se if row_se != 0 else float("inf")
        good = rel < SINGLETON_REL_TOL
        if not good:
            ok = False
        print(
            f"  singleton identity ({tag}): rel |singleton_se - row_se| = "
            f"{rel:.3e} < {SINGLETON_REL_TOL:.0e} -> "
            f"{'PASS' if good else 'FAIL'}"
        )
    print(
        "    (exact algebra: one cluster per observation makes the cluster"
        " sum collapse to the row sum)"
    )

    # 2. Absolute scale: each SE falls by ~1/sqrt(4).
    for key in ("row_se", "cluster_dml_se", "sandwich_se"):
        r = big[key] / base[key] if base[key] != 0 else float("inf")
        good = SE_RATIO_LO < r < SE_RATIO_HI
        if not good:
            ok = False
        print(
            f"  {key:<16s} ratio at 4x = {r:.6f} in "
            f"({SE_RATIO_LO}, {SE_RATIO_HI}) -> {'PASS' if good else 'FAIL'}"
        )
    print(
        "    (the check a cluster/row ratio cannot make: a variance that"
        " lost its 1/n is wrong in both columns at once)"
    )

    # 3. Clustering must actually inflate the SE on this DGP.
    for tag in ("base", "big"):
        for key in ("cluster_dml_se", "sandwich_se"):
            r = mb[tag][key] / mb[tag]["row_se"]
            good = r > CLUSTER_OVER_ROW_MIN
            if not good:
                ok = False
            print(
                f"  {tag:<4s} {key:<16s} / row_se = {r:.4f} > "
                f"{CLUSTER_OVER_ROW_MIN} -> {'PASS' if good else 'FAIL'}"
            )

    # 4. Two implementations of cluster-robust variance agree.
    for tag in ("base", "big"):
        r = mb[tag]["sandwich_se"] / mb[tag]["cluster_dml_se"]
        good = 1.0 / TWO_IMPL_MAX_FACTOR < r < TWO_IMPL_MAX_FACTOR
        if not good:
            ok = False
        print(
            f"  {tag:<4s} sandwich_se / cluster_dml_se = {r:.4f} within "
            f"1/{TWO_IMPL_MAX_FACTOR}..{TWO_IMPL_MAX_FACTOR} -> "
            f"{'PASS' if good else 'FAIL'}"
        )
    print(
        "    (cluster_sandwich_variance vs var_est_cluster: independent"
        " implementations of the same estimator)"
    )

    print()
    print(f"Clustered PLR reference: {'PASS' if ok else 'FAIL'}")
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
