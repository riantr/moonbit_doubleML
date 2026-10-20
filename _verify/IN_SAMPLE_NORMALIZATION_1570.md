# ROW M — `in_sample_normalization`: port default `false`, upstream default `True`

> **Re-audited 2026-10-20 against the `v0.164.9` tree. §5's headline is
> WITHDRAWN.** Written in the v0.157.0 round; committed 2026-10-20 in `5b0b364`
> (v0.164.4).
>
> §5 point 5 reads *"the port's `DoubleMLDIDCS` is ~20× more sensitive to this
> flag than upstream is"*. It is built by comparing Arm 2 — the port's **panel**
> `DoubleMLDIDCS`, on the `make_did_CS2021` fixture — against Arm 4 — upstream's
> `DoubleMLDIDCS`, on the `make_did_SZ2020(..., cross_sectional_data=True)`
> fixture. **Those are two different estimators that share a name, measured on
> two different fixtures.** Upstream's `DoubleMLDIDCS` is the *repeated
> cross-sections* estimator (`did/did_cs.py`: *"Double machine learning for
> difference-in-difference with repeated cross-sections"*) — the counterpart of
> the port's `DoubleMLDIDCrossSection`, not of the port's `DoubleMLDIDCS`.
> The like-for-like pair is **Arm 1 against Arm 4**: the port's cross-section
> estimator against upstream's, on the **same** fixture — **0.039 SE vs 0.048
> SE**. The port is *less* sensitive there, not 20× more. See §9.
>
> Method (shipped, tracked): `_verify/_audit_r15_defaults_1650.py`.
>
> | | as written | now (`v0.164.9`) |
> |---|---|---|
> | the 49 / 42 / 7 constructor-divergence triple | asserted | **not reproducible** from the two sources it names, under any of six scopings — replaced by §10 |
> | the port's `in_sample_normalization` default | `false` at 6 sites | `false` at 6 sites — unchanged |
> | upstream's default | `True` | `True` — unchanged |
> | `did.mbt` `in_sample_normalization` | `:164-200` | `did.mbt:166-201` |
> | `did_cross_section.mbt` `p_hat = mean(d)` note | `:1476` | `:1476` — unchanged |
>
> **What is NOT verified here.** No arm was re-run. Every number in §2–§4 is
> quoted from the original record and was not reproduced. The raw logs they
> come from (`_verify/_isn_*_1570.*`) were **not tracked** and are now tracked.

> ## ⚠ RETRACTION — the headline number in the first version of this document was wrong
>
> The first version reported, from the upstream oracle, that the flag
> **moves the reported estimate by up to 3.17 SE while leaving the reported SE
> unchanged (ratio 0.998)**, and concluded that `did.mbt`'s "differs in finite
> samples" wording **understated the divergence by two orders of magnitude**.
>
> **Both claims are retracted.** The upstream arm seeded the *data* but not the
> *estimator*. `DoubleMLDIDCS` draws its own cross-fitting split **at
> construction**, so the `np.random.seed(s)` in that script — placed before
> `fit()` — came too late.
>
> Evidence that the arm was never reproducible: run twice, the numbers disagreed
> with themselves.
>
> | quantity | run A | run B (the saved artifact) |
> |---|---|---|
> | `max dcoef_over_se` | 3.1708 | 2.8744 |
> | `mean_se` ratio | 0.9984 | 0.9756 |
> | `sd_false / sd_true` | **0.602** | **1.115** |
>
> The `sd` ratio flipped across 1.0 — the *sign* of the claimed conclusion was
> noise.
>
> **Corrected upstream figure: at most 0.048 SE.** The original
> `did.mbt` wording was essentially **right** for upstream. What survives as a
> real finding is the gap between the port's `DoubleMLDIDCS` (0.97 SE) and
> upstream's (0.048 SE) — about **20×**.
>
> Reproducibility is now demonstrated, not assumed: see §4.

**Status:** measured, three arms, port commit `8308f09` (v0.155.0).
Upstream oracle = installed `doubleml` **0.11.3** (vendored tree 0.11.4; not diffed).

One of only ~~**seven** constructor parameters where both sides declare the
parameter and only the *value* differs. The other 42 of the 49 constructor
divergences are one-sided capability gaps, not defaults.~~ **Re-measured
2026-10-20: the 49 / 42 / 7 triple does not reproduce** from the two sources
this document names, under any of six scopings — see **§10** for the live
numbers and the rule that produces them. The *point* the sentence was making
survives: the parameters where the two sides disagree in value are a handful
of names, and most of the disagreement between the two APIs is one-sided
capability rather than default choice.

---

## 1. Why the port chose `false`

`did.mbt:164-200`:

> ...equivalent asymptotically but differs in finite samples. Default is
> `false` to preserve pre-0.8.0 bit-equality with the prior `DoubleMLDID` port.

Two separable claims:

- *"false to preserve pre-0.8.0 bit-equality"* — a **backward-compatibility**
  reason, legitimate, and not disputed here.
- *"equivalent asymptotically but differs in finite samples"* — an empirical
  magnitude claim. **Measured below, and it turns out to hold.**

## 2. Arm 1 — port cross-section DID. `psi_a` bit-identical; effect ≤ 0.039 SE.

DGP fixed at RNG seed 42, so data is identical across arms and across flag
values. `n_folds=2, n_rep=1, seed=3141`.

| n | coef (`false`) | coef (`true`) | \|Δcoef\| | se (`false`) | Δcoef / se | **max \|Δpsi_a\|** | max \|Δpsi_b\| |
|---|---|---|---|---|---|---|---|
| 200 | 0.9436667056925013 | 0.9417556084833779 | 1.911e-3 | 0.0587136767328991 | 0.0325 | **0** | 0.68810 |
| 500 | 0.9972412488987678 | 0.9961977056579764 | 1.044e-3 | 0.026634237125725994 | 0.0392 | **0** | 0.10384 |
| 1000 | 0.9884480985168514 | 0.9883870050550935 | 6.109e-5 | 0.018483830884208317 | 0.0033 | **0** | 0.03178 |
| 2000 | 0.9946036784620415 | 0.9946076409803405 | 3.963e-6 | 0.012810478339491555 | 0.00031 | **0** | 0.03070 |
| 5000 | 1.006523310114337 | 1.0065234912178027 | 1.811e-7 | 0.008237680272293551 | 0.000022 | **0** | 0.03118 |

**`max |Δpsi_a| = 0` at every n** — structural, not luck: `p_hat = mean(d)`, so
`d / p_hat` and `d / mean(d)` are the *same expression*. The flag **provably
cannot** reach `psi_a`. All difference lives in `psi_b`.

`mean |psi_a| = 1.0000000000000000` (to ~1e-14) on both arms, confirming the
structural claim at `did_cross_section.mbt:1476`.

## 3. Arm 2 — port DIDCS. Up to 0.97 SE; SE itself moves 3.3×.

`make_did_CS2021(1600, 3, 1.0, seed)`, 12 seeds, read at `coef_at(0, 1)` /
`se_at(0, 1)`. `EXAMINED=12 EXPECTED=12`.

```
mean_abs_err_false = 9.827   mean_se_false = 10.053
mean_abs_err_true  = 3.955   mean_se_true  =  3.004
worst_dcoef_over_se = 0.9713777081362766
```

### Degeneracy hypothesis — refuted

`predictions_m()` min/max were printed on both arms for every seed: they are
**bit-identical between arms** and sit in `[0.352, 0.736]`, nowhere near 0 or 1.
The flag does not move the nuisance fit at all; the entire difference is the
score weighting.

### Mean-abs-error alone would have overstated this

Mean coef `false` ≈ **−1.42**, mean coef `true` ≈ **−1.75** — similar bias — so
the 2.5× gap in `mean_abs_err` is essentially **all variance**. "2.5× less
accurate" would have been the wrong claim.

## 4. Arm 3 — upstream oracle, corrected and now reproducible

Fixture: `make_did_SZ2020(n_obs=1600, cross_sectional_data=True,
return_type="DoubleMLDIDData", theta=1.0, seed=s)`, `DoubleMLDIDCS(OLS, LogReg,
n_folds=2)`. `EXAMINED=12 EXPECTED=12`.

**Seeding.** `_isn_determinism_1570.py` isolated three placements on a single
seed:

| placement | reproducible? |
|---|---|
| `np.random.seed(s)` before `fit()` only | **NO** — max\|diff\| 0.214 / 0.270 |
| before `DoubleMLDIDCS(...)` **construction** | **YES** — max\|diff\| 0 |
| at the very top, before the DGP too | **YES** — max\|diff\| 0 |

No `default_rng` / `Generator` appears anywhere in the installed `doubleml`, so
the unseeded draw is the cross-fitting split made at construction.

With seeding before construction, the full grid run **twice**:

```
max |f1-f2| = 0        max |t1-t2| = 0
```

**Reproducible.** The corrected figures:

| | `false` | `true` |
|---|---|---|
| mean coef | −0.0425163040112383 | −0.0417642341964338 |
| sd coef | 0.126340983376893 | 0.125872373359406 |
| mean se | 0.167246002051048 | 0.165395399512871 |

```
max |dcoef|                = 0.00830326862149353
mean |dcoef|               = 0.00242421856495515
mean_se_false / mean_se_true = 1.01118896017439
max dcoef_over_se_false    = 0.048494238725459
sd_false / sd_true         = 1.00372289808304
```

Both arms share a bias of ≈ −1.04 from θ = 1.0, so the contrast is valid even
though the absolute level is not an ATT-recovery statement.

**0.048 SE.** That is what "differs in finite samples" means.

## 5. What this establishes

1. `psi_a` is **provably** unreachable by the flag (`p_hat = mean(d)`); measured
   `max |Δpsi_a| = 0` at five sample sizes.
2. Port cross-section DID (`DoubleMLDIDCrossSection`): **≤ 0.039 SE**, O(1/n).
3. Port panel DIDCS (`DoubleMLDIDCS`): **up to 0.97 SE**, SE ratio 3.3×.
4. Upstream `DoubleMLDIDCS` — the **repeated cross-sections** estimator: **≤ 0.048 SE**, SE ratio 1.011.
5. ~~**The port's `DoubleMLDIDCS` is ~20× more sensitive to this flag than
   upstream is.**~~ **WITHDRAWN 2026-10-20 — see §9.** The number was formed
   by comparing item 3 with item 4, and those are **two different estimators
   that share a name**, measured on **two different fixtures**.

The like-for-like pair is item 2 against item 4 — the port's cross-section
estimator against upstream's cross-section estimator, on the **same**
`make_did_SZ2020(..., cross_sectional_data=True)` fixture:

| | port `DoubleMLDIDCrossSection` | upstream `DoubleMLDIDCS` |
|---|---|---|
| max \|Δcoef\| / SE | **0.039** | **0.048** |

⇒ **the port's cross-section estimator is *less* sensitive to this flag than
upstream's** — 0.039 against 0.048, a ratio of **0.81×** — not 20× more.

## 6. What is NOT established

- **Which arm is "better".** Neither recovers θ = 1.0 on either fixture (port
  centres near −1.5, upstream near −0.04). A direction claim needs a fixture
  where one arm is demonstrably closer to a known truth.
- **Whether the port's 3.3× SE ratio is a port defect.** Upstream's ratio is
  1.011. But the two DGPs are different constructions, so the gap **cannot be
  attributed to the port** without a matched fixture. Flagged, not asserted.

## 7. Recommendation

**Do not flip the default.** Pre-0.8.0 bit-equality is a real constraint, and
the upstream divergence turns out to be genuinely finite-sample-scale — the
original comment was right.

What is worth documenting is the ~~**20× gap on `DoubleMLDIDCS`**~~ — that
sentence is **withdrawn**, see §9. What survives is narrower and still worth
writing: on the **cross-section** estimator the port moves ≤ 0.039 SE where
upstream moves ≤ 0.048 SE, so the port is marginally *less* sensitive. The
0.97 SE figure belongs to the port's **panel** `DoubleMLDIDCS`, and the
upstream counterpart for *that* estimator is `DoubleMLDIDMulti` — which this
record never ran.

## 8. Method note

Two failures in this row, both mine, both caught by the same discipline:

1. **A 4-seed pass pointed the opposite way from the 12-seed pass.** Discarded
   and re-run at 12 seeds — the trap recorded in `N_FOLDS_INNER_1550.md`.
2. **The upstream arm was never deterministic**, and the first saved artifact
   did not match the numbers in the first draft. It took an independent
   verifier pass to surface this. Every port-side number was subsequently
   re-checked the same way and reproduces exactly (`worst_repeat_diff = 0`).

⇒ **Run every arm twice and check it reproduces before quoting a number.** The
symptom of an unseeded instrument is a large, confident, wrong number.

## 9. The 20× headline is withdrawn — a name collision, not a defect

**The claim.** §5 point 5 read: *"the port's `DoubleMLDIDCS` is ~20× more
sensitive to this flag than upstream is"*, formed from Arm 2's 0.971 SE and
Arm 4's 0.048 SE (0.971 / 0.048 = **20.2**).

**Why it does not hold.** The two arms are not the same estimator, and they
are not the same fixture:

| | arm | estimator | fixture |
|---|---|---|---|
| Arm 1 | port | `DoubleMLDIDCrossSection` | `make_did_SZ2020`, cross-section |
| Arm 2 | port | `DoubleMLDIDCS` (panel) | `make_did_CS2021` |
| Arm 4 | upstream | `DoubleMLDIDCS` | `make_did_SZ2020`, cross-section |

Upstream's `DoubleMLDIDCS` is the **repeated cross-sections** estimator —
`did/did_cs.py:17`: *"Double machine learning for difference-in-difference with
repeated cross-sections"*, taking a `DoubleMLDIDData` (one observation per
unit, binary post-period indicator `t`). The port's `DoubleMLDIDCrossSection`
is that estimator: `did_cross_section.mbt` fits 4 g-functions over
`(d, t) ∈ {0,1}²` plus one propensity, and its own header cites *"the
repeated cross-sections variant"* of the same Sant'Anna & Zhao design. The
repository's own `validate_did_cross_section_with_python.py` mirrors
`doubleml.DoubleMLDIDCS._score_elements` to produce the port's reference
estimate — i.e. the repo has always treated the two as the same estimator.

