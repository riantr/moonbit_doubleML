# RDD is gateable to probe but not to gate: the port's `se` is 3.3x upstream

_1680 series. This closes the "RDD: not yet probed" row in
`FIVE_GATES_FEASIBLE_1680.md` — in the direction of recording a measured
divergence rather than building a gate._

## The dependency, first

Upstream `RDFlex` will not run at all without `rdrobust`:

```
ImportError: rdrobust is not installed. Please install it using 'pip install DoubleML[rdd]'
```

`pip install --dry-run` showed three new packages: `rdrobust`, `plotnine`,
`mizani` — the latter two are rdrobust's *plotting* dependencies, which a
gate never touches. CI installs `doubleml numpy pandas statsmodels
scikit-learn`, so gating RDD means adding a dependency to the workflow for
a slot whose numbers do not agree anyway.

## Four call-shape traps, each measured

Every one of these was found by running, not by reading.

1. **The class is not exported at the top level.** `dml.RDFlex` and
   `dml.DoubleMLRDD` are both `False` on 0.11.3. The class is at
   `doubleml.rdd.RDFlex`. A probe that only checks `hasattr(dml, name)`
   reports a present class as missing.
2. **It takes a `DoubleMLRDDData`, not a `DoubleMLData`.** A plain
   `DoubleMLData` is rejected in `_check_data` (`rdd.py:503`).
3. **`score_col` must be disjoint from `d_cols`.** Passing the running
   variable as both raises at `_check_disjoint_sets_score_col`
   (`base_data.py:785`). `d` is the binary assignment, `score` the
   continuous running variable.
4. **`bw` is not a kwarg.** `RDFlex(**kwargs)` forwards to
   `rdrobust.rdrobust`, whose bandwidth arguments are `h` and `b`:
   `TypeError: rdrobust() got an unexpected keyword argument 'bw'. Did you
   mean 'b'?` Unlike PolicyTree's `tree_params`, `**kwargs` here genuinely
   forwards — it just forwards to different names.

Also: `rdrobust_output` has **no `RD` attribute**. The estimates are
`tau_T`, `tau_bc`, `tau_cl`.

## Determinism

| | behaviour |
|---|---|
| upstream, unseeded | **non-deterministic** — spread 2.99e-02 across four fits in one process |
| upstream, `np.random.seed(3141)` | exactly reproducible — 0.000e+00 |
| port | no `seed` label at all; deterministic by construction |

Same process-global-seeding pattern as PQ/QTE, so a gate would have had to
seed upstream explicitly. Upstream's seed spread over 6 seeds:
`coef` sd 0.008583.

## The measured divergence

Same design, integer-only so both sides build identical rows: `n=400`,
`x1`, `x2` as before, running variable `u = (i-200)/40`, `d = 1[u>0]`,
`y = 1 + 0.5*x1 + 0.3*x2 + 0.75*d + 0.2*x1*x2` (true `tau = 0.75`).

| | port | upstream (mean of 6 seeds) |
|---|---|---|
| `coef` | 0.658475 (bw=1.0) | 0.688669, sd 0.008583 |
| `se` | **0.020965** | **0.069081** |

The coefficient alone is borderline — 0.030 apart against a 3-sigma band of
0.0257. The standard error is not borderline at all: **3.3x**.

And no bandwidth setting repairs both. The port's `se` scales as `1/bw`:

| bw | port `coef` | port `se` | |gap| vs upstream coef |
|---|---|---|---|
| 0.5 | 0.602144 | 0.042462 | 0.0865 |
| 1.0 | 0.658475 | 0.020965 | 0.0302 |
| 2.0 | 0.707157 | 0.010491 | 0.0185 |

Matching `se` requires `bw ≈ 0.3`, where the coefficient is ~0.087 away.
Matching the coefficient needs `bw ≈ 2.0`, where `se` is off by 6.6x. The
`1/bw` scaling is an analytic local-linear standard error; upstream's comes
from `rdrobust`'s estimator. **These are not the same estimator's variance.**

## Follow-up: why "swap the SE" cannot be the fix

The section above measures a 3.3x gap on a two-column design and never
re-examines it on a design built to answer the question. Two things were found.

**`sec_rdd` cannot answer it.** Its design is exact --
`y = 2 + u + 0.5*z + 2*d`, no noise -- so every residual is zero. Measured:

```
sharp_se_hc0 = 0.000000000
fuzzy_se_hc0 = nan
```

