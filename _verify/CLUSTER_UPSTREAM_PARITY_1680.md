# `examples/cluster` has no usable upstream reference — measured, not assumed

**Status: investigated, documented, NOT changed.** The goal is parity with
upstream; on this surface upstream has no working reference to be parity
*with*, and adopting its formula anyway would be a regression dressed as
compliance. The numbers below are the reason.

## What the port does, and it is deliberate

`cluster_sandwich_variance` (`sandwich.mbt:533`) implements the statsmodels
`cov_type='cluster'` convention:

    var = M_inv^2 * sum_c (n_c / max(n_c-1, 1)) * S_c^2 / n^2,
    S_c = sum_{i in c} psi[i]

`validate_cluster_plr_with_python.py` already gates that against an
independent hand-rolled Python reference, and does so with the right
instrument — absolute scale and the singleton identity, not a ratio. Its own
docstring records why: dropping the `n^2` leaves `cluster SE / row SE`
UNCHANGED, so a ratio check would pass a variance whose `1/n` had been
cancelled in the algebra.

## What upstream has

Upstream's cluster variance is defined in its own test utilities,
`doubleml/tests/_utils_cluster.py`:

    gamma = (1/n_folds) * sum_folds (1/|I_k|) * sum_{i in I_k} S_i^2
    j_hat = (1/n_folds) * sum_folds (1/|I_k|) * sum_{i in test_k} psi_a[i]
    var   = gamma / j_hat^2 / n_clusters

**That oracle is validated**: applying it to `DoubleMLPLIV`'s own `psi` /
`psi_deriv` on `make_pliv_multiway_cluster_CKMS2021` reproduces upstream's
`.se` to **2.08e-17** (`0.047719` both ways). Upstream's CI asserts the same
thing at `abs_tol=1e-4` (`test_dml_pliv_multiway_cluster_se`).

**The two formulas are different estimators, not different scalings.**
Upstream's `theta` is a *cluster-average* — `est_one_way_cluster_dml2` divides
by `|I_k|`, the number of clusters in the fold — so its variance carries an
extra `1/n_clusters`. The port's `theta` is a row-average. Upstream's sum runs
over TEST-SET clusters only and is fold-weighted; the port's runs over all
clusters globally.

Putting the port's documented formula on **upstream's own psi**:

    upstream  sqrt(var_one_way_cluster)                      0.047719
    port      sqrt(M_inv^2 * sum_c S_c^2 * n_c/(n_c-1) / n^2)  0.000079
    ratio                                                    0.001647

That the same psi array reproduces upstream's `.se` to 2e-17 through
upstream's formula, and then diverges by 607x through the port's, is what
makes this a difference in estimator rather than a transcription error on
either side.

## Why there is no working reference to gate against

Enumerated, all measured (`_verify/_cluster_api_1680.py`,
`_verify/_cluster_shape_1680.py`, `_verify/_cluster_cols_1680.py`):

| route | result |
|---|---|
| `DoubleMLClusterData` | **DEPRECATED** — "will be removed with version 0.12.0" |
| `DoubleMLData.from_arrays(cluster_vars=...)`, 1-D int | `n_samples=1`, cannot fit |
| ... 1-D float / (n,1) int / (n,1) float | same, `n_samples=1`, cannot fit |
| `DoubleMLData(df, cluster_cols=...)`, int / float | `n_samples=1`, cannot fit |
| ... as **str** | fits, cluster/row SE ratio **1.0100** — clustering does nothing |
| `DoubleMLClusterData`, cluster_vars as 1-D int vs 1-D float | ratio 0.9321 vs 1.0524 — **same ids, different answer** |

`n_samples=1` is upstream's cluster-aware splitter seeing one cluster. With
`n_folds=2` it raises `Cannot have number of splits n_splits=2 greater than
the number of samples: n_samples=1` at every cluster count tried (3, 5, 10,
20, 60).

And the coefficient swings on nothing but the id column's dtype:
**1.4838 (int) / 1.3767 (float) / 1.4861 (str)** on the same fit.

## Upstream does not test this case either

`doubleml/tests/test_multiway_cluster.py` has exactly one `DoubleMLPLR`
cluster test, and its own comment says:

> in the one-way cluster case with exactly one observation per cluster, we get
> the same result w & w/o clustering

One observation per cluster makes clustering a no-op by construction. The
substantive cluster coverage upstream has is `DoubleMLPLIV` **two-way** on the
CKMS grid. So upstream never exercises repeated observations within a one-way
cluster for any PLM estimator.

## Why nothing was changed

Changing `cluster_sandwich_variance` to upstream's formula would alter the
reported SE of **15 estimators** (every class exposing
`cluster_sandwich_se` / `cluster_sandwich_variance`), would make
`cluster_sandwich_se(singletons) == se()` — the port's exact algebraic control,
asserted at `rel_tol=1e-14` — cease to hold, and would adopt an estimator
whose only upstream test covers the degenerate one-observation-per-cluster
case. That is a worse-documented estimator, not a more faithful one, and it is
a reported-behaviour change rather than a gate detail.

## What would settle it

Either upstream restores `cluster_vars` grouping (the `n_samples=1` bug), or
the port ships upstream's cluster estimator alongside the statsmodels one
under its own name, so both are callable and the choice is explicit rather
than inherited. Both are decisions, not fixes.

Reproduce:

    python _verify\_cluster_formula_1680.py   # the 607x, and the 2e-17
    python _verify\_cluster_cols_1680.py      # every route, enumerated
    python _verify\_cluster_api_1680.py       # signatures + deprecation notice

Measured on `doubleml` 0.11.3, Windows, MoonBit 0.1.20261012.
