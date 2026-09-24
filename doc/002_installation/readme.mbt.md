# Installation

## As a MoonBit library dependency

`riantr/moonbit_doubleML` is published to [mooncakes.io](https://mooncakes.io).

In your project's `moon.mod`:

```toml
import {
  "riantr/moonbit_doubleML@0.52.0",
}
```

Or via the CLI:

```console
$ moon add riantr/moonbit_doubleML
```

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

- `moon` >= 0.1.20260920 (current `latest`)
- Any backend in `native / wasm / wasm-gc / js` — all 4 supported.
- For the Python cross-check scripts: Python 3.10+, the
  `doubleml`, `numpy`, `pandas`, `statsmodels`, `scikit-learn`
  packages.

## Verification

After install, run the test suite:

```console
$ moon test --target native
Total tests: 415, passed: 415, failed: 0.
```

## Next

- See `003_quick_start` for a minimal end-to-end example.