# Five more upstream gates are available; three traps make them non-obvious

> **Historical record. Read the status line, not the census.**
>
> This file was committed on 2026-10-16 as `3f83bf1c` ("docs: measure what
> upstream coverage remains, and whether it is reachable"). It describes the
> tree at that commit. It was a feasibility measurement -- the input to a unit
> of work -- and that work has since been done.
>
> **What has changed since**, measured 2026-10-20 by diffing `git ls-tree` at
> `3f83bf1c` against the current tree:
>
> | | at `3f83bf1c` (2026-10-16) | now |
> |---|---|---|
> | `pyexample_*` upstream gates | 5 (`did`, `did_binary`, `did_cs2021`, `did_cs_binary`, `suite`) | **9** -- `+lplr`, `+pq`, `+policytree`, `+rdd` |
> | `validate_*_with_python.py` | 24 | 24, unchanged |
> | the five slots below | no upstream gate at all | PQ, QTE and LPQ in `pyexample_pq.py`; PolicyTree in `pyexample_policytree.py`; RDD in `pyexample_rdd.py` |
> | LPLR | one of the "two open decisions" | gated in `pyexample_lplr.py` |
>
> The call shapes, the three traps and the PolicyTree section below were
> measured against `doubleml` 0.11.3 and have not been re-measured since; the
> STATUS is what moved. The "Reproduce" section at the foot names three
> scripts that were never committed, so the numbers here cannot be re-derived
> from this tree -- that note is now part of the record rather than a promise.

**Status: feasibility measured 2026-10-16; all five gates built since
(2026-10-16 and 2026-10-17).** Every claim below is a printed number
or a printed exception from `dml` 0.11.3, not an inference.

## Where the goal actually stood, as measured 2026-10-16

`_verify/_coverage_census_1680.py` enumerated every `validate_*_with_python.py`
and `pyexample_*`, classified each by whether it imports `doubleml`, and mapped
the 19 driver examples to estimators via the README's own table:

    estimator slots across the driver examples   34
      with an upstream gate                      20
      exempt (no upstream class, or deprecated)   2
      analytic oracle only                      12

The 12 are RDD, PQ, QTE, LPQ, PolicyTree (all on `examples/main`), LPLR, PLPR,
the `pava` core, the cluster sandwich, `set_sample_splitting`, and `fuzz`.
LPLR/PLPR and the cluster sandwich are the two open decisions; the other eight
are unblocked.

## Four of the five are gateable today, with these call shapes

| estimator | upstream | call shape that works | exposes |
|---|---|---|---|
| PQ | `dml.DoubleMLPQ` | `(data, CLASSIFIER, CLASSIFIER, treatment=1, quantile=0.5, n_folds=2)` | `coef`, `se` |
| QTE | `dml.DoubleMLQTE` | `(data, CLASSIFIER, CLASSIFIER, quantiles=[.25,.5,.75], n_folds=2)` | `coef` (3,), `se` (3,) |
| LPQ | `dml.DoubleMLLPQ` | `(data_with_Z, CLASSIFIER, CLASSIFIER, treatment=1, quantile=0.5)` | `coef`, `se` |
| RDD | `doubleml.rdd.RDFlex` | not yet probed | not yet probed |
| PolicyTree | `dml.DoubleMLPolicyTree` | `(ndarray signal, DataFrame features, depth=2, **tree_params)` | **no `coef`/`se`** |

PQ, QTE and LPQ were each fitted and returned finite coefficients and standard
errors. Upstream's `normalize_ipw` defaults to **True** on all three; the
port's default was measured to be the opposite
(`_verify/NORMALIZE_IPW_1550.md`), so both sides must state it explicitly or a
gate would compare two different configurations.

## Three traps, each of which cost an iteration

**1. PQ/QTE/LPQ need BOTH learners to be classifiers, and the names lie.**
`pq.py:174-175` calls `_check_learner(ml_g, ..., classifier=True)` and then the
same for `ml_m`. The argument NAMES are inherited from the PLR family, where
`ml_g` is the OUTCOME learner and `ml_m` the propensity. In the quantile
estimators the roles are swapped and the names did not follow, so passing them
the intuitive way raises

    TypeError: Invalid learner provided for ml_g: LinearRegression()
               has no method .predict_proba().

**2. `RDFlex` exists but is not exported at the top level.** `dml.RDFlex` and
`dml.DoubleMLRDD` are both `False` in 0.11.3; the class is at
`doubleml.rdd.RDFlex`. The README's "upstream calls it RDFlex" is correct — but
a probe that only checks `hasattr(dml, name)` reports a class that is present
as missing. This is the same shape as the earlier `examples/parity` probe that
resolved the published package instead of local source: the thing existed, and
the instrument could not see it.

**3. `inspect.signature` renders `**kwargs` exactly like a named parameter.**
`DoubleMLPolicyTree.__init__` is

    def __init__(self, orth_signal, features, depth=2, **tree_params)

so `tree_params` is a catch-all that is splatted straight into
`DecisionTreeClassifier`. The printed signature says `tree_params` as though it
took a dict, and passing `tree_params={...}` gives

    TypeError: DecisionTreeClassifier.__init__() got an unexpected keyword
               argument 'tree_params'

A probe that trusts its own printed signature builds the wrong call. Same
family as the `alias_elimination!` line-number incident: **a call site reads as
though it defined the callee.**

## PolicyTree has no coefficient to compare

Confirmed by fitting one: it exposes `policy_tree`, `orth_signal`, `features`
and `summary`, and no `coef` or `se`. Upstream's `DoubleMLPolicyTree` does not
fit an estimator — it splits on an orthogonal signal. The port reports a
`coef`/`se` and uses different defaults (`depth=1, min_leaf_n=5` against
upstream's `depth=2, min_samples_leaf=8, ccp_alpha=0.01`). A gate here can
only compare the ROOT SPLIT (which feature, which threshold) and the
per-leaf linear value. That is a real comparison, and it is not the same
comparison the other gates make.

## Reproduce

**There is nothing to run.** The three scripts this section used to name --
`_five_api_1680.py`, `_five_fit_1680.py` and `_coverage_census_1680.py` --
were never committed to this repository, and they are not in its history
either (`git log --all -- _verify/_five_api_1680.py` is empty). The numbers
above are therefore a one-off measurement, not a reproducible one, and this
section says so rather than pointing at files that do not exist.

What supersedes it: the three gates the measurement led to, each of which
re-derives its own numbers on every run --
`pyexample_pq.py` (PQ, QTE, LPQ), `pyexample_policytree.py` (PolicyTree) and
`pyexample_rdd.py` (RDD).

Measured on `doubleml` 0.11.3, Windows, 2026-10-16.
