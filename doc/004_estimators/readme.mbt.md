# Estimators

17 estimators, all reachable through the same
`DoubleMLXxx::new(...).fit()` interface:

| Estimator | Score | Description | Upstream file |
|-----------|-------|-------------|---------------|
| `DoubleMLPLR` | partialling-out | partially linear regression | `plr.mbt` |
| `DoubleMLIRM` | ATE | interactive regression model | `irm.mbt` |
| `DoubleMLPLIV` | partialling-out | partially linear IV regression | `pliv.mbt` |
| `DoubleMLIIVM` | LATE | interactive IV model | `iivm.mbt` |
| `DoubleMLDID` | observational | difference-in-differences | `did.mbt` |
| `DoubleMLDIDBinary` | observational | 2-period panel DID | `did_binary.mbt` |
| `DoubleMLDIDCS` | observational | staggered CS-DID | `did_cs.mbt` |
| `DoubleMLDIDMulti` | observational | top-level multi-period DID | `did_multi.mbt` |
| `DoubleMLDIDCrossSection` | observational | Sant'Anna-Zhao CS-DID | `did_cross_section.mbt` |
| `DoubleMLSSM` | MAR | sample selection (missing-at-random) | `ssm.mbt` |
| `DoubleMLAPO` | APO | average potential outcome | `apo.mbt` |
| `DoubleMLAPOS` | APOS | APO share | `blp_policy.mbt` |
| `DoubleMLPQ` | PQ | potential quantile | `quantile.mbt` |
| `DoubleMLQTE` | PQ | quantile treatment effect | `quantile.mbt` |
| `DoubleMLLPQ` | LPQ | local potential quantile (compliers) | `lpq.mbt` |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk | `cvar.mbt` |
| `DoubleMLRDD` | (sharp / fuzzy) | regression discontinuity | `rdd.mbt` |
| `DoubleMLBLP` | BLP | best linear predictor | `blp_policy.mbt` |
| `DoubleMLPolicyTree` | (depth-N) | policy tree | `blp_policy.mbt` |

All 19 names map to one of the 17 upstream `doubleml.DoubleML*`
classes — some (e.g. `DoubleMLDID` and its 4 variants) live in
separate `.mbt` files for parallel maintainability.

## Constructor signature

Every estimator follows:

```moonbit nocheck
let fitted = @moonbit_doubleML.DoubleMLXxx::new(
  data,           // or some estimator-specific arg
  n_folds=2,      // K for K-fold cross-fitting
  n_rep=1,        // number of independent fold partitions
  seed=3141,      // deterministic seed for chacha8
).fit()
```

`fit()` mutates the estimator in place and returns it; accessors
(`coef_get()`, `se_get()`, `confint()`, etc.) read back the
fitted state.

## Estimator-specific arguments

- `DoubleMLPLR` / `DoubleMLIRM`: `DoubleMLData` (x, y, d).
- `DoubleMLDIDMulti`: panel-form `DoubleMLDIDData` (x, y, d, t, g, id).
- `DoubleMLPQ` / `DoubleMLQTE` / `DoubleMLLPQ`: extra `quantile` arg.
- `DoubleMLPolicyTree`: extra `depth` arg.
- `DoubleMLRDD`: `DoubleMLRDDData` with explicit running variable.

## Next

- See `005_dgps` for synthetic data generators to feed these
  estimators.