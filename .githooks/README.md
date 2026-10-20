# Git Hooks

## Pre-commit Hook

`.githooks/pre-commit` runs **one** command:

```sh
moon check
```

`moon check` is the type-check pass, run at the workspace root over the
members of `moon.work` (measured: `moon: ran 54 tasks`, exit 0 on a clean
tree). It is the same command `publish.yml` runs before it publishes.

It is **not** the test suite, the format check, `typos`, or the QA LOOP --
those live in `.github/workflows/` and run on CI, not here.

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

- `moon check` does **not** check `_test.mbt` files -- only `moon test`
  compiles them.
- It does not run `moon fmt --check`, `typos`, the 24 Python cross-checks,
  or the QA LOOP.
- A push to `master` does not run `moon check --deny-warn` either: that
  command runs only in `publish.yml`, before a release. See the README's
  "What CI actually gates" table.

For the full suite, see `.github/workflows/check.yml` and
`.github/scripts/ci_local.py`.
