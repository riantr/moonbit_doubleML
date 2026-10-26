# Python Cross-Check

Two families of Python scripts live in the project root, and **both** run in
the same CI job:

| family | count | the reference it compares the port against |
|---|---|---|
| `validate_*_with_python.py` | 24 | a Python reference: hand-rolled here in **15**, upstream's wheel in **9** |
| `pyexample_*.py` | 9 | **upstream's own code** (`doubleml-for-py`, plus `rdrobust`) |

Together they cross-check all **22** estimators. The split is not even:
**16** are checked by both families, **3** are checked *only* by the
`validate_*` family, and **3** are checked *only* by the `pyexample_*`
family.

| covered only by | estimators |
|---|---|
| `validate_*` | `DoubleMLDIDCS`, `DoubleMLDIDCrossSection`, `DoubleMLPLPR` |
| `pyexample_*` | `DoubleMLAPO`, `DoubleMLDIDMulti`, `DoubleMLQTE` |

A `validate_*` script compares the port against a reference built in
Python. Most of them re-derive that reference by hand from the model;
**9** of the 24 import the upstream `doubleml` wheel instead. A
`pyexample_*` script always runs **upstream's** estimator on the same rows
and compares that — not "does the port agree with our second
implementation" but "does the port agree with upstream".

The `validate_*` family can only catch a disagreement someone already
thought to look for, with two exceptions that gate the port against
upstream's own numbers — `validate_did_cs_binary_with_python.py` and
`validate_lplr_with_python.py`. The `pyexample_*` family is the one that
catches a shared misreading of the model.

## Workflow

The `validate_*` family needs no arguments:

```console
$ for s in validate_*_with_python.py; do echo "=== $s ==="; python $s | tail -1; done
=== validate_apos_with_python.py ===
PASS: apos reference
=== validate_bitexact_with_python.py ===
bit-exact parity: PASS
=== validate_blp_policy_with_python.py ===
BLP / policy tree parity: PASS
... (24 total)
```

The loop prints the file name and the verdict on **separate** lines, and
the glob is alphabetical -- so `validate_bitexact_with_python.py` is the
second file, between `apos` and `blp_policy`.

That command is the short form, for reading the verdicts. **CI runs a
stricter version**: it captures stdout *and* the exit code separately, so
a script that prints a PASS-looking line and then fails is still a
failure. See `.github/workflows/check.yml`.

The `pyexample_*` family is invoked with `--check`:

```console
$ python pyexample_did.py --check
...
pyexample: port vs upstream make_did_SZ2020: PASS
fixture restored byte for byte: True
```

The two families are checked in **different ways**, and the difference
matters when a script fails:

- a `validate_*` script's expected output is a trailing line containing
  the literal, upper-case `PASS`. The CI step greps for it with
  `case "$line" in *PASS*)`, which is **case-sensitive** -- a trailing
  line reading `passed` does not satisfy it. The CI step also
  requires a zero exit code, so a script that prints a PASS-looking
  line and then fails is still a failure.
- a `pyexample_*` script prints its verdict line *before* it restores
  the generated fixture, so its **last** line is
  `fixture restored byte for byte: True`, not the PASS line. Its CI
  step is `set -e` plus the script's exit code, and the script exits
  non-zero if the verdict failed *or* if the fixture was not restored
  byte for byte. Grepping these scripts for a trailing `PASS` would
  find nothing.

## CI integration

`.github/workflows/check.yml` runs both families in a single
`python-cross-check` job, and that job declares
`needs: moon-test` -- it only runs once the 4-backend test job is
green. A failure aborts the PR merge.

The two families are wired up differently, and the difference matters
when you add a script:

- the `validate_*` family is picked up by a **glob**
  (`for s in validate_*_with_python.py`), so a new script runs as soon
  as it carries that name;
- every `pyexample_*` script has its own **explicit CI step**
  (`python pyexample_did.py --check`), so a new one does **not** run
  until a step is added for it.

## Adding a new estimator

1. Port the estimator in `<estimator>.mbt` (e.g. `plr.mbt`) with a
   sibling `<estimator>_test.mbt` next to it. There is no `dml_*`
   prefix in this repository.
2. Write a matching `validate_<estimator>_with_python.py` that
   builds a reference scenario and asserts MoonBit's output lands
   inside the tolerance that script declares. **9** of the 24 take
   that reference from the upstream `doubleml.DoubleMLXxx` wheel; the
   other **15** re-derive it in Python from the same model. Say which
   one in the script's header — a hand-rolled reference is only as good
   as the reading of the model behind it.
3. Nothing to register for that family -- the CI step is a glob
   (`for s in validate_*_with_python.py`), so a new script is picked
   up as long as it carries that name -- but only scripts matching
   the glob run at all, so the naming is the registration. If the
   estimator's reference is upstream's own class rather than a
   hand-rolled one, add a `pyexample_<estimator>.py` **and** an
   explicit CI step for it, or it will never run.

No estimator ships without a Python cross-check.

## Failure modes

- **Transcendental rounding drift** — `ln`, `cos`, `sin`, `exp` and
  `pow` are not correctly rounded in any implementation, so MoonBit
  and CPython can differ by an ULP on the same input. Measured on
  `moon 0.1.20261023` vs CPython 3.13.14: `sqrt` 6/6 bit-exact
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
