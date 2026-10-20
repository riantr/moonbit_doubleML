# Upstream provenance for all 22 estimators

> **Re-audited 2026-10-20 against the `v0.164.10` tree.** This record was
> **never tracked** before this commit: it existed only as a local file, so
> the repository's upstream authority map was not something a reader could
> obtain at all. That is now fixed -- the record, and the upstream sources it
> quotes, are tracked.
>
> Written in the v0.103.0 round, against the `doubleml-0.11.4` sdist. The
> readings are re-anchored to the **installed** `doubleml` **0.11.3** package
> (`site-packages/doubleml`), which is what a user actually installs. The
> score vocabularies of all 18 upstream classes are identical in the two, and
> every line this record cites resolves in both, so the installed package is
> the anchor and the sdist is a convenience copy.
>
> **What has changed since**, measured 2026-10-20:
>
> | | as written (v0.103.0) | now |
> |---|---|---|
> | upstream module -> class map | 21 upstream classes, 22 port estimators | **unchanged** -- all 21 modules and classes verified in the installed package, none moved |
> | `DoubleMLDIDCS` -> upstream | table said upstream `DoubleMLDIDCS`; prose said upstream `DoubleMLDID` | **both withdrawn.** Upstream's `DoubleMLDIDCS` is the *repeated cross-sections* estimator, which is this port's `DoubleMLDIDCrossSection`. The port's `DoubleMLDIDCS` is a **port-side variant** of upstream's `DoubleMLDIDMulti` and has no 1:1 upstream class |
> | "our `DoubleMLDIDCS` is upstream's `DoubleMLDID`" | asserted | **false.** Upstream's `DoubleMLDID` is the *two-time-period panel* DiD, and it is this port's `DoubleMLDID` |
> | grouping | (not stated) | **19 name-identical + 2 renamed + 1 with no 1:1 upstream class** |
> | `did/did_cs.py` pointer | `L16` | **still correct** -- `class DoubleMLDIDCS(LinearScoreMixin, DoubleML):` is at line 16 in both 0.11.3 and the 0.11.4 sdist |
> | `LinearScoreMixin` snippet | quoted from `double_ml_score_mixins.py` | **still correct** -- `_compute_score` at :35, `_compute_score_deriv` at :39, `_est_coef` at :42 |
> | `var_did` snippet | quoted from `did/tests/_utils_did_manual.py` | **still correct** -- the file is in the installed package at `doubleml/did/tests/` |
> | "Files kept in this directory" | 6 files promised | **5 of 6 were untracked**; 4 are now tracked, 1 is **stale** (upstream replaced it), 1 (the sdist) is **not tracked** and is not promised |
>
> **What is NOT verified here.** No estimator was re-run and no estimate was
> recomputed: this record is a **map**, and the map is derived from upstream
> *source* (class docstrings, constructor signatures, which data class each
> class consumes) and from the port's own headers. The **numbers** the
> estimators produce are not touched by this record. The grouping is derived
> by `_verify/_audit_r16_provenance_1650.py` and pinned by
> `_verify/_verify_round16_provenance_1650.py`.

Source of truth: the **installed** `doubleml` package, cross-checked against
the published sdist `doubleml-0.11.4.tar.gz` (PyPI).

Retrieved: `https://pypi.org/pypi/doubleml/json` -> `urls[sdist]`.

## Module -> class map

The correspondence is **one-to-one**: an upstream class may correspond to at
most one port estimator, and an upstream class that has been claimed once is
not claimed again by name coincidence. `DoubleMLDIDCS` is the one port
estimator left without a partner, and the reason is given below the table.

