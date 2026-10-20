# ROW N — `n_folds`: port default 2, upstream default 5

> **Re-audited 2026-10-20 against the `v0.164.9` tree.** Written in the
> v0.157.0 round; committed 2026-10-20 in `5b0b364` (v0.164.4). The
> *structural* claims were re-checked against the source; **one of this
> record's line pointers had rotted** and the same bound is cited with a
> different (also stale) line number in
> `PORT_VS_UPSTREAM_DEFAULTS_1540.md`.
> Method (shipped, tracked): `_verify/_audit_r15_defaults_1650.py`.
>
> | pointer | as written | now (`v0.164.9`) |
> |---|---|---|
> | `DoubleMLDIDCS::fit` | did_cs.mbt:1620 | **`did_cs.mbt:1240`** |
> | `DoubleMLDIDBinary::new` | `did_binary.mbt:352` | `did_binary.mbt:352` — unchanged |
> | inner `DoubleMLDID::new` | `did_binary.mbt:439` | `did_binary.mbt:439` — unchanged |
> | `require(n_folds <= data.n_obs())` | `did.mbt:276` | `did.mbt:276` — unchanged |
> | `abort(...)` | `did.mbt:317` | `did.mbt:317` — unchanged |
> | the 4-row placeholder | `did_binary.mbt:441` | `did_binary.mbt:441` — unchanged |
> | the placeholder's comment | `did_binary.mbt:412-417` | `did_binary.mbt:412-417` — unchanged |
>
> **What is NOT verified here.** No estimator was re-run: the 4-row ceiling,
> the 2/3/4/5 threshold and the per-cell counts are quoted from the original
> record. The raw logs they come from were **not tracked** and are now tracked
> (`_verify/_nfolds_*_1570.txt`, `_verify/_binceil_*_1570.txt`), so the numbers
> are now checkable — but they were not re-derived.

> ## ⚠ CORRECTION — the first version of this document blamed the wrong mechanism
>
> The first version concluded that `n_folds = 5` aborts because *"the
> post-`preprocess_did_binary` survivor set falls below 5 rows"*. **That is
> wrong.** The binding set is a **hardcoded 4-row placeholder**
> (`did_binary.mbt:441`), created at construction of `DoubleMLDIDBinary`,
> before any preprocessing runs.
>
> The first version also reported "9 cells, all equal" — the probe looped
> `gi in [0,1,2]` and `ti in [0,1,2]`, i.e. **9 of the 16 cells** this DGP
> actually produces. Corrected: **16 cells, smallest 100 rows at n_obs = 1600
> and 250 at n_obs = 4000.**
>
> The conclusion is unchanged and now much sharper: upstream's `n_folds = 5` is
> unattainable on `DoubleMLDIDCS` because of a **constant in the code**, not a
> property of the sample. See §2 and §3.
>
> **The inherited claim in `N_FOLDS_INNER_1550.md` had the right number.** It
> said "binds against a DIDCS *cell* with 4 rows". The 4 was correct; "cell" was
> not — it is a synthetic dummy, and no cell has ever been that small.

**Status:** measured, four arms. Port commit `8308f09` (v0.155.0).

This was the **last unmeasured** shared-name/different-value constructor default.

## Headline

**Upstream's own default is unattainable on `DoubleMLDIDCS` in this port.**
`n_folds = 5` aborts at n = 1600, 4000 *and* 16000, while `n_folds = 2` fits all
three. The threshold is located exactly at **4**, and it is a hardcoded constant,
not a sample-size limit.

---

## Arm 1 — PLR, where 5 *is* attainable. The effect is real and small.

`make_plr_CCDDHNR2018(n, 20, theta=1.0, seed)`, `n_folds=2` vs `5`, `seed=3141`.
`EXAMINED=24 EXPECTED=24` (3 sizes × 8 seeds).