The port's `DoubleMLDIDCS` is a **different** estimator: a **panel**,
group-time ATT estimator (`did_cs.mbt` — per-`(g, t)` cells over a
`DoubleMLDIDCSData` with `id` / `g` / `t`), whose upstream counterpart is
`DoubleMLDIDMulti` (`did/did_multi.py`, takes a `DoubleMLPanelData`, emits
per-`(cohort, pre, eval)` ATTs). The tell is the parameters: `control_group`
and `anticipation_periods` exist on upstream's `DoubleMLDIDMulti` and on
**neither** upstream's `DoubleMLDIDCS` nor its `DoubleMLDID` — and the port's
`DoubleMLDIDCS` has both.

**So the 20× compared Arm 2 against Arm 4** — the port's panel estimator
against upstream's cross-section estimator, on different fixtures.

**The like-for-like comparison, from this record's own arms:**

| | port `DoubleMLDIDCrossSection` | upstream `DoubleMLDIDCS` |
|---|---|---|
| max \|Δcoef\| / SE | **0.039** | **0.048** |
| arm | 1 | 4 |
| fixture | `make_did_SZ2020`, cross-section | the same |

⇒ On the estimator the two sides actually share, the port is **less**
sensitive — **0.039 against 0.048, a ratio of 0.81×**. The 0.97 SE figure is
real, but it belongs to the port's panel `DoubleMLDIDCS`, and this record
never measured upstream's counterpart for it.

