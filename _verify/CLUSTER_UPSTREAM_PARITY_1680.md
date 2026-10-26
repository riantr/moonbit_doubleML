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

    python _verify\_cluster_premise_1680.py     # upstream 0.11.3, every route
    python _verify\_cluster_var_est_1680.py     # port vs upstream's own function
    python _verify\_cluster_battery_1680.py     # does the pin discriminate

## 2026-10-13: decision taken, and the finding that shrank it

**Decision: ship upstream's estimator alongside the statsmodels one, keep the
statsmodels one as the default.** The user chose this after the premise was
re-measured (section below) rather than on the earlier reading of this file.

**The work was smaller than the decision implied, because upstream's estimator
was already ported.** `var_est_cluster` (`plpr.mbt:250`) is a transcription of
upstream's `var_one_way_cluster` / `_var_est`:

| | upstream | port |
|---|---|---|
| per fold | `const = 1/len(I_k)`, `gamma += const * S^2`, `j_hat += sum(psi_a[test])/len(I_k)` | `w = 1/m`, `gamma += w*s*s`, `j_hat += w*sd` |
| finish | `gamma/n_folds`, `j_hat/n_folds` | `g = gamma/npc`, `j = j_hat/npc` |
| result | `sqrt(gamma_hat / j_hat**2 / n_clusters)` | `sqrt(g / (n_units * j * j))` |

`npc == n_folds` and `n_units == n_clusters`, so the two expressions are the
same number by algebra — not by two implementations happening to agree. So
"ship it alongside" was **already satisfied**: the choice is reachable, and
`examples/cluster` exercises and prints all three code paths (`row_se`,
`cluster_dml_se` via `var_est_cluster`, `sandwich_se` via
`cluster_sandwich_variance`) with `validate_cluster_plr_with_python.py` gating
them, including the exact identity `cluster_sandwich_se(singletons) == se()` at
`rel_tol 1e-14`.

Measured on the shipped example:

| | PLR n=200 | PLR n=800 | PLIV n=200 | PLIV n=800 |
|---|---|---|---|---|
| `sandwich_se / cluster_dml_se` | 1.1458 | 1.1180 | 0.9420 | 1.0354 |

Two estimators that disagree by 6-15% on real fits, both callable, neither
hiding the other.

### What was actually missing: `var_est_cluster` was pinned only to a hand oracle

`plpr_var_est_cluster_reference` asserts against numbers worked out by hand.
That cannot tell "this is upstream's formula" from "this is what we believed
upstream's formula was" — the exact blind spot that let the v0.115.0 LPLR bug
through two green identity gates.

`plpr_var_est_cluster_matches_upstream_var_one_way_cluster` now pins it to
upstream's **function**. Fixture: 4 clusters of unequal size 4/2/3/4 over 3
folds, so `1/m` is exercised at m=1 and m=2, and `m != n_folds` — the case a
constant divisor gets wrong.

| | value |
|---|---|
| upstream `var_one_way_cluster` | variance `0.17242815493544361`, se `0.41524469284440424` |
| port `var_est_cluster` | identical, rel gap `0.000e+00` |

Mutation battery `_verify/_cluster_battery_1680.py`, **3/3**: control (zero
failures, pin not named), `s*s` -> `s` (14 failures, pin named), `w*sd` -> `sd`
(8 failures, pin named).

### Two errors the work exposed, both worth keeping

1. **The MoonBit test caught a fixture the Python cross-check could not.** The
   first fixture passed `unit_fold` as 13 per-row fold ids; `var_est_cluster`
   reads `unit_fold[u]` for `u` in `0..n_units`, so it saw folds 1 and 2 with
   zero units and `require(m > 0)` fired. The Python side reported `0.000e+00`
   on that same wrong fixture — its `port_formula` is a per-row
   re-implementation, so it was comparing upstream's function against upstream's
   own semantics and could not see the difference. **A cross-check written in the
   same shape as the subject cannot see a shape error in the subject.**
2. **The first battery scored 0/3 because its probe could not see a pass.**
   `moon test` prints failing test names only, so "name present without
   `failed`" matched a build error as readily as a green test. The control arm
   came back `ABSENT` — the probe was broken, not the subject. The battery now
   states its instrument in terms of what `moon test` actually reports: a
   mutant must produce failures *and* name the pin, and a compile error aborts
   the run rather than counting as red.

### Also fixed: three "Reproduce" commands that pointed at nothing

This section's first draft cited `_cluster_formula_1680.py`,
`_cluster_cols_1680.py` and `_cluster_api_1680.py`. None of them is in the
repository — `Test-Path` returns `False` for all three — and none of them ever
was (`git log --all -- _verify/_cluster_formula_1680.py` is empty). A
reproduction command that cannot be run is worse than none, because it reads as
evidence. The "Reproduce" block above now names the three scripts that do
exist: `_cluster_premise_1680.py` (upstream 0.11.3, every route),
`_cluster_var_est_1680.py` (port vs upstream's own function) and
`_cluster_battery_1680.py` (does the pin discriminate).

## 2026-10-13 re-measurement: why the default was not switched

The user originally approved "switch the default to upstream's cluster-average",
on the strength of this document. That approval rests on one claim — that
upstream's cluster-average is the thing to be faithful to — so the claim was
re-measured against the installed upstream rather than re-read
(`_verify/_cluster_premise_1680.py`, `doubleml 0.11.3`).

`DoubleMLPLR`, `n_folds=2`, 400 rows, **20 clusters x 20 observations** — i.e.
repeated observations *within* a cluster, which is the entire point of the
feature:

| route | coef | se | cluster/row |
|---|---|---|---|
| no clustering at all | -0.101526 | 0.09136457 | 1.0000 |
| `cluster_cols` int | -0.115242 | 0.09030991 | **1.0000** |
| `cluster_cols` float | -0.128540 | 0.09398176 | **1.0000** |
| `cluster_cols` str | -0.062428 | 0.09333736 | **1.0000** |

Two things, and the second is the decisive one:

1. **Clustering is a no-op for the SE.** The ratio is `1.0000` in every case,
   including against the unclustered fit. Upstream 0.11.3 does not compute a
   one-way cluster variance for this design at all.
2. **The coefficient moves on nothing but the id dtype** — `-0.1015` /
   `-0.1152` / `-0.1285` / `-0.0624` on the same fit. Identical partitions,
   four different point estimates.

So upstream has no one-way cluster number to match. Switching would change the
reported SE of 15 estimators to agree with a reference that returns the
*unclustered* answer, and would break `cluster_sandwich_se(singletons) == se()` —
the port's exact algebraic control, which is the one property of that formula
that is true by construction rather than by convention.



Measured on `doubleml` 0.11.3, Windows, MoonBit 0.1.20261012.
