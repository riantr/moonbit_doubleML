# LPLR: the upstream comparison could not see the estimator, and D1 explains why

_1680 series. Measured on `b922349` plus the uncommitted LPLR gate work._

> **Re-audited 2026-10-20 (round 17).** This is the **only** `_verify/`
> record the shipped `README.mbt.md` cites (at its lines 1162 and 1217), so
> every promise made here is a promise the README inherits. The record was
> added at `d3ac364` (2026-10-16) and had never been re-audited; 33 commits
> have since touched the record and 18 have touched the port's LPLR surface.
>
> **What was re-measured live on 2026-10-20**, against upstream `doubleml`
> **0.11.4** -- the vendored sdist these numbers were originally taken
> against:
>
> | | as written | now |
> |---|---|---|
> | upstream's own failure rate on the n=66 rows (27g) | 17/40 (42%) implausible coefficients, 18/40 root warnings | **reproduced exactly** by `_verify/_lplr_upstream_fragility_control_1680.py` |
> | upstream's `mean(beta)` over the same 40 draws (27g) | mean 2.5554, sd 3.3939, range [-3.2057, 13.8508]; 14/40 above the basin edge; the port's 6.842375 at the 90th percentile | **reproduced exactly** by `_verify/_lplr_startval_bias_1680.py` |
> | the `moon test` counts quoted below | `1115/1115` (twice), `1122/1122` (twice) | **all four were TRUE when written and are now stale.** `1115` was the native count at `b223a44` / `4775218`; `1122` was the wasm-gc count at `c744fc4` / `e7471e5`. The counts are now **1117 native / 1123 wasm-gc** |
> | `moonbit_doubleML/lplr.mbt` line pointers (16 of them) | written against the `d3ac364` tree | **8 of the 16 moved** -- that file changed by 624 lines -- and all 16 are re-anchored below by content |
> | the method scripts this record names | 10 named, **none of them tracked** | **now tracked**, path-portable, and each one announces which upstream it ran against |
> | 27b/27c: the causal test and the 16-cell swap | the port's values make upstream's own solver diverge; `beta` alone does it | **reproduced exactly** by `_verify/_lplr_nuisance_causal_1680.py` -- both `PORTMETA` blocks, every one of the 16 cells |
> | 27f: the basin and the derivative collapse | 8/41 fine-scan starts converge over `[0.0, 3.5]`; score -0.0842799 / -0.111909; deriv -2.77093e-02 / -8.06571e-05; factor **344**; first step **-1381** | **reproduced exactly** by `_verify/_lplr_basin_scan_1680.py`, which is **new in this round** -- 27f previously had **no method script at all**, so the README's "344" and "-1381" had no witness |
> | the witness for 27a/27b | `_fuzz_dump_1680.log` | **the WRONG FILE, and reproducibly so.** The file the first draft named is not in this repository -- it is a scratch capture the project's own `.gitignore` keeps out of the tree -- and the file that IS tracked, `_verify/_lplr_r17_1680/_fuzz_run_1680.log`, is byte-identical to it (sha256 prefix `6903e784`) and holds the harness's PASS/FAIL transcript, not rows -- and re-running the script that creates it reproduces that byte-for-byte, because the dump probe was reverted from the shipped build. The rows are in `_verify/_lplr_r17_1680/_port_dump_1680.log` (2 `PORTMETA` blocks, n=66 p=6 seed=96696) |
>
> **What is NOT verified here.** The D2/D3 A/B numbers in sections 8-10, the
> clamp A/B table in section 23, the `m_hat` conditioning in sections 24-25 and
> the 25g/25h result are **historical results of experiments that were reverted
> and are not re-runnable from the tree**: they needed a temporary source patch
> to `examples/fuzz` / `moonbit_doubleML/lplr.mbt` that was reverted in the
> same commit that consumed it, so `_verify/_lplr_fuzzrows_upstream_1680.py`
> now prints `no FZZMETA blocks found -- was the dump probe reverted?` and
> exits 3. The 27g control that **replaced** 25g does re-run, and did. The
> *selection* step that picked trial 2's block out of 14 is **not reproducible**
> from the tree -- its inputs (the `FZZMETA` row dump and the 14-block
> `PORTMETA` run) were never committed -- so only its selected output,
> `_verify/_lplr_r17_1680/_port_dump_1680.log`, is. The upstream readings
> were taken against the **vendored** `doubleml-0.11.4` sdist, which is
> deliberately not committed
> (1.1 MB); the scripts now print which upstream they used, and on a machine
> without that tree they fall back to the **installed** `doubleml` and may
> differ.
>

## 1. What existed, and why it was blind