**What is still open.** The panel question is real and unanswered: the port's
`DoubleMLDIDCS` moves up to 0.97 SE under the flag, and upstream's
`DoubleMLDIDMulti` — the estimator it corresponds to — was never run here.
Until that arm exists, **no claim about the panel estimator's relative
sensitivity is supported**, in either direction.

## 10. The 49 / 42 / 7 constructor-divergence triple is not reproducible

This record's header said: *"One of only **seven** constructor parameters where
both sides declare the parameter and only the *value* differs. The other 42 of
the 49 constructor divergences are one-sided capability gaps, not defaults."*

**Re-measured 2026-10-20: that triple does not reproduce.** The two sources it
names are the recorded upstream capture
(`_verify/_upstream_defaults_1540.txt`, now tracked and re-encoded UTF-8) and
the port enumerator (`_verify/_enum_all_defaults_1540.py`, now tracked, and
which had been **crashing** on a `NameError` since it was written — its
per-estimator detail section never ran). Six scopings were tried against those
two sources — identity and crossed estimator-name maps, with and without the
learner slots, and with and without port-only parameters counted — and **none**
yields 49 / 42 / 7.

**What replaces it.** Under the rule stated below, the live numbers are:

- upstream declares **51** (estimator, parameter) pairs across the 10
  estimators in the capture;
