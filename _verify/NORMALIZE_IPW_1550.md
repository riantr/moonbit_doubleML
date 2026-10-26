> ## ⚠ SEVERITY VERDICT — SEE `_verify/PQ_CORRECTION_1560.md`
>
> The verdict below ("capability gap, not a numerical one worth chasing") was
> reversed once and then **re-reversed**. It was first derived from two
> fixtures whose propensity was well-behaved; it was then overturned by a
> single nonlinear-median fixture showing a 6.2× accuracy gap; and that 6.2×
> was finally refuted by an 8-seed sweep in which `normalize_ipw=True` beats
> `False` on 4/8 seeds with a mean-error ratio of **0.98**.
>
> **What survives is only the structural fact, which was read from source and
> never measured:** `DoubleMLPQ` and `DoubleMLQTE` have no `normalize_ipw`
> field and never normalize, while upstream defaults `True` and applies it at
> `pq.py:367-368` and `:414-415`. Every numerical claim attached to it has
> failed to reproduce.

# `normalize_ipw` — measured, default #5 of the port-vs-upstream defaults table

**Measured, not recalled.** Upstream read from
`_verify/_upstream_ps/doubleml-0.11.4/doubleml/irm/{pq,qte,cvar}.py` and
`apos.py` by grepping `normalize_ipw` and reading every hit — not just the
constructor signature. Port sites enumerated across the whole package.

> Version caveat, as in `SCORE_VOCABULARY_1550.md`: installed `doubleml` is
> **0.11.3**; the vendored tree is **0.11.4**; the two were not diffed.

## Upstream: the flag, its default, and where it actually bites

| estimator | default | applied at |
|---|---|---|
| `irm.py:148` | `False` | — |
| `iivm.py:154` | `False` | — |
| `apo.py:111` | `False` | — |
| `apos.py:122` | `False` | — |
| `ssm.py` | `False` | — |
| `cvar.py:117` | **`True`** | `:295-296` and `:345-346` |
| `pq.py:124` | **`True`** | `:367-368` and `:414-415` |
| `qte.py:108` | **`True`** | inherited from `pq.py`; exposed as a property at `:259-263`, forwarded at `:607` |

The two application sites in `pq.py` are the load-bearing detail:

```python
# pq.py:367-368  -- inside the bisection that SOLVES for theta
if self._normalize_ipw:
    m_hat_prelim = _normalize_ipw(m_hat_prelim, d_train_1)
# pq.py:414-415  -- the final nuisance used for the score
if self._normalize_ipw:
    m_hat_adj = _normalize_ipw(m_hat["preds"], d)
```

**So it is not an inert flag.** `m_hat_prelim` is exactly the array that
`pq_score_ipw` consumes while bisecting for `theta`. Rescaling the IPW weights
by `1/mean(w | treated)` moves `mean(w * 1{y <= theta})` from `q` to `q/c`,
which **moves the bisection root**. The point estimate and the variance both
depend on it. `cvar.py` has the identical pair of sites.

## The port: three sites, and they split three different ways

| estimator | port default | port applies it | vs upstream default |
|---|---|---|---|
| `apo.mbt:107` (`DoubleMLAPO`) | `false` | `apo.mbt:331`, `:1106` | **match** |
| `apo.mbt:1285` (`DoubleMLAPOS`) | `false` | `apo.mbt:1534` | **match** |
| `cvar.mbt:136` (`DoubleMLCVAR`) | `true` | `cvar.mbt:728-729`, `:992-993` | **match** |
| `irm.mbt`, `iivm.mbt`, `ssm.mbt` | *no field* | n/a | **match** (default is `False`, so omitting it is behaviourally right) |
| **`quantile.mbt:383` (`DoubleMLPQ`)** | **no field** | **never** | **DIVERGES** |
| **`quantile.mbt:1437` (`DoubleMLQTE`)** | **no field** | **never** | **DIVERGES** |

The three estimators that legitimately carry no field each say so in their own
doc comment rather than leaving it to inference:

- `irm.mbt:1059-1062` — *"`_propensity_score_adjustment(m_hat, d, normalize_ipw)`
  returns `m_hat` unchanged when `normalize_ipw` is `False`. That is upstream's
  default (`irm.py:138`) and it is exactly why this port's `DoubleMLIRM`
  carries no `normalize_ipw` field."*
- `iivm.mbt` — upstream `False`; `adjust_ps(m, z)` at `:493` is the propensity
  *adjustment* (clip / isotonic / CV), which is a different operation and is
  not IPW normalization.