| upstream module | class | our estimator |
|---|---|---|
| `plm/plr.py` | `DoubleMLPLR` | `DoubleMLPLR` |
| `plm/pliv.py` | `DoubleMLPLIV` | `DoubleMLPLIV` |
| `plm/lplr.py` | `DoubleMLLPLR` | `DoubleMLLPLR` |
| `plm/plpr.py` | `DoubleMLPLPR` | `DoubleMLPLPR` |
| `irm/irm.py` | `DoubleMLIRM` | `DoubleMLIRM` |
| `irm/iivm.py` | `DoubleMLIIVM` | `DoubleMLIIVM` |
| `irm/apo.py` | `DoubleMLAPO` | `DoubleMLAPO` |
| `irm/apos.py` | `DoubleMLAPOS` | `DoubleMLAPOS` |
| `irm/pq.py` | `DoubleMLPQ` | `DoubleMLPQ` |
| `irm/qte.py` | `DoubleMLQTE` | `DoubleMLQTE` |
| `irm/lpq.py` | `DoubleMLLPQ` | `DoubleMLLPQ` |
| `irm/cvar.py` | `DoubleMLCVAR` | `DoubleMLCVAR` |
| `irm/ssm.py` | `DoubleMLSSM` | `DoubleMLSSM` |
| `did/did.py` | `DoubleMLDID` | `DoubleMLDID` |
| `did/did_binary.py` | `DoubleMLDIDBinary` | `DoubleMLDIDBinary` |
| `did/did_cs.py` | `DoubleMLDIDCS` | `DoubleMLDIDCrossSection` |
| `did/did_cs_binary.py` | `DoubleMLDIDCSBinary` | `DoubleMLDIDCSBinary` |
| `did/did_multi.py` | `DoubleMLDIDMulti` | `DoubleMLDIDMulti` |
| `rdd/rdd.py` | **`RDFlex`** (renamed) | `DoubleMLRDD` |
| `utils/blp.py` | `DoubleMLBLP` | `DoubleMLBLP` |
| `utils/policytree.py` | `DoubleMLPolicyTree` | `DoubleMLPolicyTree` |
| `none` | `none` | `DoubleMLDIDCS` |

`DoubleMLDIDBinary` and `DoubleMLDIDCSBinary` are NOT in upstream's
`__all__`, but both are importable classes in their modules. Absence
from `__all__` is not absence from the package.

## Why `DoubleMLDIDCS` has no 1:1 upstream class

This is the part the old record got wrong in two different ways, and the
part a **name scan** cannot see. Scanning for the *name* `DoubleMLDIDCS`
finds upstream's class of that name -- which is a **different design**. The
three facts that settle it, all read from source:

1. **Upstream's `DoubleMLDIDCS` is the repeated cross-sections estimator.**
   Its docstring reads "Double machine learning for difference-in-difference
   with **repeated cross-sections**" and it consumes `DoubleMLDIDData`. Its
   constructor has **no** `control_group` and **no** `anticipation_periods`.
   This port's `DoubleMLDIDCrossSection` is the match: its header says the
   score function "matches the upstream `doubleml.DoubleMLDIDCS._score_elements`
   algorithm", and it carries the same `score` / `in_sample_normalization` /
   `propensity_clip` surface and none of the two DID-control parameters.

2. **Upstream's `DoubleMLDIDMulti` is the multi-period class**, and it is
   the **only** upstream DID class with a `gt_combinations` parameter
   (`did/did_multi.py:65-68`), whose keywords are `'standard'`, `'all'` and
   `'universal'` (`did/utils/_did_utils.py:127`). It labels its results
   `ATT(g, t_pre, t_eval)` (`did/did_multi.py:197`). This port's
   `DoubleMLDIDMulti` is the match: it is the only port DID estimator with
   `gt_combinations`, and it uses **upstream's own keyword vocabulary**.

3. **This port's `DoubleMLDIDCS` has no `gt_combinations`.** It derives its
   `(g, t)` cell grid itself and fits a `DoubleMLDIDBinary` per cell. So it
   is upstream's multi-period design *without* upstream's selector, and it
   transcribes upstream's `DoubleMLDIDCS` **machinery** instead -- upstream
   `did_cs.py` at lines 110, 445, 451, 456, 462, 464, 466, 470, 527, 529
   (the 2x2 `(d, t)` outcome nuisances and the panel-level sensitivity
   elements), verified bit-exact against a running upstream 0.11.3.

