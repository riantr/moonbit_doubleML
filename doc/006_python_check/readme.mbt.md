# Python Cross-Check

24 Python scripts in the project root re-derive the hand-rolled
reference for each model and compare against the MoonBit output.
They are the project's "port-verified" contract.

## Workflow

```console
$ for s in validate_*_with_python.py; do echo "=== $s ==="; python $s | tail -1; done
=== validate_apos_with_python.py === BLP/PolicyTree reference checks passed
=== validate_blp_policy_with_python.py === BLP/PolicyTree reference checks passed
=== validate_bootstrap_with_python.py === Multipliers match: PASS
=== validate_did_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 1.29e-02 ...
=== validate_did_binary_with_python.py === Reference: run `moon run examples/did_binary` for the MoonBit output.
... (24 total)
```

The expected output of every script is exactly one trailing line
that contains ` PASS ` (or `passed` or `match`). The CI loop
greps for that token; missing it breaks the build.

## CI integration

`.github/workflows/check.yml` runs all 24 scripts in a single
`python-cross-check` job that depends on the moon test pass.
A failure aborts the PR merge.

## Adding a new estimator

1. Port the estimator in `dml_xxx.mbt` + `dml_xxx_test.mbt`.
2. Write a matching `validate_xxx_with_python.py` that builds a
   reference scenario via the upstream `doubleml.DoubleMLXxx`
   and asserts MoonBit's output is within `MODEL_TOL=0.1` of the
   Python result.
3. Append the new script to the loop in `.github/workflows/check.yml`.

No estimator ships without a Python cross-check.

## Failure modes

- **Bit-exact round-trip drift** — Float32 vs Float64. Use ranges
  (`< 0.5e-2`), not `==`.
- **Upstream precision**: `doubleml` may use `numpy.linalg.lstsq`
  with different conditioning than our Cholesky. Loosen tolerance
  before claiming a regression.
- **Seeded RNG drift** — chacha8 (MoonBit) vs MT19937 (numpy
  default). Don't compare exact `rng` outputs between languages;
  compare estimator-level summaries (θ, SE, CI bounds).

## Next

- See `_verify/` for per-release verifier reports on cross-check
  failures and resolutions.