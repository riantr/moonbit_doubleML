# `score` — measured, default #4 of the port-vs-upstream defaults table

**Measured, not recalled.** Two independent sources:

- **Upstream**: `_verify/_upstream_ps/doubleml-0.11.4/doubleml/plm/*.py`, read
  for every `valid_scores` list in the package (not just the estimators the
  earlier `_upstream_defaults_1540.py` enumerated — that script missed `plr.py`,
  `plpr.py`, `pliv.py`, `apos.py`, `did_multi.py` entirely).
- **Port**: `plr.mbt`, `plpr.mbt`, `lplr.mbt` require-sites and constructor
  defaults.
- **Numbers**: the three `probe_v1550*` probes (deleted after the run; their
  output is transcribed verbatim below).

> Version caveat, stated once: the installed `doubleml` is **0.11.3**, but the
> vendored source tree under `_verify/_upstream_ps/` is **0.11.4**. The
> `valid_scores` readings below come from the 0.11.4 tree. The two were not
> diffed, so treat the vocabularies as 0.11.4.

## 1. Upstream's actual `score` vocabulary (measured)

| upstream file | `valid_scores` |
|---|---|
| `did.py:100` | `["observational", "experimental"]` |
| `did_binary.py:193` | `["observational", "experimental"]` |
| `did_cs.py:99` | `["observational", "experimental"]` |
| `did_cs_binary.py:182` | `["observational", "experimental"]` |
| `did_multi.py:211` | `["observational", "experimental"]` |
| `apo.py:111` | `["APO"]` |
| `apos.py:122` | `["APO"]` |
| `iivm.py:154` | `["LATE"]` |
| `irm.py:148` | `["ATE", "ATTE"]` |
| `qte.py:133` | `["PQ", "LPQ", "CVaR"]` |
| `lplr.py:128` | `["nuisance_space", "instrument"]` |
| `plr.py:99` | `["IV-type", "partialling out"]` |
| `plpr.py:136` | `["IV-type", "partialling out"]` |

**My earlier hypothesis was wrong.** I expected `"partialling out"` to be a
pre-0.6 vocabulary that upstream had deleted. It has not been deleted — it is
the **live default** on `plr.py` and `plpr.py`, both in `__init__`:
`score="partialling out"`. **With a space.**

## 2. The port's vocabulary, and the divergence

| port site | default | port accepts | upstream accepts |
|---|---|---|---|
| `did.mbt:231` | `"observational"` | `{observational, experimental}` | same — **match** |
| `did_binary.mbt:367` | `"observational"` | `{observational, experimental}` | same — **match** |
| `did_cross_section.mbt:191` | `"observational"` | `{observational, experimental}` | same — **match** |
| `did_cs_binary.mbt:731` | `"observational"` | `{observational}` | `{observational, experimental}` — **narrower** |
| `lplr.mbt:350` | `"nuisance_space"` | `{nuisance_space, instrument}` | same — **match** |
| `plpr.mbt:554` | `"partialling out"` | `{partialling out, IV-type}` | same — **match** |
| **`plr.mbt:388` / `:649`** | **`"partialling-out"`** | `{partialling-out, iv-type, IV-type}` | `{partialling out, IV-type}` |

So 5 of 6 `score` defaults match upstream. The one that does not is
`DoubleMLPLR`.

### The set arithmetic

```
port accepted  ∩  upstream accepted  =  { "IV-type" }
```

**One shared spelling out of two on each side.**

### Both directions are broken, and both are measured

**(a) The port rejects upstream's own default spelling.** Feeding
`DoubleMLPLR::fit(score="partialling out")` aborts:

```
test probe_v1550_abort_space_plr_test.mbt ("v1550abort_space_plr") failed: Error
    at @moonbitlang/core/abort.abort[@riantr/moonbit_doubleML.DoubleMLPLR]
```

**(b) The port's default is not a value upstream accepts.**
`DoubleMLPLR::fit`'s default `"partialling-out"` (hyphen) would be rejected by
upstream `_check_score`.

**(c) The two estimators in THIS package do not share a vocabulary.** Feeding
`DoubleMLPLPR::new(score="partialling-out")` — the spelling its own sibling
`DoubleMLPLR` accepts and defaults to — also aborts:

```
test probe_v1550_abort_hyphen_plpr_test.mbt ("v1550abort_hyphen_plpr") failed: Error
    at @moonbitlang/core/abort.abort[@riantr/moonbit_doubleML.DoubleMLPLPR]
```

So within one package, `partialling out` works on PLPR and aborts on PLR, while
`partialling-out` works on PLR and aborts on PLPR. A user who corrects the
spelling for one estimator breaks the other.

