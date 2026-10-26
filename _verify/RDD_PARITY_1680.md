# RDD: the previous "measured divergence" was measured on a noiseless design

> **RETRACTED 2026-10-13, and the gate that was declined is now installed.**
> Everything below the `sec_rdd_var` table — the 0.038/0.026 SE ratios, "the sign
> of the divergence is not stable across designs", and "the port's HC0 arm
> returns EXACTLY 0.0 ... the root cause is not yet diagnosed" — was measured on
> a design that contained **no noise at all**. The section that was introduced
> specifically to supply noise did not supply any. The retraction and the
> re-measurement are below. The original text is kept verbatim underneath so the
> reasoning can be audited rather than taken on trust.
>
> **One thing in the verbatim text cannot be run.** Its "Reproduce" block names
> three scripts — `_rdd_api_1680.py`, `_rdd_fit_1680.py` and
> `_rdd_determinism_1680.py` — that were never committed to this repository
> (`git log --all -- _verify/_rdd_api_1680.py` is empty). The "Reproduce" block
> in the live sections above names four that do exist. That note is part of the
> record rather than a promise.

## Retraction 1: `sec_rdd_var`'s "noise" was collinear with the running variable

The noise term was `(i*130363 + 777) / 131069.5 - 1`. That is an exact **linear**
function of `i` — and `u = (i + 0.5)/400 - 1` is also linear in `i`. So the term
was collinear with the running variable, the local-linear fit absorbed it
exactly, and the design reproduced `sec_rdd`'s zero-residual degeneracy it was
built to escape.

Measured, not inferred:

```
0.5 * noise ranges over        [-0.497, 396.85]      <- a ramp, not a bounded shock
regressing 0.5*noise on (1,u): residual ss-sum 6.9e-24
fit residuals, sec_rdd_var:    L 1.709e-23   R 1.987e-23
port homo_se on that design:   3.15e-15       <- not the 0.003535 in the table below
```

Consequences, each of which reverses a published claim:

| claim below | status |
|---|---|
| port/upstream SE ratios **0.038 / 0.026** | **void** — both sides were ~1e-15; the ratio measured the noise floor |
| `homo_se = 0.003535472` | **void** — it was `3.15e-15` |
| "the sign of the divergence is not stable across designs" | **void** — it compared a 3.3x against a ~0.03x, and only one of them was a variance |
| finding 2, "HC0 returns EXACTLY 0.0, root cause not diagnosed" | **withdrawn** — see below |
| "rdrobust is unseeded, 2.99e-02 spread over four fits" | **unreproduced** — see below |

**Finding 2 is withdrawn.** A White sandwich is `sum_k w_k^2 m_k^2 e_k^2`. On a
design whose residuals are `1e-23`, it returns ~0. That is the formula working,
not failing, and the observation "HC0 is 0.0 while homoskedastic is 0.003535 on
the same rows" was really "HC0 is 0.0 while homoskedastic is 3.15e-15 on the
same rows" — the two arms agreeing that the residuals are zero.
**`sandwich_se_weighted` is not defective.** It is untouched.

The one part of finding 2 that survives is an observation about the source, not
a measured defect: `sandwich_se_weighted` builds `M` from `X^T X` **unweighted**
(`linear.mbt:301`) where its docstring says `X^T W X` (`linear.mbt:280-282`).
That is a real inconsistency between code and documentation. It was *not* shown
to produce a wrong number, and it is not the cause of any zero. Recorded as a
doc/code mismatch to settle on its own merits, not as a defect with evidence
behind it.

**The determinism claim is unreproduced, not disproven.** Four fits at one seed,
four at four different seeds, and one unseeded fit all return
`tau.bc = 2.0089050907775801` bit-for-bit. The natural explanation — that the
spread came from bandwidth *selection*, which resamples — is also wrong:
`bwselect='mserd'` returns 1.9791848657268085 at all four seeds, spread 0.0e+00.
So no mechanism was found. The honest state is "could not reproduce", and the
correct response to an unreproduced hazard is a control, not a pinned seed: the
gate now fits upstream twice and fails if the two differ.

## Re-measurement on a design that does have noise

Same skeleton, noise replaced by a **multiplicative hash modulo a prime**, which
is not a linear function of the index:

```
ei = (i * 2654435761 % 1000003) / 500001.5 - 1
```

Residuals are now `~1.67e+01` per side. Bandwidth 0.5, triangular kernel,
rdrobust 2.1.1, `vce='nn'` on both sides:

