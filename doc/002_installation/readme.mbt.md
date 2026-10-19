# Installation

## As a MoonBit library dependency

`riantr/moonbit_doubleML` is published to [mooncakes.io](https://mooncakes.io).

In your project's `moon.mod`:

```toml
import {
  "riantr/moonbit_doubleML@0.164.5",
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

- `moon` — CI installs the `latest` channel build and the
  repository pins no minimum. The numbers below were measured on
  `moon 0.1.20261016`.
- Any backend in `native / wasm / wasm-gc / js` — all 4 supported.
- For the Python cross-check scripts: Python 3.10+ (CI runs them
  on 3.12), and the `doubleml`, `numpy`, `pandas`, `scipy`,
  `statsmodels` and `scikit-learn` packages. The upstream-
  comparison steps additionally need `rdrobust`.

## Verification

After install, run the test suite:

```console
$ moon test --target native
Total tests: 1117, passed: 1117, failed: 0.
```

## Next

- See `003_quick_start` for a minimal end-to-end example.
