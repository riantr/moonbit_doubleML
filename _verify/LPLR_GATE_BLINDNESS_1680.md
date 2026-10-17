# LPLR: the upstream comparison could not see the estimator, and D1 explains why

_1680 series. Measured on `b922349` plus the uncommitted LPLR gate work._

## 1. What existed, and why it was blind

`examples/lplr` is one of the twenty e2e-checked examples, and
`validate_lplr_with_python.py` **is** wired into CI (`check.yml:105` globs
`validate_*_with_python.py`). So this was not "a gate in no workflow" — it
was a gate that ran and could not fail for the reason anyone would assume it
existed to catch.

It compares two different datasets:

| side | dataset |
|---|---|
| MoonBit | `examples/lplr/main.mbt::build_dgp` on `chacha8_rng(3141)` |
| upstream | `build_simplified_lzz2020`, a **numpy** DGP |

Then it attributes the resulting gap to upstream noise — "theta standard
deviation of 0.198 on a true value near 0.5" — and sets the band to
`3 * max(se_up, se_hr, se_moonbit)` floored at `0.10`. Measured se is
~0.27 here, so the band is **~0.81**.

Two things follow, and only the first is stated in the file:

1. The band is legitimately demanded by the fold draw. On **fixed data**,
   re-drawing only the partition moves theta by **sd 0.308** (12 pinned
   splits; min 0.154, max 1.155 around a true alpha of 0.5). The width was
   not arbitrary.
2. But because the datasets differ too, that width was being spent on a
   mismatch that could be *removed*. No estimator-level difference below
   ~0.6 was observable. D1 is worth 0.114 — inside the band, and therefore
   invisible.

## 2. Upstream accepts a pinned partition, so the noise can be removed

`DoubleMLLPLR` sets `_double_sample_splitting = True`, so the public
`set_sample_splitting` raises, and 0.11.3 ships no public setter for the
inner split. Measured facts about installing one directly:

- storage is the instance-dict keys `_smpls` (outer) and `_smpls_inner`
  (inner) — **not** the name-mangled `_DoubleML__smpls`, which is only a
  property;
- nesting is `_smpls = [[fold, fold]]` (one element per repetition) and
  `_smpls_inner = [[inner_folds_of_fold0, inner_folds_of_fold1]]`;
- the inner split is nested **per outer fold** and partitions that fold's
  **training** rows (measured: 50+50 = the 100-row outer train set at
  n=200, n_folds=2);
- indices must be `ndarray`, not lists — `lplr.py:250` does
  `train[y[train] == 0]`.

With that, refitting under a pinned partition is **bit-identical**
(`|dcoef| = 0.000e+00`). So the comparison does not need a 0.81 band.

The port's own outer partition is reproducible: `fit` draws
`kfold(n, n_folds, seed + r)` (`lplr.mbt:758`).

## 3. A second divergence upstream cannot mirror at all

The port's defaults are `linear_regression()` for **both** learner slots,
so its `ml_M` — whose target is a probability — is fitted by OLS. Upstream
rejects that outright: `_check_learner(ml_M, regressor=False,
classifier=True)`.

So "fit upstream like the port's defaults" is impossible, and a comparison
against the default configuration would measure the **learner choice**, not
the estimator. The gate therefore compares a *matched-learner* configuration
(port `ml_g`=OLS / `ml_m`=logistic, mirroring upstream's own
`LinearRegression` / `LogisticRegression` pairing) and emits the default
configuration too, so the size of the learner effect stays visible.

## 4. What the port's 2-slot API actually compresses

Upstream needs three *required* learners plus one optional; all four are
load-bearing (`plm/lplr.py`):

| upstream | role | port |
|---|---|---|
| `ml_M` | `M_0(D,X) = P[Y=1\|D,X]`; supplies the score weight `w = logit(M)` | `ml_m` |
| `ml_t` | auxiliary regression `t_0(X) = E[W\|X]`, `W = logit(M_0)` | `ml_g` |
| `ml_m` | `m_0(X) = E[D\|X]` fitted on the **`Y == 0` rows** under `nuisance_space` | aliased |
| `ml_a` | inner propensity for `d_tilde`; `clone(ml_m)` when absent | `ml_m` |