`examples/lplr` is one of the twenty e2e-checked examples, and
`validate_lplr_with_python.py` **is** wired into CI (`check.yml:114` globs
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
`kfold(n, n_folds, seed + r)` (`lplr.mbt:781`).

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
(`lplr.mbt:665`: "route `ml_g` to the `ml_t` slot and `ml_m` to the
binary-classification slots"). It is not faithful on `ml_m`: the port sets
`m_pred = a_pred` (`lplr.mbt:928`) where upstream fits `ml_m` separately on
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
   *(1115 was the native count at `b223a44` (2026-10-16), where this line was
   written; it is **1117** today. The claim is that the suite was green, not
   what it counted.)*
   The LPLR invariants live in `examples/fuzz`, not in `moon test`, so
   `moon test` cannot see them. Regenerating the e2e table — which runs
   every example — is what surfaced it.

## 6. Band, measured from both sides

`set_sample_splitting` replaces the **outer** partition only
(`lplr.mbt:775-782`) — the port's inner draw still comes from
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
| logistic default, D1 held off | ALL 11 SURFACES PASSED | 1115/1115 *(the native count at `4775218`; **1117** today)* | PASS |
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

`moon test` stayed 1122/1122 — the wasm-gc count at `c744fc4`; it is **1123**
today — including the five `lplr_score_at` tests, whose
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
PASS, `moon test` 1122/1122 — the wasm-gc count at `e7471e5`; it is **1123**
today).

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

- **D2 and D3 both shipped** (v0.163.0). `W_inner` is now built from the INNER
  cross-fit of ml_M, `beta` is per-observation, and `m_hat_outer` is deleted.
  Gate gaps, measured against upstream on the same rows and the same outer
  partition:

  | | before | D2 only | D2 + D3 (shipped) |
  |---|---|---|---|
  | `nuisance_space` gap | 0.113896 | 0.027097 | **0.007307** |
  | `instrument` gap | 0.024022 | 0.008251 | **0.010609** |
  | SE ratio, `nuisance_space` | 1.3256 | 1.1480 | 1.1549 |
  | SE ratio, `instrument` | 1.0724 | 1.0238 | 1.0269 |

  **Read the `instrument` row honestly.** D3 improves `nuisance_space` 3.7x
  further and moves `instrument` the wrong way by 0.0024. That movement is
  NOT resolvable by this gate: the port mean is over 5 inner draws with
  sd ~0.03, so the standard error of the mean is ~0.014 and the band is 0.18.
  D3 was shipped because it is the faithful port of `plm/lplr.py:315-323` and
  `:345`, not because it scores better; a knowingly-divergent `beta` would
  have been shipped otherwise, which is the thing this audit exists to
  remove. The evidence for that decision is upstream's source, read directly.

- **Still not shipped**: D1 (`ml_m` is fitted on the whole sample rather than
  conditioned on `Y = 0`). Its two recorded reasons for being held off were
  both measured false in section 7b; what remains is the non-convergence
  cliff, and D2 moved that cliff rather than removing it.

## 9. What D2 did to the warning channel, and what it cost

### 9a. D2 silences the alpha cliff. It does NOT silence the channel.

The recorded blocker was that D2 "silences the warning channel", which would
have made the four `expand_v145_test.mbt` gates unfixable. Measured, on D2
code, over 19 configurations spanning `n` / alpha / `n_folds` /
`n_folds_inner` / `score` / seed:

    before D2:  swept=19  warned=16  silent=3
    after  D2:  swept=19  warned=6   silent=13

So the channel was never silenced; what changed is *which* designs warn. A
3 x 4 x 2 grid of `n` in {200, 400, 800, 1000} x alpha in {0.25, 1.0, 1.5,
2.5} x seed in {11, 17} maps the new region:

    n=200   warns at 4 of 8 cells (all of seed 11, plus alpha=2.5 seed 17)
    n=400   warns at 1 of 8  (alpha=0.25, seed 11)
    n=800   0 of 8
    n=1000  0 of 8

The warning region became a SMALL-SAMPLE phenomenon. That is a better
diagnostic than the one it replaced -- a non-convergence warning should track
a property of the data, and sample size is one -- but it is a different
invariant, and the old gates described the old one.

### 9b. GATE 6's invariant is dead, not merely mis-based.

GATE 6 asserted that the set of warning-producing alphas is a SUFFIX, read off
`(800, alpha, 17)`. Run unchanged under D2 that sweep returns

    [0.25, 0.5, 0.75, 1.0, 1.25, 1.5]  ->  [0, 0, 0, 0, 0, 0]

The invariant now holds **vacuously**: monotone, yes, but with no warning
anywhere in it. The guard that caught this was the `assert_true(warned[last])`
on the degenerate end, not the monotonicity itself. Keeping a monotonicity
assertion that every all-zero sweep satisfies would be precisely the "gate
that cannot fail" this audit has been removing, so GATE 6 was replaced with
the axis the measured region actually runs along -- sample size -- asserting
both ends, so it cannot pass on a dead channel either.

### 9c. GATE 5 was vacuous, and stayed green through the change.

GATE 5 ("warnings are returned, not printed") compared `model.warnings()`
against a second call to `model.warnings()` on the same object. That holds
with equal ease when the channel returns nothing at all, and
`(1000, 1.5, 11)` had just become exactly such a channel. It was the one
gate that should have objected and it passed. It now asserts the fixture
warns *before* asserting the read is stable.

### 9d. Two absolute tolerances were asserting luck, not arithmetic.

Both CI-identity checks were reading a quantity that scales with `se` against
a constant. `confint()` returns the stored `coef_ +/- z*se_`, so recovering
the midpoint sums two nearly-cancelling numbers and recovering the half-width
subtracts them; both carry an error of order `eps * max(|hi|, |lo|)`.

`lplr_test.mbt` asserted `(hi + lo)/2 == coef` to `1e-12`. On its fixture
`|coef| ~ 4.6e6`, so `eps * |mid| = 1.03e-9` -- a thousand times the asserted
bound. It passed on native and failed on all three web backends:

    native    dev = 0
    wasm-gc   dev = 9.313225746154785e-10   = 0.91 ulp of the midpoint

One rounding step. The test had been passing on native because that step
happened to land on zero. `examples/fuzz/main.mbt` had the same defect at
`1e-9` against `se = 1.23e7`, and D2/D3 made it fire (trial 12). Both bounds
are now derived from the operands' own magnitude. They still discriminate by
eight orders of magnitude: a genuinely wrong interval misses at `O(z*se)`,
not `O(eps*|hi|)`.

**D2/D3 did not break either identity. They moved `se` to a magnitude where
the old bounds stopped being about floating point and started being about
chance.**

### 9e. Battery

`_verify/_lplr_v1630_battery_1680.py` -- 5 arms, 6 gate subjects, all
discriminate:

| arm | subject | verdict |
|---|---|---|
| M1 | `lplr_confint_identity`, `examples/fuzz` CI check | RED |
| M2 | `lplr_beta_is_read_per_row` (new) | RED |
| M3 | `lplr_warning_names_a_documented_stop_reason` | RED |
| M4 | `lplr_warning_states_the_numbers_are_not_a_solution` | RED |
| M5 | `lplr_warnings_report_the_degenerate_design`, `lplr_warnings_are_returned_not_printed` | RED |

M5's second subject is the strengthened GATE 5: under the pre-v0.163.0 GATE 5
it would have stayed green, which is the whole reason that arm exists.

One arm was written wrong first and the battery refused to score it: the
original M3 deleted `stop_reason` outright and produced an unterminated string
literal. It returned `ERROR`, not `RED` -- a mutation that does not compile
has tested nothing. `BUILD_ERROR` is now a distinct outcome from `RED`.
## 10. D1 measured again, on the D2+D3 baseline, and reverted

D1 is the last item the audit left open: upstream's `m_hat` is NOT `a_hat`.
`plm/lplr.py:244-264` fits `ml_m` with per-score conditioning --

    if self.score == "instrument":
        weights = M_hat["preds"] * (1 - M_hat["preds"])
        filtered_smpls = smpls
    elif self.score == "nuisance_space":
        filtered_smpls = [(train[y[train] == 0], test) for train, test in smpls]
        weights = None
    m_hat = _dml_cv_predict(ml_m, x, d, smpls=filtered_smpls, sample_weights=weights)

-- while this port aliases `m_pred = a_pred`, unconditioned and unweighted.
Implemented in full (both branches: `Fold::new` over per-fold
`train[y[train]==0]` for `nuisance_space`, `M*(1-M)` outer-OOF weights for
`instrument`), measured, and reverted.

The old section 8 numbers for D1 -- `nuisance_space` 0.113896 -> 0.005995,
`instrument` 0.024022 -> 0.000526 -- were measured on the **pre-D2** baseline
and no longer describe anything. Re-measured on top of D2+D3:

| | D2+D3 (shipped) | + D1 |
|---|---|---|
| `nuisance_space` gap | 0.007307 | 0.021078 (worse) |
| `instrument` gap | 0.010609 | 0.010994 (worse) |
| SE ratio, `nuisance_space` | 1.1549 | **0.9949** |
| SE ratio, `instrument` | 1.0269 | **0.9914** |

D1 is unambiguously the faithful port, and it is the only change in this whole
series that drives both SE ratios to ~1.0. It still does not ship, because the
quantity the gate measures moves the wrong way and the estimator gets less
stable.

### 10a. The stability cost, A/B on identical designs

`examples/fuzz` passes 11/11 on the shipped state and FAILS under D1 at trial
141 (`|coef| = 1.75e10` against a `1e10` ceiling). Is that marginal or
categorical? Replicated fuzz's exact design draw -- same
`n = rng.int(100) + 60`, same inline DGP, same default configuration -- over
200 designs, on both arms:

| | shipped (D2+D3) | + D1 |
|---|---|---|
| designs with `\|coef\|` > 1e10 | 2 | 3 |
| designs with `\|coef\|` > 1e8 | 7 | 10 |
| of those, warning | 7/7 | 10/10 |
| **max `\|coef\|`** | **1.03e11** | **7.93e12** |

So the tail is **not created** by D1 -- it is present in the shipped code, 2
breaches per 200 designs, and every single large-coefficient case warns in both
arms. What D1 does is make it **77x worse at the maximum** and add three more
blow-ups. The recorded hold's reason ("the non-convergence cliff") reproduces,
and it reproduces on the current classifier default, not only on the old OLS
one the original note blamed it on.

The warning channel catching 10/10 is the reason this is a judgement call
rather than an easy call: the diagnostic is honest about every blow-up. But
`examples/fuzz`'s `|coef| < 1e10` invariant is a real stability property, and
loosening it to accommodate D1 would be editing a gate to fit a regression.

### 10b. Why this is not the D3 decision again

D3 shipped despite moving the `instrument` gap the wrong way, because it is
the faithful port and it improved everything else. D1 gets the same treatment
and lands the other way:

- D3 improved **both gated gaps**. D1 worsens both (0.0073 -> 0.0211 and
  0.0106 -> 0.0110).
- D3 left every invariant intact. D1 breaks one the shipped state passes.
- D3's cost was inside the noise; D1's cost is a 77x larger tail.

An unmeasured proxy cannot adjudicate fidelity, but it can and does register a
regression. Fidelity to `m_hat`'s conditioning is real and recorded here; it is
simply not worth a 77x tail on the small-n designs the package has to survive.

### 10c. A defect this found that ships

Reverting D1 was not a no-op. The half-width half of `lplr_confint_identity`
still carried the magic `1e-9` while the midpoint half had been given a derived
bound -- an inconsistency the D2+D3 increment introduced and half-fixed. D1
exposed it by moving `se` to 8.25e6, where the half-width deviation is
1.86e-9 against `eps*scale = 8.61e-9`. On the shipped state both halves
measure 0 with `eps*scale = 2.94e-9`, so the old bound sat **2.9x below one
rounding step** and passed only because the step happened to be zero. One
derived tolerance now covers both halves.
## 11. The parity gate agrees at n = 500 and the estimator is wrong at n = 60

This is the largest divergence found in the whole audit, and it was invisible
until the gate's own design point was questioned.

`pyexample_lplr.py` compares the port with upstream on the example's own rows
and the example's own outer partition, at **n = 500**. There the gap is
0.007307 / 0.010609 -- excellent. That is ONE design point, and it is the one
point at which this estimator has never been wrong.

Off it, on **identical rows and the identical partition** (`sec_lplr_smalln` in
`examples/parity`, seeds 9001/9002/9003):

| n | port | upstream | ratio | port warns | upstream warns |
|---|---|---|---|---|---|
| 60 | **-3.319646e+06** | **3.53962** | 9.4e5 | yes | no |
| 100 | **-1.119798e+06** | **-0.558127** | 2.0e6 | yes | no |
| 160 | 5.805777e-01 | 0.749398 | 0.77 | no | no |

Upstream is silent on all three. The port returns a coefficient six orders of
magnitude away from upstream's, and its standard errors agree with upstream's
to within a factor (`2.53e6` vs `20.2`, `3.28e5` vs `0.83`) -- so the port is
confidently reporting a catastrophe while upstream is quietly reporting an
answer.

### 11a. It is distributional, not three unlucky draws

200 designs from the same family (n = 60..159), port vs upstream:

| | upstream | port |
|---|---|---|
| fitted | 197 (3 raised) | 200 |
| median abs coef (truth 0.5) | 0.587 | **6.35** |
| Q90 | 1.51 | **1.44e7** |
| Q99 | 5.41 | **1.53e10** |
| max abs coef | **1.01e4** | **1.03e11** |
| designs above 1e4 | 0 | **88 / 200 (44%)** |
| designs above 1e8 | 0 | 7 |
| designs above 1e10 | 0 | 2 |

**44% of the port's designs exceed upstream's worst-ever coefficient**, and the
median is 10.8x further from the truth than upstream's.

### 11b. It is PRE-EXISTING, not something D2/D3 caused

Control arm, same three cases, swapping ONLY `lplr.mbt`:

| ref | n=60 | n=100 | n=160 |
|---|---|---|---|
| HEAD (D2+D3 shipped) | -3.32e6 | -1.12e6 | **0.581** |
| `bb38642~1` (pre-D2) | -1.63e6 | -1.17e6 | 1.888 |
| `c744fc4` (pre-D2) | -1.63e6 | -1.17e6 | 1.888 |

The port was already returning -1.63e6 at n = 60 before any of this session's
work. D2/D3 made n = 60 worse and n = 160 much better (1.888 -> 0.581 against
a truth of 0.5); neither direction is a cause.

### 11c. D1 is NOT the cause -- re-tested and worse

D1 was reverted in section 10 partly on the argument that the port's
`|coef| < 1e10` fuzz ceiling is the PORT's invariant, not a property upstream
must satisfy. That argument deserved the same-rows test, and it was run:

| arm | n=60 | n=100 | n=160 |
|---|---|---|---|
| baseline (alias) | -3.32e6 | -1.12e6 | 0.581 |
| with D1 | **-6.52e6** | **-1.46e6** | 0.705 |

D1 is upstream's `m_hat`, `m_hat` feeds `d_tilde`, `d_tilde` drives the score
and therefore the Newton root -- so it was the live candidate. It makes both
divergences worse. **The revert stands, now for a stronger reason than the one
it was made on.**

### 11d. What is ruled in and what is not

Ruled out by direct comparison against upstream source:

- **The score.** `_score_elements` (`plm/lplr.py:401-415`) and `_compute_score`
  / `_compute_score_deriv` (`:495-512`) match `lplr_score_at` term for term,
  including `deriv = psi_hat * d_tilde * (-y*exp(-coef*d)*d)`.
- **`m_hat`** -- D1, measured above.
- **D2/D3** -- control arm above.

Not yet pinned: why the port's Newton fails to converge where upstream's
converges. Two measured constraints narrow it. The port clamps each Newton
step to 0.25 over 50 iterations, so `|theta|` can exceed its starting value by
at most 12.5 -- a reported `-3.3e6` therefore implies a START of that size, and
the start is `sum(d*t_pred)/sum(d^2)` (`lplr_initial_theta`). The measured
`t_pred` range at n = 60 is `[-35.3, 37.0]`, which is already ~2x outside the
`logit` range `[-18.4, 18.4]` that `W_inner` is clipped to -- the `ml_g`
regression is extrapolating well past its own target range, and the starting
value inherits that. **This is the next thing to measure, and it is a lead, not
a conclusion.**

### 11e. Why it is reported and not gated

Gating it would be a permanently-red gate, which this repo treats as strictly
worse than no gate. So `pyexample_lplr.py` section 5 re-measures all three
cases on every run and prints the ratios, flagged `<-- DIVERGES` above 100x.
The numbers sit next to the ones that ARE gated, so nobody has to remember
that a regime exists where they are not.

Reproduction: `python pyexample_lplr.py` (sections 1-4 gated, section 5
reported). Sweeps: `_verify/_upstream_lplr_tail_1680.py` (upstream side) and
the port-side probe it was paired with.
## 12. Root cause of section 11, and the fix (D4 + upstream's start value)

Section 11 established that the port returns -3.3e6 where upstream returns
3.54, and ruled out D2/D3, D1 and the score. It left the mechanism open. Here it
is.

### 12a. The coefficient was never the root

Upstream takes the root directly:

    theta_hat = root_res.root          # double_ml_score_mixins.py, _root_find

and uses the score only for the VARIANCE. The port ran the Newton, got `theta`,
and then **threw it away**:

    let psi_b_arr = vector_subtract(sc.psi, vector_scale(sc.psi_deriv, theta))
    let (coef_r, se_r) = var_est(psi_a, psi_b_arr)
    coefs[r] = coef_r                   // <-- not theta

`var_est` returns `-mean(psi_b)/mean(psi_a)`. At a root, `psi(theta) = 0` makes
`psi_b = -theta*psi_a` and the ratio collapses to `theta`, so the two agree and
nobody notices. Off a root they do not, and the ratio carries a factor
`1/mean(psi_a)` -- which is exactly what a non-converging design produces.

The arithmetic that had been assumed impossible is what pinned it down. The
Newton clamps each step to 0.25 over 50 iterations, so `theta` can exceed its
start by at most 12.5, and the start `sum(d*t_pred)/sum(d^2)` is bounded by
`|t_pred| <= 37`. A reported **-3.3e6** is therefore unreachable by `theta` --
which is only consistent if the reported number was never `theta`. The
re-derivation, not the root, was producing the 1e6.

**D4: the point estimate is `theta`.** The variance comes from the existing
`var_est_with_jacobian(sc.psi, mean(psi_a))`, which is upstream's form:
`gamma` at the known root rather than at a re-derived one.

### 12b. Upstream's start value, which the port was not using

`plm/lplr.py:326` sets `self._coef_start_val = np.average(beta)` and hands it
to the root finder. The port's `lplr_initial_theta` accepts a `beta_start`
argument, prefixes it with `_` -- **unused** -- and substitutes an ad-hoc OLS
scale. Shipping that substitution is arm (a).

### 12c. Four arms, measured

Identical rows, identical outer partition, truth 0.5:

| arm | n=60 | n=100 | n=160 |
|---|---|---|---|
| pre-D4 | -3.32e6 WARN | -1.12e6 WARN | 0.581 ok |
| D4 only | 14.97 WARN | 13.29 WARN | 0.581 ok |
| (a) start=`mean(beta)`, clamp kept | **-0.049 ok** | 14.43 WARN | 0.581 ok |
| (b) unclamped Newton | **-0.049 ok** | **-0.644 ok** | 0.581 ok |
| (a)+(b) | **-0.049 ok** | **-0.644 ok** | 0.581 ok |

upstream: 3.53962 / -0.558127 / 0.749398.

**Shipped: D4 + (a).** Arm (b) also fixes n=100 and is also what upstream does
-- `root_scalar(score, x0=..., fprime=..., method="newton")` is unclamped -- but
it takes `examples/fuzz` from 11/11 to FAIL (trial 7, `se = 6.13e14` at
`theta = 34.67`): without the clamp, some design that used to be pinned walks
far enough for the variance to blow up. That trade is not understood well
enough to ship, so it is recorded rather than taken.

Note also that (a) alone restores `lplr_ns_theta` to `0.46033435469463013`
exactly -- the value `pyexample_lplr.py` was already pinned to. The ad-hoc OLS
start was not merely different from upstream's, it was rounding the answer away
from the one the port has always reported.

### 12d. Effect on the 200-design sweep

| | pre-D4 | D4 | D4 + (a) | upstream |
|---|---|---|---|---|
| designs > 1e4 | 88/200 | 0 | **0** | 0 |
| designs > 1e8 | 7 | 0 | **0** | 0 |
| max abs coef | 1.03e11 | 24.35 | **24.18** | 1.01e4 |
| median abs coef | 6.35 | 7.35 | **1.89** | 0.587 |
| Q99 | 1.53e10 | 23.0 | 22.5 | 5.41 |
| designs warning | — | 105 | **91** | 0 |

**44% of designs exceeded upstream's worst-ever coefficient; now none do**, and
the median moves from 6.35 to 1.89 against upstream's 0.587. The n = 500 gated
numbers do not move at all (0.007307 / 0.010609), which is the signature of a
fix that only bites where the solver was failing.

### 12e. What is still open

91 of 200 small-n designs still fail to converge, against upstream's zero, and
the median is still 3.2x upstream's. Arm (b) is the measured next step and it
works on all three cases; it needs a runaway guard that does not also cap the
step size, since the current clamp conflates those two jobs. The `|theta_new| >
1e6` divergence guard is separate and is kept.

## 13. Arm (b) is faithful and does not ship (measured)

Section 12e proposed arm (b) -- remove the Newton clamp -- as the next step,
on the grounds that it fixes all three small-n cases and that the clamp
conflates two jobs (cap the step, bound the iterate). That proposal is now
measured and it does not hold up. The clamp stays; this section is the
record.

### 13a. The clamp really is unfaithful

Checked in source, not inferred. Upstream solves with
`root_scalar(score, x0=..., fprime=..., method="newton")`
(`doubleml/double_ml_score_mixins.py:149`), and scipy 1.18's Newton
(`scipy.optimize._zeros_py.newton`) is a bare step:

    newton_step = fval / fder
    p = p0 - newton_step
    if np.isclose(p, p0, rtol=rtol, atol=tol): converged

No step cap, no `rmax`, no damping. The port's 0.25-step fallback does not
exist upstream, so arm (b) is the faithful port.

### 13b. Upstream's variance has no guard either

`doubleml/utils/_estimation.py:362-418`:

    J = np.mean(psi_deriv);  gamma_hat = np.mean(np.square(psi))
    scaling = 1 / (n * J**2);  sigma2_hat = scaling * gamma_hat

No overflow guard. So a non-finite SE at a runaway iterate is upstream's
formula too, not a port-only fiction. Verified arithmetically at the observed
iterate (`d` is binary in the fuzz DGP, so `exp` is not what overflows):

| quantity | value | finite |
|---|---|---|
| `exp(-theta*d)`, d=1, theta=-440 | 1.2291e+191 | yes |
| `mean(psi^2)` | inf | **no** |
| `sigma2 = gamma / (J^2 * n)` | nan | **no** |

The overflow is in the **squaring**, not in `exp`.

### 13c. But upstream never reaches it, and the port does

Same binary DGP, 300 draws, upstream `DoubleMLLPLR` with the same learner
configuration `pyexample_lplr.py` uses:

| | non-finite SE | non-finite coef | draws completed |
|---|---|---|---|
| upstream | **0 / 300** | 0 / 300 | 300 |
| port, unclamped | by trial 2 | by trial 28 | -- |

Upstream is not marginally safer; it never got there in 300 draws. Since the
solver and the variance formula now both match upstream, the remaining
difference must be an **input**. The known one is `m_pred = a_pred` in this
file against upstream's `d_tilde = d - m_hat["preds"]` (`plm/lplr.py:403`,
fed from `ml_M`). That is the D1 thread, reverted at `903e5ce`.