| quantity | port | upstream `rdrobust` | rel gap |
|---|---|---|---|
| `tau_bc` vs `tau.bc` | 2.0089050907775863 | 2.0089050907775801 | **3.1e-15** |
| `tau_bc_se_rb` vs `se.rb` | 0.13164869924415856 | 0.1316486992441567 | **1.4e-14** |
| `homo_coef` vs `tau.us` | 2.0168404167343894 | 2.0288599714992888 | 5.9e-3 |
| `homo_se` vs `se.us` | 0.005241166289055757 | 0.09818767604537382 | 9.5e-1 |

**The port's bias-corrected estimator was already correct.** Finding 1 below —
"upstream bias-corrects and the port does not" — is true of the *default arm*,
but the port has carried a full rdrobust port of the bias-corrected estimator in
`DoubleMLRDD::tau_bc` and its robust SE in `DoubleMLRDD::tau_bc_se_rb` all
along. They agree with upstream to 3.1e-15 and 1.4e-14. The planned
re-specification ("add local bias correction") would have duplicated code that
already exists and already matches.

So the real shape of the gap is narrower and sharper than the section below
describes: **the estimator is ported and agrees; only the default is wrong.**
`coef()` / `se()` are homoskedastic and uncorrected where rdrobust's default is
bias-corrected and robust. That is a **default change**, not a re-specification,
and it is much smaller than the one that was approved.

## Decision: RDD is gated, on the arm that matches

`pyexample_rdd.py` gates `tau_bc` against `tau.bc` and `tau_bc_se_rb` against
`se.rb` at bound `1e-11` — about four orders above the measured gaps, and nine
orders below the 2.0e-2 that separates rdrobust's own `tau.us` from `tau.bc`.
The default arm is printed on every run and **not** gated: requiring it to match
would be a permanently red gate, which is either a failing CI or an
`--allow-inert` mute.

Mutation battery `_verify/_rdd_battery_1680.py`, **6/6**:

| arm | mutation | expected | why |
|---|---|---|---|
| C0 | none | PASS | the arm set can produce green |
| M1 | `tau_bc * (1+1e-9)` | FAIL | 100x the bound |
| M2 | `tau_bc_se_rb * (1+1e-9)` | FAIL | same, on the SE |
| M3 | `tau_bc * (1+1e-13)` | **PASS** | below the bound — a gate that failed here would be a tripwire, not a measurement |
| M4 | `sum_y + 1e-6` | FAIL | the fingerprint discriminates, so green is not a gate that skipped step 1 |
| M6 | `tau_bc` row deleted | FAIL | fails closed on a missing row |

M6 earned its place immediately: it found a live bug in the gate. The
`tau_bc_collapsed` reporting block read `vals["tau_bc"]` unguarded, so with the
row missing the gate raised `KeyError` and exited 1 **with no `RESULT:` line**.
A battery scoring only the exit code would have called that a pass — a crash and
a red gate are indistinguishable that way. Fixed, and the battery now reports a
crash as its own outcome.

Reproduce:

    python pyexample_rdd.py --check
    python _verify\_rdd_battery_1680.py
    python _verify\_rdd_design_audit_1680.py      # the collinearity, and the fix
    python _verify\_rdd_det_reconcile_1680.py     # the unreproduced spread

## Also measured: a docstring that states something its own test cannot see

`DoubleMLRDD::tau_bc_collapsed` returns `1.9834057184231799` on this design
while `tau_bc` returns `2.0089050907775863` — they differ by `2.55e-02` at
`b == h`, which is the case the v0.116.0 docstring claimed they "agree to ~1e-15
when `b == h`". They do not, on a design with noise. The test
`v116_tau_bc_equals_the_collapsed_form_only_when_b_equals_h` cannot see the
difference because its fixture is exact, so both forms reduce to the same
noise-free limit.

**Corrected.** Both docstrings now say the substitution fails, and why: `bias`
is not a difference of two fits — it returns `rdd_limit(s, h, p) - xi_bc_s`
with `xi_bc_s` from the `Q` sandwich — so `rdrobust`'s analytic local bias
correction agrees with an order-`q` fit to leading order in `h`, not exactly.
They publish both measured gaps, **6.7e-8** on the v0.116.0 fixture and
**1.3e-2** on `rdd_var`, five orders apart, and `pyexample_rdd.py` settles which
form is right against upstream: `tau_bc` matches `tau.bc` at **3.1e-15**, so
`tau_bc` is correct and `tau_bc_collapsed` is a distinct quantity that sometimes
nearly equals it.

The test is left alone on purpose. It pins the BOUNDARY — equal at `b == h`,
different elsewhere — which is the fact worth pinning; the reason it cannot
establish the identity is written down next to it. The correction shipped with
the commit that added this section (`3b26b2d`), so the note that used to stand
here — "not yet corrected ... logged, not fixed" — was out of date the moment it
was written, and the test name it quoted was the pre-rename one.

