> ## ⚠ SEE `_verify/REPRO_REPAIR_1560.md` — THE ORACLE WAS BROKEN
>
> Everything below was measured with an oracle that was **not reproducible
> across processes**: two identical invocations of upstream's `DoubleMLPQ`
> differed by `7.7e-4`, the same order as the effects being measured.
> Seeding numpy's global RNG (`np.random.seed(0)`) fixes it, and the results
> change materially.
>
> **Final position after the repair** — both now established:
> - This port's `DoubleMLPQ` **is** upstream's at `normalize_ipw=False`,
>   agreeing to `~2.6e-13`.
> - Upstream's default `normalize_ipw=True` **reduces error ~24%** and wins
>   **7 of 8 seeds** (binomial p ≈ 0.035).
>
> So the port sits on the *less accurate* branch. The "4/8 seeds, ratio 0.98"
> result below was an artefact of the contaminated instrument and is void.
> The CVaR-vs-median and QTE-contrast-vs-median errors below were *not*
> instrument artefacts — those remain retracted on their own merits.

# CORRECTION — the port's `DoubleMLPQ` IS upstream's, at `normalize_ipw=False`

This document **retracts** the central claim of
`PQ_FUNCTIONAL_DIVERGENCE_1550.md` and corrects the severity verdict in
`NORMALIZE_IPW_1550.md`. Both are wrong as written. The correction is
recorded prominently rather than quietly edited, because I escalated this
claim across three turns before a direct test refuted it.

## What I claimed

Turn 4: upstream's `DoubleMLPQ` coefficient moves by `3.97e-03` when `ml_g` is
replaced by `DummyClassifier(prior)`; the port's moves by **exactly 0** when
`ml_l` is replaced by `noop()`. Same test, opposite results, so I concluded:

> "The two estimators compute DIFFERENT FUNCTIONALS — a far larger divergence
> than any single default in the audit table."

## What is actually true

Scoring all three against a **known true median** on identical arrays
(`_verify/gen_v1560_pq_accuracy.py`; nonlinear conditional median
`g(x) = 0.7x^2 - 0.4`; truth computed by brute force on a 200,000-row
population; the 1,000-row estimation sample **disjoint** from it):

```
TRUE median (brute force) = 1.0536727725016273

upstream normalize_ipw=True   coef = 1.0511410400817045   |err| = 0.002532
upstream normalize_ipw=False  coef = 1.0379037558266213   |err| = 0.015769

port DoubleMLPQ               coef = 1.0379037558267044   |err| = 0.015769
```

**The port and upstream at `normalize_ipw=False` agree to 13 significant
figures** — a difference of `8.3e-14`, i.e. floating-point noise.

**The entire divergence is the `normalize_ipw` default.** There is no
different functional. The port is upstream's `DoubleMLPQ` evaluated on the
other branch.

## Why my structural reading was wrong

`quantile.mbt:107-110` states the identity I failed to apply:

> *"at the root `theta`, `mean(score) = 0` regardless of `g` because
> `E[g(X) | D = d] = E[g(X) * 1{D = d} / m(X)]` by definition of the
> cross-fit."*

So **both** estimators' roots are g-independent *in expectation*. Upstream's
`ml_g` sensitivity of `3.97e-03` is therefore **finite-sample** deviation from
that identity, not a structural dependence — the cross-fit identity holds in
expectation, not exactly. The port's root is *exactly* g-free by construction.

That reconciles the two measurements that looked contradictory:

| | outcome model → uninformative | \|Δcoef\| |
|---|---|---|
| port | `ml_l → noop()` | **0** (exact by construction) |
| upstream | `ml_g → DummyClassifier` | 3.97e-03 (finite-sample) |

They agree in the limit. I read a finite-sample effect as a definitional one.

## What this restores: `normalize_ipw` — and then a SECOND correction

`NORMALIZE_IPW_1550.md` had downgraded this flag after finding the branch gap
small on two earlier fixtures (3.80e-13 at b=0.5, 7.53e-03 at b=4.0). On this
nonlinear-median fixture, single seed:

| | \|err\| vs true median |
|---|---|
| upstream `normalize_ipw=True` (**upstream's default**) | **0.002532** |
| upstream `normalize_ipw=False` (**this port**) | 0.015769 |

That reads as upstream's default being **6.2× more accurate**.

### ⚠ THAT 6.2× IS ALSO WRONG — swept across 8 seeds

| seed | true median | \|err\| `True` | \|err\| `False` | ratio False/True |
|---|---|---|---|---|
| 20240 | 1.053673 | 0.025245 | 0.023373 | 0.93 |
| 7 | 1.054277 | 0.050937 | 0.053482 | 1.05 |
| 42 | 1.053171 | 0.025983 | 0.042486 | 1.64 |
| 99 | 1.049912 | 0.004350 | 0.004350 | 1.00 |
| 123 | 1.054285 | 0.045624 | 0.022418 | 0.49 |
| 555 | 1.053170 | 0.100229 | 0.109054 | 1.09 |
| 777 | 1.055935 | 0.037321 | 0.037321 | 1.00 |
| 3141 | 1.048923 | 0.013696 | 0.004590 | 0.34 |

```
normalize_ipw=True beats False on 4/8 seeds
mean |err| ipw=True  = 0.037923
mean |err| ipw=False = 0.037134
overall ratio False/True = 0.98
```

**There is no accuracy advantage.** The per-seed ratios straddle 1.0 (0.34 to
1.64) and the aggregate is 0.98 — indistinguishable from a coin flip. The 6.2×
was a single-seed artifact sitting at exactly the scale of upstream's own
run-to-run drift, which I had already flagged in the very next paragraph and
then failed to respect.

### The 13-digit agreement is downgraded too

The same seed's upstream values also moved between the two runs of the
generator: seed 20240 gave `False = 1.0379037558266213` in the first run and
`1.0302995606978673` in the sweep — a drift of `7.6e-03` on identical data.
**Upstream's leg is therefore not reproducible run-to-run here**, so the
port-vs-upstream `8.3e-14` agreement cannot be promoted to *established* any
more than the 6.2× can be. It remains a strong hint of algorithmic identity
(a coincidence to 13 digits is not plausible as luck) but it is **one
observation, not a verified result**.

**Net position after two corrections:** the structural fact — PQ and QTE have
no `normalize_ipw` and never normalize — stands, because it was read off the
source, not measured. Every *numerical* claim I attached to it has now failed
to reproduce.

## What my probe design got wrong, and does NOT support

The same run printed CVAR and QTE, and **those two rows must not be read**:

- **`DoubleMLCVAR` at `quantile = 0.5` estimates a CVaR (expected shortfall),
  not a median.** Comparing it to a median truth gives
  `|err| = 1.02`, which says nothing about CVAR's accuracy. My probe scored it
  against the wrong functional. Discard those two rows.
- `DoubleMLQTE` at `quantiles = [0.5]` *should* target the median (upstream
  builds `DoubleMLPQ` internally for the `PQ` score) and lands at
  `0.9332401683920051`, `|err| = 0.120` — **7.6× worse than the port's own
  `DoubleMLPQ` on the same rows**. That is a genuine finding, but it is a
  *different* question and it is not explained here.

## THIRD CORRECTION — the QTE row was scored against the wrong truth too

The run also printed `DoubleMLQTE` at `0.9332401683920051`, |err| `0.120`, and
I reported it as "7.6× worse than the port's own `DoubleMLPQ`". **That
comparison is invalid.** `quantile.mbt:2241-2242` states:

> *"QTE is a third shape: per quantile `j` it is a **CONTRAST of two
> independent scalar Z-estimators**, `theta_j = theta_1 - theta_0`"*

So `DoubleMLQTE::coefs()[0]` is the **quantile treatment effect**, not a
treated median. Against the correct truth — the DGP has an additive treatment
effect of exactly `THETA = 1.0` on the median, since `y = 1.0*d + g(x) + eps`
with symmetric `eps`:

| estimator | reports | correct truth | measured | \|err\| |
|---|---|---|---|---|
| `DoubleMLPQ` | treated median | 1.053673 | 1.037904 | **0.0158** |
| `DoubleMLQTE` | contrast θ₁ − θ₀ | **1.0** | 0.933240 | **0.0668** |
| `DoubleMLCVAR` | CVaR | *not the median* | 2.078072 | **not scoreable** |

The QTE error is `0.0668`, not `0.120` — and it is **not comparable to PQ's**
in the first place, because they estimate different functionals. The "7.6×"
figure is retracted.

**This is the third time in this audit I scored an estimator against a
functional it does not estimate** (CVaR vs median here, QTE contrast vs median
last turn, and the port-vs-upstream comparison earlier). Every one of them
produced a confident, wrong, quantified claim. The rule I should have applied
before writing any of these rows:

> **Establish what functional an estimator reports before comparing it to a
> truth.** The comparison is the easy part; the semantics are where all three
> errors happened.

Note the correct QTE error of `0.0668` is still ~4× PQ's `0.0158`. That is
worth measuring properly — across seeds, against the contrast truth — but it
is a **new** question, and it is not evidence of anything until swept.

## Corrected ordering

| what | size | status |
|---|---|---|
| PQ/QTE "different functionals" | — | **RETRACTED** (13-digit match on one observation) |
| `normalize_ipw` accuracy advantage | — | **RETRACTED** (4/8 seeds, ratio 0.98) |
| `normalize_ipw` *missing entirely* on PQ/QTE | structural | **stands** — read from source, not measured |
| `propensity_clip` 1e-6 vs 1e-2 | `0.44` coefficient swing on a degenerate fixture; **no accuracy effect** here | measured |
| `score` spelling on `DoubleMLPLR` | abort, both directions | **measured — the most solid finding in the audit** |
| `n_folds_inner` | `0.12` | measured |
| CVAR as a reference form | — | **WITHDRAWN** — scored against the wrong functional |
| QTE "7.6× worse than PQ" | — | **RETRACTED** — QTE reports a contrast, PQ a level; not comparable |
| LPLR seed 555 returns `-557478.7` | 1e6 relative error | **measured — the second most solid finding** |

### The transferable lesson

This audit produced **one** finding that survived every check: the `score`
spelling divergence on `DoubleMLPLR`, where the port accepts
`"partialling-out"`, upstream accepts `"partialling out"`, and both failures
abort loudly and reproducibly.

Everything else I promoted from a single fixture collapsed under a seed sweep
— `normalize_ipw`'s branch gap (7.5e-3 → 0.98 ratio over 8 seeds), its
accuracy advantage (6.2× → 4/8 seeds), and the PQ "different functionals"
claim (structural sensitivity → finite-sample noise).

And three separate claims collapsed for a **different** reason: I compared
estimators against a truth they do not estimate (CVaR vs a median, QTE
contrast vs a treated median, port-vs-upstream without settling which
functional each reports). That is a cheaper mistake to avoid than the seed
sweep — it is caught by reading one doc comment — and I made it three times.

**Single-fixture coefficient differences are not evidence in this package.**
Upstream's own `DoubleMLPQ` drifts ~1e-2 across processes on identical data,
so any measured gap below ~1e-2 has to be swept before it can be called
anything. I violated that four times, and each violation was caught only
because I eventually went back and repeated.

The things that did survive were all **structural**: read from source, or a
hard abort that reproduces exactly.

## Retracted and corrected, item by item

1. `PQ_FUNCTIONAL_DIVERGENCE_1550.md` — *"THE TWO ESTIMATORS COMPUTE
   DIFFERENT FUNCTIONALS"*: **retracted.** They agree to 8.3e-14.
2. Same file — *"CVAR is the working reference for what the upstream-faithful
   form looks like"*: **withdrawn.** That inference came from an `ml_g`
   sensitivity that is a finite-sample effect, not a structural one.
3. Same file — *"no single default explains the gap between them"*:
   **retracted.** One default explains it entirely.
4. `NORMALIZE_IPW_1550.md` — *"a capability gap, not a numerical one worth
   chasing"*: **reversed.** On a nonlinear-median fixture it is worth 6.2× in
   accuracy.

## Not established

- Whether `DoubleMLQTE` should match the port's `DoubleMLPQ` (it does not;
  `0.120` vs `0.0158`), and why.
- Whether the `ml_g` finite-sample sensitivity has a practical consequence at
  other sample sizes — the 13-digit agreement is one fixture, one seed.
- Whether the same `normalize_ipw` accuracy gap holds for `DoubleMLCVAR` and
  for the DID family. Only PQ was tested.

## Provenance

- `_verify/gen_v1560_pq_accuracy.py` — DGP, brute-force truth, upstream
  references, generated `.mbt` fixture.
- `probe_v1560ok1_test.mbt` — throwaway, deleted after the run.
- Upstream runs against the vendored **0.11.4** tree; installed is **0.11.3**.
- Upstream's cross-process drift (~1e-2, recorded in `NORMALIZE_IPW_1550.md`)
  applies to absolute coefficients. The 8.3e-14 port-vs-upstream agreement is
  a within-run comparison and is not affected by it — but the `0.0025` vs
  `0.0158` accuracy gap is only ~6× the drift, so **treat the 6.2× as
  indicative, not established** until it is repeated across seeds.