# ROW P — the two "upstream parity" comments, verified

Both were on the outstanding list as *possibly false*. One is accurate. One is
false in a specific, shippable way. Both were checked by reading upstream and
running the estimator, not by reading the port's own comments.

---

## 1. `apo.mbt:52-60` — **VERIFIED ACCURATE**

The comment claims APO's `ml_m` is fitted against the `treated` indicator
vector, not raw `d`, and that *"Upstream agrees: `regressor=False,
classifier=True` plus `predict_proba`."*

Read from the installed upstream (`doubleml/irm/apo.py`):

| port claim | upstream | verdict |
|---|---|---|
| `ml_m` requires a classifier, not a regressor | `apo.py:120` — `self._check_learner(ml_m, "ml_m", regressor=False, classifier=True)` | **exact match** |
| `ml_m` predicts with `predict_proba` | `apo.py:131` — `self._predict_method = {"ml_g": "predict", "ml_m": "predict_proba"}` | **exact match** |
| the target is `treated`, not raw `d` | `apo.py:107` — `self._treated = self._dml_data.d == self._treatment_level` | **exact match** |

The comment is right on all three counts. No change.

Useful contrast it documents: upstream's `ml_g` accepts
`regressor=True, classifier=True` (`apo.py:119`) and only switches to
`predict_proba` when the outcome is binary (`apo.py:123-124`), whereas `ml_m` is
classifier-only. The port's split defaults mirror that.

---

## 2. `cvar.mbt:354-357` — **the premise is right, the conclusion is false**

The comment says:

> The constant `psi_a = -1` and the residual `y - g_hat` let us reuse the shared
> `irm_style_sensitivity` helper … `cf_y` / `cf_d` are the confounding-strength
> upper bounds (defaults 0.05) and are **passed through to the result for
> upstream parity**.

### The premise holds — and is now measured

`psi_a` constant ⟹ the treatment nuisance `nu2` is exactly 1. Measured:

```
CVAR coef=1.7417212460064047  se=0.019633851063058223
nu2 = 1   (exactly, at every cf)
```

So "reuse `irm_style_sensitivity` because `psi_a` is constant" is sound.

### The conclusion does not

`cf_y` / `cf_d` **round-trip and reach no computation.** CVAR at cf ∈
{0.00, 0.03, 0.05, 0.10, 0.20}:

```
cf=0     rv=1.8627402166027296 max_bias=0.9350317507950578 sigma2=0.8742843749948602 nu2=1  stored_cf_y=0
cf=0.03  rv=1.8627402166027296 max_bias=0.9350317507950578 sigma2=0.8742843749948602 nu2=1  stored_cf_y=0.03
cf=0.05  rv=1.8627402166027296 max_bias=0.9350317507950578 sigma2=0.8742843749948602 nu2=1  stored_cf_y=0.05
cf=0.1   rv=1.8627402166027296 max_bias=0.9350317507950578 sigma2=0.8742843749948602 nu2=1  stored_cf_y=0.1
cf=0.2   rv=1.8627402166027296 max_bias=0.9350317507950578 sigma2=0.8742843749948602 nu2=1  stored_cf_y=0.2