- `ssm.mbt:47`, `:85-86` — *"`normalize_ipw = False` … `normalize_ipw = True`
  and the nonignorable-nonresponse case are out of scope."*

**`DoubleMLPQ` and `DoubleMLQTE` have no such comment, and no such field.**

## The divergence

`DoubleMLPQ::new` (`quantile.mbt:383-387`) takes `treatment`, `quantile`,
`n_folds`, … and no `normalize_ipw`. `DoubleMLQTE::new` (`:1437-1441`) takes
`quantiles`, `n_folds`, `seed`, … and no `normalize_ipw`.

The only propensity handling either estimator reaches is `fit_propensity`
(`quantile.mbt:151-177`), whose last statement is:

```moonbit
PSProcessor::from_config(cfg).adjust_ps(m, treated)
```

`adjust_ps` is clip / isotonic / CV calibration — **there is no
`_normalize_ipw` call anywhere in `quantile.mbt`.** The package does own the
function (`pub fn normalize_ipw`, exercised by CVAR at `cvar.mbt:629`), so the
capability exists; it is simply not plumbed into the quantile estimators.

⇒ **`DoubleMLPQ` and `DoubleMLQTE` never normalize their IPW weights, while
upstream normalizes by default.** The port is not "missing a knob on a
behaviour that happens to match" — it takes the branch upstream does not.

Note the internal inconsistency this creates: `DoubleMLCVAR` and `DoubleMLPQ`
are neighbours in the same file family and solve the same IPW-bisection
problem (`quantile.mbt:114` even documents PQ's score as
`mean(treated/m * 1{y <= theta} - q)`, structurally identical to CVAR's at
`:2090-2092`). One got the flag wired; the other did not.

## Magnitude — MEASURED, and it downgrades the claim above

`_verify/gen_v1550_pq_oracle.py` runs **upstream's own** `DoubleMLPQ` twice on
identical data — once at the default `normalize_ipw=True`, once at `False` —
with splits pinned via upstream's own `DoubleMLResampling`
(`utils/resampling.py:5`). The pinned path was verified bit-reproducible
before any comparison was read. Learners are plain sklearn
`LogisticRegression`, matching upstream's own tests
(`tests/test_model_defaults.py:33`). n=2000, seed 3141, q=0.5, n_folds=2.

| confounding `b` | propensity range | `coef(True)` | `coef(False)` | \|gap\| |
|---|---|---|---|---|
| 0.5 | [0.1826, 0.9064] | 1.0374358099 | 1.0374358099 | **3.80e-13** |
| 0.9 | [0.0432, 0.9756] | 1.0318808775 | 1.0345459035 | 2.67e-03 |
| 1.5 | [0.0041, 0.9970] | 1.0372631252 | 1.0318808775 | 5.38e-03 |
| 2.5 | [0.0001, 0.9999] | 1.0699368493 | 1.0712196616 | 1.28e-03 |
| 4.0 | [0.0000, 1.0000] | 1.1240680236 | 1.1011235381 | 2.29e-02 |

### What this establishes

**On a well-behaved propensity the two branches agree to machine precision.**
At `b = 0.5` the gap is `3.80e-13` — floating-point noise. So on the common
case the port's missing `normalize_ipw` costs **nothing measurable**, and the
divergence I called "silent numerical" in the previous revision of this file
is not numerical in that regime. **That claim was too strong and is corrected
here.**

The gap only becomes real once the propensity approaches its bounds, and by
`b = 4.0` it is `2.29e-02` — about 4% of the coefficient.

### What this does NOT establish — the sweep is inconclusive as a trend

Two reasons, both stated rather than smoothed over:

1. **The gap is not monotone in `b`.** 3.8e-13 → 2.7e-3 → 5.4e-3 → 1.3e-3 →
   2.3e-2. It falls by a factor of four between `b=1.5` and `b=2.5`. Whatever
   switches it on is discontinuous, most plausibly the
   `trimming_threshold=0.01` clip in `pq.py:414-415` starting to bind, but
   **that is a hypothesis and was not tested**.
2. **The "fold noise" yardstick is itself unstable.** Re-running the
   *unpinned* estimator gave gaps of 4.6e-13, 1.8e-12, 7.1e-3, 5.2e-4 and
   3.2e-13 across the same five rows. It is sometimes exactly zero and
   sometimes 7e-3, so the `gap/noise` column in the script's output divides by
   a near-zero denominator and **carries no information**. It is printed by
   the script for completeness but should not be read.

### Placing the port — MEASURED, and the answer is "neither"

