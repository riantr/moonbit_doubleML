## [0.131.0] -- the shared `nu2 = mean(psi_a^2)` was upstream's FALLBACK, not its formula

### Scope, established before changing anything

Upstream sets `_sensitivity_implemented = True` for only **seven** classes --
`did`, `did_binary`, `did_cs`, `did_cs_binary`, `apo`, `irm`, `plr`. LPQ's
`_sensitivity_element_est` is a bare `pass` (and `lpq.py` never sets the flag),
and `ssm` / `lplr` / `plpr` explicitly set it to `False`. So:

- for those **7**, the port's sensitivity must match upstream, and does not;
- for the port's other ~9 sensitivity entry points (PQ, QTE, IIVM, PLIV, SSM,
  LPLR, PLPR, RDD, BLP/PolicyTree, CVaR, DID-cross-section) there is **no
  upstream implementation to be faithful to**. `single_psi_sensitivity` is the
  port's own construction, not a divergence.

That is what turned a scary-looking "13 estimators share this helper" into a
seven-estimator job -- and it is why this release migrates one estimator rather
than all of them.

### The divergence

Upstream's primary `nu2` (`irm.py:422`, `did_cs_binary.py:932`) is

    nu2_score_element = 2 * m_alpha - rr^2
    nu2               = mean(nu2_score_element)

where `rr` is the **Riesz representer**. The shared `irm_style_sensitivity`
helper used `mean(psi_a^2)`, and `psi_a` is a *different object*: upstream
deliberately separates them, `_score_elements` returning `psi_a`/`psi_b` and
`_sensitivity_element_est` returning `riesz_rep`.

Worse, `mean(rr^2)` is not simply "a different formula" -- it is upstream's
**fallback**, used only when the primary comes out non-positive
(`double_ml.py:1634-1641`):

```python
if np.any(nu2 <= 0):
    msg = "The estimated nu2 for {d} is not positive. Re-estimation based on riesz representer (non-orthogonal)."
    psi_nu2 = np.power(riesz_rep, 2)
    nu2 = np.mean(psi_nu2, ...)
```

So the port was applying the degenerate-case formula permanently, and to the
wrong variable.

