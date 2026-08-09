"""
Standalone smoke test for the n_rep=5 Python logic only (no MoonBit call).

This runs the proposed reference_*_mimic_moonbit_n_rep5 and upstream_*_n_rep5
helpers and prints their outputs, so the producer can verify the Python-side
math before the moonbit-coder has added the n_rep=5 section to cmd/main.

It does NOT touch any *.mbt file; it just exercises the Python helpers that
TODO #7 is about to add to each of the four validate_*.py scripts.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import doubleml as dml
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.model_selection import KFold


# Pull in the four validate_*_with_python modules by their file path so we
# can call their functions without re-implementing them here.
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import importlib.util
def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

irm_mod  = _load("irm_mod",  ROOT / "validate_irm_with_python.py")
pliv_mod = _load("pliv_mod", ROOT / "validate_pliv_with_python.py")
iivm_mod = _load("iivm_mod", ROOT / "validate_iivm_with_python.py")
did_mod  = _load("did_mod",  ROOT / "validate_did_with_python.py")


def moonbit_aggregate(coefs, ses):
    """Mirror aggregator.mbt:32-60 exactly.

    coefs, ses: list-like of equal length n.
    n == 1 fast path returns (coefs[0], ses[0]) (the only row of the sorted
    array is the input element).
    Otherwise: theta_hat = sorted_coefs[n//2] (high median),
               ub = coefs + 1.96 * ses, ub_hat = sorted_ub[n//2],
               se_hat = (ub_hat - theta_hat) / 1.96.
    """
    coefs = list(coefs)
    ses = list(ses)
    assert len(coefs) == len(ses) and len(coefs) >= 1
    n = len(coefs)
    if n == 1:
        return coefs[0], ses[0]
    sc = sorted(coefs)
    theta_hat = sc[n // 2]
    ub = [coefs[i] + 1.96 * ses[i] for i in range(n)]
    ub.sort()
    ub_hat = ub[n // 2]
    se_hat = (ub_hat - theta_hat) / 1.96
    return theta_hat, se_hat


def handrolled_nrep5_irm(x, y, d, propensity_clip=1e-6, n_rep=5):
    coefs, ses = [], []
    n = len(y)
    for r in range(n_rep):
        kf = KFold(n_splits=2, shuffle=True, random_state=3141 + r)
        folds = list(kf.split(x))
        c, s = irm_mod.reference_irm_mimic_moonbit(x, y, d, folds, propensity_clip)
        coefs.append(c)
        ses.append(s)
    return moonbit_aggregate(coefs, ses)


def handrolled_nrep5_pliv(x, y, d, z, n_rep=5):
    coefs, ses = [], []
    for r in range(n_rep):
        kf = KFold(n_splits=2, shuffle=True, random_state=3141 + r)
        folds = list(kf.split(x))
        c, s = pliv_mod.reference_pliv_mimic_moonbit(x, y, d, z, folds)
        coefs.append(c)
        ses.append(s)
    return moonbit_aggregate(coefs, ses)


def handrolled_nrep5_iivm(x, y, d, z, propensity_clip=1e-6, n_rep=5):
    coefs, ses = [], []
    for r in range(n_rep):
        kf = KFold(n_splits=2, shuffle=True, random_state=3141 + r)
        folds = list(kf.split(x))
        c, s = iivm_mod.reference_iivm_mimic_moonbit(x, y, d, z, folds, propensity_clip)
        coefs.append(c)
        ses.append(s)
    return moonbit_aggregate(coefs, ses)


def handrolled_nrep5_did(x, y, d, propensity_clip=1e-6, n_rep=5):
    coefs, ses = [], []
    n = len(y)
    for r in range(n_rep):
        kf = KFold(n_splits=2, shuffle=True, random_state=3141 + r)
        folds = list(kf.split(x))
        c, s = did_mod.reference_did_mimic_moonbit(x, y, d, folds, propensity_clip)
        coefs.append(c)
        ses.append(s)
    return moonbit_aggregate(coefs, ses)


def upstream_nrep5_irm(x, y, d):
    dml_data = dml.DoubleMLData.from_arrays(x=x, y=y, d=d)
    np.random.seed(3141)
    obj = dml.DoubleMLIRM(
        dml_data,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=1000),
        n_folds=2,
        n_rep=5,
        score="ATE",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


def upstream_nrep5_pliv(x, y, d, z):
    z2d = z.reshape(-1, 1)
    dml_data = dml.DoubleMLData.from_arrays(x=x, y=y, d=d, z=z2d)
    np.random.seed(3141)
    obj = dml.DoubleMLPLIV(
        dml_data,
        ml_l=LinearRegression(),
        ml_m=LinearRegression(),
        ml_r=LinearRegression(),
        n_folds=2,
        n_rep=5,
        score="partialling out",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


def upstream_nrep5_iivm(x, y, d, z):
    z2d = z.reshape(-1, 1)
    dml_data = dml.DoubleMLData.from_arrays(x=x, y=y, d=d, z=z2d)
    np.random.seed(3141)
    obj = dml.DoubleMLIIVM(
        dml_data,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=1000),
        ml_r=LogisticRegression(max_iter=1000),
        n_folds=2,
        n_rep=5,
        score="LATE",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


def main():
    print("=" * 70)
    print("TODO #7 standalone Python smoke (no MoonBit call)")
    print("=" * 70)

    # IRM
    x, y, d = irm_mod.make_dgp(n=500, p=5, theta0=1.0, seed=1111)
    hr_c, hr_s = handrolled_nrep5_irm(x, y, d)
    up_c, up_s = upstream_nrep5_irm(x, y, d)
    print(f"IRM   handrolled_nrep5 theta={hr_c:.12f}  se={hr_s:.12f}")
    print(f"IRM   upstream_nrep5   theta={up_c:.12f}  se={up_s:.12f}")

    # PLIV
    x, y, d, z = pliv_mod.make_dgp(n=500, p=5, alpha0=1.0, seed=1111)
    hr_c, hr_s = handrolled_nrep5_pliv(x, y, d, z)
    up_c, up_s = upstream_nrep5_pliv(x, y, d, z)
    print(f"PLIV  handrolled_nrep5 theta={hr_c:.12f}  se={hr_s:.12f}")
    print(f"PLIV  upstream_nrep5   theta={up_c:.12f}  se={up_s:.12f}")

    # IIVM
    x, y, d, z = iivm_mod.make_dgp(n=500, p=5, theta=1.0, alpha=0.5, seed=1111)
    hr_c, hr_s = handrolled_nrep5_iivm(x, y, d, z)
    up_c, up_s = upstream_nrep5_iivm(x, y, d, z)
    print(f"IIVM  handrolled_nrep5 theta={hr_c:.12f}  se={hr_s:.12f}")
    print(f"IIVM  upstream_nrep5   theta={up_c:.12f}  se={up_s:.12f}")

    # DID
    x, y, d = did_mod.make_dgp(n=1000, p=5, theta=1.0, seed=1111)
    hr_c, hr_s = handrolled_nrep5_did(x, y, d)
    print(f"DID   handrolled_nrep5 theta={hr_c:.12f}  se={hr_s:.12f}")
    print(f"  (no upstream comparison for DID; ml_m is LinearRegression)")


if __name__ == "__main__":
    main()
