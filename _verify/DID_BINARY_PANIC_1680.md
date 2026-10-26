# RETRACTED: `DoubleMLDIDBinary` does not panic on the CS2021 panel

**Status: the finding below is WRONG and is retracted.** It is kept, unedited in
substance, because a wrong conclusion that reads like a right one is worse than
no conclusion — the next reader has to be able to see what was claimed and what
disproved it.

The retraction is `pyexample_did_binary.py`, a working upstream gate over all six
cells. The defect described here never existed.

## What was claimed

An earlier version of that gate passed upstream's default `n_folds = 5`, and the
emitter aborted with:

```
section did_binary_upstream
val db_generated 1
val db_n_cells 6
precondition failed at did.mbt:276:5-276:37@riantr/moonbit_doubleML
PanicError
```

`did.mbt:276` is `require(n_folds <= data.n_obs())` inside `DoubleMLDID::new`.
It was recorded as: the eligible wide-format subset must be smaller than
`n_folds`, so the CS2021 panel defeats the port.

## Why that reasoning was wrong

The claim rested on an INFERENCE about the call graph, not on a measurement.
The real `inner_pre = DoubleMLDID::new(wide_data, ...)` is at
`did_binary.mbt:898`, so the panic was read as coming from there. But
`DoubleMLDIDBinary::new` builds a **second, 4-row dummy** `DoubleMLDID` at
`did_binary.mbt:445` — a placeholder so that construction cannot itself trip
`n_folds <= n_obs`. Both calls raise at the SAME line and print the SAME
message. The panic text cannot tell them apart, and the call site was never
evidence about which one fired.

It was always a known port limit, recorded next to the code it came from
(`did_binary.mbt:425-439`) and in `_verify/N_FOLDS_1570.md`: the 4-row dummy
caps `n_folds` at 4 for this type, `n_folds <= 4` fits and `n_folds >= 5`
aborts, **at every sample size**. The port default of 2 sits under the ceiling,
which is why it went unnoticed until a gate passed 5.

## What is actually true (measured)

Sweep on the CS2021 panel, cell ATT(2,1,2), 5000 rows:

| `n_folds` | constructs | fits | coef |
|---|---|---|---|
| 2 | yes | yes | 1.14480 |
| 3 | yes | yes | 1.14611 |
| 4 | yes | yes | 1.11875 |
| 5 | **no** | — | aborts |

Upstream's `DoubleMLDIDBinary` on the same cell: **1.13860**.

`preprocess_did_binary` emits **515** wide rows (252 + 263, exactly as the
independent Python calculation predicts), so the subset is nowhere near small.
And `n_folds = 5` aborts **during construction** — a `println` placed before
each construct/fit pair shows the "about to construct" line printing and no
"constructed" line, with no preprocessing output at all. That is what locates
the raise in the dummy rather than the real model.

The control for this: the same sweep run through `examples/parity`, a workspace
member, and through a non-member directory. The non-member resolved
`riantr/moonbit_doubleML@0.162.0` from the registry instead of the local
source and produced **bit-identical** coefficients — which is a real result
(published and local agree on this path) and is also why the first probe run
showed no probe output at all. A probe that does not print is a probe pointed at
the wrong subject.

## What replaced it

`pyexample_did_binary.py` gates `DoubleMLDIDBinary` against upstream on the
same CS2021 panel, all six cells explicitly requested on both sides, both sides
at `n_folds = 2`. Coefficients agree to 57.5% of band and standard errors to
51.2% at worst. Wired into `check.yml` and the QA LOOP.

The `n_folds <= 4` ceiling is a **real, separate, still-open limitation** and
is not fixed here — upstream's default of 5 remains unattainable on this type.
Fixing it means removing the dummy (build the inner model lazily, on `fit`) so
that construction has no row count to check. That is a behaviour change to a
constructor and was not undertaken speculatively.

Reproduce:

    python pyexample_did_binary.py --check          # the gate

The second command this section used to name — `_didbin_reach_1680.py` — was
never committed to this repository (`git log --all -- _verify/_didbin_reach_1680.py`
is empty), so the arms it re-measured cannot be re-derived from this tree. The
gate above re-derives all six cells on every run, and it is the retraction this
document names.

Measured on Windows, MoonBit 0.1.20261012 (748b63c 2026-10-12), doubleml 0.11.3.
