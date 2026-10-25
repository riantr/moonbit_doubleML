# Quick Start

A minimal end-to-end example: partially linear regression (PLR) on a
deterministic (n=100, p=5) synthetic panel.

```moonbit nocheck
// inside a function body -- MoonBit rejects a module-scope `let` bound to a
// call ("Cannot infer the type of variable data"), so this fragment is the
// body of a function, not the top of a file.  `using_test.mbt` below is the
// executable form of exactly this code.
// 1. Build a (n=100, p=5) design matrix and a treatment + outcome.
let n = 100
let x_data : Array[Double] = Array::make(n * 5, 0.0)
for i = 0; i < n; i = i + 1 {
  x_data[i * 5 + 0] = i.to_double()
  x_data[i * 5 + 1] = (i % 2).to_double()
  x_data[i * 5 + 2] = ((i + 1) % 3).to_double()
  x_data[i * 5 + 3] = ((i + 2) % 5).to_double()
  x_data[i * 5 + 4] = ((i + 3) % 7).to_double()
}
let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
  x_data, n, 5,
)
let y : Array[Double] = Array::make(n, 0.0)
let d : Array[Double] = Array::make(n, 0.0)
for i = 0; i < n; i = i + 1 {
  d[i] = i.to_double() * 0.5
  y[i] = i.to_double() * 1.0 + (i % 2).to_double()
}

// 2. Wrap into the data container.
let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)

// 3. Construct + fit a PLR estimator.
let fitted = @moonbit_doubleML.DoubleMLPLR::new(
  data,
  n_folds=2,
  n_rep=1,
  seed=3141,
).fit()

// 4. Read off the estimated coefficient, standard error, and CI.
let theta = fitted.coef()
let se = fitted.se()
let (lo, hi) = fitted.confint()
```

`Matrix::from_array` takes **three** arguments -- the flat
row-major `data`, then `nrows`, then `ncols` -- and panics when
`data.length() != nrows * ncols`. The fixture above is the same one
the executable tutorial test (`using_test.mbt`) builds.

## What this example actually produces

The fixture is deterministic, so the numbers are fixed. The same code
run on `native` and on `wasm-gc` (the backend this tutorial package
builds for) returns the same values, and all three values below were
re-measured bit-identical on all four supported backends (`native`,
`wasm-gc`, `wasm`, `js`):

| quantity | value |
|---|---|
| `coef()` | `-8.782651064906958` |
| `se()` | `13.75724952565863` |
| `confint()` | `(-35.74634818655666, 18.18104605674274)` |

The tutorial's own test (`using_test.mbt`) asserts all three values
bit-exactly, so this table cannot drift away from the code it
documents.

The estimate is far from zero and the interval is wide. That is
correct, not a bug: the fixture is a deterministic *modular* pattern
(`d` and `y` are polynomials in the row index, not an RNG draw), so
the DML orthogonality assumption the estimator relies on does not
hold for it. The point of this example is the **API shape**, not a
recovered effect. For a DGP with a known theta, and for a recovery
band that is actually asserted, see `005_dgps` and the estimator
recovery tests in the package.

The `DoubleMLPLR::new(...).fit()` is the canonical entry point.
The same shape applies to all 22 estimators — see
`004_estimators` for the catalogue.

## Cross-platform

The same `DoubleMLPLR::new(...).fit()` call runs on all 4 supported
backends (`native`, `wasm`, `wasm-gc`, `js`). Within one backend the
draws are deterministic: `chacha8_rng(seed)` rebuilds the same
`@random.Rand`, `box_muller_pair` takes its two normals with
`rng.double()`, and the same `seed` and `n_rep` reproduce the same
DGP output across runs.

Across backends the *estimates* are not bit-identical in general: the
`did_cs` quantities carry a known spread of about 1.5e-15 relative,
which is why the suite pins those assertions at 1e-12 relative instead
of `==`. A test that passes on native is not evidence that it passes
on the other three. This tutorial's PLR fixture happens to be an
exception — its three published values came out bit-identical on all
four backends — but that is a property of this fixture, not a general
licence to assert `==` on any estimate.

## Next

- See `004_estimators` for the full estimator catalogue and the
  estimator-specific constructor signatures.
- See `005_dgps` for the 18 DGP factories you can use to test.
- See `006_python_check` for the cross-validation workflow.