### Measured

    nu2       3.30275229357797    -> 26.718919562055802      (8.1x)
    max_bias  0.0805875050863701  -> 0.22921295256141525
    rv        12.296893946098622  -> 4.323385709026423
    sigma2    0.0019663436427471525 -> unchanged (v0.130.0's fix, untouched)

### Why `nu2` is the whole story

While measuring, `psi_sigma2` and `psi_nu2` turned out to be **dead** in this
path: they feed only `psi_max_bias`, which every caller discards
(`let (max_bias_arr, _) = ...`). The returned `max_bias` is
`sqrt(sigma2 * nu2)` and `rv = |theta| / sqrt(sigma2 * nu2)`, neither of which
depends on them. So the entire reported result is a function of `sigma2` and
`nu2` alone -- the same "computed and handed to a callee that never accepts
it" shape found in CVaR's sensitivity path in v0.126.0.

The bias expression itself **is** faithful: upstream's
`utils/_sensitivity.py` is `max_bias = sqrt(sigma2*nu2)` and
`psi_max_bias = (sigma2*psi_nu2 + nu2*psi_sigma2) / (2*max_bias)`, which is what
`compute_sensitivity_bias` already computes. So getting `nu2` right closes the
whole gap rather than half of it.

### Verification, and two things it caught

`_verify/_probe_nu2.py` and `_verify/_oracle_1310.py`:

1. **Transcription.** Recomputing upstream's
   `in_sample_normalization = false` branch (`:896-902`) from the port's own
   `d`, `t` and `m_hat` reproduces the MoonBit's `nu2` **bit for bit**:
   `26.718919562055802`.
2. **Real package.** The vendored upstream 0.11.4 fitted on the same fixture
   with the **same flag** reports `nu2 = 23.179137007778895` and
   `sigma2 = 0.002063990297219876`. The port is now ~15% away; before the fix
   it was **7x** away. (The residual gap is the `ml_m` learner: upstream
   *requires* a classifier with `predict_proba`, the port fits OLS.)

Two things went wrong first and are worth recording:

- The first verification reproduced **26.869**, not 26.719, and looked like a
  transcription bug. It was not: `DoubleMLDIDCSBinary::new` defaults
  `in_sample_normalization = false` (`did_cs_binary.mbt:712`), so my check had
  hard-coded the *other* branch. Caught only because the numbers disagreed --
  a 0.5% gap is not rounding, so it was chased rather than accepted.
- The first version of the new gate asserted
  `r.max_bias == sqrt(sigma2*nu2)` and failed. The helper broadcasts the scalar
  to a length-`n` array and averages it, and summing `n` copies back is not
  bit-exact in IEEE754; MEASURED relative difference 6e-15. The gate now
  asserts a 1e-12 relative tolerance and says why.

### What changed in code

Two new public helpers in `sensitivity.mbt`, parameterised by the
per-observation `nu2` score element and the Riesz representer:

    irm_style_sensitivity_from_elements(...)
    irm_style_sensitivity_cluster_from_elements(...)

`irm_style_sensitivity` is now the `nu2_score_element = psi_a^2` special case of
the first, rather than a second copy of the C&H core. The refactor was
verified **bit-identical for all 13 existing callers** -- the 1005-test suite
passes unchanged apart from the two `did_cs_binary` pins this release
deliberately moves.

`DoubleMLDIDCSBinary` gained `cs_bin_sensitivity_nu2_elements`, transcribed
from `_sensitivity_element_est`, computing both branches of
`in_sample_normalization`. The score path (`cs_bin_score_obs`) was NOT touched.

### A gate that was asserting the wrong thing

`v130_cs_binary_sensitivity_cluster_shares_the_residual_vector` asserted
`cluster.nu2 == iid.nu2`. That held only because both sides computed the same
quantity. The cluster helper's own convention is "cluster sums of the
per-observation scalar, squared", which for the residuals coincides with the
IID definition but for `nu2` legitimately does not: the per-observation scalar
*is* already the nu2 score element, so singleton clusters give `mean(elem^2)`
against IID's `mean(elem)`. The gate now keeps the real invariant
(`cluster.sigma2 == iid.sigma2`, which is what proves the two entry points
share one residual builder) and pins the cluster values explicitly.

### New gates

- `v131_cs_binary_nu2_is_upstreams_score_element_not_mean_psi_a_squared` --
  recomputes `m_alpha` and `rr` from the public accessors, asserts the reported
  `nu2` is exactly their mean, and asserts it is **not** `mean(psi_a^2)` nor
  `mean(elem^2)`. Also pins `max_bias = sqrt(sigma2*nu2)` and
  `rv = |coef| / sqrt(sigma2*nu2)` to a 1e-12 relative tolerance.

### Deliberately NOT changed

**`in_sample_normalization` default.** Upstream defaults it to `True`
(`did_cs_binary.py:118`); this port defaults it to `false`
(`did_cs_binary.mbt:712`). It moves `coef` and `se`, not just sensitivity, so
it is a behavioural release of its own with its own measurement pass. Recorded
here because it dominated this round's verification -- upstream's own `nu2`
moves between the two branches (23.18 vs 25.38).

**The other six upstream-faithful estimators** -- `did`, `did_binary`,
`did_cs`, `apo`, `irm`, `plr` -- still use `mean(psi_a^2)` via the shared
helper. Each needs its own `m_alpha` / `rr` plumbing (upstream's
`_sensitivity_element_est` differs per class: IRM uses `_get_weights` and
`m_hat_adj`, DID-CS uses the `(d,t)` cell weights) and its own measurement
pass. `irm_style_sensitivity` keeps its current behaviour for them, so nothing
moves until each is migrated deliberately.

### Verification

    native 1005/1005    wasm 1005/1005    js 1005/1005    wasm-gc 1011/1011
    (v0.130.0 was 1004/1004/1004 and 1010 -- +1 test)
    moon check --deny-warn clean on all four targets
    mutation harness: 5 KILLED / 3 SURVIVED / 0 inconclusive, residue clean