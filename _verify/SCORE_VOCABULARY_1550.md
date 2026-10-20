# `score` — measured, default #4 of the port-vs-upstream defaults table

> **Re-audited 2026-10-20 against the `v0.164.9` tree. §2 and §4 described a
> state that the commit this document anchors on had already changed.**
> `8308f09` — *"score: accept upstream's spelling of the partialling-out
> score"*, released as `v0.155.0` — **is the fix §4 recommends**. This document
> was written before that commit landed and was never updated, so its §2
> findings describe a tree that no longer exists.
> Method (shipped, tracked): `_verify/_audit_r15_defaults_1650.py`.
>
> | | as written (`v0.155.0`) | now (`v0.164.9`) |
> |---|---|---|
> | `DoubleMLPLR` accepted `score` spellings | `{partialling-out, iv-type, IV-type}` | `{partialling-out, partialling out, iv-type, IV-type}` |
> | port ∩ upstream, for `DoubleMLPLR` | `{"IV-type"}` — *"one shared spelling out of two on each side"* | `{"partialling out", "IV-type"}` — **two** |
> | upstream classes that validate a `score` | 13 read (the `valid_scores` mechanism only) | **18** — 5 more validate through a different mechanism |
> | `plr.mbt` score default | `:388` / `:649` | `:417` / `:676` |
> | `did.mbt` / `lplr.mbt` score default | `:231` / `:350` | `:262` / `:354` |
>
> **What is NOT verified here.** No estimator was re-run for this re-audit.
> The §3 measurement (the PLR / PLPR control) is quoted from the original
> record and was **not** reproduced. What was re-measured is the *vocabulary* —
> what each side accepts and what each side defaults to — read from source.

**Measured, not recalled.** Two independent sources:

- **Upstream**: `_verify/_upstream_ps/doubleml-0.11.4/doubleml/plm/*.py`, read
  for every `valid_scores` list in the package (not just the estimators the
  earlier `_upstream_defaults_1540.py` enumerated — that script missed `plr.py`,
  `plpr.py`, `pliv.py`, `apos.py`, `did_multi.py` entirely).
- **Port**: `plr.mbt`, `plpr.mbt`, `lplr.mbt` require-sites and constructor
  defaults.
- **Numbers**: the three `probe_v1550*` probes (deleted after the run; their
  output is transcribed verbatim below).

> Version caveat, stated once: the installed `doubleml` is **0.11.3**, and the
> vendored source tree under `_verify/_upstream_ps/` is **0.11.4**.
> **The two have now been diffed** (2026-10-20): the score vocabulary of all
> 18 classes is **identical** in 0.11.3 and 0.11.4, and every line number in
> the table below resolves in **both**. So the readings stand for either
> version — and the vendored tree is a convenience copy only. It is **not
> tracked**, and a reader does not need it.

## 1. Upstream's actual `score` vocabulary (measured)

**18 upstream classes validate a `score`, through four different mechanisms.**
The original table below listed the 13 that use a class-level `valid_scores`
list. The other 5 validate through a local variable, an inline list, or a
method — and one of them (`irm/ssm.py`) is the reason the
`missing-at-random` spelling exists at all.

| upstream file | accepts | default | mechanism |
|---|---|---|---|
| `did/did.py:100` | `["observational", "experimental"]` | `observational` | `valid_scores` |
| `did/did_binary.py:193` | `["observational", "experimental"]` | `observational` | `valid_scores` |
| `did/did_cs.py:99` | `["observational", "experimental"]` | `observational` | `valid_scores` |
| `did/did_cs_binary.py:182` | `["observational", "experimental"]` | `observational` | `valid_scores` |
| `did/did_multi.py:211` | `["observational", "experimental"]` | `observational` | `valid_scores` |
| `irm/apo.py:111` | `["APO"]` | `APO` | `valid_scores` |
| `irm/apos.py:122` | `["APO"]` | `APO` | `valid_scores` |
| `irm/cvar.py:131` | `["CVaR"]` | `CVaR` | local `valid_score` |
| `irm/iivm.py:154` | `["LATE"]` | `LATE` | `valid_scores` |
| `irm/irm.py:148` | `["ATE", "ATTE"]` | `ATE` | `valid_scores` |
| `irm/lpq.py:140` | `["LPQ"]` | `LPQ` | local `valid_score` |
| `irm/pq.py:146` | `["PQ"]` | `PQ` | local `valid_score` |
| `irm/qte.py:133` | `["PQ", "LPQ", "CVaR"]` | `PQ` | `valid_scores` |
| `irm/ssm.py:138` | `["missing-at-random", "nonignorable"]` | `missing-at-random` | inline list |
| `plm/lplr.py:128` | `["nuisance_space", "instrument"]` | `nuisance_space` | `valid_scores` |
| `plm/pliv.py:195` | `["partialling out", "IV-type"]` | `partialling out` | method |
| `plm/plpr.py:136` | `["IV-type", "partialling out"]` | `partialling out` | `valid_scores` |
| `plm/plr.py:99` | `["IV-type", "partialling out"]` | `partialling out` | `valid_scores` |