### 13d. What removing the clamp actually costs

Measured as a 2-file scripted mutation (both restored byte-for-byte):

| trial | first failure under the unclamped Newton |
|---|---|
| 2 | `se = NaN`, `theta = -440.16` |
| 24 | `lplr CI identity`, `se = Infinity` |
| 28 | `th = NaN` |

Each is a gate that could not be satisfied, not a wrong answer:

- the absolute `se` ceiling is a property upstream does not have;
- the CI-identity tolerance is derived as `4*eps*max(|hi|,|lo|)`, which is
  itself infinite once `se` is, so `NaN <= inf` is false even for a
  bit-exact interval;
- `again.se() == se` is false for a **bit-identical** refit, because
  `NaN == NaN` is false.

Plus one hard abort: `precondition failed at var_est.mbt:79`, the
`require(jacobian.abs() > 0.0)`, which is uncatchable. Upstream returns NaN
there. A guard at the LPLR call site removes that abort (measured: trials
2-27 then pass), and it is the right fix -- but it does not help, because
trial 28 then fails on `th = NaN`.

Four gates would have to be conditioned on the solver having converged, on a
surface whose purpose is to catch exactly this. Upstream stays finite across
the same 300 draws.

### 13e. Conclusion

Removing the clamp before the score's `d_tilde` input agrees with upstream
makes the port numerically **worse**, not more faithful: it converts a wrong
number into a NaN and then a process abort on designs where upstream returns
a finite value. The clamp stays.

**The ordering is the finding.** Fix `d_tilde` first, then remove the clamp.
An unclamped Newton is safe when the score being solved is the right score;
with a differing `d_tilde` it runs away where upstream's does not.

The cost is unchanged and still reported: gap to upstream at n=60 is 11.4 and
at n=100 is 13.8, against 3.59 and 0.086 unclamped. 91 of 200 small-n designs
still warn where upstream warns zero times. None of that is gated.

## 14. Correction to 13e -- the alias is CORRECT, and the premise was wrong

Section 13e recommended fixing `m_pred = a_pred` before removing the Newton
clamp, on the reasoning that the port aliases the propensity where upstream
uses `m_hat`. **That reading was wrong**, and the recommendation is retracted.
It was tested and falsified in the same sitting.

### 14a. What upstream's `m_hat` actually is

`plm/lplr.py`, in order:

- `:228` `M_hat` is built from `self._learner["ml_M"]` on `x_d_concat, y`,
  with `smpls_inner`. That is `E[Y | D, X]`.
- `:240` the comment reads `# nuisance m`.
- `:254` `m_hat = _dml_cv_predict(self._learner["ml_m"], x, d, ...)` --
  a PLAIN outer cross-fit of the propensity, no inner split.
- `:347` `psi_elements = self._score_elements(y, d, r_hat["preds"], m_hat["preds"])`
- `:403` `d_tilde = d - m_hat`

So the score's `d_tilde` subtracts **`m_hat`, the plain outer cross-fit of
`ml_m`**, not `M_hat`. In this port `a_pred` is exactly that array --
`a_pred = cross_fit_predict_dispatch(ml_m, x, d, outer)` at `:836` -- and
`m_pred = a_pred` hands it to `lplr_score_at`, which builds
`dt = d[i] - m_pred[i]` at `:199`.

**The alias is faithful.** It is not the bug, and section 12's D1 revert was
correct on this axis after all.

### 14b. The wrong version of D1 was tested anyway

`_verify/_lplr_d1_unclamped_1680.py` sets `m_pred` to ml_M's outer nuisance
and removes the clamp. Result:

    FUZZ FAIL: lplr non-negative finite se
                (trial=0, se=5.802668727856591e+139, th=322.4273297452067)

Trial **0**, against trial 2 for aliasing-plus-unclamp. So pointing the
score at `M_hat` is worse, and 13e's premise is falsified rather than merely
unproven. The probe is kept because a negative result with a named number is
what stops the next reader retrying it.

### 14c. The gap that IS still open

Not `d_tilde`. It is the OTHER nuisance, `a_hat`, in

    r_hat["preds"] = t_hat["preds"] - beta * a_hat["preds"]      (`:345`)