The port's 2-slot API is a faithful compression of the *structure*
(`lplr.mbt:644`: "route `ml_g` to the `ml_t` slot and `ml_m` to the
binary-classification slots"). It is not faithful on `ml_m`: the port sets
`m_pred = a_pred` (`lplr.mbt:810`) where upstream fits `ml_m` separately on
the `Y == 0` subsample (`lplr.py:247-252`). **That is D1.**

## 5. D1 measured, not assumed — and then measured again

The in-body note says this "was tried and reverted", citing a collapse
(`beta_start` reaching -4.75, `mean(psi_deriv)` -3.2e-8, Newton
non-convergence, `se` -2.4e6) on `lplr_test`'s n=120 fixture. The note also
says why upstream is immune: **its default `ml_m` is a `LogisticRegression`**.

Implementing the filter behind `match kind { NuisanceSpace => ... }` and
re-measuring on the MATCHED-LEARNER configuration, same rows, same outer
partition, 5 inner seeds each side:

| | port (matched) | upstream | gap | port inner sd | SE ratio |
|---|---|---|---|---|---|
| before D1 | 0.506110 | 0.392214 | **0.113896** | 0.030143 | 1.3256 |
| after D1 | 0.398209 | 0.392214 | **0.005995** | 0.007654 | 1.0979 |

**19x** gap reduction, and the SE ratio moves most of the way to 1.

The `instrument` score is a built-in control for this mutation and it did
not move at all (0.436704 before and after) — correct, because upstream
applies the `Y == 0` filter only under `nuisance_space`; under `instrument`
it uses `weights = M*(1-M)` with `filtered_smpls = smpls`. A mutation that
moved both arms would have been a different defect.

The non-convergence cliff moves outward, and it moves **differently for each
of the two fixtures the v1450 gates use**, which is why it had to be
measured twice rather than once:

| alpha | 1.0 | 1.25 | 1.5 | 1.75 | 2.0 | 2.5 | 3.0 |
|---|---|---|---|---|---|---|---|
| n=1000, seed=11 (gates 2–5) | 0 | 0 | 0 | **1** | 1 | 1 | 1 |
| n=800, seed=17 (gate 6) | 0 | 0 | 0 | 0 | 0 | 0 | **1** |

The cliff is not a constant of the estimator — it moves with n and seed.
Re-fixturing the gates from either fixture's value alone would have asserted
a property of neither.

## 5b. CORRECTION: the 19x does not license shipping D1

The table above is real, and it is **not** sufficient grounds to ship. It
was measured on the *matched-learner* configuration. The estimator's
*default* configuration is a different thing, and it was checked only on the
example's own n=500 fixture — which D1 handles fine (`lplr_ns_theta`
0.464110 → 0.393779, `lplr_ns_se` 0.271114 → 0.225975).

Running the full example corpus found it:

```
[8/11] DoubleMLLPLR nonlinear fit invariants ...
FUZZ FAIL: lplr CI identity (trial=5, se=13072741.313829884)
```

`se = 1.3e7` on fuzz trial 5. That passes the corpus's own declared bound
(`se < 1.0e10`, `examples/fuzz/main.mbt:478`), and the CI-identity check
fails only because it compares against an **absolute** `1e-9` on a quantity
of magnitude `z*se = 2.6e7`, where double rounding is already ~5.6e-9. But
the SE itself being 1.3e7 on a binary-outcome partially-logistic model is
the real finding: the fit is nearly unidentified there.

Mechanism — and it vindicates the original revert. The port's `ml_m`
defaults to **`linear_regression()`**, and D1 fits that OLS on the `Y == 0`
subsample; the in-body note recorded exactly this (`beta_start` -4.75,
`mean(psi_deriv)` -3.2e-8, `se` -2.4e6). The note's explanation is right in
substance but wrong in a way that matters: **upstream has no default `ml_m`
at all** — it is a required argument, and every upstream call site in this
repo passes a classifier. The logistic learner in the 19x table was a choice
this repo's validator made, not an upstream default.

So the two configurations genuinely diverge under D1, and the measured 19x
belongs to the one the example does *not* use.

⇒ **D1 is not shipped.** It requires first changing the port's default
`ml_m` to a bounded (logistic) learner — a separate behavioural change
affecting every LPLR caller, with its own evidence.

Two lessons, both of which cost a cycle here:

1. **A tight band on a matched configuration says nothing about the
   configuration that ships.** This gate compares matched learners *by
   necessity* (upstream rejects a regressor for `ml_M`), which makes it a
   poor instrument for a question about defaults.
2. **The test suite was green (1115/1115) while the estimator was broken.**
   The LPLR invariants live in `examples/fuzz`, not in `moon test`, so
   `moon test` cannot see them. Regenerating the e2e table — which runs
   every example — is what surfaced it.