`_verify/gen_v1550_pq_fixture.py` emits the fixture into generated
`v1550_fixture_b*.mbt` files as float literals, so the MoonBit side reads
upstream's **exact** arrays rather than re-deriving them from NumPy's PCG64.
n=1000, seed=3141, q=0.5, n_folds=2, one feature.

| fixture | port coef | upstream `True` | upstream `False` | port-vs-True | port-vs-False | True-vs-False |
|---|---|---|---|---|---|---|
| b=1.5 | 1.0369740589670084 | 1.0354613542323716 | 1.0354613542334126 | 1.51e-03 | 1.51e-03 | **1.04e-12** |
| b=4.0 | 0.6038781952285628 | 0.9890104959605935 | 0.9965394647700562 | **3.85e-01** | **3.93e-01** | 7.53e-03 |

**b=1.5 is not a discriminating fixture and was declared as such in advance.**
The two upstream branches are `1.04e-12` apart there, so a verdict drawn from
it would be unfalsifiable. The port happens to sit `1.51e-3` from both, which
is consistent with either branch and therefore proves nothing.

**b=4.0 is discriminating, and the answer is NEITHER.** The branches are
`7.53e-03` apart. The port is `0.385` from one and `0.393` from the other —
roughly **50× further from both than they are from each other.** The port does
not sit on upstream's `False` branch; it does not sit on `True` either. It is
somewhere else entirely.

### What that means for this finding

The `normalize_ipw` gap is `7.53e-03`. The port-vs-upstream gap on the same
fixture is `0.39`. So **this flag accounts for about 2% of the disagreement**
between the two implementations. Whatever else separates them is an order of
magnitude larger and has nothing to do with `normalize_ipw`.

The likely dominant cause is a *different, already-known* divergence: on
b=4.0 the true propensity ranges over `[0.0000, 1.0000]`, and this port's
`propensity_clip = 1.0e-6` is not upstream's `trimming_threshold = 0.01`.
That is the "deliberate rename of a different quantity" already recorded in
`PORT_VS_UPSTREAM_DEFAULTS_1540.md`, and on a fixture with propensities at the
boundary it would dominate everything. **This is a plausible explanation, not a
measured one** — it was not tested here.

### Two further measured facts about the oracle itself

1. **Upstream's `DoubleMLPQ` is not reproducible across processes at a fixed
   seed.** Two runs of the same generator, same data, same pinned splits,
   gave b=1.5 `True = 1.0443004914653655` and then `1.0354613542323716` — a
   drift of `8.8e-3`, which is *larger* than the `7.53e-03` branch gap being
   measured. Inside a single process the pinned path was bit-reproducible
   (checked before any comparison was read), so this is cross-process
   nondeterminism, most likely in `_default_kde`. Consequence: **upstream
   reference coefficients are good to ~1e-2, not 1e-12**, and every comparison
   in this section is reported at that precision.
2. **The gap is unstable in `n` as well as in `b`.** At b=1.5, n=2000 gave a
   `5.38e-03` gap while n=1000 gives `1.04e-12`. Neither is a stable function
   of confounding strength, which is why the earlier sweep was recorded as
   inconclusive rather than as a trend.

### What is still not measured

`DoubleMLQTE` has been read but never run — no oracle, no port-side
measurement. And the port-vs-upstream gap of `0.39` on b=4.0 is itself
**unexplained**; it is simply much larger than the flag under investigation.

## Verdict

**A real capability gap. A numerical one only in the extreme, and I overstated
it.** The two estimators whose upstream default is `False` are correct to omit
the field; the two whose upstream default is `True` do not carry the knob and
never take upstream's default branch.

An earlier revision of this file called that "the more serious of the two
findings in this batch, because it is a *silent numerical* difference on a
default path rather than a spelling mismatch that fails loudly". **The oracle
overturns that.** At `b = 0.5` the two upstream branches agree to `3.80e-13` —
machine precision — so on an ordinary propensity there is no silent numerical
difference to hide. The `score` spelling bug, by contrast, fails loudly and
immediately.

What survives is: a missing capability that only bites when the propensity
approaches 0 or 1, where the gap reaches `2.29e-02`. That is worth knowing and
worth a note in the docs; it is not worth changing a default over on the current
evidence, because the trend across `b` is non-monotone and the port's own
number has not yet been placed on either branch.

Adding the field is a behaviour change (it would alter reported numbers for
every existing `DoubleMLPQ`/`DoubleMLQTE` caller, since the default would have
to become `true` to match upstream) and is **not** done here.