**Verdict: a real, narrow API defect.** Not a numerical one — `plr_score_elements`
(`plr.mbt:356`) branches on `score == "iv-type" || score == "IV-type"` and falls
through to PO for everything else, so the divergence is **purely lexical**: had
the space spelling been accepted it would have taken the identical PO branch.
That makes the fix zero-risk and strictly additive — accept both spellings,
change no default, move no number.

## 3. Is `score` live? Measured, with a control that first failed

`DoubleMLPLR`, `build via v1550_plr_dgp(300, 42)` (a byte-for-byte copy of the
file-private `plr_iv_test_dgp`, `plr_iv_type_wbtest.mbt:41-65`), `n_folds=4`:

```
PLR  default        coef=1.4445411463639795   se=0.045208884326958514
PLR  partialling-out coef=1.4445411463639795  se=0.045208884326958514
PLR  IV-type        coef=1.4458428687532077   se=0.09586484178844529
  |default - hyphen|   coef=0                  se=0
  |IV-type - default|  coef=0.0013017223892282104   se=0.050655957461486774
```

**Control PASSED.** The coefficient and the SE both move under `IV-type`, so
`score` is genuinely load-bearing on `DoubleMLPLR`, and the default is
bit-identical to its own explicit spelling.

`DoubleMLPLPR`, `build_panel_dgp(60, 4, 1.0, 3141)`:

```
PLPR default        coef=1.0291375166089582   se=0.02001453916863923
PLPR IV-type        coef=1.0291375166089578   se=0.022156879285840595
  |IV-type - default|  coef=4.440892098500626e-16
```

**Control FAILED.** I declared `|coef gap| > 1e-9`; it is `4.44e-16`. Per the
package's own rule — *correct the declaration when measurement refutes it* — the
declaration was wrong, not the measurement.

### Is PLPR's coefficient invariance a code fact or a fixture accident?

Both were live hypotheses, so the sweep separates them. Eight seeds:

| seed | `|coef gap|` | `|se gap|` |
|---|---|---|
| 3141 | 4.44e-16 | 2.1423e-3 |
| 7 | 4.44e-16 | 1.1818e-3 |
| 42 | 3.33e-16 | 7.0312e-4 |
| 99 | 2.22e-16 | 1.9690e-3 |
| 123 | **0** | 4.6825e-4 |
| 2024 | 4.44e-16 | 2.3592e-4 |
| 555 | 1.11e-16 | 1.7256e-3 |
| 777 | **0** | 4.9913e-5 |

```
max |coef gap| = 4.440892098500626e-16 (seed 3141)
max |se gap|   = 0.002142340117201366 (seed 3141)
```

**Fixture noise is ruled out.** Under "accident", the gap would vary by orders
of magnitude across seeds. Instead the coefficient gap never exceeds machine
epsilon and is **exactly zero on two seeds**, while the SE gap is nonzero on
**all eight**. Eight-for-eight at ≤1 ulp is structural identity, not luck.

