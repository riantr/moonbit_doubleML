"""Diagnostic 4: probe installed doubleml 0.11.4 PLPR internals.

Answers three questions about the cre_general SE path:
  Q1  Is the transformed data treated as cluster data? (_is_cluster_data)
  Q2  Are folds unit-level (no unit spans train+test)?
  Q3  Which variance formula reproduces the reported SE?
"""

import warnings

import numpy as np
from sklearn.linear_model import LinearRegression

import sys

sys.path.insert(0, ".")
from validate_plpr_with_python import build_panel_dgp

import doubleml as dml
from doubleml.plm import DoubleMLPLPR


def main() -> None:
    df = build_panel_dgp(60, 4, 1.0, 3141)
    panel_data = dml.DoubleMLPanelData(
        df,
        y_col="y",
        d_cols="d",
        t_col="t",
        id_col="id",
        x_cols=["x1", "x2"],
        static_panel=True,
    )
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        obj = DoubleMLPLPR(
            panel_data,
            ml_l=LinearRegression(),
            ml_m=LinearRegression(),
            n_folds=2,
            approach="cre_general",
        )
        obj.fit()

    print("version:", dml.__version__)
    print("Q1 _is_cluster_data:", obj._is_cluster_data)
    print("   n_folds:", obj.n_folds)
    for attr in ("_n_folds_per_cluster", "_smpls_cluster"):
        print("   has", attr, ":", hasattr(obj, attr))

    # transformed data rows and ids
    dt = obj.data_transform.data
    id_var = np.asarray(obj.data_transform.id_var).ravel()
    print("transformed rows:", len(dt), "unique ids:", len(np.unique(id_var)))

    smpls = obj.smpls
    print("Q2 n_folds in smpls:", len(smpls[0]))
    leak = 0
    for k in range(len(smpls[0])):
        train_idx = set(np.asarray(smpls[0][k][0]).ravel().tolist())
        test_idx = set(np.asarray(smpls[0][k][1]).ravel().tolist())
        for g in np.unique(id_var):
            rows = {i for i in range(len(id_var)) if id_var[i] == g}
            if rows & train_idx and rows & test_idx:
                leak += 1
    print("Q2 units spanning both sides of a fold:", leak)

    pe = obj.psi_elements
    psi_a = np.asarray(pe["psi_a"]).ravel()
    psi_b = np.asarray(pe["psi_b"]).ravel()
    th = -np.mean(psi_b) / np.mean(psi_a)
    J = np.mean(psi_a)
    gam_naive = np.mean((th * psi_a + psi_b) ** 2)
    se_naive = np.sqrt(gam_naive / (J * J * len(psi_a)))
    print("Q3 naive row-level se:", round(se_naive, 6))
    print("Q3 reported se       :", round(float(obj.se[0]), 6))

    # cluster formula with S_g sums over units
    resid = th * psi_a + psi_b
    uniq, inv = np.unique(id_var, return_inverse=True)
    N = len(uniq)
    sums = np.bincount(inv, weights=resid, minlength=N)
    se_cluster = np.sqrt(np.sum(sums**2) / (N * N * J * J))
    print("Q3 cluster-unit se   :", round(se_cluster, 6))


if __name__ == "__main__":
    main()
