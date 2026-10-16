# PQ / QTE are gateable — but not on the DGP I first wrote

**Status: design settled, bands measured, gate not yet built.** The two
estimators are different quantities, and the DGP has to carry a real treatment
effect before either one means anything. Both facts were found by measurement.

## Two estimators, two truths

| | estimand | true value on this DGP | measured (upstream, seed 3141) |
|---|---|---|---|
| `DoubleMLPQ` at `quantile=q` | quantile of the **treated outcome** | `1.0 + median(confounders)` | 0.7700 / 1.0163 / 1.2697 at q=0.25/0.5/0.75 |
| `DoubleMLQTE` at `quantiles=[q]` | quantile **treatment effect** | `1.0` at every level | 1.0534 / 1.0082 / 0.9889 |

The index mapping is fine: `est.quantiles` echoes `[0.25, 0.5, 0.75]` back, and
`coef` is in that order. Verified rather than assumed, because an index mapping
that is wrong compares the wrong numbers on both sides and still looks like a
pass.

## The DGP bug that made QTE look broken

My first DGP was `y = 1.0 + 0.5*x1 + 0.3*x2 + 0.25*e` — **no `d` term**, so the
true treatment effect was exactly zero. `DoubleMLPQ` still looked right (it
estimates the treated outcome, ~1.02 against a treated-sample median of 1.126)
while `DoubleMLQTE` returned `[0.0534, 0.0067, -0.0096]` and read as broken.

It was not broken. QTE is an *effect* estimator, and on a zero effect the answer
~0 is the correct answer. Adding `1.0 * d` moved QTE to `[1.0534, 1.0082,
0.9889]` — all three ≈ 1.0, the true effect.

⇒ **A gate on an estimator whose estimand you have not written down will look
like a defect report.** `examples/parity`'s section 1 records the same shape for
the rank-2 design; this is its sibling.

## The other DGP bug: a "deterministic" draw can still be degenerate

The first uniform draw was `(i * 48271) % 2147483647`, which never wraps for
`i < 1000` and steps by a constant. It correlates with the `x` columns
(themselves `(i * 7919) % 1000` and `(i * 6271) % 997`), `d` came out blocky,
and every upstream fit died with

    ValueError: This solver needs samples of at least 2 classes in the data,
                but the data contains only one class

Replaced with `(i * 104729 + 12345) % 999983`: 447 treated / 553 control, halves
204/296 and 243/257. `_pq_tol_1680.py::balance()` now prints that split so the
next reader does not rediscover it from a stack trace.

Integer-only draws are deliberate — CPython and MoonBit reproduce them exactly,
so the two sides build identical arrays with no RNG library and no cross-language
stream mismatch.

## Measured bands

Within-process, 12 fits, re-seeded before each (`np.random.seed`, since
upstream's `check_random_state(None)` returns the process-global RandomState):

| quantity | mean | sd | 3 sd | \|v\|/sd |
|---|---|---|---|---|
| `pq_coef` | 1.016169 | 2.803e-03 | 8.408e-03 | 362.6 |
| `pq_se` | 0.0197531 | 2.365e-04 | 7.096e-04 | 83.5 |
| `qte[1] coef` | 1.008220 | 2.924e-03 | 8.773e-03 | — |
| `qte[1] se` | 0.0211404 | 2.266e-04 | 6.798e-04 | — |

Across-process, 6 fresh interpreters at a fixed seed: **`sd = 0.000e+00`**,
bit-identical to 16 digits on both `coef` and `se`.

## This CORRECTS `_verify/NORMALIZE_IPW_1550.md`

That file records that "upstream's `DoubleMLPQ` is not reproducible across
processes at a fixed seed", quoting b=1.5 giving `1.0443004914653655` and then
`1.0354613542323716` — a drift of **8.8e-3**, "larger than the 7.53e-03 branch
gap being measured" — and attributes it to `_default_kde` without testing that.

**It does not reproduce here: the cross-process drift is exactly zero.** The
attribution is consistent with what is observed: `_default_kde` applies to the
density-based PQ score, and this configuration is `score='PQ'` (IPW) with
`kde=None`, so the suspected mechanism is not in play. The honest statement is
that the mechanism is untested and the drift is absent in the IPW path — not
that upstream is reproducible in general. Whether the KDE path drifts remains
open.

## What the gate has to state explicitly

* `normalize_ipw` — upstream defaults it **True** on PQ and QTE; the port has no
  such field (`quantile.mbt:478`) and never normalizes. On a well-behaved
  propensity that gap was measured at `3.80e-13` (machine precision), and this
  DGP keeps the propensity in `[0.15, 0.85]` for exactly that reason — the gate
  would otherwise be testing the known flag gap rather than the estimator.
* `trimming` — upstream's `trimming_threshold = 0.01` against the port's
  `propensity_clip = 1.0e-6`. `_verify/NORMALIZE_IPW_1550.md` identifies this as
  the likely DOMINANT source of the port-vs-upstream gap (0.39 on an extreme
  fixture, of which `normalize_ipw` accounts for ~2%) while stating that the
  explanation is a hypothesis and was never tested.
* both learners must be classifiers upstream; the port's `DoubleMLPQ::new`
  defaults `ml_l` to a REGRESSOR, so both sides need spelling out.

Reproduce:

    python _verify\_pq_tol_1680.py            # DGP, balance, within-process bands
    python _verify\_pq_tol_1680.py --across 6 # cross-process, and the correction
    python _verify\_qte_shape_1680.py         # the two estimands side by side

Measured on `doubleml` 0.11.3, Windows, `n=1000`, `p=2`, `n_folds=2`, `n_rep=1`.