delta vs cf=0.0 :  rv=0  max_bias=0  sigma2=0  nu2=0     (all five arms)
```

Only the **stored** fields move. Every computed field is bit-identical.

### The structural reason, which is sharper than the measurement

The port's `SensitivityResult` (`sensitivity.mbt:534`) is:

```
rv, sigma2, nu2, cf_y, cf_d, max_bias
```

Upstream's `sensitivity_params`, read by introspection:

```
theta{lower,upper}, se{lower,upper}, ci{lower,upper}, rv, rva, input
```

`cf` was measured to control the **theta band width** upstream (±6.88 SE). The
port's result type has **no band, no CI, and no `rva`** — so it *structurally
cannot carry the quantity `cf` is supposed to move*.

⇒ "passed through to the result for upstream parity" describes plumbing, and
presents it as fidelity. The value survives the round-trip and changes nothing.
This is the same defect class as row K (inert parameter), dressed as a parity
claim.

### Also in that comment: the default

"(defaults 0.05)" is **true of the port and wrong about upstream**, which is
0.03 at all 17 estimators — see ROW O. The comment documents the port's value
without marking it as a divergence.

---

## 3. `iivm.mbt:185` — the `ml_r` default is a regressor; upstream forbids it

Verified against installed upstream (`doubleml/irm/iivm.py`):

| | |
|---|---|
| `iivm.py:164` | `self._check_learner(ml_r, "ml_r", regressor=False, classifier=True)` |
| `iivm.py:43-45` | docstring: *"ml_r : classifier implementing `fit()` and `predict_proba()` … for `r_0(Z,X) = E[D\|X,Z]`"* |
| `iivm.mbt:185` | `ml_r~ : LearnerDispatch = LearnerDispatch::linear_regression()` |

So the port ships exactly the learner class upstream rejects, and nothing in the
file recorded it.

### Measured, on `make_iivm_data(n, 20, theta=1.0, seed)`, `EXAMINED=8`

`LearnerDispatch::linear_regression().is_classifier()` = **false**;
the logistic arm = **true**.

| n | seed | coef (regressor) | coef (classifier) | \|Δ\| | Δ/SE |
|---|---|---|---|---|---|
| 500 | 11 | 0.8421 | 0.7754 | 0.0667 | *(degenerate — see below)* |
| 500 | 22 | 1.0593 | 0.9206 | 0.1387 | 0.127 |
| 500 | 33 | −1.0802 | −1.0654 | 0.0148 | 0.006 |
| 500 | 44 | 2.1676 | 3.6399 | 1.4722 | 1.231 |
| 1000 | 11 | 1.9307 | 2.4638 | 0.5332 | 0.339 |
| 1000 | 22 | −0.0695 | −0.0947 | 0.0253 | 0.036 |
| 1000 | 33 | −1.2360 | −1.5257 | 0.2897 | 0.213 |
| 1000 | 44 | −3.4658 | −1.9460 | 1.5199 | 0.421 |

**Up to 1.23 SE on well-behaved fits.** The learner choice is not cosmetic.

### The degenerate row, and why it is not the headline

`n=500, seed=11` prints `Δ/SE = 371.78`. That number is an **artifact**:
`se_reg = 1.79e-4` and `se_cls = 1.56e-4` — both learners produce a near-zero
SE, i.e. the fit's variance estimate collapsed under *either* learner. Quoting
371 SE as the cost of the learner choice would have been exactly the
"unseeded arm" mistake in a new costume: a big confident number produced by a
degenerate denominator.

⇒ Excluded from the effect size and reported separately. It does carry its own
finding: **this port's `DoubleMLIIVM` can return a near-zero SE on
`make_iivm_data`** at n=500/seed=11, under either learner. That is worth a
tripwire and is flagged, not fixed.

### Neither arm is better

`mean |error|` = 1.521 (regressor) vs 1.630 (classifier) over 8 fits. On this
sample the port's default is marginally *better*, so there is no measured basis
for calling it a bug.

### Why the default is defensible anyway

`ml_r` models `E[D | X, Z]` and `D` is binary, so least squares estimates the
same conditional mean a logistic fit would. The difference is the **constraint**:
OLS is free to predict outside `[0,1]`, logistic is not, and those predictions
feed a selection score.

**Verdict: contract divergence, not a defect.** Aligning with upstream means
changing the default — a behaviour change on 14 estimators' worth of surface,
so it is the user's call. The comment now records the divergence and the
measurement.

---

## Recommendation

Both are documentation-only fixes, in the same shape as the v0.156.0 comments:

- `apo.mbt:52-60` — **no change.** It is correct.
- `cvar.mbt:354-357` — rewrite the last clause. Something like: *"`cf_y`/`cf_d`
  are stored so a caller can read back what was requested; they reach no
  computation, and upstream uses them to set a band this result type does not
  carry. The port's default is 0.05 where upstream's is 0.03."*

No behaviour changes; no test-count impact.

## Artifacts

- `_verify/_cvar_cf_1570.txt` — the cf sweep on CVAR
- `_verify/_probe_cvar_cf_1570_test.mbt.txt` — the probe (removed from the package)
- `_cf_default_1570.txt` — ROW O, the 0.05 vs 0.03 default