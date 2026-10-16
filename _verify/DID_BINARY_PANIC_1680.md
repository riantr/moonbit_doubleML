# Finding: `DoubleMLDIDBinary` panics on the CS2021 panel, upstream does not

**Status:** confirmed defect, NOT fixed. The gate built for it was removed
rather than shipped red.

## What happens

Fitting the port's `DoubleMLDIDBinary` on upstream's own CS2021 panel, for
`examples/did_binary`'s estimator, aborts the whole process:

```
section did_binary_upstream
val db_generated 1
val db_n_cells 6
precondition failed at did.mbt:276:5-276:37@riantr/moonbit_doubleML
PanicError
```

`did.mbt:276` is `require(n_folds <= data.n_obs())` inside `DoubleMLDID::new`.
The panic fires on the FIRST cell, ATT(2,1,2), before any coefficient is
emitted, so the entire `examples/parity` emitter dies and takes every other
section with it.

Upstream's `DoubleMLDIDBinary` fits the same panel, the same cell and the same
learners without error, for all six cells.

## It is NOT the data

Checked, because "the DGP was unfalsifiable" is a finding this repo has been
bitten by before (`sec_blp_policy`'s header records exactly that):

* **Units with both periods.** For ATT(2,1,2) (t_pre=1, t_value_eval=2),
  1000 of 1000 units have a row at t=1 AND a row at t=2. The same holds for
  all six cells.
* **Cohort labels are stable.** `g` takes the same cohort distribution at
  every period t=0..4: `{0: 263, 2: 252, 3: 265, 4: 220}`. So reading the
  cohort from the PRE-period row (`did_binary.mbt:185`, `g_unit =
  data.g[pre_idx]`) is not reading a blank.
* **The eligible subset is large.** `preprocess_did_binary` keeps a wide row
  iff `g_indicator + c_indicator == 1.0` (`did_binary.mbt:208`), i.e. the unit
  is exactly one of {cohort == g_value, cohort == min(g)}. For ATT(2,1,2) that
  is 252 + 263 = **515 rows**, far above `n_folds = 2`.

So `data.n_obs() >= 2` at the call site by every route available to
inspection, and yet the precondition fires.

## Structural difference worth noting

The two implementations are not the same construction:

* **upstream** consumes the PANEL directly (`DoubleMLDIDBinary(obj_dml_data,
  g_value, t_value_pre, t_value_eval, ...)`).
* **the port** converts the panel to a WIDE cross-section first
  (`preprocess_did_binary` -> `y_diff = y[eval] - y[pre]`), builds a
  `DoubleMLDIDData`, and then constructs an inner `DoubleMLDID` on it
  (`did_binary.mbt:833`, `:892`).

That is a legitimate alternative formulation, and `examples/did_binary`'s own
two-period DGP exercises it successfully. What is unexplained is why the wide
row count reaching `DoubleMLDID::new` is below `n_folds` when the panel
supplies 515 eligible units.

## What was NOT done

* No speculative fix. The obvious-looking candidates -- widen the fold
  guard, clamp `n_folds`, or special-case the panel -- would each paper over
  the row-count bug rather than locate it, and a fix that silences a
  precondition without restoring the rows would make the estimator quietly
  wrong instead of loudly broken.
* No red gate. A gate that panics on every run is not a gate; keeping it would
  either fail CI permanently or get muted with `--allow-inert`, which is worse
  than not having it.

## Where the remaining binary-DID coverage stands

`examples/did_cs_binary` IS gated, via `pyexample_did_cs_binary.py`, against
upstream's `DoubleMLDIDCSBinary` -- all six cells, none excluded. It is a
different estimator with a different construction path (it consumes the panel
and cross-fits it), and it does not hit this.

`examples/did_binary` remains ungated **upstream-side**. Its own deterministic
two-period DGP is still covered by the parity emitter's section 5, which
compares the port's `att` against a hand-computed reference; what is missing is
the upstream cross-check on upstream's own data.

## Reproducing

    python _verify/_didbin_tol_1680.py     # upstream reference, fits cleanly
    # then install the CS2021 fixture and run the emitter:
    #   precondition failed at did.mbt:276 ... PanicError

Reproduced on Windows, MoonBit 0.1.20261012 (748b63c 2026-10-12), doubleml
0.11.3.