Upstream's single `DoubleMLDIDMulti` class is therefore **split** across two
port estimators: the port's `DoubleMLDIDCS` is the grid, and the port's
`DoubleMLDIDMulti` is the grid **plus** upstream's `gt_combinations`
selector -- its own header calls it "a thin top-level wrapper over
`DoubleMLDIDCS`". The 1:1 counterpart of upstream's `DoubleMLDIDMulti` is
the port's `DoubleMLDIDMulti`; the port's `DoubleMLDIDCS` is a port-side
variant of that class, not that class.

**This also corrects the README**, which said "three are upstream estimators
under a different name", listing `DoubleMLDIDCS` as upstream's
`DoubleMLDIDMulti` -- while also marking the port's `DoubleMLDIDMulti` as
name-identical to upstream's `DoubleMLDIDMulti`. That is one upstream class
claimed twice, and no 1:1 map can express it. The corrected grouping is
**19 name-identical + 2 renamed + 1 with no 1:1 upstream class**.

## What the README got wrong (v0.103.0, still true as history)

`README.mbt.md` marked three estimators *(extra)*, which reads as "no
upstream counterpart, nothing to compare against":

- `DoubleMLDIDCSBinary` -> `did/did_cs_binary.py`, exists
- `DoubleMLLPLR` -> `plm/lplr.py`, exists
- `DoubleMLPLPR` -> `plm/plpr.py`, exists

All three have a reference implementation upstream. Corrected in
v0.103.0.

## The DIDCS estimator, for the record

`did/did_cs.py` L16:

```python
class DoubleMLDIDCS(LinearScoreMixin, DoubleML):
```

`double_ml_score_mixins.py`, `LinearScoreMixin`:

```python
def _compute_score(self, psi_elements, coef):
    psi = psi_elements["psi_a"] * coef + psi_elements["psi_b"]
    return psi

def _compute_score_deriv(self, psi_elements, coef):
    return psi_elements["psi_a"]

def _est_coef(self, psi_elements, smpls=None, scaling_factor=None, inds=None):
    ...
    coef = -np.mean(psi_b) / np.mean(psi_a)
```

`did/tests/_utils_did_manual.py` (the cleanest hand reference, shared
with the DIDCS manual harness):

```python
def var_did(theta, psi_a, psi_b, n_obs):
    J = np.mean(psi_a)
    var = 1 / n_obs * np.mean(np.power(np.multiply(psi_a, theta) + psi_b, 2)) / np.power(J, 2)
    return var
```

## Files kept in this directory

**Tracked**, and byte-identical to the installed `doubleml` 0.11.3 package
(verified by sha256 on 2026-10-20):

- `did_cs.py` -- upstream's `DoubleMLDIDCS`
- `_utils_did_cs_manual.py` -- upstream's DIDCS manual harness
- `_utils_did_manual.py` -- upstream's DID manual harness
- `double_ml_score_mixins.py` -- upstream's `LinearScoreMixin` and
  `NonLinearScoreMixin`

**Not tracked, and not promised:**

- `doubleml-0.11.4.tar.gz` -- the sdist, 1.1 MB. It is a vendored upstream
  artefact, so it is deliberately not committed. The record is anchored to
  the **installed** package instead; the sdist is at
  `https://pypi.org/pypi/doubleml/json` -> `urls[sdist]`.
- `double_ml_linear_score.py` -- **stale**. This was upstream's file before
  it was replaced by `double_ml_score_mixins.py`; it does not exist in
  0.11.3 or in the 0.11.4 sdist, and it still carries the superseded
  `_est_causal_pars_and_se` API. The old record listed it *and* quoted the
  replacement's contents. It is kept on disk only as local history and is
  not tracked.
