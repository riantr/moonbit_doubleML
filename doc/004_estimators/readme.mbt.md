# Estimators

22 estimators, all reachable through the same
`DoubleMLXxx::new(...).fit()` interface:

| Estimator | Score argument | Description | Port file |
|-----------|----------------|-------------|-----------|
| `DoubleMLPLR` | `fit(score=...)` | partially linear regression | `plr.mbt` |
| `DoubleMLIRM` | — (fixed: ATE) | interactive regression model | `irm.mbt` |
| `DoubleMLPLIV` | — (fixed: partialling-out) | partially linear IV regression | `pliv.mbt` |
| `DoubleMLIIVM` | — (fixed: LATE) | interactive IV model | `iivm.mbt` |
| `DoubleMLDID` | `new(score=...)` | difference-in-differences | `did.mbt` |
| `DoubleMLDIDBinary` | `new(score=...)` | DID with panel data, binary (group, time) design | `did_binary.mbt` |
| `DoubleMLDIDCS` | — (fixed: `observational`) | DID with staggered adoption (Callaway-Sant'Anna) | `did_cs.mbt` |
| `DoubleMLDIDCSBinary` | `new(score=...)` | CS-DID with repeated cross-sections, binary (group, time) design | `did_cs_binary.mbt` |
| `DoubleMLDIDMulti` | — (fixed) | multi-period DID with group-time ATT aggregation | `did_multi.mbt` |
| `DoubleMLDIDCrossSection` | `new(score=...)` | Sant'Anna-Zhao 2020 cross-section DID | `did_cross_section.mbt` |
| `DoubleMLSSM` | — (fixed: missing-at-random) | sample selection | `ssm.mbt` |
| `DoubleMLAPO` | — (fixed: APO) | average potential outcomes for one treatment level | `apo.mbt` |
| `DoubleMLAPOS` | — (fixed: APO) | average potential outcomes across several treatment levels | `apo.mbt` |
| `DoubleMLPQ` | — (fixed: PQ) | potential quantile | `quantile.mbt` |
| `DoubleMLQTE` | — (fixed: PQ) | quantile treatment effect | `quantile.mbt` |
| `DoubleMLLPQ` | — (fixed: LPQ) | local potential quantile | `lpq.mbt` |
| `DoubleMLLPLR` | `new(score=...)` | partially logistic regression, Liu-Zhang-Zhou 2021 | `lplr.mbt` |
| `DoubleMLPLPR` | `new(score=...)` | partially linear panel regression, Clarke-Polselli 2025 | `plpr.mbt` |
| `DoubleMLCVAR` | — (fixed: CVaR) | conditional value-at-risk | `cvar.mbt` |
| `DoubleMLRDD` | — (fixed) | regression discontinuity | `rdd.mbt` |
| `DoubleMLBLP` | — (fixed) | best linear predictor of an orthogonal signal | `blp_policy.mbt` |
| `DoubleMLPolicyTree` | — (fixed) | policy tree | `blp_policy.mbt` |

**Only 7 of the 22 estimators take a `score` argument**, and it does
not always live in the same place: `DoubleMLPLR` takes it on `fit()`,
the other six take it on `new()`, and the remaining **15 take no
`score` argument at all** -- for those the estimand is fixed by the
estimator, and the table's second column says which one. The accepted
spellings and the defaults are in
[The `score` argument](#the-score-argument) below.

Those spellings are the port's own, read out of the port's source; they
are *not* upstream's. Upstream `doubleml-for-py` 0.11.4 uses a
different set of **15** spellings -- `APO`, `ATE`, `ATTE`, `CVaR`,
`IV-type`, `LATE`, `LPQ`, `PQ`, `experimental`, `instrument`,
`missing-at-random`, `nonignorable`, `nuisance_space`, `observational`
and `partialling out` -- and takes **no score argument at all** for
`RDFlex`, `DoubleMLBLP` or `DoubleMLPolicyTree`. The package README's
estimator table uses a third vocabulary -- a prose estimand label such
as "partialling-out" or "policy score" -- and is reconciled with this
one by that note.

Of the 22, **19** match a class of the same name upstream. Two are
upstream's under another name: `DoubleMLRDD` is upstream's `RDFlex`,
and `DoubleMLDIDCrossSection` is upstream's `DoubleMLDIDCS` -- the
*repeated cross-sections* estimator, which upstream still ships, along
with the Sant'Anna-Zhao (2020) DGP (`make_did_SZ2020`) it is built on.
One has no 1:1 upstream class: `DoubleMLDIDCS`, this port's variant of
upstream's multi-period `DoubleMLDIDMulti`, which upstream keeps in a
single class that this port splits in two. The package
README's estimator table records the provenance of each row and notes
the few that are importable but absent from upstream's `__all__`.
Several here (e.g. `DoubleMLDID` and its 5 variants) live in
separate `.mbt` files for parallel maintainability.

## The `score` argument

The port has **9 `score` parameters, at 7 estimators**. Because the
argument sits in a different place per estimator, read the argument
column before writing the call:

| estimator | argument | default | accepts |
|---|---|---|---|
| `DoubleMLPLR` | `fit(score=...)` | `partialling-out` | `partialling-out`, `partialling out`, `iv-type`, `IV-type` |
| `DoubleMLDID` | `new(score=...)` | `observational` | `observational`, `experimental` |
| `DoubleMLDIDBinary` | `new(score=...)` | `observational` | `observational`, `experimental` |
| `DoubleMLDIDCrossSection` | `new(score=...)` | `observational` | `observational`, `experimental` |
| `DoubleMLDIDCSBinary` | `new(score=...)` | `observational` | `observational` |
| `DoubleMLLPLR` | `new(score=...)` | `nuisance_space` | `nuisance_space`, `instrument` |
| `DoubleMLPLPR` | `new(score=...)` | `partialling out` | `partialling out`, `IV-type` |

`DoubleMLPLR` also takes the argument on `fit_cluster(...)` and
`tune(...)`, with the same default and the same accepted set.

**`apo`, `apos`, `pq`, `qte`, `lpq`, `cvar` and `policy_tree` are not
score values.** They are the internal cache-kind tags the port passes to
`hash_hyperparams(...)` -- and, for `policy_tree`, the
`estimator_kind` -- and no estimator accepts one. Handing such a string
to an estimator that has no `score` parameter does not compile; handing
it to `DoubleMLPLR`, which has one, aborts at the `require`.

Two edges worth knowing before you copy a spelling across:

- `DoubleMLPLPR` rejects the hyphen spelling `partialling-out` that its
  own sibling `DoubleMLPLR` accepts *and defaults to*. Use
  `partialling out` (with a space) for `DoubleMLPLPR`.
- `DoubleMLDIDCSBinary` accepts only `observational`; upstream also
  allows `experimental` there.

`DoubleMLDIDCS` has no `score` parameter of its own: it builds a child
`DoubleMLDIDBinary` and forwards `score="observational"` to it.

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

The `score` argument is the one that does **not** follow the snippet
above: it goes on `new()` for six estimators and on `fit()` for
`DoubleMLPLR`. See [The `score` argument](#the-score-argument).

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
