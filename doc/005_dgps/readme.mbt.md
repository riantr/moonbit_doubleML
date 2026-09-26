# DGP Catalogue

35 synthetic-data generators, each ported from a corresponding
`doubleml.did.datasets.dgp_*` / `make_*_data` factory in
upstream doubleml-for-py. Each DGP is a deterministic function
of a `chacha8_rng(seed)` draw, plus structural parameters
(n_obs, n_features, theta, etc.).

## Quick reference

| DGP | Upstream name | Default θ | File |
|-----|---------------|-----------|------|
| `make_plr_data` / `make_plr_CCDDHNR2018` | partialling-out PLR | 1.0 | `dgp_plr.mbt` / `dgp_plr_CCDDHNR.mbt` |
| `make_irm_data` | ATE IRM | 1.0 | `dgp_irm.mbt` |
| `make_pliv_data` | PLIV | 1.0 | `dgp_pliv.mbt` |
| `make_iivm_data` | IIVM | 1.0 | `dgp_iivm.mbt` |
| `make_did_data` / `make_did_SZ2020` / `make_did_CS2021` / `make_did_cs_CS2021` | DID family | 1.0 | `did*.mbt` |
| `make_ssm_data` | SSM | 1.0 | `dgp_ssm.mbt` |
| `make_apos_data` | APO(S) | 1.0 | `apo.mbt` |
| `make_plpr_data` | PLPR | 1.0 | `dgp_plpr.mbt` |
| `make_lplr_data` | LPLR | 1.0 | `dgp_lplr.mbt` |
| `make_cvar_data` | CVaR | 1.0 | `cvar.mbt` |
| `make_simple_rdd_data` | sharp/fuzzy RDD | 1.0 | `dgp_simple_rdd.mbt` |
| (heterogeneous variants) | `make_irm_heterogeneous`, `make_irm_confounded`, `make_irm_discrete`, `make_plr_confounded`, `make_plr_turrell`, `make_pliv_cluster` | various | `dgp_*_*.mbt` |

The full list of 35 is in `dgp_*_*.mbt` / `dgp_*.mbt` files at the
root.

## Usage pattern

Every DGP follows the same shape:

```moonbit nocheck
///|
let rng = chacha8_rng(3141)

///|
let data = make_plr_CCDDHNR2018(rng, n_obs=500, n_features=5, theta=1.0)

///|
let fitted = @moonbit_doubleML.DoubleMLPLR::new(data, n_folds=2, seed=3141).fit()
// fitted.coef_get() should be within MAX(MODEL_TOL=0.1, 2.0 * handrolled_se) of 1.0
```

The deterministic `chacha8_rng(seed)` is the only randomness
source — given the same seed, two runs produce bit-identical
output.

## Recovery tests

`dgp_recovery_test.mbt` runs every estimator end-to-end on its
matching DGP and asserts `|coef() - θ_true| < MAX(MODEL_TOL=0.1,
2.0 * handrolled_se)`. These tests are the contract that the
upstream parity tests verify.

## Next

- See `006_python_check` for how the Python `validate_*.py`
  scripts cross-check each estimator + DGP pair.