- of those, the port declares the same parameter on the same estimator in
  **30** cases — **18** with the same value, **12** with a different one;
- those **12** value differences fall across **3** distinct parameter names
  (`n_folds`, `in_sample_normalization`, `n_folds_inner`);
- the remaining **21** are one-sided: upstream declares a parameter the port's
  corresponding estimator does not (`n_rep`, `normalize_ipw`, `score`,
  `trimming_threshold`);
- and **45** parameters the port's constructors declare have no upstream
  counterpart in the capture at all.

The rule, so it can be re-derived: *match the capture's 10 upstream estimators
1:1 to the port's corresponding `::new`, compare parameter **names** first and
values second, count learners as parameters, and report upstream-only pairs
separately from value differences.* `n_folds` appears 10 times in the
difference column because 10 of the 10 capture estimators carry it; the two
`in_sample_normalization` differences are `DoubleMLDID` and
`DoubleMLDIDCrossSection`; the single `n_folds_inner` difference is
`DoubleMLLPLR`. The 1:1 map matters — upstream's `DoubleMLDIDCS` is the
repeated-cross-sections estimator, which is the port's
`DoubleMLDIDCrossSection` (§9), and the port's `DoubleMLDIDCS` has no entry
in the capture because its upstream counterpart, `DoubleMLDIDMulti`, is not
one of the capture's 10.

`_verify/_audit_r15_defaults_1650.py` §8 prints these numbers, and
`_verify/_verify_round15_defaults_1650.py` pins them.

**The point the original sentence was making survives.** The number of
parameters where the two sides disagree *in value* is small — it is a
handful of names, not a wide list — and most of the disagreement between the
two APIs is one-sided capability, not default choice. The specific figures
49 / 42 / 7 were not that point's evidence, and they are withdrawn.

## Artifacts

- `_verify/_isn_port_1570.txt` — MoonBit arms, raw
- `_verify/_isn_determinism_1570.py` / `.txt` — seed-placement isolation
- `_verify/_isn_upstream_1570_v2.py` / `.txt` — corrected oracle, 2 passes
- `_verify/_isn_upstream_1570.py` / `.txt` — superseded first pass, kept as evidence
- `_verify/_probe_determinism_1570_test.mbt.txt` — port-side reproducibility check