`plm/pliv.py` accepts the second spelling **conditionally** — only when
`partialX and not partialZ` and there is exactly one instrument
(`pliv.py:196-201`).

**The five the original table missed** are `irm/cvar.py`, `irm/lpq.py`,
`irm/pq.py`, `irm/ssm.py` and `plm/pliv.py`. The first three use a local
variable named `valid_score` (singular); `irm/ssm.py` passes the list inline;
`plm/pliv.py` overrides the check with a method. A census that only looks for
the string `valid_scores =` finds none of them — which is why the original
table stopped at 13.

**My earlier hypothesis was wrong.** I expected `"partialling out"` to be a
pre-0.6 vocabulary that upstream had deleted. It has not been deleted — it is
the **live default** on `plr.py` and `plpr.py`, both in `__init__`:
`score="partialling out"`. **With a space.**

## 2. The port's vocabulary, and the divergence

| port site | default | port accepts | upstream accepts |
|---|---|---|---|
| `did.mbt:262` | `"observational"` | `{observational, experimental}` | same — **match** |
| `did_binary.mbt:367` | `"observational"` | `{observational, experimental}` | same — **match** |
| `did_cross_section.mbt:191` | `"observational"` | `{observational, experimental}` | same — **match** |
| `did_cs_binary.mbt:731` | `"observational"` | `{observational}` | `{observational, experimental}` — **narrower** |
| `lplr.mbt:354` | `"nuisance_space"` | `{nuisance_space, instrument}` | same — **match** |
| `plpr.mbt:554` | `"partialling out"` | `{partialling out, IV-type}` | same — **match** |
| **`plr.mbt:417` / `:676`** | **`"partialling-out"`** | `{partialling-out, partialling out, iv-type, IV-type}` | `{partialling out, IV-type}` |

So 5 of 6 `score` defaults match upstream. The one that does not is
`DoubleMLPLR` — and it still does not: the port's default is the **hyphen**
spelling, which upstream rejects.

> **The `plr.mbt` row changed under us.** When this table was written,
> `DoubleMLPLR` accepted three spellings: `{partialling-out, iv-type,
> IV-type}`. It now accepts **four** — `8308f09` (v0.155.0) added
> `"partialling out"`, which is exactly the fix §4 recommends. The port's
> guard is now `require(plr_is_po_score(score) || plr_is_iv_score(score))`
> (`plr.mbt:421`), with the two spellings resolved by `plr_is_po_score`
> (`plr.mbt:394-396`).

### The set arithmetic

**Per estimator**, not as one union — a union would hide that the `DID`
family and the `PLM` family have nothing to do with each other:

| estimator | port accepts | upstream accepts | ∩ |
|---|---|---|---|
| `DoubleMLDID` | `{observational, experimental}` | `{observational, experimental}` | `{observational, experimental}` — 2 |
| `DoubleMLDIDBinary` | `{observational, experimental}` | `{observational, experimental}` | 2 |
| `DoubleMLDIDCrossSection` | `{observational, experimental}` | `{observational, experimental}` | 2 |
| `DoubleMLDIDCSBinary` | `{observational}` | `{observational, experimental}` | `{observational}` — 1, **narrower** |
| `DoubleMLLPLR` | `{nuisance_space, instrument}` | `{nuisance_space, instrument}` | 2 |
| `DoubleMLPLPR` | `{partialling out, IV-type}` | `{IV-type, partialling out}` | 2 |
| `DoubleMLPLR` | `{partialling-out, partialling out, iv-type, IV-type}` | `{IV-type, partialling out}` | `{partialling out, IV-type}` — **2** |