**⇒ `DoubleMLPLPR`'s `score` moves `se()` and has never moved `coef()`.**
That is the same defect class the package already fixed once for LPLR
(`lplr.mbt:24-27`: *"v0.105.0: these two used to be inert. `score` was validated
and stored but never read"*) — except here it is **half**-inert.

### MECHANISM: STILL OPEN, but now narrowed to one link

Re-investigated after the instrument work. Two candidate explanations are
**eliminated by reading**, not by inference:

1. ~~"The coefficient is computed from a psi-independent quantity."~~ **No.**
   `plpr.mbt:1106,1134` → `aggregate_coef_se(coefs, ses)`; `coefs[r] = theta_r`
   (`:1086,1103`) from `cluster_causal_param_and_se`; and that function
   (`kfold.mbt:649`) calls `est_coef_cluster(psi_a, psi_b, ...)`. The
   coefficient is a function of **both** psi arrays.

2. ~~"`est_coef_cluster` might collapse the two arrays."~~ **No.**
   `plpr.mbt:196-224` is exactly the fold-weighted ratio

   ```
   theta = - ( sum_k w_k * sum_{i in k} psi_b )
           / ( sum_k w_k * sum_{i in k} psi_a ),      w_k = 1/|I_k|
   ```

   Nothing in it treats the branches specially.

3. ~~"`l_pred` is fit on `y` in both branches, so the two `psi_b` are the
   same arrays."~~ **Already ruled out** — `:997` fits on `tf.y`, while the
   IV-type branch uses `g_pred` fit on `y - theta_init*d` (`:1045-1051`). The
   arrays genuinely differ.

So the chain is now fully traced: **`score` selects genuinely different
`psi_a`/`psi_b`, those feed a plain ratio, and the ratio comes out equal to
1 ulp on 8/8 seeds.**

The one link that could explain it, and the only one left:

> **`g_pred` and `l_pred` must be bringing the ratio back to the same value.**
> Invariance to 4.44e-16 is an *identity*, not a small difference, so whatever
> relates `psi_b = v(y - g)` to `psi_b = v(y - l)` and `psi_a = -v d` to
> `psi_a = -v²` must hold exactly on this fixture. Note `plpr.mbt:1040-1044`
> computes `theta_init` from the **PO** formula (`-v²`, `v·u`) inside the
> IV-type branch — so `g_pred`'s *starting value* is branch-independent by
> construction, which is a plausible route to that identity.

**This is a hypothesis about the last link, not a measurement.** It has now
been tested — see below.

### THE MECHANISM: settled by stress test

`build_panel_dgp` (`plpr_test.mbt:12-18`) makes `g` and `m` **linear in X**:

```
Y_it = theta0 * D_it + g(X_it) + alpha_i + zeta_it
D_it = m(X_it) + 0.5 * alpha_i / sd_alpha + V_it
```

So a linear outcome fit can recover `g` exactly, `m_hat ~ d`, and the PO and
IV-type ratios become **the same algebraic quantity**. That predicts the
invariance is an identity of this DGP — and that breaking the collinearity
would break it.

**Stress test**: `alpha_scale` from `1e-9` to `20` (four orders of magnitude),
4 approaches × 3 seeds = **36 cells**.

| approach | cells not invariant | max \|Δcoef\| |
|---|---|---|
| `fd_exact` | 0/12 | **0** |
| `cre_general` | 0/12 | **0** |
| `wg_approx` | 0/12 | **0** |
| **`cre_normal`** | **12/12** | **3.74e-11** |

**Result: the invariance survived the stress test.** Driving the unit fixed
effect from ~0 to 20 — which breaks exactly the collinearity the identity
rests on — left `fd_exact`, `cre_general` and `wg_approx` *exactly* invariant
(bit-for-bit) on every seed. So **the 8/8 invariance is not a `build_panel_dgp`
artefact**; it is structural.

**`cre_normal` is the exception, and it is explicable.** It augments `ml_m`'s
training inputs with a per-unit treatment mean
(`plpr.mbt:998-1009`): `ml_m` gets `[X, d_mean]` instead of `X`. That changes
the nuisance model's input set, so `g_pred` and `l_pred` stop being *exactly*
recoverable, and the ratio loses its bit-exactness.

But look at the magnitude: `3.74e-11` is **five orders of magnitude above
machine epsilon** and still numerically meaningless as a coefficient
difference. And its SE is *invariant across all four `alpha_scale` values* to
12+ digits (`0.0022959651525...`) while its coefficient varies — so even
`cre_normal` is convergent, just not bit-identical.

### Verdict

> `DoubleMLPLPR::coef()` is **structurally invariant** to `score` for the
> `fd_exact`, `cre_general` and `wg_approx` approaches — bit-for-bit across a
> 4-order-of-magnitude stress on the fixed-effect strength. `cre_normal`
> deviates at the `1e-11` level because it changes `ml_m`'s input set.

So this is **not** the defect class I originally suspected. It is an algebraic
identity of the estimator under linear `g`/`m`, plus a numerically negligible
exception where the nuisance inputs differ. **No code change is warranted, and
none is proposed.** The earlier "half-inert `score`, same class as LPLR
pre-v0.105.0" framing in this document is **retracted** — that comparison was
wrong, and it was wrong for the same reason several other claims in this audit
were wrong: asserting a defect from a measurement without separating "structural"
from "coincidental on this fixture".

## Not established

- Whether the identity survives a **nonlinear** `g(X)` or a nonlinear `m(X)`,
  which `build_panel_dgp` cannot produce. That is the one remaining way the
  invariance could dissolve, and it is the genuinely open question.
- Whether upstream's `plpr.py` shows the same invariance. **No Python oracle
  was ever run for this default.**

## 4. What this does and does not license

- **Safe and additive**: let `DoubleMLPLR` accept `"partialling out"` alongside
  `"partialling-out"`. Strictly widens the accepted set, changes no default, and
  provably moves no number (the fall-through PO branch already covers any
  non-IV string). **Not done here** — it is a behaviour change and the release
  is already sitting unauthorized.
- **Not licensed**: flipping the default to `"partialling out"`. That would break
  every caller that passes `score="partialling-out"` explicitly, including
  `plr_iv_type_wbtest.mbt:199-201`.
- **Not licensed**: any claim that PLPR's `coef()` is a bug. It is measured to
  be score-invariant; it is *not* measured to be wrong, and the mechanism is
  open.
- **Unrelated but recorded**: `did_cs_binary.mbt:756` requires
  `score == "observational"` while upstream's `did_cs_binary.py:182` allows
  `experimental` too. Narrower, not wrong; left alone.