## 6. Band, measured from both sides

`set_sample_splitting` replaces the **outer** partition only
(`lplr.mbt:1630`) — the port's inner draw still comes from
`self.seed + r*1000 + 7`. That is the residual, so both sides' inner
spreads are measured and the band is built from them rather than assumed:

```
band = 3 * sqrt(sd_port_inner^2 + sd_up_inner^2)
```

Measured: sd_port 0.030143, sd_up 0.043537 → band 0.158860.

## 7. The gate discriminates — 7/7 mutation arms

Baseline is asserted green before any mutation, and every arm is written to
disk, re-read, and asserted present before the gate runs; each restores its
own file in a `finally`.

| arm | what it breaks | expected | result |
|---|---|---|---|
| M1 | emitter scales the matched coefficient ×1.3 | FAIL | KILLED — gap 0.265729 vs band 0.175723 |
| M2 | gate hands upstream a rolled partition | FAIL | KILLED |
| M3 | gate hands upstream a permuted treatment column | FAIL | KILLED — gap 0.326383 vs band 0.144930 |
| M4 | self-check constant drifts | FAIL | KILLED — gate refused to compare |
| M6 | port score: `expit(-r_hat)` → `expit(r_hat)` | FAIL | KILLED — gate refused to compare |
| M7 | port score: `d_tilde` sign flipped | PASS | **EQUIVALENT**, measured shift exactly 0 |
| M5 | inner-seed list reordered (control) | PASS | as expected |

Two of these are worth keeping:

**M1 was re-targeted, not counted as a survivor.** Its first form mutated
`lplr_match_ns_theta` and the gap came back *bit-identical*. The cause was
the arm, not the gate: the gate compares the `lplr_match_seed*` probes and
never reads that value. A surviving mutation and a mutation aimed at dead
output look identical from the verdict alone, so the check is whether the
number moved at all.

**M7 is a measured property of the estimator, not a hole in the gate.**
`psi` is `psi_hat · d_tilde · (…)` in both arms, so negating `d_tilde`
negates the whole score and the Newton root of `mean(psi)` is unchanged.
The coefficient therefore *cannot* see a global sign flip in `d_tilde`, at
any sample size. Recorded so a later reader does not re-derive it.

M6 is killed by the self-check rather than by the band: flipping `psi_hat`
moves `lplr_ns_theta` (the default configuration), which the self-check
pins to the example's printed value. That is a kill, but it means the
self-check is the stricter of the two paths.

## 7b. The prerequisite, tested: and it is INSUFFICIENT

§5b named the prerequisite and then stopped. This section is the test of it.

**Change 1 — the default `ml_m` becomes a classifier.** `ml_m` drives both
binary-target nuisances, `M_hat = E[Y|X]` (fitted on `y`) and
`a_hat = E[D|X]` (fitted on `d`), so with an OLS default both escape `[0, 1]`.
Upstream refuses exactly that: `_check_learner(..., classifier=True)` for
`ml_M` and `_check_is_propensity` for `ml_m` (`lplr.py:268-269`). Changing the
default to `logistic_regression` is a correctness fix in its own right and it
ships.

**Change 2 — enable D1 on top of it.** The gap collapses, and further than
§5 predicted because `instrument` needs the *other* half of upstream's
convention (`weights = M*(1-M)`, `filtered_smpls = smpls`,
`lplr.py:244-252`) which the alias had been dropping too:

| score | gap before | gap after | collapse |
|---|---|---|---|
| `nuisance_space` | 0.113896 | **0.005995** | 19x |
| `instrument` | 0.024022 | **0.000526** | **46x** |

SE ratio 1.3256 → 1.0979. `pyexample_lplr.py` PASSes.

**And `examples/fuzz` still fails.**

```
before D1                      trial=5,  se=13072741.313829884
logistic default + D1          trial=25, se=14771494.100785563
```

Different trial, same failure. ⇒ **"bound the default `ml_m` first" is
measured insufficient.** The premise §5 and §5b both relied on is false.

Note the shape of the error: the prerequisite was *necessary-looking* and
*testable*, and it was not tested until now. It had the confidence of a
mechanism (`se` exploding ⇒ propensity unbounded ⇒ bound the propensity) with
no measurement behind the middle step.

**Where the blow-up actually comes from.** The propensity is now in `[0, 1]`
by construction, so it is not the cause. What is left is `beta_start`:

```
r_hat = t_pred - beta_start * a_pred
psi_deriv carries exp(r_hat)
```