Upstream's `a_hat` comes from `_double_dml_cv_predict(..., smpls=smpls,
smpls_inner=...)` and is a **full `n`-vector**: rows inside an outer fold's
training set get an INNER out-of-fold prediction, rows in its test set get
the outer model's. The port's `a_pred` is a plain outer cross-fit, so for
every row that sits in some outer fold's training set -- which is most of
them -- it substitutes an outer-model prediction for an inner one.

The machinery to close it is already present and already correct for `beta`:
`a_inner_per_fold` (`:801`) is ml_m's inner OOF per outer fold, and
`prelim_beta_per_fold` consumes `a_inner_per_fold[fi]` against
`ti = outer[fi].train_idx` (`:976-981`). `double_cross_fit_predict` returns a
vector of length `len(outer[fi].train_idx)` per fold (`kfold.mbt:757`,
`Array::make(m, 0.0)` with `m = train_idx.length()`), so combining is:

    for fi in 0..outer.length():
        let ti = outer[fi].train_idx
        for k in 0..ti.length():
            a_hat[ti[k]] = a_inner_per_fold[fi][k]

with the outer cross-fit still filling `outer[fi].test_indices()`.

**This is NOT measured.** No arm has implemented it. It is the next thing to
try, and it is a candidate for why the port's Newton runs away where
upstream's does not -- but a candidate, not a conclusion. Nothing above
licenses removing the clamp yet.

## 15. The `a_hat` candidate is measured, and falsified

Section 14c named the `a_hat` double-cross-fit as "a candidate for why the
port's Newton runs away where upstream's does not". It was a candidate with
no measurement behind it. Here is the measurement.

The arm, implemented in `_verify/_lplr_ahat_1680.py`, closes the gap:

    a_pred = cross_fit_predict_dispatch(ml_m, x, d, outer)
    for fi_a = 0; fi_a < outer.length(); fi_a = fi_a + 1 {
      let ti_a = outer[fi_a].train_idx
      for k = 0; k < ti_a.length(); k = k + 1 {
        a_pred[ti_a[k]] = a_inner_per_fold[fi_a][k]
      }
    }

which is upstream's `_double_dml_cv_predict(..., smpls_inner=...)` shape:
an inner OOF on rows inside an outer fold's training set, the outer model
on its test rows.

### 15a. Judged against upstream, not against the pin

The change moves the port off the pinned example value, so
`pyexample_lplr.py:285` refuses before comparing. That refusal is correct
normally and useless here -- it hides the number the arm exists to produce.
`_verify/_mk_lplr_gap_probe_1680.py` makes a copy in the repo root that
continues past the pin and reports the gap; the rows are untouched, only
the PORT moved. Upstream in every row below is fitted on the same rows and
the same outer partition.

| | HEAD | arm a (`a_hat`) | upstream |
|---|---|---|---|
| n=500 `nuisance_space` gap | **0.007307** | 0.033977 | 0.392214 |
| n=500 `instrument` gap | **0.010609** | 0.054513 | 0.412682 |
| SE ratio, `nuisance_space` | 1.1549 | 1.1279 | 1 |
| SE ratio, `instrument` | 1.0269 | 1.0278 | 1 |
| fuzz (11 surfaces) | GREEN | GREEN | -- |

The gate still reads OK, because the band is 3 sigma and the port's own
spread fell (0.206 -> 0.139). But the gap went **up by 4.6x and 5.1x**.
Reading "still OK" as "no change" is the same error as reading a green
parity gate as "unchanged".

Small-n moves the same way:

| n | HEAD port | arm a port | upstream |
|---|---|---|---|
| 60 | -0.049129 | 0.20959 | 3.53962 |
| 100 | 14.431 (warn) | 14.431 (warn) | -0.558127 |
| 160 | 0.580578 | **3.88988** | 0.749398 |

n=160 is the worst of it: gap to upstream 0.169 becomes **3.14**.

### 15b. Combined with the unclamped Newton, fuzz still dies

The reason the arm matters is the clamp. So it was also run unclamped:

| arm | fuzz | n=100 port | upstream |
|---|---|---|---|
| a only | GREEN | 14.431 (warn) | -0.558127 |
| `a_hat` + unclamped | **RED** | **-0.502784**, warn=0 | -0.558127 |

The unclamped arm does fix n=100 -- -0.5028 against upstream's -0.5581 is
the closest this port has ever come on that design. But it buys that by
aborting the process:

    precondition failed at var_est.mbt:79:5-79:34
    [8/11] DoubleMLLPLR nonlinear fit invariants ...

which is `require(jacobian.abs() > 0.0)`, uncatchable, on the surface that
upstream completes. **So the `a_hat` gap does not explain the divergence
either.** Closing it does not make the unguarded Newton safe.

### 15c. Where that leaves it

Three explanations have now been measured and none of them holds:

| explanation | status | evidence |
|---|---|---|
| start value (`np.average(beta)`) | FIXED, shipped at `df049c2` | -- |
| the point estimate was never the root | FIXED, shipped at `df049c2` | -- |
| `d_tilde` uses the wrong nuisance | **falsified** | §14b, trial 0 vs trial 2 |
| `a_hat` is not double-cross-fitted | **falsified** | §15b, still aborts |

The clamp therefore stays, and it stays for a reason that is still not
fully explained: upstream is 0/300 non-finite on this DGP and the port
diverges by trial 2, with the solver, the score formula, the start value
and both nuisance inputs now individually checked against source. Something
in the port's evaluation of the score still differs, and it has not been
located. That is the honest state, and it is recorded rather than papered
over with a guard whose justification would be a guess.

The cost is unchanged: gap to upstream 11.4 at n=60 and 13.8 at n=100 with
the clamp, against 3.59 and 0.086 without it; 91 of 200 small-n designs
warn where upstream warns zero times. None of that is gated.

## 16. What has actually been checked against upstream, and the one confound that was not

Section 15c ended with "something in the port's evaluation of the score still
differs and has not been located". Here is the exhaustive list of what HAS
been checked, so the next reader does not re-walk it -- and one comparison
that was confounded and has now been cleared.

### 16a. Verified equivalent

| piece | upstream | port | where |
|---|---|---|---|
| root finder | `root_scalar(..., method="newton")`, no cap | damped 0.25-step clamp | `:149` / `lplr.mbt` |
| Newton step | `p = p0 - fval/fder` | `theta - s/sd` | scipy 1.18 `_zeros_py` |
| start value | `np.average(beta)` (`:326`) | `mean(beta_start)` | shipped `df049c2` |
| point estimate | `theta_hat = root_res.root` | `coefs[r] = theta` | shipped `df049c2` |
| `d_tilde` | `d - m_hat` (`:403`) | `d - m_pred`, `m_pred = a_pred` | `:254` is ml_m's plain outer CV -- **see §24** |
| `psi_hat` | `expit(-r_hat)` | `expit(-r_hat)` | `:404` |
| `score_const` | `d_tilde * (1-y) * exp(r_hat)` | same | `:405` |
| score | `psi_hat * (y*exp(-theta*d)*d_tilde - score_const)` | same | `:523-524` |
| derivative | `psi_hat * d_tilde * (-y*exp(-theta*d)*d)` | same | `:534-535` |
| aggregation | `np.mean(psi)` | `s / n_obs` | `_aggregate_obs:121` |
| variance | `mean(psi^2) / (n * J^2)`, no guard | same, no guard | `_estimation.py:362-418` |

So the score, its derivative, the aggregation, the start value, the point
estimate and the variance formula all match upstream. The root finder does
NOT, and that is the one deliberate deviation.

> **QUALIFIED by §24.** Every row above is an identity of FORM, verified by
> reading both sources. The `d_tilde` row in particular is an algebraic match
> only: upstream's `m_hat` is fitted on the `Y = 0` rows (`lplr.py:247-252`)
> and the port's is not, and the two differ by rms 0.15-0.35 on a propensity
> that lives in `[0, 1]`. Nothing else on this list is known to differ
> numerically, but nothing else on this list has been checked numerically
> either.

### 16b. The confound in 13c, cleared

The 0/300 measurement in 13c was about to be thrown out. It fitted upstream
with `LogisticRegression(C=1e6, ...)` while `DoubleMLLPLR::new` defaults to
`LearnerDispatch::logistic_regression(LogisticRegression::new())`
(`lplr.mbt:360-362`), and `LogisticRegression::new()` looks like a C = 1.0
default -- so the two sides of the comparison would have had different
regularization, and "upstream is robust where the port is not" would have
been an artifact.

It is not. `LogisticRegression` in this port has no regularization parameter
at all:

    pub fn LogisticRegression::new() -> LogisticRegression {
      { fitted: false, coef_: [], }
    }

(`logistic.mbt:23-25`). No `C`, no penalty term, no lambda -- it is an
unregularized MLE, which is the same regime as upstream's `C=1e6`. The two
configurations are matched in substance, so the 0/300 figure stands.

A sweep written to "fix" this by forcing upstream to `C = 1.0` was deleted
rather than kept: it would have introduced the very mismatch it was meant to
remove. This is the second time in this series that an experiment was caught
before it produced a number by checking the premise first (the first was the
0-anchor `d_tilde` probe in 14b).

### 16c. What is left

Unknown, and narrower than 15c made it sound. The estimator structure is
verified equivalent term by term; both nuisance inputs were tested and both
moved the port AWAY from upstream; the learners match; the aggregation
matches; the variance formula matches. What remains unexplained is why
upstream stays finite on 300/300 draws of this DGP while the port's Newton
diverges by trial 2.

That gap is real and is not closed by anything in this document. The clamp
stays, its cost is recorded, and the small-n regime stays reported rather
than gated.

## 17. The stopping tolerance is 14.8x off, and it is irrelevant (measured)

Sections 13-16 all varied something the Newton loop is FED. This one aimed
at the loop itself: WHEN it stops.

### 17a. The mismatch is real

Read out of installed scipy 1.18.0, not recalled:

* `double_ml_score_mixins.py:149` is
  `root_scalar(score, x0=self._coef_start_val, fprime=score_deriv, method="newton")`
  -- no `tol`, `xtol`, `rtol` or `maxiter`.
* `_root_scalar.root_scalar` forwards `xtol`/`rtol`/`maxiter` **only when not
  None** (`for k in [...]: v = locals().get(k); if v is not None`), and all
  three default to `None`. It then forces
  `kwargs.update(full_output=True, disp=False)`.
* So `newton` runs on its own signature defaults: `tol=1.48e-8`,
  `rtol=0.0`, `maxiter=50`. Its test is

      np.isclose(p, p0, rtol=0.0, atol=1.48e-8)

  i.e. `|p - p0| <= 1.48e-8`, a **pure absolute** bound -- the relative term
  is multiplied by zero.

The port's test, `lplr.mbt:1264`, is

    (theta_new - theta).abs() < 1.0e-9

That is 14.8x tighter, and the two disagree on every step size in the window
`(1e-9, 1.48e-8]`: upstream declares convergence there, the port keeps
iterating. A stricter stop means more iterations at exactly the point where
the score is cancelling in floating point, which is a plausible route to
walking `theta` into `exp()` overflow. Worth testing.

### 17b. It does not matter: the window is never occupied

Two arms, each instrumented to record the smallest `|fval/fder|` its
trajectory ever produced. The verdict follows from `min_step` alone, because
steps shrink as Newton converges:

| `min_step` | upstream | port |
|---|---|---|
| `<= 1e-9` | stops | stops |
| `(1e-9, 1.48e-8]` | **stops** | keeps going |
| `> 1.48e-8` | keeps going | keeps going |

**CLAMPED** (the shipping configuration), 600 solves over `examples/fuzz`:

    both stop (min_step <= 1e-9)            : 346
    IN THE 14.8x WINDOW                     : 0
    neither stops (min_step > 1.48e-8)      : 254
    stop_reason tally: {'converged': 346, 'exhausted_step_budget': 254}

**UNCLAMPED** -- the configuration that actually diverges, which is the only
arm where the question is worth asking:

    fuzz: FUZZ FAIL: lplr non-negative finite se
          (trial=2, se=NaN, th=-440.15956528046615)

    both stop (min_step <= 1e-9)            : 4
    IN THE 14.8x WINDOW                     : 0
    neither stops (min_step > 1.48e-8)      : 1

**Zero solves in the window, in either arm.** The behaviour is BIMODAL:
a solve either lands inside 1e-9 or never gets near even 1.48e-8. The
tolerance difference never gets a chance to act, so it cannot be the cause,
and tightening or loosening the port's threshold would change nothing.
Hypothesis falsified; recorded so it is not retried.

### 17c. What the bimodality does say

The one non-converging unclamped solve is the one that detonates, and it
never comes close to the root first -- it takes an enormous step straight to
`theta = -440`. That is the signature of a collapsing denominator rather than
of a slow approach:

    mean(psi_deriv) = -mean_i[ psi_hat_i * d_tilde_i * y_i * d_i * exp(-theta*d_i) ]

and the port's own log records this exact collapse ("`mean(psi_deriv)`
collapsed to -3.2e-8"). Note the two aggregates are summed over different
populations: `psi` has a `y`-term AND a `(1-y)` term (via `score_const`),
while `psi_deriv` has only the `y`-term. So `mean(psi)` can stay O(1) while
`mean(psi_deriv)` vanishes, and the step `s/sd` explodes. That structure is
upstream's too (`lplr.py:405`, `:534-535`), which is why upstream being
finite 300/300 remains unexplained by anything here.

### 17d. Two smaller things found while looking

**The derivative is associated differently.** Upstream computes
`deriv = psi_hat * d_tilde * deriv_1` where `deriv_1 = -y * exp(-theta*d) * d`;
the port computes `psi_hat * y * -d * exp(-theta*d) * dt`. Same factors,
different grouping, so the rounding differs at ~1e-16 relative per
evaluation. Mathematically identical, numerically not bit-identical. Recorded,
not acted on -- it is far too small to explain a trial-2 detonation.

**`lplr_initial_theta` documented a computation it did not perform.** Its
comment claimed "Simple OLS scale: theta ~ mean(d * t_pred) / mean(d^2)",
evaluated at `theta = 0`, "taking whichever magnitude is smaller" -- and it
computed exactly that into `num` and `den`, then returned `beta_start`
anyway. `num` was dead, and `den`'s only live effect was the all-`d == 0`
guard. A reader checking the start value against upstream `:326`
(`np.average(beta)`) would have concluded the port used a *different*
quantity, when it uses the same one. Comment corrected and `num` removed in
the same commit; `moon check --deny-warn`, 1117/1117 native tests,
`moon fmt --check` and `examples/fuzz` all pass unchanged, which is what
"no behavioural change" means here.

### 17e. Status

Four explanations are now measured and none holds: `d_tilde` (14), `a_hat`
(15), the start value (12, re-verified against source in 17d), and now the
stopping tolerance. Section 16c's "unknown" survives, narrowed to the
collapse mechanism in 17c -- specifically why upstream's `mean(psi_deriv)`
does not vanish on the draws where the port's does, given that the formulas
producing it are equivalent.

## 18. LEAD (NOT MEASURED): the port's `a_pred` is not upstream's `a_hat["preds"]`

17c located the mechanism -- `mean(psi_deriv)` collapses because
`psi_hat = expit(-r_hat)` vanishes -- and 17e narrowed the question to
*which input makes `r_hat` too large*. Following that back lands on
`r_hat = t_hat - beta * a_hat["preds"]` (`lplr.py:345`), and on a structural
difference that 16a's table does not cover.

### 18a. What upstream computes

`plm/lplr.py:302-312` builds `a_hat` with `_double_dml_cv_predict`, and
`utils/_estimation.py:207-229` is what that actually does:

    res["preds"] = np.zeros(y.shape)
    for smpls_single_split, smpls_double_split in zip(smpls, smpls_inner):
        res_inner = _dml_cv_predict(estimator, x, y,
                                    smpls=smpls_double_split,
                                    return_models=True)
        res["preds_inner"].append(res_inner["preds"])
        for model in res_inner["models"]:
            res["preds"][smpls_single_split[1]] += model.predict(x[smpls_single_split[1]])
    res["preds"] /= len(smpls)

So `a_hat["preds"]` is an **aggregate over the models of an inner
cross-fit** -- every one of that outer fold's inner models predicts the
outer test rows and the results are summed, then divided by the number of
outer folds. It is a bagged predictor, not a single model's output.

`lplr.py:345` then uses exactly that:

    r_hat["preds"] = t_hat["preds"] - beta * a_hat["preds"]

### 18b. What the port computes

`lplr.mbt:836`:

    a_pred = cross_fit_predict_dispatch(ml_m, x, d, outer)

One model per outer test row -- the ordinary K-fold OOF value. No inner
cross-fit, no averaging. `r_hat` is then built from it at `lplr.mbt:198`:

    let r_hat = t_pred[i] - beta[i] * a_pred[i]

So the port's `r_hat` uses a single outer-OOF prediction where upstream uses
an average of inner-model predictions, and `r_hat` feeds
`psi_hat = expit(-r_hat)` and `score_const = d_tilde * (1-y) * exp(r_hat)`
(`lplr.mbt:202-203`) -- the exact pair that 17c identified as the collapse
mechanism.

### 18c. Why 16a did not catch this

16a's table lists `d_tilde | d - m_hat | d - m_pred, m_pred = a_pred` as
verified equivalent. That row is about the **alias** `m_pred = a_pred`
(cleared in section 14), not about **how `a_pred` itself is constructed**.
`t_pred` and `a_pred` were the two inputs to `r_hat` that had no row in
16a at all. The verification enumerated the pieces the solver consumes and
stopped one level short of the pieces that produce those pieces.

`ml_t` is clean, by contrast, and is worth recording as cleared: upstream's
`_dml_cv_predict` takes the `fold_specific_target` branch
(`_estimation.py:65,117-131`) because `W_inner` is a list, materialises
`xx[train_idx] = W_inner[idx]` padded with NaN, and `_fit` uses
`y[train_index]`, so it reduces to fit-on-`(x[train_idx], W_inner[idx])`
and predict-`x[test_idx]`. The port's `cross_fit_predict_inner`
(`lplr.mbt:1616-1634`) does exactly that.

### 18d. Magnitude, measured (the direction claim here was WRONG -- see 19)

`_verify/_lplr_ahat_bag_1680.py` spies on upstream's
`_double_dml_cv_predict` so the compared value IS upstream's own
`a_hat["preds"]` rather than a re-derivation, and captures the partition
from the same call so both sides fit on identical folds. 12 draws, n=500,
p=6, n_folds=2, n_folds_inner=2:

    median span of a_hat across rows : 0.57863
    median rms(bag - plain)          : 0.39261
    median rms/span                  : 0.6920

The two differ by **69% of `a_hat`'s own span** -- not a rounding
difference and not an offset. The port's `a_pred` is simply not upstream's
quantity.

The sign is uniform: `mean(bag) - mean(plain)` is negative on **12 of 12**
draws (-0.248, -0.187, -0.265, -0.185, -0.272, -0.229, -0.148, -0.174,
-0.149, -0.091, -0.111, -0.278), because averaging shrinks a fitted value
toward the mean.

An earlier version of this section also claimed the resulting direction was
"wrong" for explaining the collapse. **It was wrong**, the reasoning was
single-channel, and section 19 retracts it with the measurement.

## 19. CORRECTION to 18d: the "wrong direction" claim is REFUTED

18d measured that `a_hat` (bagged) < `a_pred` (plain) on 12/12 draws, then
asserted the resulting direction was "wrong" for explaining the collapse:

> a smaller `a_hat` makes upstream's `r_hat` LARGER, `psi_hat` SMALLER,
> `mean(psi_deriv)` smaller -- pushing upstream toward the collapse

**That is wrong**, and measuring it says so plainly.
`_verify/_lplr_bag_direction_1680.py` holds `t_hat`, `beta`, `m_hat`,
`W_inner`, `a_inner` and `theta0` at UPSTREAM's own values and varies only
`a_hat` (bagged) against `a_pred` (plain), on 8 draws, n=500:

    quantity                        BAGGED        PLAIN      ratio
    mean psi_hat                  0.40856     0.44722      0.914
    mean(psi)                     0.0012142  -0.016214     -0.075
    mean(psi_deriv)              -0.010983   -0.010224      1.074
    FIRST Newton step             0.00099174  1.3938       0.001
    |psi| max at solution          0.88217     1.0517       0.839

    CHANNEL (1) runaway step : first_step smaller under BAGGED -> True
    CHANNEL (2) psi^2 overflow: |psi| max smaller under BAGGED -> True

### 19a. What went wrong in the reasoning

There are **two** failure channels and 18d considered one of them.

1. The runaway step. `mean(psi_deriv)` shrinking does make `s/sd` bigger.
2. The variance overflow. Once `theta` is large,
   `A = y*exp(-theta*d)*d_tilde` reaches ~1e191, `psi = psi_hat*A`, and the
   variance squares it: `psi^2 ~ psi_hat^2 * 1e382`. **`psi_hat` is
   squared**, so shrinking it by `k` shrinks the square by `k^2`.

18d read the sign off channel 1 and applied it to the whole problem. The
measurement says both channels favour the bagged construction, and channel
1 by a factor of ~1000.

### 19b. The actual mechanism, measured

> **WITHDRAWN IN FULL by section 21c.** Every number in this subsection is an
> artifact of the control, not of the port. The `PLAIN` arm was rebuilt with
> sklearn's `.predict` -- hard 0/1 labels -- where both nuisances under
> comparison are probability vectors. On the correct scale the ratios are
> **0.99** and **1.00**, not `~13x` and `~1400x`. What follows is kept verbatim
> as the record of what was believed and why, and **must not be cited as a
> measurement.** Section 21d supersedes it.

`mean(psi_deriv)` is nearly unchanged between the arms (ratio 1.074). The
entire difference is in the **numerator**: `mean(psi)` at `theta0` is ~13x
larger under PLAIN, and since the first Newton step is `s/sd`, the first
step is ~1400x larger. So the port's non-bagged `a_pred` leaves the score
much further from zero at the start value, and Newton throws `theta`
somewhere far away on its very first move -- which is exactly the observed
signature (`theta = -440` by trial 2).

That is a mechanism, stated from measurement rather than inference, and it
is the first one in sections 13-19 whose predicted sign matches the
observation.

### 19c. What this does NOT show, stated plainly

At n=500 neither arm reproduces the divergence: **BAGGED 7/8 finite, PLAIN
8/8 finite** -- draw 4 blows up under BAGGED (`fder==0`, `theta = 8.35e4`)
while every PLAIN draw converged. So this is **not** a demonstration that
bagging fixes anything, and the one failure here is on the *upstream-shaped*
arm.

Three things remain before this can be called the cause:

1. **The real configuration.** n=500 with n_folds=2 is well-conditioned.
   The failure under test is the fuzz DGP's trial 2. Re-run this comparison
   on THAT partition, with the port's own nuisances rather than upstream's
   captured ones, since upstream's `beta`/`t_hat` may themselves differ.
2. **Occupancy**, again in 17b's sense: is the enlarged first step actually
   what lands on the diverging draws, or does it need 18e/18d.2 resolved
   first?
3. **Fold-count scaling.** `/= len(smpls)` divides by the OUTER count, so
   with n_folds != n_folds_inner an implementation must divide by the number
   of contributing models, not the outer folds, or it will be wrong in a
   way this n_folds == n_folds_inner == 2 test cannot see.

So: 18d's magnitude measurement stands (69% of span, 12/12 negative), its
direction claim is retracted, and 19b replaces it with a measured mechanism
whose sign is right. The gate-blindness method needs one more entry as well:
**an argument about which way a difference acts is itself a hypothesis, and
this one was written down, published and committed before it was measured.**
It should have been measured in 18d, in the same run that produced the
magnitude.


### 18e. SETTLED: the inner-split scope is faithful -- there is no divergence here

This was left open deliberately in 18a-18b, because implementing the average
requires knowing which rows the inner models were trained on. Now answered,
from `utils/resampling.py:52-65`:

    def split_samples(self):
        all_smpls = [(train, test) for train, test in
                     self.resampling.split(X=np.zeros(self.n_obs), ...)]
        smpls = [all_smpls[(i_rep*n_folds):((i_rep+1)*n_folds)]
                 for i_rep in range(self.n_rep)]
        smpls_inner = []
        for i_rep in range(self.n_rep):
            smpls_inner_rep = []
            for train, test in smpls[i_rep]:
                smpls_inner_rep.append(
                    [(train[train_inner], train[test_inner])
                     for train_inner, test_inner in
                     self.resampling_inner.split(X=train)])

`self.resampling_inner.split(X=train)` yields **positional** indices into
the outer fold's TRAINING rows, and `train[train_inner]` maps them back to
original positions. So upstream's inner cross-fit covers the outer training
rows only -- exactly what the port does at `kfold.mbt:751-757`:

    let m = train_idx.length()
    let inner = kfold(m, n_inner, rng_state)
    ... train_idx[ifold.train_idx[k]] ...

**Faithful.** The port's inner-split scope is not a divergence, and
`preds_inner` (which feeds `W_inner` and `beta`) is therefore sound. The
earlier worry here -- that upstream "passes full `x, d`" to the inner
`_dml_cv_predict` -- was a misreading: the full arrays are passed, but the
SPLIT restricts them to `train`, and `_dml_cv_predict` indexes with it.

One difference remains and is not a scope question: upstream's
`resampling_inner` is a single `RepeatedKFold(n_splits=n_folds_inner,
n_repeats=1)` reused across outer folds with `random_state=None`, so each
outer fold draws a fresh permutation; the port advances `rng_state` by one
per fold. Both are "a different inner split per outer fold" -- the specific
draws cannot match across two different RNGs, and never could.

**Consequence for 18a-18b.** With the scope settled, `a_hat["preds"]` is now
fully specified and `a_pred` at `:836` is the only remaining `a_hat`
divergence. Upstream's is

    for each outer fold i:
        fit the n_folds_inner inner models on i's TRAINING rows
        preds[test_i] += model.predict(x[test_i])   for EVERY such model
    preds /= len(smpls)                             # len(smpls) == n_folds

so with `n_folds == n_folds_inner` it is the MEAN of the inner models'
predictions, and otherwise carries a `n_folds_inner / n_folds` scale factor
on top. Reproducing it needs one new function that returns, per outer fold,
the inner models' predictions on that fold's outer TEST rows -- which is not
what `double_cross_fit_predict` returns (it gives the inner OOF on the outer
TRAIN rows).

## 20. UPSTREAM IS ALSO ILL-POSED AT SMALL n -- the 0/300 figure was n=500-only

Every "upstream is fine, the port is wrong" statement in this document rests
on one number: upstream emits 0 non-finite SE over 300 draws. That number is
real, and it was measured at **n=500** (`_verify/_lplr_nan_upstream_1680.py`, whose
`part2` defaults to `n=500`). It was then used as a property of the
estimator rather than of that sample size.

`_verify/_lplr_upstream_smalln_1680.py` runs REAL upstream
(`DoubleMLLPLR(...).fit()`, not a reconstruction) on the same DGP at the
same small n, 25 draws per n, n_folds=2, n_folds_inner=2:

    n      completed  non-finite se  non-finite coef  root warnings
    60     25/25      7              2                11
    100    25/25      1              0                1
    160    25/25      1              0                1
    500    25/25      0              0                0

The failures are the same species the port's clamp was blamed for. At n=60,
draw 9 and draw 15 return `coef=nan, se=nan`; draw 6 returns
`coef=5.4e22, se=inf`; draw 14 `coef=3.5e15, se=inf`. And 11 of 25 draws at
n=60 raise upstream's own `Could not find a root of the score function.`
warning -- the same condition the port surfaces through
`DoubleMLLPLR::warnings`.

### 20a. What this does to the clamp

The clamp was justified in section 13 by "upstream is 0/300 finite here".
That justification holds at n=500 and nowhere else. At n=60 the comparison
is:

    upstream (no clamp, as shipped)  : 18/25 finite SE, 11/25 root warnings
    port (clamped)                   : finite SE on every draw, with WARNED
                                       set where Newton did not converge

So at small n the port is **not** diverging where upstream holds. It is
returning a finite but wrong number -- and warning -- where upstream returns
NaN or a coefficient of order 1e22 on 28% of draws. The clamp converts a
non-finite answer into a finite wrong one; it does not manufacture the
failure.

### 20b. Section 19's sweep, reconciled

19's BAGGED arm scored 16/25 finite at n=60 while real upstream scores
18/25. The arm is a reconstruction (upstream's captured `a_hat`, with
`t_hat`, `beta`, `m_hat`, `W_inner` and `theta0` recomputed here and an
unclamped Newton written to match scipy 1.18's stopping rule), so it is
*more* pessimistic than upstream by two draws. The gap is small and in the
expected direction, and the ordering it established -- BAGGED above PLAIN at
every small n (16 vs 15, 21 vs 19, 20 vs 19) -- stands. It simply does not
license the claim that matching upstream's construction removes the
small-n problem, because upstream has no answer at small n to match.

### 20c. What this means for the parity goal

"Make the port agree with upstream" is well-posed where upstream has a
defined answer, and section 11 already shows that is n=500, where the
parity gate passes. At small n upstream's answer is NaN, `inf`, or 1e22 with
a root-failure warning, so there is nothing to agree WITH; agreement there
would mean reproducing a non-finite value.

The honest statement of the residual is therefore not "a port deviation
whose cause we could not locate". It is: **at n <~ 200 this estimator is
ill-posed for both implementations; the port returns a finite warned answer
where upstream returns a non-finite one, and the gap the README discloses at
n=60 and n=100 is the cost of that choice, measured.** The clamp stays, and
its justification is now the one in 20a rather than the n=500-only 0/300.

> **CORRECTED by §22.** The aggregate rate is real -- upstream is non-finite on
> 7 of 25 draws at n=60 -- but the sentence above generalises it into the
> specific rows the README tabulates, and on those rows it is **backwards**. At
> n=60 the port is the well-conditioned one and upstream is not; at n=100 it is
> exactly reversed. "Ill-posed for both" survives as a statement about the
> REGIME. It does not survive as a description of any single row, and it does
> not license reading the port as the broken one by default.

## 22. The small-n picture changed after D4, and a live docstring never noticed

Section 12 established that a reported `-3.3e6` was arithmetically unreachable
by `theta` -- Newton clamps each step to 0.25 over 50 iterations, and the start
`sum(d*t_pred)/sum(d^2)` is bounded by `|t_pred| <= 37` -- and therefore that
the number had never been `theta`. The pre-D4 re-derivation was producing the
1e6, and D4 made the point estimate `theta` itself (v0.163.0).

### 22a. A live docstring described pre-D4 behaviour

`print_report_smalln`'s docstring in `pyexample_lplr.py` still read:

> the port returns -3.3e6 and -1.1e6 where upstream returns 3.54 and -0.558

The upstream half was right. The port half was a build from before D4. That
file ships and is run by the gate on every CI pass, so the number was being
re-measured correctly sixty characters below the comment that misdescribed it.

This is the same defect as the 0478 header that read `DISCARDED` next to a
function returning values. The historical records in §11, §12 and `CHANGELOG.md`
of `-3.3e6` stay -- they correctly describe what was true then. A **live**
comment describing current behaviour does not get that protection.

### 22a-bis. A sweep found three live artifacts, not one

Searching tracked source for the pre-D4 figures rather than trusting that the
one I happened to open was the only one turned up **three**, all carrying the
same stale port numbers with the same *correct* upstream numbers beside them:

  1. `pyexample_lplr.py` `print_report_smalln` docstring -- fixed in 22a.
  2. `examples/parity/main.mbt` `sec_lplr_smalln` -- **the emitter itself**,
     the function that produces the rows the gate re-measures. Its header said
     "the port and upstream disagree by ~1e6" and tabulated
     `-3.319646e+06` / `-1.119798e+06`, plus "the port warns on the first two"
     (it now warns on one). Corrected.
  3. §19b of this file -- the subsection that §21 retracts. A reader arriving
     at 19b saw `~13x` and `~1400x` stated flatly, with the withdrawal only
     300 lines later. Corrected with an inline banner at the subsection head.

The upstream figures (`3.53962`, `-0.558127`, `0.749398`) were correct in all
three, which is exactly why the stale halves survived so long: the tables
looked self-consistent. **Grep for the withdrawn numbers in tracked source
whenever you retract one** -- one of three being fixed is an assumption, not a
result.

Two figures were left alone deliberately. `CHANGELOG.md` and §11/§12 record
`-3.3e6` and `1.03e11` as history and are correct as history. `lplr.mbt:870`'s
`1.03e11` is a §8-10 D2 A/B result, explicitly labelled as such and pointing
at its own sections.

### 22b. What the port actually returns now

Re-measured at `8da9915` via `python pyexample_lplr.py`, identical rows and
identical outer partition:

| n | port coef | port `se` | warns | upstream coef | upstream `se` |
|---|---|---|---|---|---|
| 60 | `-0.0491291` | `0.762404` | 0 | `3.53962` | `20.1991` |
| 100 | `14.431` | `751657` | 1 | `-0.558127` | `0.832026` |
| 160 | `0.580578` | `0.777112` | 0 | `0.749398` | `0.587901` |

**The direction reverses.** At n=60 the port has `se` 0.76 and upstream has
`se` 20.2 with a coefficient of 3.54 against a true effect near 0.5. At n=100
it is exactly the other way: the port returns `se` 7.5e5 with one warning and
upstream returns `se` 0.83. At n=160 both are finite and well-conditioned and
sit 29% apart.

### 22c. What this corrects, and what it does not

§20c's "the port returns a finite warned answer where upstream returns a
non-finite one" is true as an AGGREGATE over 25 draws, and false as a
description of the three rows the README tabulates next to it. Both statements
were in the same document.

The clamp's justification is untouched: 20a rests on upstream genuinely being
ill-posed below n≈200 (7/25 non-finite SE at n=60, 11/25 root warnings), which
is what makes adopting upstream's bare Newton the worse choice. What is
withdrawn is the stronger claim that the tabulated gap IS the cost of that
choice. At n=60 the port is the better-behaved implementation, so the clamp
cannot be what explains that row.

**The meta-point is 7b/20d for the third time, now inside shipped prose:** an
aggregate rate was read as a property of each individual case, and the table
sitting immediately above it says otherwise. The reader who checks the table
against the sentence finds the contradiction in seconds -- which is the
argument for keeping the table and the prose adjacent, and against ever
replacing either with a summary.

### 22d. One honest consequence for the parity goal

The n=100 row is the port's genuine failure: the port returns `se` 751657 and
`coef` 14.431 where upstream returns `se` 0.83 and `coef` -0.558, both finite,
both on identical rows. §21 removed the `a_hat` bagging from the candidate
list. The candidates falsified so far are `d_tilde`, `preds_inner`, the
stopping tolerance, and the bagging.

> **RESOLVED by §23.** This paragraph originally called the n=100 row
> "unexplained". It is explained: it is the Newton step clamp, and its cost
> there is now measured. It remains a real divergence in the shipped build,
> but it is not an open question -- it is a documented trade.

**The n=100 row is still a divergence where upstream has a perfectly
well-defined answer**, and it is not explained by ill-posedness on upstream's
side.

## 23. The clamp A/B, re-measured -- it costs nothing except at n=100

The table justifying the step clamp (`lplr.mbt`, and mirrored in the README)
was measured before D4, so §22's numbers did not reproduce it. Re-run at
`8c01e96`.

### 23a. Method

Raise the two damping thresholds at `lplr.mbt:1260` from `5.0` / `1.0` to
`1.0e300` so the branch cannot fire on any finite value, leaving
`theta_new = theta - raw_delta` -- scipy's bare Newton, exactly. Run
`pyexample_lplr.py` and `examples/fuzz`. Revert with `git checkout`. The tree
was clean beforehand and is clean after; nothing else was edited while the
experiment was live, because the QA loop compiles `examples/parity` and a
concurrent `.mbt` edit corrupts its run.

### 23b. Result

| n | clamped | unclamped | upstream | gap clamped -> unclamped |
|---|---|---|---|---|
| 60 | `-0.0491291` ok | `-0.0491291` ok | `3.53962` | `3.589` -> `3.589` |
| 100 | `14.431` WARNED | `-0.643589` ok | `-0.558127` | `14.989` -> **`0.085`** |
| 160 | `0.580578` ok | `0.580578` ok | `0.749398` | `0.169` -> `0.169` |

**The clamp is bit-identical to the unclamped arm at n=60 and n=160.** It
costs exactly nothing there. It bites at n=100 and nowhere else on these three
designs, and there it is the entire difference between agreeing with upstream
to `0.085` and being `14.989` away.

The old table's clamped column read `n=60 14.966 WARNED` and
`n=100 13.285 WARNED`. Neither reproduces. **D4 fixed the REPORTING of the
n=60 row, not the clamp**: the damping never fired there and the solve
converged either way, so post-D4 the clamped arm reports `theta = -0.0491291`
with no warning where it used to report a re-derivation of `14.966`. The
README's "11.4 -> 3.59 at n=60" described that pre-D4 pair and is withdrawn;
both arms are now `3.589`.

### 23c. The clamp's justification reproduces exactly

Unclamped `examples/fuzz`:

```
FUZZ FAIL: lplr non-negative finite se (trial=2, se=NaN, th=-440.15956528046615)
```

That is the documented failure, to the digit. So the clamp is not defending
against a stale memory: remove it and the suite goes red on trial 2.

### 23d. The trade, stated as a trade

| requirement | wants | at n=100 |
|---|---|---|
| agree with upstream | no clamp | `0.085` |
| survive `examples/fuzz` | clamp | 11/11 PASS |

They pull opposite ways, and the same A/B shows why this is not resolvable by
simply picking the faithful one: the design where upstream has a clean answer
(n=100) is not the design where this port can safely drop its damping without
going non-finite at n=500. **The clamp stays.** §22d's "unexplained" is
withdrawn; what remains is a documented, measured trade, not an open defect.

This is also the fourth confirmation that the pre-D4 numbers were a separate
failure mode from the clamp. D4 was worth doing on its own -- it is why n=60
is healthy now -- and the clamp is a separate decision that happens to have
been described using D4-era arithmetic.

## 24. The `m_hat` conditioning: a real deviation, implemented TWICE and held off twice

> **CORRECTION.** This section was first written claiming the conditioning was
> "the one structural deviation never tested". **That was wrong**, and the
> error came from reading §14a rather than the `m_pred` block it points at.
> `lplr.mbt:854-876` records TWO prior implementations, both reverted, both
> with numbers -- most recently on the D2+D3 baseline in v0.163.0, where the
> gated `nuisance_space` gap went **0.007307 -> 0.021078**. Section 25 is an
> independent third implementation, and it reproduced that figure exactly.
>
> What §14a genuinely failed to check stands, though: it verified the
> outer-cross-fit SHAPE, never what is inside the fit. So `d_tilde` was always
> an identity-of-form claim and never a numerical one -- which is the claim
> that survives.

While auditing §16a's "verified equivalent" table against upstream's source
rather than against the port's comments, one row turned out to be verified by
FORM and never by VALUE.

### 24a. What upstream does

`plm/lplr.py:244-264`:

```python
if self.score == "instrument":
    weights = M_hat["preds"] * (1 - M_hat["preds"])
    filtered_smpls = smpls