A variance formula cannot be compared where the variance is identically zero:
that design "agrees" with any formula, including a wrong one. The new section
`sec_rdd_var` uses an integer-only **noisy** design (n=800, modulo noise) and
emits both `cov_type` arms, so CPython rebuilds identical rows with nothing
transmitted.

Bandwidth 0.5, triangular kernel, same rows:

| | coef | se |
|---|---|---|
| port, homoskedastic (default) | 2.000000005 | 0.003535472 |
| port, HC0 | 2.000000005 | **0.000000000** |
| upstream, conventional | 2.148600465 | 0.092729567 |
| upstream, bias-corrected | 2.068653420 | 0.136825728 |

Port/upstream SE ratios: **0.038** conventional, **0.026** bias-corrected.

**The sign of the divergence is not stable across designs** -- 3.3x smaller on
the old design, 26-39x smaller here. So it is not a scale factor to tune; it is
design-dependent, which is what a formula difference looks like.

### Three findings, in order of how much they change the decision

**1. Upstream's estimator is BIAS-CORRECTED and the port's is not.** `rdrobust`
reports both arms and defaults to the corrected one. The true jump here is
exactly 2.0: the port recovers `2.000000005` while `rdrobust` reports
`2.148600` / `2.068653`.

So the two sides are not estimating the same functional, which is exactly why
no bandwidth repaired both. **Matching upstream is therefore not an SE change.**
It needs Calonico-Cattaneo-Titiunik local bias correction on the *point
estimate* -- a different estimator, not a different variance.

Call-shape notes, all found by running: `rdrobust(y, x, c=...)` has **no `d=`**
(a sharp design is `c` plus a derived `d`); there is **no `biascorr` flag** in
2.1.1 (`subset` is an observation subset); top-level `tau_T`/`se_T` are `None`;
`tau_bc` is a per-side **list**, so `float()` on it raises. The usable handle is
`o.Estimate`, columns `tau.us` / `tau.bc` / `se.us` / `se.rb`. It is unseeded --
measured spread 2.99e-02 over four fits in one process -- so `np.random.seed`
must be set.

**2. The port's HC0 arm returns EXACTLY 0.0 on both designs.** On `sec_rdd_var`,
where `homo_se = 0.003535472` on the *same rows with non-zero residuals*. An SE
of precisely zero is never legitimate and it is not caused by anything upstream
does. The accumulator is `sum_k w_k^2 * m_k^2 * e_k^2` (`linear.mbt:319`), so
the zero means one of `w`, `m_k`, `e_k` is identically zero on that path --
and `sandwich_se_weighted` builds `X^T X` **unweighted** where its docstring
says `X^T W X`. A separate defect with its own merit; the root cause is **not
yet diagnosed**, so it is recorded rather than guessed at.

**3. The RDD work is therefore a re-specification**, not a parity edit: bias
correction + a robust variance + the HC0 defect. That is the user's call.

## Decision: no RDD gate

A gate built on this would be permanently red, which is worse than
recording the defect — it is either a failing CI or an `--allow-inert`
mute. So RDD is recorded as a **measured divergence**, which is a real
advance over "not yet probed".

What it would take:

1. reconcile the variance estimators — the port's analytic `1/bw` against
   `rdrobust`'s — which is an estimator change, not a gate;
2. decide the bandwidth policy: the port takes a fixed `bandwidth`, upstream
   auto-selects (`bwselect='mserd'`). A gate would have to pin both, and
   "pin both" is only meaningful once they agree;
3. only then add `rdrobust` to CI.

Upstream's `coef` also has a 3-element `[different, equal, equal]` structure
matching `tau_T`, where the port exposes a scalar. Element 0 is the
comparable one; the other two are ADRF-style variants the port does not
report at all.

## Side effect worth stating

`rdrobust` (with `plotnine` and `mizani`) was installed into the local
Python environment to take these measurements. Nothing in the repository,
CI, or the test suite depends on it, and `examples/parity` carries no RDD
section — the probe was removed, not committed. Uninstall with
`pip uninstall rdrobust plotnine mizani` if the environment should not keep
it.

Reproduce:

    python _verify\_rdd_api_1680.py        # the export trap and the signature
    python _verify\_rdd_fit_1680.py        # the data-shape traps
    python _verify\_rdd_determinism_1680.py  # seeding, and the seed spread
