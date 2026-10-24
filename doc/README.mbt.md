# `riantr/moonbit_doubleML-doc` -- the tutorials

The documentation for
[`riantr/moonbit_doubleML`](https://mooncakes.io/docs/riantr/moonbit_doubleML),
written as a set of numbered MoonBit packages rather than as prose about the
library.  Each tutorial is a package of this project -- one directory, with
its own `moon.pkg` and its own tests -- and `doc` is a member of the
repository's `moon.work` workspace, so in the repository the tutorials build
against the library in the tree rather than against the version this
project's manifest pins.

| tutorial | what it covers |
|---|---|
| `001_introduction` | what Double / Debiased Machine Learning is, and why the port exists |
| `002_installation` | adding the library as a dependency, and the toolchain it needs |
| `003_quick_start` | an end-to-end fit, from generated data to a coefficient |
| `004_estimators` | the estimator families, their arguments, and their scores |
| `005_dgps` | the data-generating processes the examples and the tutorials use |
| `006_python_check` | comparing the port against upstream `doubleml-for-py` |

Every tutorial is a `wasm-gc` package.  Run one from the repository root with

```
moon test --target wasm-gc -p 003_quick_start
```

and read the tutorial itself in `doc/<name>/readme.mbt.md`.

The library's own README -- the one the registry serves -- is
`moonbit_doubleML/README.mbt.md`, and the verifiers that check its numbers
live under `_verify/`.