---

# Original text (retracted where marked above)

# RDD is gateable to probe but not to gate: the port's `se` is 3.3x upstream

_1680 series. This closes the "RDD: not yet probed" row in
`FIVE_GATES_FEASIBLE_1680.md` — in the direction of recording a measured
divergence rather than building a gate._

## The dependency, first

Upstream `RDFlex` will not run at all without `rdrobust`:

```
ImportError: rdrobust is not installed. Please install it using 'pip install DoubleML[rdd]'
```

`pip install --dry-run` showed three new packages: `rdrobust`, `plotnine`,
`mizani` — the latter two are rdrobust's *plotting* dependencies, which a
gate never touches. CI installs `doubleml numpy pandas statsmodels
scikit-learn`, so gating RDD means adding a dependency to the workflow for
a slot whose numbers do not agree anyway.

## Four call-shape traps, each measured

Every one of these was found by running, not by reading.

1. **The class is not exported at the top level.** `dml.RDFlex` and
   `dml.DoubleMLRDD` are both `False` on 0.11.3. The class is at
   `doubleml.rdd.RDFlex`. A probe that only checks `hasattr(dml, name)`
   reports a present class as missing.
2. **It takes a `DoubleMLRDDData`, not a `DoubleMLData`.** A plain
   `DoubleMLData` is rejected in `_check_data` (`rdd.py:503`).
3. **`score_col` must be disjoint from `d_cols`.** Passing the running
   variable as both raises at `_check_disjoint_sets_score_col`
   (`base_data.py:785`). `d` is the binary assignment, `score` the
   continuous running variable.
4. **`bw` is not a kwarg.** `RDFlex(**kwargs)` forwards to
   `rdrobust.rdrobust`, whose bandwidth arguments are `h` and `b`:
   `TypeError: rdrobust() got an unexpected keyword argument 'bw'. Did you
   mean 'b'?` Unlike PolicyTree's `tree_params`, `**kwargs` here genuinely
   forwards — it just forwards to different names.

Also: `rdrobust_output` has **no `RD` attribute**. The estimates are
`tau_T`, `tau_bc`, `tau_cl`.

## Determinism

| | behaviour |
|---|---|
| upstream, unseeded | **non-deterministic** — spread 2.99e-02 across four fits in one process |
| upstream, `np.random.seed(3141)` | exactly reproducible — 0.000e+00 |
| port | no `seed` label at all; deterministic by construction |

Same process-global-seeding pattern as PQ/QTE, so a gate would have had to
seed upstream explicitly. Upstream's seed spread over 6 seeds:
`coef` sd 0.008583.

## The measured divergence

Same design, integer-only so both sides build identical rows: `n=400`,
`x1`, `x2` as before, running variable `u = (i-200)/40`, `d = 1[u>0]`,
`y = 1 + 0.5*x1 + 0.3*x2 + 0.75*d + 0.2*x1*x2` (true `tau = 0.75`).

| | port | upstream (mean of 6 seeds) |
|---|---|---|
| `coef` | 0.658475 (bw=1.0) | 0.688669, sd 0.008583 |
| `se` | **0.020965** | **0.069081** |

The coefficient alone is borderline — 0.030 apart against a 3-sigma band of
0.0257. The standard error is not borderline at all: **3.3x**.

And no bandwidth setting repairs both. The port's `se` scales as `1/bw`:

| bw | port `coef` | port `se` | |gap| vs upstream coef |
|---|---|---|---|
| 0.5 | 0.602144 | 0.042462 | 0.0865 |
| 1.0 | 0.658475 | 0.020965 | 0.0302 |
| 2.0 | 0.707157 | 0.010491 | 0.0185 |

Matching `se` requires `bw ≈ 0.3`, where the coefficient is ~0.087 away.
Matching the coefficient needs `bw ≈ 2.0`, where `se` is off by 6.6x. The
`1/bw` scaling is an analytic local-linear standard error; upstream's comes
from `rdrobust`'s estimator. **These are not the same estimator's variance.**

## Follow-up: why "swap the SE" cannot be the fix

The section above measures a 3.3x gap on a two-column design and never
re-examines it on a design built to answer the question. Two things were found.

**`sec_rdd` cannot answer it.** Its design is exact --
`y = 2 + u + 0.5*z + 2*d`, no noise -- so every residual is zero. Measured:

```
sharp_se_hc0 = 0.000000000
fuzzy_se_hc0 = nan
```