elif self.score == "nuisance_space":
    filtered_smpls = []
    for train, test in smpls:
        train_filtered = train[y[train] == 0]
        filtered_smpls.append((train_filtered, test))
    weights = None

m_hat = _dml_cv_predict(self._learner["ml_m"], x, d, smpls=filtered_smpls, ...)
```

For `nuisance_space` upstream fits the propensity **on the control rows only**
and predicts on the full test fold. The port's `m_pred = a_pred` is an
UNCONDITIONED outer cross-fit (`lplr.mbt:836`, alias at `:928`).

§14a checked the outer-cross-fit SHAPE -- that `_dml_cv_predict(ml_m, x, d)`
really is a plain outer cross-fit -- and found the alias faithful. It did not
check what happens INSIDE that fit. The port's own header has always said the
conditioning "is implemented on neither branch"; what was missing was any
measurement of what that costs.

### 24b. It is a material difference, measured

`_verify/_lplr_mhat_conditioning_1680.py`, 12 draws per n, both arms on the
probability scale (section 21's correction), everything else held at
upstream's real values, `m_pred` the ONLY thing that differs:

| n | rms difference in `m_hat` | UNCONDITIONED finite | CONDITIONED finite |
|---|---|---|---|
| 100 | **0.3549** | 11/12 | 10/12 |
| 160 | 0.2404 | 12/12 | 12/12 |
| 500 | 0.1526 | 12/12 | 12/12 |

A propensity prediction on `[0, 1]` differing by rms 0.15 to 0.35 is not a
rounding difference. `d_tilde = d - m_hat` enters every `psi`, so §16a's
"verified equivalent" row for `d_tilde` is verified as an algebraic identity
and NOT as a numerical agreement.

Reconstruction check, as required by 21e: rms(port `a_plain` - upstream
`ml_a` bagged) averaged 0.0608, max 0.1645 -- consistent with section 21b's
measured 1.7%-of-span, so the stand-in is sound and was not the thing being
measured.

### 24c. It is NOT the cause of the Newton runaway

Strictly better on 1 draw, strictly worse on 2, tied on 33 of 36. At n=100 --
the row that matters for the remaining divergence -- conditioning is slightly
WORSE for survival (10/12 vs 11/12).

So this is a genuine, material, previously unmeasured deviation that does
**not** explain the clamp's necessity. Implementing it would not remove the
clamp.

### 24d. What this probe does NOT cover, stated plainly

**It did not reproduce the runaway.** At n=500 both arms are 12/12 finite here,
while the fuzz harness and `_verify/_lplr_tol_window2_1680.py` both produce
`se = NaN, th = -440` on this design family. So the DGP/draw combination in
this probe does not enter the failure region, and 24c's "not the cause" is a
statement about the draws it ran, **not** about the runaway itself.

That is section 7b's pattern appearing inside the probe that was written to
avoid it. The honest reading of 24c is narrower than it looks: *the
conditioning did not rescue the draws where the port already converged.* It
was never tested on a draw that ran away, so it cannot be exonerated there.

### 24e. Why it is recorded and not implemented

Three reasons, in order:

1. It would change results at EVERY n, including the n=500 design where the
   gate currently passes. The D2/D3 precedent (§7d, §7e) is that this class of
   change is implemented, measured, and reverted when it does not help -- and
   both of those made parity worse.
2. The n=500 gate cannot detect a regression here. Its band is
   `3 * sqrt(sd_port^2 + sd_up^2)` = 0.206 against a measured gap of 0.007, so
   a `d_tilde` change of this size could move the coefficient materially and
   still read OK. **A loose gate cannot certify a change to the thing it is
   loose about.**
3. 24c gives no evidence it helps.

So the deviation is now measured, scoped and priced, rather than being an
unexamined gap in the equivalence table -- which is what it was for six
sections. But it was never unexamined in the port: it was built twice and
reverted twice, and the price was already on the record. §25 re-measures it a
third time.

## 25. Third implementation of the conditioning -- it replicates exactly

Section 24's premise was wrong, so the experiment got run anyway. If the
recorded 0.021078 were an artifact of the two old implementations, a fresh
one would land somewhere else.

### 25a. Method

The primitive already exists: `cross_fit_predict_conditional_dispatch`
(`learner.mbt:380-425`) fits on `train INTERSECT cond` and predicts on the
**full** test fold, which is exactly upstream's
`filtered_smpls = [(train[y[train] == 0], test)]`. So the change is small:

```moonbit
m_pred = match kind {
  NuisanceSpace => {
    let mut cond_y0 : Array[Int32] = []
    for i = 0; i < y.length(); i = i + 1 {
      if y[i] == 0.0 { cond_y0 = cond_y0 + [(i : Int32)] }
    }
    cross_fit_predict_conditional_dispatch(ml_m, x, d, outer, cond_y0)
  }
  // `instrument` conditions by SAMPLE WEIGHTS M*(1-M) (`lplr.py:245`), not by
  // row subset -- a different mechanism, still not implemented.
  Instrument => a_pred
}
```

The `instrument` branch is deliberately left alone: conditioning there is
sample weighting, not a row subset, so this is `nuisance_space` only.

### 25b. Result -- identical to the v0.163.0 record

The gate **failed closed** on the changed build, which is the check doing its
job:

```
lplr_ns_theta = 0.41361558678817151
example prints 0.46033435469463013
identical: False
REFUSING to compare: the fixture is not the example's data.
```

The refusal blocked the comparison, so `_verify/_lplr_cond_n500_1680.py`
reads the 5 match-seeds straight out of the emitter instead and runs upstream
on the same rows:

| | port mean | upstream mean | gap |
|---|---|---|---|
| shipped (unconditioned) | 0.399521 | 0.392214 | **0.007307** |
| conditioned | 0.371136 | 0.392214 | **0.021078** |

`0.007307 -> 0.021078` is the **same pair** `lplr.mbt:868` records for the
v0.163.0 implementation. Two independent implementations, a year of
intervening work apart, landing on the same two numbers to six digits. The
recorded price of this change is confirmed, not re-litigated.

The example's published single fit moves by `-0.046719`
(`0.46033435469463013 -> 0.41361558678817151`), which is why the self-check
fired. Reverted; the gate returns to `identical: True`, gaps
`0.007307`/`0.010609`, and all three small-n rows bit-identical.

### 25c. The fails-closed message names the wrong thing

> `REFUSING to compare: the fixture is not the example's data.`

