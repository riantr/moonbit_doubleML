# Estimators

22 estimators, all reachable through the same
`DoubleMLXxx::new(...).fit()` interface:

| Estimator | Port `score` string | Description | Port file |
|-----------|---------------------|-------------|-----------|
| `DoubleMLPLR` | `partialling-out` | partially linear regression | `plr.mbt` |
| `DoubleMLIRM` | — (fixed: ATE) | interactive regression model | `irm.mbt` |
| `DoubleMLPLIV` | — (fixed: partialling-out) | partially linear IV regression | `pliv.mbt` |
| `DoubleMLIIVM` | — (fixed: LATE) | interactive IV model | `iivm.mbt` |
| `DoubleMLDID` | `observational` | difference-in-differences | `did.mbt` |
| `DoubleMLDIDBinary` | `observational` | DID with panel data, binary (group, time) design | `did_binary.mbt` |
| `DoubleMLDIDCS` | `observational` | DID with repeated cross-sections (Callaway-Sant'Anna) | `did_cs.mbt` |
| `DoubleMLDIDCSBinary` | `observational` | CS-DID with repeated cross-sections, binary (group, time) design | `did_cs_binary.mbt` |
| `DoubleMLDIDMulti` | — (fixed) | multi-period DID with group-time ATT aggregation | `did_multi.mbt` |
| `DoubleMLDIDCrossSection` | `observational` | Sant'Anna-Zhao 2020 cross-section DID | `did_cross_section.mbt` |
| `DoubleMLSSM` | — (fixed: missing-at-random) | sample selection | `ssm.mbt` |
| `DoubleMLAPO` | `apo` | average potential outcomes for one treatment level | `apo.mbt` |
| `DoubleMLAPOS` | `apo` / `apos` | average potential outcomes across several treatment levels | `apo.mbt` |
| `DoubleMLPQ` | `pq` / `qte` | potential quantile | `quantile.mbt` |
| `DoubleMLQTE` | `pq` / `qte` | quantile treatment effect | `quantile.mbt` |
| `DoubleMLLPQ` | `lpq` | local potential quantile | `lpq.mbt` |
| `DoubleMLLPLR` | `nuisance_space` / `instrument` | partially logistic regression, Liu-Zhang-Zhou 2021 | `lplr.mbt` |
| `DoubleMLPLPR` | `partialling out` / `IV-type` | partially linear panel regression, Clarke-Polselli 2025 | `plpr.mbt` |
| `DoubleMLCVAR` | `cvar` | conditional value-at-risk | `cvar.mbt` |
| `DoubleMLRDD` | — (fixed) | regression discontinuity | `rdd.mbt` |
| `DoubleMLBLP` | `policy_tree` | best linear predictor of an orthogonal signal | `blp_policy.mbt` |
| `DoubleMLPolicyTree` | `policy_tree` | policy tree | `blp_policy.mbt` |

The **Port `score` string** column is the value you pass to
`fit(score=...)`, read out of the port's own source. It is *not*
upstream's spelling: upstream `doubleml-for-py` 0.11.4 uses `APO`,
`ATE`, `PQ`, `LPQ`, `CVaR`, `nuisance_space`, `partialling out`,
`observational` and `missing-at-random`, and takes **no score
argument at all** for `RDFlex`, `DoubleMLBLP` or
`DoubleMLPolicyTree`. The package README's estimator table uses a
third vocabulary -- a prose estimand label such as "partialling-out"
or "policy score" -- and is reconciled with this one by that note.

Of the 22, **20** match a class of the same name upstream,
`DoubleMLRDD` is upstream's `RDFlex` renamed, and
`DoubleMLDIDCrossSection` has no upstream estimator -- though upstream
does ship the Sant'Anna-Zhao (2020) DGP (`make_did_SZ2020`), so the
design is upstream and only the estimator is port-only. The package
README's estimator table records the provenance of each row and notes
the few that are importable but absent from upstream's `__all__`.
Several here (e.g. `DoubleMLDID` and its 5 variants) live in
separate `.mbt` files for parallel maintainability.

## Constructor signature

Every estimator follows:

```moonbit nocheck
///|
let fitted = @moonbit_doubleML.DoubleMLXxx::new(
  data, // or some estimator-specific arg
  n_folds=2, // K for K-fold cross-fitting
  n_rep=1, // number of independent fold partitions
  seed=3141, // deterministic seed for chacha8
).fit()
```

`fit()` mutates the estimator in place and returns it; accessors
(`coef()`, `se()`, `confint()`, etc.) read back the
fitted state.

The accessor set is **not** uniform. 16 of the 22 estimators expose
all four of `coef()` / `se()` / `confint()` / `bootstrap()`, and six
do not:

| estimator | instead of | because |
|---|---|---|
| `DoubleMLAPOS` | `coef` / `se` -> `coefs` / `ses` | one estimate per treatment level |
| `DoubleMLQTE` | `coef` / `se` -> `coefs` / `ses` | one estimate per quantile |
| `DoubleMLDIDCS` | `coef` / `se` -> `coef_at` / `se_at` | one ATT per (group, period) |
| `DoubleMLDIDMulti` | `coef` / `se` -> `coef_at_idx` / `se_at_idx` | the same cells, by row-major index |
| `DoubleMLBLP` | `confint` -> `confint_joint` | the interval is for a contrast of the IV coefficient vector |
| `DoubleMLPolicyTree` | no scalar coefficient at all | `leaf_influence`, `leaf_se`, `policy_value`, `policy_value_se` |

## Estimator-specific arguments

- `DoubleMLPLR` / `DoubleMLIRM`: `DoubleMLData` (x, y, d).
- `DoubleMLDIDMulti`: panel-form `DoubleMLDIDData` (x, y, d, t, g, id).
- `DoubleMLPQ` / `DoubleMLQTE` / `DoubleMLLPQ`: extra `quantile` arg.
- `DoubleMLPolicyTree`: extra `depth` arg (default 1).
- `DoubleMLRDD`: `DoubleMLRDDData` with explicit running variable.

## Next

- See `005_dgps` for synthetic data generators to feed these
  estimators.
