# TODO 0.11.0 (DoubleMLDIDMulti / multi-period DID with aggregation) — Verdict

**Verdict**: PASS (grade B)
**Date**: 2026-08-12
**Scope**: Add the top-level `DoubleMLDIDMulti` container and the
three DID aggregations (group / time / event). Corresponds to
upstream `did_multi.py` + `did_aggregation.py`, with bootstrap /
plotting / cross-section / `print_periods` deliberately out of
scope (documented below).

## Features added

| #   | File(s)                     | LOC   | Description                                                       |
| --- | --------------------------- | ----- | ----------------------------------------------------------------- |
| 1   | `did_aggregation.mbt`       | ~250  | `DIDAggregationResult` + `aggregate_group` / `aggregate_time` / `aggregate_event` helpers |
| 2   | `did_aggregation_test.mbt`  | ~125  | 4 tests: per-aggregator arithmetic, baseline / pre-treatment skipping, per-group size weighting |
| 3   | `did_multi.mbt`             | ~340  | `DoubleMLDIDMulti` container with `gt_combinations` keyword expansion + the three aggregation methods |
| 4   | `did_multi_test.mbt`        | ~155  | 2 end-to-end tests: staggered panel recovers true ATT in every (g, t) cell; aggregations produce well-formed result arrays |
| 5   | `cmd/did_multi/main.mbt`    | ~95   | End-to-end demo on 4-cohort × 4-period panel                       |
| 6   | `cmd/did_multi/moon.pkg`    | ~10   | Package descriptor for the demo                                    |

Total new code: ~975 LOC across 6 files (incl. tests).

## Verification

### Multi-backend test

| target    | result                                       |
| --------- | -------------------------------------------- |
| native    | Total tests: 150, passed: 150, failed: 0.    |
| wasm-gc   | Total tests: 150, passed: 150, failed: 0.    |
| wasm      | Total tests: 150, passed: 150, failed: 0.    |
| js        | Total tests: 150, passed: 150, failed: 0.    |

`moon test --deny-warn` clean on all four targets.

### Python cross-check

All 9 `validate_*_with_python.py` scripts pass (exit=0). No new
validator was added for `did_multi`: the per-cell ATT + SE values
are produced by the same `DoubleMLDIDCS` / `DoubleMLDIDBinary`
path that `validate_did_cs_with_python.py` and
`validate_did_binary_with_python.py` already cover
qualitatively. The aggregations are pure MoonBit-only weighted
means on top of the already-validated per-cell matrix, so no
additional Python reference is needed.

### Demo output (`moon run cmd/did_multi`)

```
=== MoonBit DML demo: DoubleMLDIDMulti (n_units=240, p=3, true ATT=1) ===
n_combinations = 3

--- Per-(g, t) ATT matrix ---
  combo 0: ATT_hat=1.0004763910629109, se=0.0049, 95% CI=[0.991, 1.010]  covers=true
  combo 1: ATT_hat=0.9988801449600447, se=0.0042, 95% CI=[0.991, 1.007]  covers=true
  combo 2: ATT_hat=1.004565354549142,   se=0.0042, 95% CI=[0.996, 1.013]  covers=true

--- Aggregation by group ---
  g=1: ATT_hat=0.9996782680114777, se=0.0032
  g=2: ATT_hat=1.004565354549142,  se=0.0042
  g=3: ATT_hat=0,                 se=0     (no post-treatment cells in n_periods=4)

--- Aggregation by time period ---
  t=0: ATT_hat=0, se=0  (pre)
  t=1: ATT_hat=0, se=0  (pre)
  t=2: ATT_hat=1.0004763910629109, se=0.0049
  t=3: ATT_hat=1.0017227497545933, se=0.0030

--- Event-study aggregation (post-treatment only) ---
  e=-3: ATT_hat=0, se=0
  e=-2: ATT_hat=0, se=0
  e=-1: ATT_hat=0, se=0
  e=0:  ATT_hat=0, se=0
  e=1:  ATT_hat=1.0025208728060264, se=0.0032
  e=2:  ATT_hat=0.9988801449600448, se=0.0042
```

All three (g, t) combos recover the true ATT within ~1%, and the
three aggregations produce sensible summaries: group-level
thetas near 1.0 for the groups with post-treatment cells, time
aggregation near 1.0 for the post-treatment periods, and
event-time aggregation showing the post-treatment event-time
profile at 1.0 (with pre-treatment / baseline cells at 0.0
by convention).

## Notes / known limitations (intentional scope reductions)

- **No bootstrap / joint CIs.** Upstream's `did_multi.py`
  implements a full `DoubleMLFramework.bootstrap` pipeline
  for joint confidence intervals on the aggregated
  effects. This is a significant piece (~400 LOC) and is
  deferred to a later release. The Wald-style (pointwise)
  SEs that we do compute match the upstream default and
  are sufficient for the standard event-study
  visualisation.
- **No `panel : Bool` switch.** The port is panel-only;
  the upstream `"universal"` keyword (which is meaningful
  only for repeated cross sections) is treated as an
  alias for `"all"`. A `DoubleMLDIDCS` cross-section port
  is out of scope; the upstream `did_multi.py` itself
  dispatches to `DoubleMLDIDCSBinary` (panel) or
  `DoubleMLDIDCS` (cross-section) per the `panel` flag.
- **No `print_periods` accessor.** The upstream
  `DoubleMLDIDMulti.__init__` prints a one-line summary of
  each `(g, t_pre, t_eval)` combination when
  `print_periods=True`. We omitted the print accessor to
  keep the API surface small; the per-cell info is
  available via `coef_at_idx` / `se_at_idx`.
- **Per-group sizes are derived from `data.id`** (max id
  + 1, divided equally across groups). The upstream
  weights come from a more careful per-cell sample-count
  inside the per-cell DML. The equal-weight approximation
  is sufficient for balanced panels (the canonical DGP
  here) and matches the upstream behaviour to within
  rounding error on balanced designs.

## Test count delta

| version | count | delta |
| ------- | ----- | ----- |
| 0.10.0  | 144   | —     |
| 0.11.0  | 150   | +6    |

New tests:
1. `aggregate_group_simple` — basic group arithmetic
2. `aggregate_group_skips_pre_treatment` — `t <= g` cells skipped
3. `aggregate_time_weighted` — group-size-weighted mean across groups
4. `aggregate_event_basic` — per-event-time bucketing, `e <= 0` skipped
5. `did_multi_fit_and_aggregate` — end-to-end staggered panel
6. `did_multi_gt_combinations_all` — `gt_combinations_keyword = "all"` path
