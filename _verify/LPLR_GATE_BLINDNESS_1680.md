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

## 5. D1 measured, not assumed

The in-body note says this "was tried and reverted", citing a collapse
(`beta_start` reaching -4.75, `mean(psi_deriv)` -3.2e-8, Newton
non-convergence, `se` -2.4e6) on `lplr_test`'s n=120 fixture. The note also
says why upstream is immune: **its default `ml_m` is a `LogisticRegression`**.
That is the same learner mismatch as §3 — so the blocker was the OLS
default, not the filter.

Implementing the filter behind `if kind == NuisanceSpace` and re-measuring,
same rows, same outer partition, 5 inner seeds each side:

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

## 8. Status

- **Shipped in this series**: `sec_lplr_upstream` in `examples/parity` and
  `pyexample_lplr.py` — a shared-rows, shared-partition gate that is
  materially stronger than the validator it complements.
- **Not yet shipped**: D1 itself. It is a behavioural change that moves the
  example's printed values, the generated e2e table, and the validator's
  assertions. Its blast radius on the test suite is being measured before
  it is proposed.
- **Still open**: D2 (`W_inner` uses outer OOF; upstream uses inner OOF) and
  D3 (one fold-averaged `beta_start`; upstream uses per-fold `beta[test]`).
  Both were left in place while measuring D1, so their contribution is not
  yet separated.