A variance formula cannot be compared where the variance is identically zero:
that design "agrees" with any formula, including a wrong one. The new section
`sec_rdd_var` uses an integer-only **noisy** design (n=800, modulo noise) and
emits both `cov_type` arms, so CPython rebuilds identical rows with nothing
transmitted.

Bandwidth 0.5, triangular kernel, same rows:

| | coef | se |
|---|---|---|
| port, homoskedastic (default) | 2.000000005 | 0.003535472 |
| port, HC0 | 2.000000005 | **0.000000000** |
| upstream, conventional | 2.148600465 | 0.092729567 |
| upstream, bias-corrected | 2.068653420 | 0.136825728 |

Port/upstream SE ratios: **0.038** conventional, **0.026** bias-corrected.

**The sign of the divergence is not stable across designs** -- 3.3x smaller on
the old design, 26-39x smaller here. So it is not a scale factor to tune; it is
design-dependent, which is what a formula difference looks like.

### Three findings, in order of how much they change the decision

**1. Upstream's estimator is BIAS-CORRECTED and the port's is not.** `rdrobust`
reports both arms and defaults to the corrected one. The true jump here is
exactly 2.0: the port recovers `2.000000005` while `rdrobust` reports
`2.148600` / `2.068653`.

So the two sides are not estimating the same functional, which is exactly why
no bandwidth repaired both. **Matching upstream is therefore not an SE change.**
It needs Calonico-Cattaneo-Titiunik local bias correction on the *point
estimate* -- a different estimator, not a different variance.

Call-shape notes, all found by running: `rdrobust(y, x, c=...)` has **no `d=`**
(a sharp design is `c` plus a derived `d`); there is **no `biascorr` flag** in
2.1.1 (`subset` is an observation subset); top-level `tau_T`/`se_T` are `None`;
`tau_bc` is a per-side **list**, so `float()` on it raises. The usable handle is
`o.Estimate`, columns `tau.us` / `tau.bc` / `se.us` / `se.rb`. It is unseeded --
measured spread 2.99e-02 over four fits in one process -- so `np.random.seed`
must be set.

**2. The port's HC0 arm returns EXACTLY 0.0 on both designs.** On `sec_rdd_var`,
where `homo_se = 0.003535472` on the *same rows with non-zero residuals*. An SE
of precisely zero is never legitimate and it is not caused by anything upstream
does. The accumulator is `sum_k w_k^2 * m_k^2 * e_k^2` (`linear.mbt:319`), so
the zero means one of `w`, `m_k`, `e_k` is identically zero on that path --
and `sandwich_se_weighted` builds `X^T X` **unweighted** where its docstring
says `X^T W X`. A separate defect with its own merit; the root cause is **not
yet diagnosed**, so it is recorded rather than guessed at.

**3. The RDD work is therefore a re-specification**, not a parity edit: bias
correction + a robust variance + the HC0 defect. That is the user's call.

## Decision: no RDD gate

A gate built on this would be permanently red, which is worse than
recording the defect — it is either a failing CI or an `--allow-inert`
mute. So RDD is recorded as a **measured divergence**, which is a real
advance over "not yet probed".

What it would take:

1. reconcile the variance estimators — the port's analytic `1/bw` against
   `rdrobust`'s — which is an estimator change, not a gate;
2. decide the bandwidth policy: the port takes a fixed `bandwidth`, upstream
   auto-selects (`bwselect='mserd'`). A gate would have to pin both, and
   "pin both" is only meaningful once they agree;
3. only then add `rdrobust` to CI.

Upstream's `coef` also has a 3-element `[different, equal, equal]` structure
matching `tau_T`, where the port exposes a scalar. Element 0 is the
comparable one; the other two are ADRF-style variants the port does not
report at all.

## Side effect worth stating

**SUPERSEDED — this section described the pre-gate state.** `rdrobust` is now a
declared CI dependency (`check.yml`, pinned `>=2,<3`), and `examples/parity` does
carry committed RDD sections (`rdd` and `rdd_var`). The text below is kept as the
record of what was true before `pyexample_rdd.py` existed.

`rdrobust` (with `plotnine` and `mizani`) was installed into the local
Python environment to take these measurements. Nothing in the repository,
CI, or the test suite depends on it, and `examples/parity` carries no RDD
section — the probe was removed, not committed. Uninstall with
`pip uninstall rdrobust plotnine mizani` if the environment should not keep
it.

Reproduce:

    python _verify\_rdd_api_1680.py        # the export trap and the signature
    python _verify\_rdd_fit_1680.py        # the data-shape traps
    python _verify\_rdd_determinism_1680.py  # seeding, and the seed spread