so a runaway `beta_start` inflates `r_hat` and collapses `mean(psi_deriv)`
exactly as the original revert recorded (`beta_start` -4.75,
`mean(psi_deriv)` -3.2e-8, `var_est` -2.4e6). That is **D3** — one
fold-averaged `beta_start` where upstream uses per-fold `beta[test]` — already
listed as open in §8.

**Shipped state, measured on every one of these:**

| configuration | fuzz | `moon test` | LPLR gate |
|---|---|---|---|
| logistic default, D1 held off | ALL 11 SURFACES PASSED | 1115/1115 | PASS |
| logistic default, D1 on | FAIL trial 25 | — | PASS |

So the default change ships and D1 does not. D1 is now blocked on **D3**, not
on the default — which reorders the work and is a bigger change, since it
alters what the Newton loop iterates over.

## 7c. CORRECTION (v0.163.0): `examples/fuzz` passes today

§7b and §8 both record a fuzz failure. Re-measured:

    $ moon run examples/fuzz --target native
    === fuzz harness (300 trials per surface, fixed seed 20260824) ===
    [1/11] .. [11/11]   all OK
    ALL FUZZ SURFACES PASSED (no invariant violations)

**The repository is green.** Both recorded failures were in configurations that
do not ship:

| trial | se | configuration | status |
|---|---|---|---|
| 5 | 13072741.313829884 | old OLS `ml_m` default | fixed by the classifier default (v0.163.0) |
| 25 | 14771494.100785563 | bounded default **+ D1** | D1 is **off** |

So "D1 is blocked on D3" is a statement about a variant that is switched off,
not about a live red gate. §7b's framing — "it still cannot ship" — is about
enabling D1, and that remains true; but §8's "D3 is the live blocker" reads as
though something is currently red, and nothing is.

Two consequences worth stating plainly:

1. **The source comment was the thing that misled.** `lplr.mbt` carried the line
   "It still cannot ship: `examples/fuzz` FAILS" inside a file, with no marker
   that "it" meant the not-yet-enabled conditioning. This session read it as a
   live failure and had to spend a `moon run` discovering otherwise. Rewritten
   to name the variant, the trial numbers, and the green measurement.
2. **`fuzz` is not run by any workflow.** It is registered `scope="full"`, and
   neither `check.yml` nor `publish.yml` passes `--full` except the service step
   (`--only api_test,security_dast`). Its passing is a local measurement, not a
   property CI holds in place.

### D3 restated from upstream's source, not from the port's comment

`doubleml/plm/lplr.py:315-326` and `:345`:

    beta = np.zeros(d.shape, dtype=float)
    for i, (train, test) in enumerate(smpls):
        ...
        beta[test] = np.sum(d_tilde * w) / np.sum(d_tilde**2)

    # Use preliminary beta estimates as starting value for root finding
    self._coef_start_val = np.average(beta)

    ...
    r_hat["preds"] = t_hat["preds"] - beta * a_hat["preds"]

Upstream keeps `beta` as a **per-observation array** — each test row carries
its own fold's value — and uses `np.average(beta)` **only** as the Newton
starting value. This port uses a single fold-averaged scalar for *both*, so
`r_hat = t_pred - beta_start * a_pred` is wrong on every row whose fold's beta
differs from the mean, and `exp(r_hat)` — which appears in `psi` as well as
`psi_deriv` — amplifies exactly that error.

A second difference rides along: `np.average(beta)` averages over the
n-observation array and is therefore **fold-size weighted**;
`beta_acc / beta_count` is the unweighted mean of per-fold betas. They coincide
on equal-size folds and differ on unequal ones — cluster folds, or an external
partition.

**So D3 is a genuine upstream-parity defect, and it is independent of D1.** Its
observable is the gate gap `pyexample_lplr.py` already prints every run
(0.113896 / 0.024022 today), not a fuzz blowup. It also changes a published
`pub fn` signature, so it wants its own increment with its own before/after
gap — not a drive-by on the strength of a failure that does not exist.

## 7d. D3 IMPLEMENTED, MEASURED, AND REVERTED — it makes parity worse

The D3 change was implemented in full and measured, because "it is a real
divergence" and "fixing it improves agreement" are different claims and only
one of them had been tested.