The rows were **identical**. Same DGP, same seed, same emitter. What differed
was the port's *answer*. The check is really "has the port's output moved",
which is a behaviour-change tripwire -- a good thing to have -- but the
wording sends the next reader hunting a data-generation bug in a file that
was not touched. Worth re-wording if this gate is next edited.

### 25d. The methodological point, which is the reason this was worth running

In a system carrying several deviations at once, **correcting one can make the
aggregate worse**, because the deviations were partly cancelling. The
conditioning is unambiguously the faithful construction and it makes the
n=500 answer 2.9x further from upstream. That is D2 and D3 a third time.

So "this piece differs from upstream, therefore matching it will bring the
numbers together" does not hold here, and it has now failed on three separate
pieces. Fidelity is a direction, not a lever.

### 25e. CLOSING 24d: the conditioning does NOT rescue the solver, tested in the failure region

24d said this probe "cannot be exonerated" at the runaway because it never
reproduced one. That is now closed, by running the experiment where the
failure actually lives.

Both changes at once -- upstream's `Y = 0` conditioning **and** the clamp
removed (`theta_new.abs() > 5.0 || (theta_new - theta).abs() > 1.0` raised to
`1.0e300`, leaving scipy's bare `theta - s/sd`):

```
FUZZ FAIL: lplr non-negative finite se
           (trial=7, se=8.883758984028203e+59, th=139.7860980312463)
```

| build | fuzz |
|---|---|
| clamped, alias `m_pred = a_pred` (shipped) | **11/11 PASS** |
| unclamped, alias | FAIL trial 2, `se=NaN`, `th=-440.16` |
| **unclamped + conditioned** | **FAIL trial 7**, `se=8.88e+59`, `th=139.79` |

The conditioning does not rescue the Newton. It moves the failure from trial 2
to trial 7 and changes it from `NaN` to a finite-looking `8.9e+59` -- which is
worse as a diagnostic, because a huge finite `se` reads as a plausible number
rather than an obvious failure.

**So the clamp is necessary for reasons independent of the `m_hat`
conditioning.** The port's Newton is unstable on this DGP family whatever
`m_pred` is, which means the instability comes from somewhere else in the
score path that upstream does not share. That is a live open question, not a
settled one -- but it is no longer confounded by this deviation.

This also retires the last idea that would have removed the clamp: "fix the
fidelity gap and the damping becomes unnecessary" is now measured and false.

### 25f. The fuzz surface never runs at n=500, so "unclamped fails fuzz" is not a port defect

`examples/fuzz/main.mbt:412`:

```moonbit
let n = rng.int(limit=100) + 60
```

**The LPLR fuzz surface only ever runs at `n` in [60, 160].** It never runs at
n=500. Every "unclamped fails fuzz" number in this file -- trial 2 at
`th=-440.16`, and 25e's trial 7 at `th=139.79` -- is from that band.

And section 20 measured, with real `DoubleMLLPLR` fits on a comparable binary
DGP, that upstream is itself unreliable exactly there: non-finite SE on 7 of 25
draws at n=60, 1 of 25 at n=100, 1 of 25 at n=160.

So the fuzz failure is **not, on its own, evidence of a port defect.** It is
evidence that this surface exercises a band where upstream also fails. The
clamp is what keeps the port finite inside a regime upstream does not survive.

This corrects a claim sitting in the code since before section 20. The clamp
block in `lplr.mbt` justifies itself with "On this repo's own binary DGP at
**n = 500**, upstream stayed finite on 300/300 draws while the unclamped port
reaches `se = NaN`". That n=500 figure comes from a separate probe
(`make_dgp` at n=500), not from the fuzz surface -- so the port's fuzz failure
and that probe's failure are two different experiments being cited as one.

**What this does and does not settle.** It does not prove upstream fails on the
exact fuzz draws in question; that needs both solvers run on the identical
`chacha8_rng` rows, which is not cheap to arrange because the DGP is generated
inline in MoonBit and is not reproducible in Python. It does mean the fuzz
result cannot be read as a port-specific bug without that comparison, and that
the n=500 justification and the fuzz evidence should not be quoted together as
though they were one measurement.

### 25g. The comparison 25f called "not cheap" -- run, and it goes the OTHER way

25f left one thing open and said it would take both solvers on identical rows.
That turns out to be cheap, because the fuzz DGP is a pure function of `trial`
(`examples/fuzz/main.mbt:412-459`): `n`, `seed`, `x`, `y`, `d` come from
`ch_rng = chacha8_rng(seed)` and nothing there reads the clamp. **The same rows
are produced whether or not the port is clamped -- only the outcome differs.**
So they can be dumped from the shipped build and handed to upstream, with no
need to un-clamp anything.

A temporary dump for trials 2 and 7 was added to `fuzz_lplr` and reverted in
the same commit. It reported:

```
FZZMETA trial=2 n=66 p=6 seed=96696
FZZMETA trial=7 n=97 p=6 seed=36677
```

`_verify/_lplr_fuzzrows_upstream_1680.py` then ran real `DoubleMLLPLR` on those
exact rows:

| rows | port (unclamped) | upstream `nuisance_space` |
|---|---|---|
| trial 2, n=66 | `se=NaN`, `th=-440.15956528046615` | **`coef=-1.47917`, `se=0.580154` FINITE** |
| trial 7, n=97 | `se=8.883758984028203e+59`, `th=139.786` (conditioned) | **`coef=0.279131`, `se=0.406804` FINITE** |

> **v0.163.4: the two upstream NUMBERS above are not reproducible and must not
> be quoted.** They came from `draw_sample_splitting=True`, which re-draws the
> partition on every call. Re-running the same rows unpinned gives
> `coef=+1.97947`; pinned (see 25h) it is `coef=-0.393576`. **The conclusion --
> upstream is finite on these rows -- survives every draw observed, but each
> individual number is one random draw.** The port's numbers in the left column
> ARE reproducible, because they come from the fuzz harness whose DGP is a pure
> function of `trial` (25g). That asymmetry is the whole reason the table can
> be trusted to compare the two sides at all.

**So 25f's caveat is falsified, and it matters.** Upstream is finite on BOTH
rows under the score the port actually uses, while the unclamped port blows up
on both. This is not a regime where the estimator is ill-posed for everyone and
the port merely reports it differently -- **the port's Newton is genuinely
unstable where upstream's converges, on identical data.**

Upstream does fail on trial 7's `instrument` score (`coef=50.8467, se=inf`,
`Could not find a root of the score function`) -- but that is not the score the
port's fuzz surface exercises.