The union over all seven port estimators is
`{observational, experimental, nuisance_space, instrument, partialling out, IV-type}`
— six spellings, but **none of them is a property of `DoubleMLPLR` alone**.

> **The original arithmetic was `port ∩ upstream = { "IV-type" }` — "one shared
> spelling out of two on each side". That was true when the port's accepted
> set was `{partialling-out, iv-type, IV-type}`, and it is false now.** The port
> accepts upstream's own spelling, so the intersection for `DoubleMLPLR` is
> **two** spellings wide.

### Both directions were broken; one of them has been fixed

**(a) The port rejected upstream's own default spelling.** Feeding
`DoubleMLPLR::fit(score="partialling out")` aborted:

```
test probe_v1550_abort_space_plr_test.mbt ("v1550abort_space_plr") failed: Error
    at @moonbitlang/core/abort.abort[@riantr/moonbit_doubleML.DoubleMLPLR]
```

> **RESOLVED in v0.155.0 (`8308f09`).** The port now accepts the space
> spelling, so this abort no longer happens. The probe quoted above was
> deleted after the run; the *behaviour* it documented is gone. See §4.

**(b) The port's default is not a value upstream accepts.**
`DoubleMLPLR::fit`'s default `"partialling-out"` (hyphen) would be rejected by
upstream `_check_score`. **Still true** — the fix was additive and changed no
default, exactly as §4 argued it would.

**(c) The two estimators in THIS package do not share a vocabulary.** Feeding
`DoubleMLPLPR::new(score="partialling-out")` — the spelling its own sibling
`DoubleMLPLR` accepts and defaults to — also aborts:

```
test probe_v1550_abort_hyphen_plpr_test.mbt ("v1550abort_hyphen_plpr") failed: Error
    at @moonbitlang/core/abort.abort[@riantr/moonbit_doubleML.DoubleMLPLPR]
```

**Still true.** `plpr.mbt:567` requires exactly
`score == "partialling out" || score == "IV-type"`.

So the package now reads: `partialling out` works on **both** PLR and PLPR;
`partialling-out` works on PLR (and is PLR's default) but aborts on PLPR; and
PLR's *default* is still a spelling upstream rejects. The asymmetry is now
one-sided — the fix removed the case where a user correcting the spelling for
upstream compatibility would break the estimator, and left in place the case
where a user matching PLR's own default breaks PLPR.

**Verdict: a real, narrow API defect — half-fixed.** The divergence is
**purely lexical**: `plr_score_elements` (`plr.mbt:347`, branch at `:356`)
selects the IV branch only on an iv-type spelling and falls through to PO for
everything else, so the space spelling computes the identical PO score. The
PLR side of this has been fixed; the **PLPR side has not** — PLPR still
rejects the hyphen spelling that its own sibling uses and defaults to.

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

- **Taken, in v0.155.0.** `DoubleMLPLR` now accepts `"partialling out"`
  alongside `"partialling-out"` — `8308f09`, *"score: accept upstream's
  spelling of the partialling-out score"*. Strictly widens the accepted set,
  changes no default, and provably moves no number (the fall-through PO branch
  already covers any non-IV string). The recommendation below was implemented
  **in the very commit this document anchors on**, which is why §2 went stale.
- **Not licensed**: flipping the default to `"partialling out"`. That would break
  every caller that passes `score="partialling-out"` explicitly, including
  `plr_iv_type_wbtest.mbt:199-201`. (It has not been flipped — the default is
  still the hyphen, `plr.mbt:417` / `:676`.)
- **Not licensed**: any claim that PLPR's `coef()` is a bug. It is measured to
  be score-invariant; it is *not* measured to be wrong, and the mechanism is
  open.
- **Still open — and now the only half of the defect that remains**:
  `DoubleMLPLPR` still rejects the hyphen spelling its own sibling defaults to
  (`plpr.mbt:567`). Widening PLPR to accept `"partialling-out"` is the same
  zero-risk additive change PLR already received — but it is a behaviour
  change, and it is **not** done.
- **Unrelated but recorded**: `did_cs_binary.mbt:756` requires
  `score == "observational"` while upstream's `did_cs_binary.py:182` allows
  `experimental` too. Narrower, not wrong; left alone.