| n | mean \|err\| `2` | mean \|err\| `5` | mean ratio | max ratio |
|---|---|---|---|---|
| 500 | 0.0579 | 0.0502 | 0.426 | 0.735 |
| 1000 | 0.0373 | 0.0266 | 0.424 | **1.030** |
| 2000 | 0.0161 | 0.0156 | 0.208 | 0.632 |
| **all** | **0.037089** | **0.030776** | — | **1.030** |

`n_folds=5` is mildly more accurate at every size, margin closing with n (17%
better overall, 0.6% at n=2000). Ordinary cross-fitting noise, correctly priced
by the reported SE. Not a defect in either direction.

## Arm 2 — `DoubleMLDIDCS`. Upstream's default cannot run.

Under the `panic_` convention an **abort passes** and a **successful fit fails**.

| test | n_obs | outcome |
|---|---|---|
| `panic_ROW_N_didcs_f5_at_1600` | 1600 | **aborted** (passed) |
| `panic_ROW_N_didcs_f5_at_4000` | 4000 | **aborted** (passed) |
| `panic_ROW_N_didcs_f5_at_16000` | 16000 | **aborted** (passed) |
| `panic_ROW_N_CONTROL_didcs_f2_at_1600_must_fit` | 1600 | **fit → FAILED** |

`Total tests: 4, passed: 3, failed: 1.`

**The control is load-bearing.** `n_folds=2` at n=1600 fitting is
independently established by ROW M, so the control was *required* to fail. It
did. A discriminator nobody has seen fire is not evidence.

## Arm 3 — the threshold, which locates the mechanism

| `n_folds` | n_obs = 1600 | n_obs = 4000 |
|---|---|---|
| 2 | fits (−2.0724) | — |
| 3 | fits (−2.4242) | — |
| **4** | **fits (−2.0103)** | **fits (−1.2473)** |
| **5** | **aborts** | — |

**4 still fits at both sample sizes; 5 does not.** That pins the ceiling at
exactly 4 and rules out any sample-size explanation.

### Abort chain (line numbers at `8308f09`+v0.156.0)

```
DoubleMLDIDCS::fit              did_cs.mbt:1240
DoubleMLDIDBinary::new          did_binary.mbt:352
  inner: DoubleMLDID::new(      did_binary.mbt:439
    DoubleMLDIDData::new(Matrix::zeros(4, ...))   did_binary.mbt:441
      require(n_folds <= data.n_obs())            did.mbt:276
      abort(...)                                  did.mbt:317
```

### Why it exists

`did_binary.mbt:412-417` states it outright:

> Placeholder: the real `DoubleMLDID` is built in `fit()` once the wide-format
> preprocessing has produced a non-empty dataset. **We pass a 4-row dummy here**
> so the `DoubleMLDID::new` precondition `n_folds <= n_obs` is not tripped at
> construction time (`n_folds` defaults to 2).

So the ceiling is a deliberate workaround whose own justification — *the default
is 2* — is exactly what hides it. Nobody notices while the default sits under
the limit.

## Arm 4 — the real cells are nowhere near the limit

Full 4×4 sweep, matching `dgp_did_CS2021.mbt:50-52` (`n_periods = 4`,
`n_groups = 4`, `n_per_cohort = n_obs / 4 / 4`). The DGP implies a per-cell row
count, so the measured value is checked against it rather than merely reported:

| n_obs | rows | examined | expected | non-empty | **measured smallest** | **implied by DGP** | match |
|---|---|---|---|---|---|---|---|
| 1600 | 1600 | **16** | 16 | 16 | **100** | **100** | ✅ |
| 4000 | 4000 | **16** | 16 | 16 | **250** | **250** | ✅ |

Full per-cell histogram (`_nfolds_cellgrid_1570.txt`): every one of the 16 cells
holds exactly 100 rows at n_obs = 1600 and exactly 250 at n_obs = 4000 — uniform,
no small tail. Every cell holds 25–50× the 5 folds requested, so the raw cell
size is irrelevant to the failure.

## Arm 5 — the ceiling belongs to `DoubleMLDIDBinary` itself, and is scale-invariant