Three consequences, in order of how much they matter:

1. **The clamp is justified.** It is not papering over ill-posedness upstream
   shares; it is substituting for a stability upstream has and the port lacks.
   The clamp stays, and n=100's disagreement is a genuine port-side
   instability rather than a documented trade with an upstream.
2. **There is a real defect to find.** Section 24e ruled out the `m_hat`
   conditioning; section 21 ruled out the `a_hat` bagging. The instability is
   in the score path somewhere else, and it is now the highest-value open
   question in this file.
3. **25f's closing paragraph is superseded.** The "not on its own evidence of a
   port defect" caveat was the right caution at the time and is now measured
   against. What survives from 25f is the correction to the `lplr.mbt` bullet:
   the n=500 figure and the fuzz trials are two different experiments, and
   neither one on its own settles this. The comparison above does.

### 25h. The harness VALIDATED, and the formula EXONERATED

25g left the divergence localised to "the score path somewhere else", which
splits in two: the FORMULA (how `psi` and `psi_deriv` are built) or the
NUISANCE VALUES fed into it. `_verify/_lplr_formula_vs_nuisance_1680.py`
separates them, and is first and foremost a validation of the Python harness
that every conclusion in sections 19, 21, 24 and 25e rests on.

**Validation.** Upstream's real nuisances (`t_hat`, `m_hat`, `a_hat`, `beta`,
all captured from the fit itself), run through the Python Newton on trial 2's
rows, partition pinned:

```
coef=-0.393576  se=0.566214      upstream
coef=-0.393576  se=0.566214      python
VALIDATION: |theta_python - coef_upstream| = 0   (tol 1e-3)  -> MATCH
```

Not "within tolerance" -- **exactly zero**, and bit-reproducible across runs.
The harness is upstream's Newton.

**Exoneration.** With the formula reproducing upstream to the last bit on the
very rows where the unclamped port dies, the formula is not the defect. The
divergence is in the **values**: `t_pred`, `m_pred`, `a_pred` or `beta`. So the
next step is a numeric dump of the port's own four arrays on `n=66` and a
row-by-row diff against upstream's -- not another reading of the source.

**A parser bug worth recording, because it produced plausible numbers.** The
first version of the probe's row parser terminated on `len(rec) < 7` while the
initial dict held three keys, not four. It therefore ran past trial 2's own
data lines and silently overwrote them with trial 7's, yielding trial 2's
header (`n=66`) beside trial 7's values (582 floats) with no error raised. A
sentinel count is an assumption about the dict's size; the loop now terminates
on the keys it needs and refuses any value count that disagrees with its
header. The symptom was a reshape error on a length that was internally
consistent -- exactly the shape of bug this investigation has been correcting
all along, arriving from a different direction.

## 26. Bare local `typos` FAILS this repo on tracked files -- do not "fix" them

The release gate pins `typos` **v1.19.0** and runs it bare over the whole
checkout. The local binary is **1.50.3**. They disagree, and the disagreement
lands on TRACKED files.

Local 1.50.3 over a clean `git archive HEAD` export (580 files) reports 11
findings, all in tracked paths:

| file | finding | v1.19.0 |
|---|---|---|
| `pyexample_policytree.py:229,239,253` | `thr_ok` should be `the` | does not flag |
| `_verify/H1-verdict.md:4` | `REIVEW` should be `REVIEW` | does not flag |
| `_verify/_commit_msg_final7_1680.txt` | `datas` x1, `psiBa` / `Ba` x5 | does not flag |
| `_verify/_commit_msg_fixgates_1680.txt` | `datas` x1, `psiBa` / `Ba` x3 | does not flag |

All eleven pass the pinned gate, which last exited 0 on `873f0ea` over the same
580 files. There is no `.typos.toml`, so both binaries run with defaults and
the only difference is the dictionary.

**Why this file quoting those tokens is still safe.** Writing this section
made the evidence file itself fail local `typos` (exit 2), which is the trap
demonstrating itself. The pinned binary could not be re-run at the time --
its download was down -- so the claim rests on an inference rather than a
fresh run, and the inference is direct: **the same tokens were already in
tracked files inside the 580-file checkout that the pinned gate cleared on
`873f0ea`.** `thr_ok` sat in `pyexample_policytree.py`, `REIVEW` in
`_verify/H1-verdict.md`, `datas`/`psiBa` in the two scratch commit messages.
v1.19.0 saw them and passed. Re-stating the same strings in another tracked
file cannot introduce a finding the dictionary does not have.

**The hazard is `thr_ok`.** It is a local variable in a shipped gate. Someone
running local `typos`, believing it authoritative, renames it to `the_ok` and
the rename has to be propagated through the file -- or not, and the gate breaks
in a way that looks like a real bug. `datas` and `psiBa` are the same trap in
`_verify/` scratch: they are the identifiers those commit messages are
*quoting*, so "correcting" them destroys the record they preserve.

So: **local `typos` is necessary and not sufficient, and where the two
disagree the pinned binary wins.** CI's result is the gate; a local finding on
these eleven is not a defect to fix until v1.19.0 agrees it is one.

The QA loop's `static_code_check` reports its findings as "in 14 UNTRACKED
file(s) ... none are tracked, so the release gate is clean", which is true and
also misleading: it implies a clean tracked surface that the pinned binary
does confirm, but the local binary disagrees with the pinned one about what
that surface contains.

### 26a. §26's safety claim is REFUTED -- v0.163.4's publish run FAILED at `Check typos`

The inference above is wrong, and it cost a release. `v0.163.4`'s publish run
(`39122421293`) went red at `Check typos`, the same gate that killed `v0.163.1`:

```
error: `datas` should be `data`
  --> ./_verify/LPLR_GATE_BLINDNESS_1680.md:2245:44
error: `Ba` should be `By`, `Be`
  --> ./_verify/LPLR_GATE_BLINDNESS_1680.md:2245:59
  ... 2245, 2246, 2259, 2266
```

Everything up to it passed -- including `Resolve release version`, so the tag
agreed with `moon.mod` -- and `Publish to Mooncakes` and `Create GitHub Release`
were both **skipped**. mooncakes still serves 0.163.3.

**Why the inference failed.** It rested on: "the same tokens were already in
tracked files inside the 580-file checkout that the pinned gate cleared on
`873f0ea`". They were not. Every file it cites for that purpose is untracked
scratch or excluded:

| token | cited as "already cleared" | actually |
|---|---|---|
| `thr_ok` | `pyexample_policytree.py` | passes on its own -- no finding |
| `REIVEW` | `_verify/H1-verdict.md` | **untracked** |
| `datas` / `psiBa` | `_verify/_commit_msg_*.txt` | **untracked, and `extend-exclude`d** |

So the pinned gate had never seen `datas` or `psiBa` at all, and "re-stating the
same strings in another tracked file cannot introduce a finding the dictionary
does not have" was a statement about a checkout that did not contain them. The
580-file checkout `873f0ea` cleared predates §26's own commits (`5b3fc73`,
`7d5ef8a`) -- §26 introduced the very findings it then excused.

**The generalisable failure.** §26 wrote down its own epistemic status -- "the
claim rests on an inference rather than a fresh run" -- and then spent two
sections building on it. A stated inference is not a weaker version of a
measurement; it is a different thing, and it cannot be promoted by being
re-quoted. The check was one download away and the download recovered the moment
it mattered.

**Fixed** in `c223062`: `datas` and `Ba` are whitelisted in
`_typos.toml [default.extend-words]`. Per-token, not by excluding the whole
record -- that file is our own prose and the other ~2,600 lines should stay
spell-checked. The same config already excludes verbatim *evidence* for exactly
this reason, and the §26 table's whole subject is the misspelling it reports, so
correcting it would make the record stop quoting what it is a record of.

**Verified with the pinned binary, not inferred.** `_verify/_typos_pinned_check_1680.py`
downloads typos v1.19.0 and runs it over a pristine `git archive` export -- the way
CI checks out -- and reports `NOT VERIFIED` rather than falling back to the local
1.50.3, since a local pass says nothing about a pinned gate. Before the fix it
reproduced the CI failure exactly (exit 2, same 10 findings); after it, exit 0 over
581 files.

### 20d. The meta-point, which is the same one as section 7b

A measurement taken in the regime where a failure cannot occur is not
evidence about the regime where it can. The 0/300 number was true and it was
load-bearing for six sections and two shipped design decisions, and it was
true *at n=500*. §11 recorded that the parity gate agrees at n=500 while the
estimator is wrong at n=60 -- the two facts were in the same document, and
the inference still did not get made. The same pattern as §7b and §19: a
number was produced, then generalised past the conditions it was measured
under.

## 21. RETRACTION: 18d's magnitude and ALL of 19 were measured against the wrong control

Sections 18d and 19 (and the n-sweep in 20b) compared upstream's `a_hat` against
a Python reconstruction of "what the port builds". The reconstruction was wrong,
and it was wrong in the one way that guarantees a large answer.

### 21a. The control was hard labels; both nuisances are probabilities

The reconstruction used

```python
LogisticRegression(...).fit(x[tr], d[tr]).predict(x[te])
```

and sklearn's `.predict` returns **0.0 / 1.0 class labels**. But both nuisances
under comparison are probability vectors:

  * `a_hat` -- `method=self._predict_method["ml_a"]`, which is `"predict_proba"`
    (`plm/lplr.py:166`, consumed at `:311`), so `_double_dml_cv_predict` takes
    the `predict_proba` branch at `utils/_estimation.py:225-226`.
  * `m_hat` -- `method=self._predict_method["ml_m"]`, also `"predict_proba"`
    (`plm/lplr.py:150`, consumed at `:261`). `_verify/_lplr_bag_nsweep_1680.py:125`
    rebuilt this with `.predict()` as well, so the n-sweep had the defect TWICE,
    once in each nuisance.

The port is on the probability side, verified in the implementation and not only
in its comment: `logistic.mbt:217-243` returns `sigmoid(eta[i])` clipped into
`(1e-15, 1-1e-15)`, and the hard-label path is a *separate* function,
`predict_class` at `logistic.mbt:250-262`.

So every "PLAIN is much worse" number in this document was measuring **hard
labels against probabilities**. That control is guaranteed to look bad: labels
discard all the confidence information the score depends on, so Newton
destabilises for a reason that has nothing to do with bagging.

### 21b. Corrected on the gate's own fixture (n=500, p=6, 2x2 folds)

`_verify/_lplr_ahat_proba_1680.py`, upstream's own `upstream_fit`, so rows and
partition are the gate's:

| control | rms vs upstream `a_hat` | / span | corr |
|---|---|---|---|
| `predict_proba` (**correct**) | 0.00870977 | **0.0170** | 0.995883 |
| `predict` (labels, withdrawn) | 0.424712 | 0.8287 | 0.716463 |

`span(a_hat) = 0.512483`. The real difference is **1.7% of span**, not the 69%
of 18d and not the 82.9% my first re-probe reported.

Effect on the coefficient, substituting the plain OOF into upstream and changing
nothing else, over the gate's own five inner seeds:

```
bagged  mean 0.392214 (sd 0.043537)
plain   mean 0.392604 (sd 0.043659)
mean shift +0.000390   max|shift| 0.002234   sign consistent 4 of 5
```

The gate's band is `3 * hypot(sd_port, sd_up)`, so its floor at `sd_up` alone is
`0.130611`. A shift of `+0.00039` is **335x below that floor**, and roughly 18x
below the gate's own reported gap of `0.007307`.

### 21c. Corrected small-n sweep -- the survival advantage was entirely the artifact

`_verify/_lplr_bag_proba_nsweep_1680.py`, both nuisances on `predict_proba`,
unclamped Newton, 25 draws per n:

| n | BAGGED finite | PLAIN finite | rms/span of the nuisance gap | mean(psi) ratio | first-step ratio |
|---|---|---|---|---|---|
| 60 | 18/25 | 18/25 (tie) | 0.215 | 0.992 | 1.000 |
| 100 | 20/25 | 20/25 (tie) | 0.126 | 1.015 | 1.013 |
| 160 | 25/25 | 25/25 (tie) | 0.078 | 0.999 | 1.000 |
| 500 | 25/25 | 25/25 (tie) | 0.026 | 0.999 | 0.999 |

**Exact ties at every n.** 19's `15 vs 16, 19 vs 21, 19 vs 20 of 25` were the
labels. 19b's `~13x` and `~1400x` are `0.99` and `1.00`.

### 21d. What is left standing

