# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- The library lives at `moonbit_doubleML/` (its own `moon.mod` and
  `moon.pkg`). The project root is a pure workspace aggregator
  (`moon.work` lists every member) — it owns no MoonBit source itself.

- `moon.work` members (16 total):
  - `moonbit_doubleML/` — the library
  - `doc/` — wasm-gc-targeted numbered tutorials (`001_introduction`
    through `006_python_check`)
  - `examples/<bin>/` × 14 — `main`, `apos`, `consumer_demo`,
    `cvar`, `datasets`, `did_binary`, `did_cross_section`, `did_cs`,
    `did_cs_binary`, `did_multi`, `fuzz`, `lplr`, `plpr`, plus
    `api_server` (the HTTP-service example; no third-party framework,
    built directly on `moonbitlang/async`).

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## Dependency rule

- Only official (`moonbitlang/*`) packages are allowed.
- Non-official packages may only be `riantr/*` (i.e., this repo itself).
- For official packages, prefer the latest published version on the
  registry; pin the major-version (e.g. `moonbitlang/async@0.20.3`) and
  upgrade when bumping is intentional.

## HTTP service (examples/api_server)

- `examples/api_server/` is a hand-rolled HTTP service on top of
  `moonbitlang/async@0.20.3`. It deliberately avoids any third-party
  web framework (see commit `2ae0127` for the rationale).
- All routing, JSON parsing, and response shaping lives in
  `examples/api_server/main.mbt`. The moonbit_doubleML library is
  consumed via `@moonbit_doubleML.Matrix::from_array` /
  `DoubleMLData::new` / `DoubleMLPLR::new(...).fit()` — the same
  public API any other consumer would call.
- `main_test.mbt` is currently empty because `moonbitlang/async`'s
  `@http.get/post` helpers raise `ReaderClosed` when reading the
  response body on Windows. Endpoint correctness is verified via the
  PowerShell smoke-test recipe in `examples/api_server/README.md`.
