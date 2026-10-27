# Git Hooks

## Pre-commit Hook

`.githooks/pre-commit` runs **one** command:

```sh
moon check
```

`moon check` is the type-check pass, run at the workspace root over the
23 members of `moon.work` (exit 0 on a clean tree). `publish.yml` runs the
same pass with a target and `--deny-warn` added:
`moon check --target "$target" --deny-warn`.

It is **not** the test suite, the format check, `typos`, or the QA LOOP --
those live in `.github/workflows/` (the QA LOOP's own scripts in
`.github/scripts/qa_loop/`) and run on CI, not here.

### Usage Instructions

The hook is **not** active in a fresh clone, and it cannot be, for two
reasons that are worth stating rather than discovering:

1. **It is not executable in the checkout.** The file is tracked with mode
   `100644`, not `100755` -- no file in this repository is tracked as
   executable -- so every clone needs:
   ```bash
   chmod +x .githooks/pre-commit
   ```

2. **`core.hooksPath` is not set in the repository.** It is a *local* Git
   setting, so it cannot be committed and every clone has to opt in:
   ```bash
   git config core.hooksPath .githooks
   ```

Once both are done, the hook runs automatically on `git commit`, and a
non-zero `moon check` aborts the commit.

### What it does not cover

Running the hook is not a substitute for the gate:

- `moon check` type-checks the `_test.mbt` files and the `readme.mbt.md`
  doctests, but does not **run** them -- only `moon test` runs them.
- It does not run `moon fmt --check`, `typos`, the 24 Python cross-checks,
  or the QA LOOP.
- A push to `master` does not run `moon check --deny-warn` either: that
  command runs only in `publish.yml`, before a release. See `ENGINEERING.md`'s
  "What CI actually gates" section.

For the full suite, see `.github/workflows/check.yml` and
`.github/scripts/ci_local.py`.