The bagging IS a real difference -- upstream sums every inner model's prediction
on the outer test rows and divides by `len(smpls)` (`_estimation.py:207-229`),
where `lplr.mbt:836` is a single outer OOF -- and it shrinks with n
(21.5% of span at n=60, 2.6% at n=500). It is simply **not a cause of
anything**: survival ties at every n, Newton-step ratios 1.00, and a coefficient
shift of 3.9e-4 against a tolerance of 1.3e-1.

**Do not ship the bagging.** It cannot move the gated gap, it does not improve
small-n survival, and 18d's premise -- that it is "REAL and large" -- does not
survive a control on the right scale. 18d's *structural* observation (a_hat is a
bagged predictor, `preds_inner` is a separate quantity) remains correct; only
its magnitude and its consequences are withdrawn.

Unaffected by this retraction: 13-16 (verified-equivalent table), 17 (tolerance
falsified), 18e (inner-split scope faithful), 20 (upstream ill-posed at small n),
20a (the clamp's justification), and 7b/20d.

### 21e. The failure mode, which is new

§7b and §20d are both "a number measured where it cannot fail was generalised
past its regime". This is a different one, and it is worse: **the control was
never checked against the implementation it was standing in for.**

The probe was supposed to answer "what does the port compute?" by writing the
port's construction in Python. Nothing verified that Python matched the
MoonBit. Two functions, `.predict` and `.predict_proba`, sit one call apart, the
port uses the second, and the probe used the first. The error was invisible
because it produced a *plausible, large, directional* number -- which is exactly
what made 18d and 19 publishable and load-bearing.

The check that would have caught it costs one grep: read the port's `predict`
implementation and see what it returns. It was already written down at
`learner.mbt:159`. **A control reconstructed from source must be validated
against the source before it is used to measure anything.**

---

## 27. The last open LPLR divergence is CLOSED -- and it reverses 25g

25h exonerated the formula but left the cause unlocated, so this section does the
thing 25h said to do next: dump the port's own four arrays on the failing rows
and find out which one carries the effect. The answer is `beta`, and following
it one level further turns out to reverse a conclusion this record has been
carrying since 25g.

### 27a. What had to be dumped, and why a diff was impossible

A row-by-row comparison of the port's `t_pred` against upstream's `t_hat` was
never available and never would be: the two sides draw different partitions, so
`upstream.t_hat[i]` and `port.t_pred[i]` are predictions from different models.
The only test that survives that is **causal** -- hand upstream's solver the
port's values and see whether the port's behaviour reproduces.

A temporary probe dumped `x`, `y`, `d`, `t_pred`, `m_pred`, `a_pred`, `beta_start`
whenever `n == 66`, from the **shipped** build, on the DGP rows of
`examples/fuzz/main.mbt:412-459`. Reverted in the commit that consumed it;
`moonbit_doubleML/lplr.mbt` is byte-identical to `1520c04` after the revert.

Two things about the dump are worth recording because both nearly hid a result:

* The guard `n == 66` fired **14 times** across the 300-trial surface, not once.
  The block belonging to trial 2 was therefore located by **exact row equality**
  against the fuzz harness's row dump, not by taking the first or last
  occurrence. Two blocks matched -- the port fits each trial twice, and those
  two fits are bit-identical to each other -- so this is a 14-way ambiguity that
  happens to have a clean answer, not an unambiguous guard.
  **Corrected 2026-10-20 (round 17): this bullet named
  `_fuzz_dump_1680.log` as that witness, and that is
  the WRONG FILE.** The file of that name is not in this repository -- it is
  a scratch capture the project's own `.gitignore` keeps out of the tree --
  and the file that IS tracked,
  `_verify/_lplr_r17_1680/_fuzz_run_1680.log` (sha256 prefix `6903e784`),
  is byte-identical to it and
  holds the harness's PASS/FAIL transcript, not rows. This is **reproducible,
  not merely an observation**: re-running
  `_verify/_lplr_fuzzrows_upstream_1680.py` -- the script that CREATES that
  file -- writes a `_fuzz_dump_1680.log` with the same sha256 prefix
  `6903e784`, because the dump probe was reverted from the shipped build in
  the same commit that consumed it, so the capture takes the transcript and
  nothing else. The file that actually carries the rows is
  `_verify/_lplr_r17_1680/_port_dump_1680.log` (sha256 prefix `7be25bac`),
  which holds the **2** `PORTMETA` blocks for trial 2
  (`n=66 p=6 seed=96696`) -- the two
  matching fits this bullet describes. The selection step is therefore **not
  reproducible** from the tree: its inputs (the `FZZMETA` row dump and the
  14-block `PORTMETA` run) were never committed. What is committed is the
  selected result.
* A first parse read the inner scan to EOF and so collected only the first block
  while reporting 14. The count came from a separate line count, and the two
  disagreed. Same family as the 25a dict-size bug: **terminate a parser on the
  keys it needs, never on a sentinel count.**

### 27b. The causal test: the port's own values make upstream's solver diverge

Feeding the port's dumped arrays to the 25h-validated Python Newton:

| side | `beta` values (2 folds) | `mean(beta)` = theta0 | Newton | stop | implied se |
|---|---|---|---|---|---|
| upstream's own | `[-8.4691, 10.4752]` | 1.003059 | -0.393576 | converged | 0.566214 |
| **the port's** | `[3.6101, 10.0746]` | **6.842375** | **-440.159565** | **maxiter** | **NaN** |

The port's values (`t` in `[-23.17, 20.34]`, `m_pred == a_pred`) are enough on
their own to break a solver that converges on those same rows when handed
upstream's values. Both matched blocks give the identical answer, as expected
since they are the same fit.

### 27c. The 16-cell swap names the array

| `t` | `m` | `a` | `b` | theta | verdict |
|---|---|---|---|---|---|
| U | U | U | U | -0.393576 | ok |
| P | U | U | U | 0.675398 | ok |
| U | P | U | U | 0.058868 | ok |
| U | U | P | U | -0.303850 | ok |
| P | P | P | U | 0.897963 | ok |
| **any** | **any** | **any** | **P** | -321 .. -440, or NaN | **DIVERGES (8/8)** |

A clean partition: all 8 cells with `b` from upstream converge, all 8 with `b`
from the port diverge. `t`, `m` and `a` move the root by at most ~1.0 and none of
their cells fails. `beta` is necessary and sufficient.

### 27d. Inside `beta`: the START value, not `r_hat`

`beta` enters the solve twice, and the two uses are not interchangeable:
`theta0 = np.average(beta)` (`plm/lplr.py:326`, the Newton start) and
`r_hat = t_hat - beta * a_hat` (`plm/lplr.py:345`). Separating them, with
upstream's `t`/`m`/`a` held fixed throughout:

| configuration | theta | verdict |
|---|---|---|
| `theta0` = U.mean, `r_hat` uses U.b | -0.393576 | ok |
| `theta0` = **P**.mean, `r_hat` uses U.b | NaN, nonfinite | **DIVERGES** |
| `theta0` = U.mean, `r_hat` uses **P**.b | -0.658438 | ok |
| `theta0` = **P**.mean, `r_hat` uses **P**.b | NaN, nonfinite | **DIVERGES** |

So `beta` inside `r_hat` is harmless, and the **start value** is the whole
defect. The port's start 6.842375 goes non-finite on upstream's *own*
well-behaved function, where upstream's own start 1.003059 converges to -0.394.

### 27e. The port's solver is FAITHFUL -- upstream runs the same unbracketed Newton

This is what stops 27d from being a port bug. `plm/lplr.py:326` sets
`self._coef_start_val = np.average(beta)` and `plm/lplr.py` never sets
`_coef_bounds` anywhere. In `double_ml_score_mixins.py:143-150`:

```python
if self._coef_bounds is None:
    bounded = False
if not bounded:
    root_res = root_scalar(score, x0=self._coef_start_val,
                           fprime=score_deriv, method="newton")
```

With no bounds, upstream runs an **unbracketed Newton from exactly the start
value the port uses**. The port's start *rule* is `np.average(beta)`, verbatim.
The clamp at `lplr.mbt:1261` is standing in for a robustness upstream does not
have either.

### 27f. The basin, and the derivative collapse that explains it

Real `scipy.optimize.root_scalar(..., method="newton")` -- not a mimic -- on
upstream's own nuisances, over a grid of starts. The method script is
`_verify/_lplr_basin_scan_1680.py`; it was **written on 2026-10-20 (round 17)**
because this section previously had **no** script at all, and it reproduces
every number below exactly:


| `x0` | root | converged |
|---|---|---|
| -20, -10, -5, -3, -2, -1, 0, 0.5, 1.003, 2, 3 | -0.393576 | yes |
| 4, 5, 6 | -26.9, -165.0, -542.0 | **no** |
| 6.842 (the port's), 8, 10, 15, 20 | NaN | **no** |

Fine scan `0.0 .. 20.0` step `0.5`: 8/41 converge, range `[0.0, 3.5]`. The basin
edge for **this** draw lies in `(3.5, 4.0]`.

**"Converged" means converged TO THE ROOT.** Starts 4, 5 and 6 return finite
numbers -- -26.9, -165.0, -542.0 -- and every one of them is wrong. A finite
answer is not a solution, and a gate that counts "did scipy return a number"
would score 13/41 here instead of 8/41 and would call three runaways
successes. The script tests the root against upstream's own fitted
coefficient, not against finiteness.

The mechanism is a derivative collapse, not an overflow from a large number:

```
at x0 = 1.003059 :  score = -0.0842799   deriv = -2.77093e-02
at x0 = 6.842375 :  score = -0.111909    deriv = -8.06571e-05
```

The score barely changes (0.084 -> 0.112) while the derivative falls by a factor
of 344, so the first step `theta - score/deriv` at 6.842 is `6.842 - 1387.5`,
about **-1381**. That is the `e+70`/`e+122` mechanism, and it is why the start
value is the lever: a flat-score region is safe to *be in* and fatal to *start*
in.

### 27g. 25g DOES NOT SURVIVE: upstream fails 42% on these same rows

25g concluded "upstream is FINITE on the exact fuzz rows the unclamped port dies
on", and from that "the clamp is justified, real port instability proven". That
rested on **one** upstream draw with `draw_sample_splitting=True` -- which 25g
itself flagged as unreproducible. Sweeping 40 **pinned** redraws on the same
rows, upstream's own start value is a wide draw:

```
mean(beta) over 40 upstream draws : mean 2.5554  sd 3.3939  range [-3.2057, 13.8508]
quantiles                         : 25% 0.4509  50% 1.9216  75% 5.0785  90% 6.5903
draws with start > basin edge 3.5 : 14/40  (35%)
the port's 6.842375 sits at the 90th percentile
```

The two runs behind this section are `_verify/_lplr_startval_bias_1680.py`
(the start-value sweep above) and
`_verify/_lplr_upstream_fragility_control_1680.py` (the uninstrumented control
below). Both were **untracked** until 2026-10-20 (round 17), and both now
print which upstream they ran against. Re-run on 2026-10-20 against
`doubleml` 0.11.4, they reproduce the table above and the control below
**exactly**.

and, on the **uninstrumented control** -- no spies, no rebuilt `beta`, no re-run
`root_scalar`, just `DoubleMLLPLR(...).fit()` and read `.coef[0]`:

| | instrumented | control |
|---|---|---|
| upstream fits that did not converge | 18/40 (45%) | **17/40 implausible (42%)** |
| fits raising upstream's own root warning | -- | 18/40 |

Sample of upstream's own output on rows it is supposed to handle: `coef`
`-648.285`, `-592.928`, `-235.134`, `-242.104`, `-102.605`, `172149`, `nan` (x4),
`5.18e+70`, `8.44e+122`, `3.73e+119`, `2.92e+26`, `9.78e+82`, `2.20e+74`, with
`se` `nan` or `inf` on most of them.

**So 25g's conclusion is withdrawn.** The port does not diverge "where upstream
does not" -- on these rows upstream fails ~42% of the time and the port's start
value is an unremarkable 90th-percentile draw. The clamp is not covering a port
defect; it is covering a **fragility upstream shares and does not guard against
either**. 25g's individual measurement was accurate for its one draw, which is
precisely why it needed the population rate.

The same sweep also bounds a bias claim. It does **not** show the port's `beta`
is unbiased, because the port's own draws were not measured on this sweep (that
would need the partition injected into the port). It removes "the port's start
value is systematically too large" as a conclusion and leaves it unmeasured.
The basin edge is also draw-specific -- among the sweep's draws, 3.5491 and
3.7774 both converged -- so 3.5 is *this* draw's edge, not a constant.

### 27h. What this does and does not establish

**Does:** the mechanism, end to end and causally. The port's `mean(beta)` lands
outside the Newton basin on the n=66 rows; there the derivative collapses by
~344x; the first step overshoots to about -1381; the score overflows; the port
returns `NaN`. Upstream's own solver has the identical exposure and fails
~42% of the time on the same rows, by its own output, with nothing
instrumented.

**Does not:** show the port's `beta` is unbiased (that needs the port swept over
the same partitions); show the port is *better* than upstream here -- it is
unclamped-fatal where upstream is ~42% fatal, so on this row set the clamp is
what makes the port *no worse*, a different and smaller claim than 25g made; or
change any shipped behaviour. **The clamp stays**, and is now justified by a
fragility measured on both sides rather than by an asymmetry that did not exist.

### 27i. A withdrawn number was still live 33 lines below its own withdrawal

Correcting 27g required re-reading what cites it, and the sweep for the withdrawn
bagging figure found `lplr.mbt:1236-1242` still reading "One real divergence
remains and it is NOT implemented ... (69% of `a_hat`'s own span apart)" -- 33
lines below the paragraph at `:1202-1205` that withdraws that exact figure, and
23 lines below `:1213-1215` which says **do not implement the bagging**. Fixed
in the same commit. This is 22a-bis recurring: **withdrawing a number in the
place you were already editing is not a sweep.**
