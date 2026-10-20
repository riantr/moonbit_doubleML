# `n_folds_inner` — measured, default #6 — and a much worse thing it uncovered

> **Re-audited 2026-10-20 against the `v0.164.9` tree, and now TRACKED.**
> Written in the v0.155.0 round; cited by `_verify/N_FOLDS_1570.md` and
> `_verify/IN_SAMPLE_NORMALIZATION_1570.md`, which lean on its "the 4 was the
> right number" finding. Until this round it was an untracked local file, so
> those two citations were promises a reader could not check.
> Method (shipped, tracked): `_verify/_audit_r15_defaults_1650.py`.
>
> | pointer | as written | now (`v0.164.9`) |
> |---|---|---|
> | upstream `n_folds_inner = 5` | `lplr.py:116` | `lplr.py:116` — **unchanged**, re-checked in the installed 0.11.3 |
> | upstream guard `n_folds_inner < 2` | `resampling.py:40-42` | `resampling.py:40-42` — **unchanged** |
> | upstream use `for i in range(self.n_folds_inner)` | `lplr.py:212` | `lplr.py:212` — **unchanged** |
> | upstream forward per outer fold | `double_ml_sampling_mixins.py:48` | `double_ml_sampling_mixins.py:48` — **unchanged** |
> | port `DoubleMLLPLR::new` | `lplr.mbt:352` | `lplr.mbt:352` — **unchanged** |
> | port `require(n_folds_inner >= 2)` | `lplr.mbt:361` | `lplr.mbt:361` — **unchanged** |
> | port inner cross-fit | `lplr.mbt:776` | `lplr.mbt:776` — **unchanged** |
> | the LPLR recovery gate | `dgp_lplr_test.mbt:41-49` | `dgp_lplr_test.mbt:41` — **unchanged** |
> | upstream source of truth | the **untracked** vendored 0.11.4 tree | the **installed** `doubleml` 0.11.3 — every line this record cites resolves there, at the same line, with the same content |
>
> **What is NOT verified here.** No estimator was re-run. The seed-555 numbers,
> the 2-seed-vs-8-seed comparison and the control are quoted from the original
> record and were not reproduced. The `probe_v1550ok3/ok4` probes were deleted
> after the run and are **not** recoverable; their output is transcribed above.

**Measured, not recalled.** Upstream read from the **installed**
`doubleml` — `plm/lplr.py`, `utils/resampling.py` and
`double_ml_sampling_mixins.py`. Port sites read from `lplr.mbt`. Numbers from
`probe_v1550ok3/ok4` (deleted after the run).

> Version caveat, as in the two sibling documents: installed `doubleml` is
> **0.11.3**, and a vendored **0.11.4** tree was used when this was written.
> Every line this record cites was re-checked in the installed 0.11.3 on
> 2026-10-20 and resolves at the same line with the same content, so the
> citations are anchored to the installed package — which a reader can obtain
> with `pip install doubleml`. The vendored tree is a local convenience copy
> and is **not tracked**.

## The default itself

| | upstream | port |
|---|---|---|
| value | **5** (`lplr.py:116`) | **2** (`lplr.mbt:352`) |
| guard | `n_folds_inner < 2` raises (`resampling.py:40-42`) | `require(n_folds_inner >= 2)` (`lplr.mbt:361`) — **same bound** |
| use | `for i in range(self.n_folds_inner)` (`lplr.py:212`), forwarded per outer fold (`double_ml_sampling_mixins.py:48`) | passed to the inner cross-fit (`lplr.mbt:776`) — **same use** |

**The parameter is live.** Declared control: the estimate must move. Measured
max consecutive `|coef gap|` across `n_folds_inner` 2→3→4→5 = **0.1246**, and
max `|se gap|` = **0.1128**. Control passed — this is not an inert knob.

**`n_folds_inner = 5` is attainable, unlike `n_folds = 5`.** This is the
structural difference worth recording. `n_folds` binds against a DIDCS *cell*
with 4 rows and aborts at 5; `n_folds_inner` binds against the outer
*training slice* (~250 rows at n=500), so upstream's own 5 runs fine.

## Do NOT read the 2-seed result as the answer — I nearly did

Two seeds gave a clean monotone story, and it looked decisive:

