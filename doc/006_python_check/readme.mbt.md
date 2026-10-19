# Python Cross-Check

24 Python scripts in the project root re-derive the hand-rolled
reference for each model and compare against the MoonBit output.
They are the project's "port-verified" contract.

## Workflow

```console
$ for s in validate_*_with_python.py; do echo "=== $s ==="; python $s | tail -1; done
=== validate_apos_with_python.py === PASS: apos reference
=== validate_blp_policy_with_python.py === BLP / policy tree parity: PASS
=== validate_bootstrap_with_python.py === bootstrap weight draw parity: PASS
=== validate_did_binary_with_python.py === binary DID parity: PASS
... (24 total)
```

The expected output of every script is a trailing line containing
the literal, upper-case `PASS`. The CI step greps for it with
`case "$line" in *PASS*)`, which is **case-sensitive** -- a trailing
line reading `passed` does not satisfy it. The CI step also
requires a zero exit code, so a script that prints a PASS-looking
line and then fails is still a failure.

## CI integration

`.github/workflows/check.yml` runs all 24 scripts in a single
`python-cross-check` job, and that job declares
`needs: moon-test` -- it only runs once the 4-backend test job is
green. A failure aborts the PR merge.

## Adding a new estimator

1. Port the estimator in `<estimator>.mbt` (e.g. `plr.mbt`) with a
   sibling `<estimator>_test.mbt` next to it. There is no `dml_*`
   prefix in this repository.
2. Write a matching `validate_<estimator>_with_python.py` that
   builds a reference scenario via the upstream
   `doubleml.DoubleMLXxx` and asserts MoonBit's output lands
   inside the tolerance that script declares.
3. Nothing to register. The CI step is a glob
   (`for s in validate_*_with_python.py`), so a new script is picked
   up as long as it carries that name -- but only scripts matching
   the glob run at all, so the naming is the registration.

No estimator ships without a Python cross-check.

## Failure modes

- **Transcendental rounding drift** — `ln`, `cos`, `sin`, `exp` and
  `pow` are not correctly rounded in any implementation, so MoonBit
  and CPython can differ by an ULP on the same input. Measured on
  `moon 0.1.20261016` vs CPython 3.13.14: `sqrt` 6/6 bit-exact
  (guaranteed by IEEE-754), `cos` and `sin` 6/6 bit-exact (observed,
  not guaranteed), `ln` 5/6 with `ln(3.0)` off by exactly 1 ULP.
  Because `box_muller_pair` uses `ln`, every DGP is one
  transcendental away from bit-level non-reproducibility. Use
  ranges, not `==`.
- **Upstream precision**: `doubleml` may use `numpy.linalg.lstsq`
  with different conditioning than our Cholesky. Loosen tolerance
  before claiming a regression.
- **Seeded RNG drift** — the port draws from `chacha8_rng`, the
  Python references from `numpy.random.default_rng` (PCG64); the
  legacy global `np.random.seed()` path (MT19937) is what the
  upstream-`doubleml` comparison uses. Don't compare exact `rng`
  outputs between languages; compare estimator-level summaries
  (θ, SE, CI bounds).

## Next

- See `_verify/` for per-release verifier reports on cross-check
  failures and resolutions.
