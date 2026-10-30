# Installation

## As a MoonBit library dependency

`riantr/moonbit_doubleML` is published to [mooncakes.io](https://mooncakes.io).

In your project's `moon.mod`:

```toml
import {
  "riantr/moonbit_doubleML@0.164.58",
}
```

Or via the CLI:

```console
$ moon add riantr/moonbit_doubleML
```

`moon add` always resolves the newest published version; the
pinned form above tracks the current release.

## From source (gitee / github)

```console
$ git clone https://gitee.com/ren-yongxiang/moonbit_doubleml.git
$ cd moonbit_doubleml
$ moon test --target native
```

The repo's three platforms (gitee, github, mooncakes.io) carry the
same commit graph — pick whichever has the lowest latency to your
machine.

## Toolchain requirements

- `moon` **0.1.20261028 or newer**. The published package declares
  `moonbitlang/async@0.22.7`, and that version's published source imports
  `moonbitlang/core/async` — a core subpackage that older cores do not
  carry. On `moon 0.1.20261023` a consumer's build cannot be solved at all:
  "Cannot find import `moonbitlang/core/async` in
  `moonbitlang/async@0.22.7`". CI installs the `latest` channel build, and
  the numbers below were measured on `moon 0.1.20261028`.
- Any backend in `native / wasm / wasm-gc / js` — all 4 supported.
- For the Python cross-check scripts: Python 3.10+ (CI runs them
  on 3.12), and the `doubleml`, `numpy`, `pandas`, `statsmodels`
  and `scikit-learn` packages -- `scipy` is required too, and
  arrives transitively. The upstream-comparison steps additionally
  need `rdrobust`, **pinned `>=2,<3`**: its bias-corrected estimator
  is a dense linear-algebra port, so a version bump can move `tau.bc`
  in the last few digits and turn the machine-precision RDD gate red
  for no real reason.

## Verification

The test suite ships in the **repository**, not in the published package:
the package carries the library and no test files, so `moon test` in a
project that installed it reports `Total tests: 0, passed: 0, failed: 0.`

To run the suite, clone the repository (see above) and run it from the
repository root:

```console
$ moon test --target native
Total tests: 1117, passed: 1117, failed: 0.
```

## Next

- See `003_quick_start` for a minimal end-to-end example.