**What was changed** (all four parts, matching upstream's source):

1. `lplr_score_at`'s `beta_start : Double` became `beta : Array[Double]`, with
   `r_hat = t_pred[i] - beta[i] * a_pred[i]`.
2. `fit` stopped averaging the per-fold `b_f` away and instead wrote each
   fold's value into that fold's **test** rows — `beta[test]`, as upstream does.
3. The Newton start became `mean(beta_row)`, matching `np.average(beta)`.
4. The fit cache stored the length-n array instead of a packed length-1 scalar.

`moon test` stayed 1122/1122 — including the five `lplr_score_at` tests, whose
expected literals did not move, because a constant array gives the same `r_hat`
a scalar did.

**The gap got worse.**

| | before | after D3 | |
|---|---|---|---|
| nuisance_space port mean | 0.506110 | 0.525607 | moved AWAY |
| nuisance_space upstream mean | 0.392214 | 0.392214 | fixed reference |
| **nuisance_space gap** | **0.113896** | **0.133393** | **+17%** |
| instrument port mean | 0.436704 | 0.451248 | moved AWAY |
| **instrument gap** | **0.024022** | **0.038566** | **+61%** |

The gate still PASSes — the band is 3 sigma over five inner splits and moved
with the point estimate — which is exactly why the band is not the instrument
for this question. The band answers "are these two numbers distinguishable";
the gap answers "how far apart are they", and only the second one registers a
change as an improvement.

**Reverted.** A faithful transcription that moves a published coefficient
further from upstream is not a fix, and shipping it would trade a documented
divergence for a silent one.

### Why the correct formula made the answer worse

Because **`beta` is not the dominant divergence — its inputs are.** Upstream
computes

    w          = logit(M_hat["preds_inner"][i][train])    # INNER OOF of ml_M
    d_tilde    = (d - a_hat["preds_inner"][i])[train]     # INNER OOF of ml_a
    beta[test] = sum(d_tilde * w) / sum(d_tilde**2)

and this port (D2) computes `w` from the **outer** OOF, passing
`a_inner_for_fold` as both `m_inner` and `a_inner`. So `b_f` here was never
upstream's `b_f`. Applying upstream's *combination rule* to a non-upstream
`b_f` does not reproduce upstream's beta — it changes the wrong quantity, and
the fold-to-fold spread it introduces lands on rows where the old scalar had
smoothed it over.

That predicts the fix has to land as **D2 + D3 together**, not D3 alone, and
that the order matters: D3 on its own measures D2's residual error, and D2 on
its own cannot be scored while the combination rule is still wrong. Both are
needed before either is worth shipping, and the honest next step is to
implement D2, then D3 on top, and measure the gap once — not to keep landing
them separately.

Nothing in this section is speculative: every number above came from
`pyexample_lplr.py`, whose band, fixture guard and refusal behaviour all ran.
The reproduce script is `_verify/_lplr_d3_gap_1680.py`; it patches an
out-of-repo COPY of the gate's expected constant so the repo golden is never
edited to match whatever the change produces. That ordering matters — editing
the golden first would have blessed a regression and reported it as agreement.

## 7e. D2 IMPLEMENTED AND MEASURED — it is where the gap lives (also reverted)

The §7d conclusion said D2 must land first. It was implemented and measured.

**The change**, all matching `plm/lplr.py:317-323` and `:332-341`:

1. added `m_inner_per_fold`, the INNER cross-fit of `ml_M` on `(X, D) -> Y`,
   with the same seed offset as `a_inner_per_fold` (upstream draws both inner
   partitions from the one `_DoubleML__smpls__inner`, so they must coincide);
2. `W_inner` now reads it, so `w = logit(clip(M_inner))` instead of
   `logit(M_outer)` — this also feeds the `ml_t` inner cross-fit;
3. `prelim_beta_per_fold` now receives `m_inner` and `a_inner` as SEPARATE
   arrays. It had been passed `a_inner` for both, so `beta`'s `w` was being
   rebuilt from `ml_a`'s prediction where upstream uses `ml_M`'s;
4. the outer `ml_M` fit `m_hat_outer` lost its last reader (upstream consumes
   it only through `d_tilde = d - m_hat`, which this port aliases to `a_pred`
   while D1 is off) and was deleted.

**The gap collapsed.**

| | before | after D2 |
|---|---|---|
| nuisance_space gap | 0.113896 | **0.027097** — 4.2x |
| instrument gap | 0.024022 | **0.008251** — 2.9x |
| SE ratio, nuisance_space | 1.3256 | **1.1480** |
| SE ratio, instrument | 1.0724 | **1.0238** |

So the LPLR divergence is dominated by `W_inner`'s outer OOF, not by `beta`.
That is the opposite of what §7b concluded and what I carried into D3, and it
is the same lesson one level down: the *combination rule* was wrong, but the
*inputs* were wronger, and fixing the rule alone moved the answer the wrong
way because it applied a correct operation to an incorrect argument.

## 7f. Why D2 is still not shipped: it silences the warning channel

D2 turns four gates red — `expand_v145_test.mbt:38-136` — all of which assert
that `make_lplr_LZZ2020(1000, alpha=1.5, seed=11)` **must** warn because the
objective goes rootless at `alpha >= 1.25`. After D2 it converges silently.

A vanishing warning has two causes with opposite responses, so a temporary
probe swept `alpha = 0.25 .. 2.25` (9 values, a 9x range) on the port:

| alpha | 0.25 | 0.5 | 0.75 | 1.0 | 1.25 | 1.5 | 1.75 | 2.0 | 2.25 |
|---|---|---|---|---|---|---|---|---|---|
| coef | .0694 | .3216 | .5971 | .8277 | 1.0471 | 1.3146 | 1.5170 | 1.6918 | 2.0479 |
| se | .1361 | .1532 | .1783 | .2063 | .2411 | .2873 | .3362 | .3837 | .5099 |
| warnings | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

**D2 does not produce garbage at high alpha — it produces a smooth, monotone,
sensible answer across the whole range.** So the `alpha >= 1.25` degeneracy was
a *symptom* of the outer-OOF `W_inner`, not a property of the design.

But: **the warning channel then has no reachable input in that range**, while
four gates assert it does. Shipping D2 would mean either deleting those gates —
giving up the "the solver never returns a confident wrong number" guarantee on
no evidence that the failure mode is gone — or leaving them red. Neither is
acceptable, and I did not find an input that still triggers non-convergence, so
I cannot re-base them.

**Reverted**, and the baseline re-verified exactly (`0.113896 / 0.024022`,
PASS, `moon test` 1122/1122).

What would unblock it, in order:

1. **Sweep wider** for a still-degenerate input — other `n`, `n_folds`,
   `n_folds_inner`, `score`, and the degenerate designs `expand_v1410_*` built.
   If one exists, re-base the four gates onto it and ship D2.
2. If none exists, the channel is genuinely unreachable for LPLR after D2, and
   the four gates should be replaced by a gate on the CHANNEL (does it still
   fire when handed a `degenerate_derivative`?) rather than on one fixture.
3. Only after (1) or (2) is settled does D3 become worth retrying on top — and
   per §7d it should be re-measured there, not assumed to help.

Note the ordering trap this exposes: §7d's advice to "do D2 then D3" was right
about the *cause* and wrong about the *cost*, because D2 has a gate consequence
that has to be resolved before either is worth landing.

### A trap worth recording: a gate run from a copy finds the wrong cwd

The first attempt at that script failed with `moon run examples/parity exited
-1`. The gates derive their working directory from
`HERE = os.path.dirname(os.path.abspath(__file__))`, so a patched copy parked
in `_verify/` runs `moon run` from there and fails. The error looks like a
build failure and is not one. A patched copy has to live in the repo root,
which is why the script writes it there and removes it in a `finally`.

## 8. Status

- **Shipped in this series**: `sec_lplr_upstream` in `examples/parity` and
  `pyexample_lplr.py` — a shared-rows, shared-partition gate that is
  materially stronger than the validator it complements.
- **Also shipped now**: the default `ml_m` is a classifier. Correctness fix in
  its own right — both binary-target nuisances were escaping `[0, 1]`, which
  is what upstream refuses (§7b). Measured green: fuzz 11/11, `moon test`
  1115/1115, gate PASS.
- **Still not shipped**: D1. Its prerequisite was tested and found
  insufficient (§7b); it is blocked on **D3**, the fold-averaged
  `beta_start`. Re-measured per §7c: this blocks *enabling D1*, and is not a
  live failure today.
- **Still open**: D2 (`W_inner` uses outer OOF; upstream uses inner OOF) and
  D3 (one fold-averaged `beta_start`; upstream uses a per-observation
  `beta[test]` array in the score and the average only as the Newton start).
  **D3 is a real parity defect in its own right** and its own increment; see
  §7c for the source lines.
- **D3 was implemented, measured, and reverted** (§7d). Correct against
  upstream's source, but it moves the gate gap the WRONG way — +17% on
  `nuisance_space`, +61% on `instrument` — because `b_f` is computed from
  `w = logit(M_outer)` rather than upstream's inner OOF, so D3's inputs are
  D2's divergence. **D2 must land first**, then D3 on top, measured once.


