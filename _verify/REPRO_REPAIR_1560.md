# Repairing the instrument: upstream's `DoubleMLPQ` needed `np.random.seed(0)`

This is the most important result of the audit, and it is a **methodological**
one. It retroactively invalidates one sweep and confirms another.

## The defect

Upstream's `DoubleMLPQ` is **not reproducible across processes** on identical
data unless numpy's *global* RNG is seeded. `_verify/gen_v1560_repro_check.py`
prints one coefficient and nothing else, so two invocations can be diffed
directly:

```
=== run A (SEED_GLOBAL_RNG=1, PYTHONHASHSEED unset) ===
pyhashseed=unset seeded=1  True:0.9661052548646248 False:0.958171245406125
=== run B (identical invocation) ===
pyhashseed=unset seeded=1  True:0.9661052548646248 False:0.958171245406125
=== run C (SEED_GLOBAL_RNG=0, i.e. no global seeding) ===
pyhashseed=unset seeded=0  True:0.9661052548638632 False:0.9668735788958803
=== run D (SEED_GLOBAL_RNG=0 again) ===
pyhashseed=unset seeded=0  True:0.9661052548635702 False:0.9661052548644208
```

**A and B are identical. C and D are not.** `PYTHONHASHSEED` was unset
throughout and was not the variable.

**The cause is the unseeded global `numpy.random`**, and one line fixes it:

```python
np.random.seed(0)
```

## Why it mattered more than anything else measured

On the b=0.9 fixture, the spread between two unseeded runs of the *same*
configuration was `7.7e-4`:

```
unseeded run C: False = 0.9668735788958803
unseeded run D: False = 0.9661052548644208
```

That is the **same order as the `normalize_ipw` effect being measured**
(`0.9661052548646248 − 0.958171245406125 = 7.9e-3` on a neighbouring fixture).
The instrument's noise was competing with its signal. Every numerical claim
in this audit built on that oracle was therefore at the mercy of process state.

## What the repair retroactively invalidates

**The first 8-seed sweep in `gen_v1560_pq_accuracy.py` is invalid.** It ran
without the seeding line and produced "normalize_ipw=True beats False on
**4/8** seeds, mean-error ratio **0.98**" — which I used to retract the
`normalize_ipw` finding a second time. That result was an artefact.

**Severity of the contamination**, using seed 20240's
`normalize_ipw=True` coefficient across three runs on identical data:

| run | value |
|---|---|
| first (unseeded) | 1.0511410400817045 |
| contaminated sweep (unseeded) | 1.028427796993311 |
| repaired (seeded) | 1.04798764441281 |

A spread of `2.3e-2` across runs of the same estimator on the same data.

## What the repair confirms — both key claims

Re-run with the seeding line in place, same 8 seeds, same DGP:

| seed | true median | \|err\| `True` | \|err\| `False` | ratio False/True |
|---|---|---|---|---|
| 20240 | 1.053673 | 0.005685 | 0.015769 | **2.77** |
| 7 | 1.054277 | 0.053482 | 0.078987 | 1.48 |
| 42 | 1.053171 | 0.042486 | 0.047949 | 1.13 |
| 99 | 1.049912 | 0.004350 | 0.004350 | 1.00 |
| 123 | 1.054285 | 0.011549 | 0.013530 | 1.17 |
| 555 | 1.053170 | 0.062844 | 0.058170 | **0.93** |
| 777 | 1.055935 | 0.027215 | 0.039187 | 1.44 |
| 3141 | 1.048923 | 0.006034 | 0.007782 | 1.29 |

```
normalize_ipw=True beats False on 7/8 seeds
mean |err| ipw=True  = 0.026706
mean |err| ipw=False = 0.033216
overall ratio False/True = 1.24
```

**7 of 8 seeds favour upstream's default.** Under a binomial test at p=0.5,
`P(>= 7 of 8) = 9/256 ≈ 0.035` — significant. Seven of eight per-seed ratios
are ≥ 1.0 and the single exception is 0.93.

**And the 13-digit port-vs-upstream agreement survives the repair.** Seed
20240, `normalize_ipw=False`:

```
port DoubleMLPQ                       1.0379037558267044
upstream DoubleMLPQ, normalize_ipw=False  1.0379037558264403
                                     difference ~2.6e-13
```

## The final position on `normalize_ipw`

Both of these are now **established**, and both point the same way:

1. This port's `DoubleMLPQ` **is** upstream's `DoubleMLPQ` evaluated at
   `normalize_ipw=False`, agreeing to ~2.6e-13.
2. Upstream's default `normalize_ipw=True` **reduces median-estimation error
   by about 24% on average** and wins 7 of 8 seeds on a nonlinear-median DGP.

**So the port is on the less accurate branch, and by a reproducible margin.**
That is a real finding, and it is the one the audit started chasing in the
first place — reached only after repairing the instrument that had been
silently corrupting every earlier attempt.

## The lesson, stated properly

My original error was promoting single-fixture numbers. But the *deeper*
error was trusting an oracle I had never checked for reproducibility. Both
`PQ_FUNCTIONAL_DIVERGENCE_1550.md` and the first `normalize_ipw` sweep were
built on it.

**Before measuring with an external implementation, measure the
implementation.** Two identical invocations and a diff. It takes a minute and
it is the precondition for every number that follows.

Two other claims in this audit were wrong for unrelated reasons and remain
retracted regardless of this repair: the CVaR-vs-median and QTE-contrast-vs-
median comparisons (`PQ_CORRECTION_1560.md`).

## Reproducing

```
python _verify/gen_v1560_repro_check.py       # A/B identical, C/D not
python _verify/gen_v1560_pq_accuracy.py       # the 8-seed sweep, now seeded
```

Both scripts pin `PYTHONHASHSEED` untouched and add `np.random.seed(0)`
unconditionally (`gen_v1560_repro_check.py` gates it behind
`SEED_GLOBAL_RNG` purely so the failure can be demonstrated).

## Not established

- Whether the ~24% accuracy advantage holds for other DGPs, sample sizes, or
  for `DoubleMLQTE` and `DoubleMLCVAR`. Only `DoubleMLPQ` was swept.
- Whether upstream's own 0.11.3 (installed) behaves like the vendored 0.11.4
  tree under seeding.
- What upstream's unseeded global RNG call actually *is*. The fix is verified;
  the offending call site was not located.