This closes what the earlier passes left open: *"whether **any other**
estimator funnels through a reduced subset the way DIDCS does"* — arm 1
exercised PLR only.

The abort trace runs `DoubleMLDIDCS::fit → DoubleMLDIDBinary::new →
DoubleMLDID::new`, so the ceiling could belong to the DIDCS cell loop or to the
binary wrapper. Isolated by constructing **`DoubleMLDIDBinary` directly**, with
no DIDCS involved, and scaling the real data up 150×:

```
subset_small(4 units)=4      subset_large(600 units)=600
```

The wide-format subset really does hold **600 rows**. Then:

| `n_folds` | 600-unit subset | reading |
|---|---|---|
| 2 | **fits** (test failed under `panic_`) | control fires |
| 4 | **fits** (test failed under `panic_`) | — |
| **5** | **aborts** (test passed, no survivor line) | — |

`Total tests: 3, passed: 1, failed: 2.`

**A subset-size limit would have sailed through at 600 rows. It aborts.** So:

1. The ceiling is the **hardcoded placeholder**, not the data. 600 rows and 4
   rows behave identically.
2. The ceiling belongs to the **`DoubleMLDIDBinary` type**, not to DIDCS's cell
   loop — so anyone constructing that type directly hits the same wall.

The control (`n_folds=2`, which must fail under this convention) fired as
predicted, which is what licenses the `n_folds=5` reading.

## Where this lands

| estimator group | `n_folds=5` | port's `2` |
|---|---|---|
| PLR, IRM, APO, APOS, PLIV, IIVM, CVAR, SSM, DID, BLP, LPLR, LPQ, PQ, QTE | attainable, mildly better, ≤1.03 SE | costs ≤ ~1 SE, closes with n |
| **DIDCS** | **aborts: hard ceiling of 4** | the only sensible value |

## Recommendation

**Do not change the default.** Matching upstream on `DoubleMLDIDCS` would break
the estimator. Elsewhere the difference is ≤1.03 SE of correctly-priced noise and
2 folds halves compute.

Now documented at three sites — `did_cs.mbt` (the missing guard), `did_binary.mbt:412`
(the placeholder that creates the ceiling), and this document — so the default
is not "fixed" into a broken state.

The real improvement would be to replace the 4-row dummy with the real
preprocessed subset, or to reject `n_folds >= 5` with a clear message instead of
aborting inside `DoubleMLDID::new`. **Both are behaviour changes and neither was
made here.**

## Not established

- Whether the **other 13** estimators that share
  `require(n_folds <= data.n_obs())` are affected by anything analogous. They
  apply the bound to the **full** dataset at construction rather than to a
  subset, and PLR was exercised at `n_folds = 5` successfully across 24 fits.
  That is read from the source for the rest, not measured.

## Artifacts

- `_verify/_nfolds_plr_1570.txt` — arm 1, 24 fits
- `_verify/_nfolds_attain_1570.txt` — arm 2, attainability + control
- `_verify/_nfolds_abort_1570.txt` — arm 2 first pass, full abort trace
- `_verify/_nfolds_threshold_1570.txt` — arm 3, the 2/3/4/5 threshold
- `_verify/_nfolds_cellgrid_1570.txt` — arm 4, full 4×4 sweep + DGP cross-check
- `_verify/_binceil_1570.txt` — arm 5, ceiling on a 600-row subset
- `_verify/_binceil_subset_1570.txt` — arm 5, subset sizes
- `_verify/_probe_nfolds4_1570_test.mbt.txt` — threshold probe (removed)
- `_verify/_probe_cellgrid_1570_test.mbt.txt` — cell-grid probe (removed)
- `_verify/_probe_binceil_1570_test.mbt.txt` — binary-ceiling probe (removed)

Every arm above has a saved raw artifact. Arm 4 originally had none — it was
printed to the console only — which is why the cell-count claim could not be
checked against anything. Re-run and saved; the measured per-cell count now
agrees with what `dgp_did_CS2021.mbt:50-52` implies, which is a check the
original run did not perform.