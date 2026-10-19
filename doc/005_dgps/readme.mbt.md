# DGP Catalogue

18 synthetic-data generators, ported from the corresponding
`doubleml.did.datasets.dgp_*` / `make_*_data` factories in
upstream doubleml-for-py. They live in **17** `dgp_*.mbt` modules
at the package root, each with a sibling `dgp_*_test.mbt` --
**35 files** in all.

Every factory takes **positional** arguments and returns a DGP
struct with `x_get()` / `y_get()` / `d_get()` accessors (plus
`theta_get()` where the design has a single causal parameter). The
randomness is a `chacha8_rng(seed)` draw rebuilt from the `seed`
argument, so the same arguments always give the same sample.

## Quick reference

| Factory | Model | Signature | File |
|---------|-------|-----------|------|
| `make_plr_CCDDHNR2018` | PLR, Chernozhukov et al. 2018 | `(n_obs, dim_x, theta, seed)` | `dgp_plr_CCDDHNR.mbt` |
| `make_confounded_plr_data` | PLR, confounded | `(n_obs, dim_x, theta, seed)` | `dgp_plr_confounded.mbt` |
| `make_plr_turrell2018` | PLR, Turrell 2018 | `(n_obs, theta, seed)` | `dgp_plr_turrell.mbt` |
| `make_irm_data` | IRM | `(n_obs, dim_x, theta, seed)` | `dgp_irm.mbt` |
| `make_irm_heterogeneous_data` | IRM, heterogeneous effects | `(n_obs, theta, seed)` | `dgp_irm_heterogeneous.mbt` |
| `make_irm_confounded_data` | IRM, confounded | `(n_obs, dim_x, theta, seed)` | `dgp_irm_confounded.mbt` |
| `make_irm_discrete_treatments` | IRM, discrete treatments | `(n_obs, dim_x, theta, seed)` | `dgp_irm_discrete.mbt` |
| `make_iivm_data` | IIVM | `(n_obs, dim_x, theta, seed)` | `dgp_iivm.mbt` |
| `make_pliv_data` | PLIV | `(n_obs, dim_x, theta, seed)` | `dgp_pliv.mbt` |
| `make_pliv_CHS2015` | PLIV, Chernozhukov et al. 2015 | `(n_obs, dim_x, theta, seed)` | `dgp_pliv.mbt` |
| `make_pliv_multiway_cluster` | PLIV, multiway clustered | `(n_obs, dim_x, theta, seed)` | `dgp_pliv_cluster.mbt` |
| `make_lplr_LZZ2020` | LPLR, Liu-Zhang-Zhou 2020 | `(n, alpha, seed)` | `dgp_lplr.mbt` |
| `make_plpr_CP2025` | PLPR, Clarke-Polselli 2025 | `(n_obs, dim_x, theta, seed)` | `dgp_plpr.mbt` |
| `make_did_SZ2020` | DID, Sant'Anna-Zhao 2020 | `(n_obs, dim_x, theta, seed)` | `dgp_did_SZ2020.mbt` |
| `make_did_CS2021` | DID, Callaway-Sant'Anna 2021 | `(n_obs, dim_x, theta, seed)` | `dgp_did_CS2021.mbt` |
| `make_did_cs_CS2021` | CS-DID, Callaway-Sant'Anna 2021 | `(n_obs, dim_x, theta, seed)` | `dgp_did_cs_CS2021.mbt` |
| `make_ssm_data` | SSM | `(n_obs, dim_x, theta, seed)` | `dgp_ssm.mbt` |
| `make_simple_rdd_dgp` | sharp / fuzzy RDD | `(n_obs, theta, seed)` | `dgp_simple_rdd.mbt` |

The `dgp_*.mbt` / `dgp_*_test.mbt` glob at the package root is the
source of truth for the current set.

## Usage pattern

The DGP struct is not a `DoubleMLData` -- wrap it first:

```moonbit nocheck
///|
let dgp = make_plr_CCDDHNR2018(5000, 20, 0.5, 3141)

///|
let data = DoubleMLData::new(dgp.x_get(), dgp.y_get(), dgp.d_get())

///|
let fitted = @moonbit_doubleML.DoubleMLPLR::new(
  data,
  n_folds=2,
  n_rep=1,
  seed=3141,
).fit()
```

The panel and DID DGPs return their own data types
(`DoubleMLPanelData`, `DoubleMLDIDCSData`, ...) and carry the extra
`t` / `g` / `id` accessors, so the wrapper differs per model --
see `dgp_recovery_test.mbt` for a worked example of each shape.

The deterministic `chacha8_rng(seed)` is the only randomness
source — given the same seed, two runs produce bit-identical
output.

## Recovery tests

`dgp_recovery_test.mbt` holds **three** end-to-end recovery tests,
covering the staggered DID and PLPR estimators -- not every
estimator:

| Test | Estimator | Band |
|------|-----------|------|
| `DIDCS_DGP_estimator_recovers_true_ATT` | `DoubleMLDIDCS` | SE-relative; the band was measured across 12 seeds (max error 14.41 absolute, 2.41 in SE units) |
| `DIDCS_on_multicohort_DGP_recovers_some_ATT` | `DoubleMLDIDCS` | SE-relative, on the 4-cohort DGP |
| `PLPR_DGP_estimator_recovers_within_band` | `DoubleMLPLPR` | `10.0 * se + 0.5` |

`DoubleMLDIDMulti` has **no** recovery test, and the file says why:
it ignores `t_pre` (`coef_at_idx` calls `ignore(t_pre)` and the
inner `DoubleMLDIDCS` derives its own base as `g - 1`), so this DGP
cannot serve as a DIDMulti recovery fixture yet.

The `MAX(MODEL_TOL=0.1, 2.0 * handrolled_se)` tolerance belongs to
the **Python** cross-validators in `validate_*_with_python.py`, not
to this MoonBit test file. It is also not one package-wide
constant: the IRM validator uses `0.1`, while the APOS and
DIDCSBinary validators use `0.3`, and most validators do not use the
name at all.

## Next

- See `006_python_check` for how the Python `validate_*.py`
  scripts cross-check each estimator + DGP pair.