```
seed=3141  k=2 0.46411  k=3 0.47998  k=4 0.48593  k=5 0.48713   (truth 0.5)
seed=7     k=2 1.31177  k=3 1.26261  k=4 1.20613  k=5 1.18718
```

Both move monotonically **toward** 0.5 as k rises. From two seeds I would have
written "upstream's 5 is strictly better". Eight seeds say otherwise, because
one of them ruins the aggregate:

```
k=2  mean|err| = 69685.16894790482  max|err| = 557479.2119611416
k=3  mean|err| = 69773.68710197211  max|err| = 558187.5074363189
k=4  mean|err| = 69782.83936657711  max|err| = 558260.8282587449
k=5  mean|err| = 69813.19306792872  max|err| = 558503.6752913339
```

`557479.21 / 8 = 69684.90` — **one seed supplies the entire mean.** With that
seed removed, the seven healthy seeds do restore the original ordering:

| k | mean \|err\| (7 healthy seeds) | seeds better than k=2 |
|---|---|---|
| **2** (port default) | **0.3057** | — |
| 3 | 0.2842 | 5/7 |
| 4 | 0.2695 | 5/7 |
| **5** (upstream) | **0.2671** | 5/7 |

So the direction survived, but **2 seeds was not enough to know that**, and the
8-seed summary as printed is actively misleading. Any verdict on this default
has to state which seeds it excludes and why.

## The real finding: seed 555 returns garbage, at every fold count

```
seed=555  k=2  coef=-557478.7119611416  se=153199.75615763792
seed=555  k=3  coef=-558187.0074363189  se=141292.89283339056
seed=555  k=4  coef=-558260.3282587449  se=140243.60407083237
seed=555  k=5  coef=-558503.1752913339  se=136956.5158562339
```

`make_lplr_LZZ2020(500, 0.5, 555)` has true θ = 0.5. The estimator returns
**−5.57 × 10⁵**, a relative error of ~1.1 × 10⁶, and returns it as a finite,
non-NaN `Double` with no abort and no warning.

Four things make this worse than a bad number:

1. **It is independent of `n_folds_inner`** — all four fold counts agree to 4
   significant figures. Whatever breaks is not a fold-assignment effect, so the
   inner-fold count cannot be tuned around it.
2. **The SE responds while the point estimate does not.** `se` moves
   153,199 → 136,957 (−10.6%) across k while `coef` stays at ≈ −5.57e5. The
   variance path is alive; the point estimate is not.
3. **The package's only LPLR recovery gate cannot see it.**
   `dgp_lplr_test.mbt:41-49` pins `seed=3141` and asserts
   `theta_hat.abs() < 100.0`. Seed 555 misses that bar by four orders of
   magnitude — but that gate never evaluates that seed. The loose bound is
   explicitly justified in the comment as absorbing "fold-RNG noise"; it is
   wide enough to pass a coefficient that is wrong by a factor of a million.
4. **The other seven seeds are healthy** (0.0129 – 0.8118, sensible SEs), so
   nothing else in the DGP looks pathological.

## What is NOT established

- **Why** seed 555 breaks. Not investigated. A first guess would be a
  degenerate `m_hat` on one of the outer folds — the LPLR score divides by `m`,
  and a near-zero propensity produces exactly this shape of blow-up — but that
  is a hypothesis, not a measurement, and it is not asserted here.
- Whether upstream's `DoubleMLLPLR` does the same thing on this DGP. **No
  Python oracle was run.**
- Whether seed 555 is a property of `make_lplr_LZZ2020` or of `DoubleMLLPLR`.
  Distinguishing those needs the oracle.

## Verdict

- **On the default:** no change recommended yet. Upstream's 5 is attainable and
  is the better of the two on the seven healthy seeds, but the fixture has a
  seed that breaks the estimator by six orders of magnitude, and that has to be
  understood before a default is moved on the strength of a mean.
- **On seed 555:** this is tripwire-grade. Pinning the measured number, marked
  *invert, don't delete*, would stop it changing silently; and the LPLR recovery
  gate's seed-pinning plus its `abs() < 100.0` bound is a genuine coverage gap.
  Both are behaviour-preserving.
- Neither is done here. The release is still sitting unauthorized, and adding
  gates changes the test counts that `README.mbt.md` and `CHANGELOG.md` pin.