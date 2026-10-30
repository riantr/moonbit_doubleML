# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- A directory holding a `moon.mod` file is a **module**; a directory holding a
  `moon.pkg` file is a **package**. A module may hold several packages, and
  each package lists its own dependencies in its `moon.pkg`. Test files sit
  next to the source they cover: blackbox tests end in `_test.mbt`, whitebox
  tests end in `_wbtest.mbt`.

- The library lives at `moonbit_doubleML/` (its own `moon.mod` and
  `moon.pkg`). The project root is a pure workspace aggregator
  (`moon.work` lists every member) — it owns no MoonBit source itself.

- `moon.work` members (23 total):
  - `moonbit_doubleML/` — the library
  - `doc/` — a module of 6 wasm-gc-targeted packages: the numbered
    tutorials (`001_introduction` through `006_python_check`), each with its
    own `moon.pkg`
  - `examples/<bin>/` × 21 — `api_server` (the HTTP-service example;
    no third-party framework, built directly on `moonbitlang/async`),
    `apo`, `apos`, `bitexact`, `cluster`, `consumer_demo`, `cvar`,
    `datasets`, `did_binary`, `did_cross_section`, `did_cs`,
    `did_cs_binary`, `did_multi`, `fuzz`, `lplr`, `main`, `parity`,
    `pava`, `plpr`, `splitting`, `ssm`.

- Three directories hold MoonBit source outside the workspace: `_verify/`
  (helper scripts with no `moon.pkg`) and the proof pilots `_prove_pilot/`
  and `_prove_pilot2/` (each its own `moon.pkg`, neither a `moon.work`
  member).

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory. No `deprecated.mbt` file exists in the tree today.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` regenerates each package's interface file `pkg.generated.mbti` --
  a brief formal description of the package. The file is **git-ignored**, so
  it never shows up in `git diff`: to see whether a change reaches the
  external package users, run `moon info` before and after the change and
  diff the two copies yourself. If nothing in it changes, the change does not
  bring visible changes to the external package users, and it is typically a
  safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. The interface file is not tracked, so `git diff` will not
  show it -- read it directly.

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
- Non-official packages may only be `riantr/*` (this repo itself). One
  declared line does not meet the rule today:
  `moonbit-community/sqlite3@0.2.3`, in `moonbit_doubleML/moon.mod` --
  **no `.mbt` in the library imports it** (0 references), so it is a dead
  entry, not a runtime dependency.
- For official packages, pin to the latest published version on the
  registry (e.g. `moonbitlang/async@0.22.7`) and upgrade when bumping is
  intentional.

## HTTP service (examples/api_server)

- `examples/api_server/` is a hand-rolled HTTP service on top of
  `moonbitlang/async@0.22.7`. It deliberately avoids any third-party
  web framework (see commit `2ae0127` for the rationale).
- All routing, JSON parsing, and response shaping lives in
  `examples/api_server/main.mbt`. The moonbit_doubleML library is
  consumed via `@moonbit_doubleML.Matrix::from_array` /
  `DoubleMLData::new` / `DoubleMLPLR::new(...).fit()` — the same
  public API any other consumer would call.
- The package ships **no** test file: `moonbitlang/async`'s
  `@http.get/post` helpers raise `ReaderClosed` when reading the
  response body on Windows, which blocks an `assert_eq`-style
  integration test inside the test driver. Endpoint correctness is
  verified via the PowerShell smoke-test recipe in
  `examples/api_server/README.md` instead.
