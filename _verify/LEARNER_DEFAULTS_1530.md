# Learner defaults in `moonbit_doubleML` — measured inventory

**v0.153.0 working note.** Produced because the active goal refers to "the
remaining 11 defaults" and that list could not be recovered from any durable
artifact. This re-derives the candidate set from the **source**, so a
user-supplied list can be checked against what actually exists.

Generator: `_verify/_enum_defaults_1530.py` (parses, does not grep).
Scope: 213 `.mbt` files, 34 `DoubleMLXxx::new` definitions, **27 learner
default sites**.

A "default" here means a `::new` parameter whose default *value* is a
`LearnerDispatch::...()` construction — i.e. what a caller who never mentions
the argument actually receives. Deliberately excluded: `::fit` parameters
defaulting to `self.ml_g` (that is "reuse what was stored", not a learner
choice), and bare struct fields with no default.

## 1. Inventory

| slot | sites | distinct defaults |
|---|---|---|
| `ml_g` | 12 | `linear_regression` × 12 |
| `ml_m` | 12 | `logistic_regression` × 6, `linear_regression` × 6 |
| `ml_l` | 2 | `linear_regression` × 2 |
| `ml_r` | 1 | `linear_regression` × 1 |

### `ml_m` — split 6 / 6

**logistic** (migrated): `DoubleMLIRM` (v0.132.0), `DoubleMLAPO` (v0.134.0),
`DoubleMLAPOS` (v0.135.0), `DoubleMLSSM` (v0.138.0), `DoubleMLPQ`,
`DoubleMLQTE`.

**linear** (not migrated): `DoubleMLCVAR`, `DoubleMLDID`,
`DoubleMLDIDCrossSection`, `DoubleMLDIDMulti`, `DoubleMLIIVM`,
`DoubleMLLPLR`.

### `ml_g` — all OLS

`DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLBLP`, `DoubleMLCVAR`, `DoubleMLDID`,
`DoubleMLDIDCrossSection`, `DoubleMLDIDMulti`, `DoubleMLIIVM`,
`DoubleMLIRM`, `DoubleMLLPLR`, `DoubleMLRDD`, `DoubleMLSSM` — all at
`linear_regression`. This matches upstream: `ml_g` models `E[y | x]`, so OLS is
the correct default and diverging from it would be the bug, not the fix.

### `ml_l` / `ml_r`

`ml_l`: `DoubleMLPQ`, `DoubleMLQTE` — both OLS. `ml_r`: `DoubleMLIIVM` only,
OLS.

## 2. The `ml_m` queue is CLOSED — do not reopen it

The most obvious reading of "the remaining 11 defaults" is the `ml_m` queue,
and measurement shows it is finished:

| release | what it did |
|---|---|
| v0.131.9 | introduced the `ml_m` default hazard; listed **six** estimators |
| v0.132.0 | corrected the count to **fourteen**; migrated `DoubleMLIRM` |
| v0.134.0 / v0.135.0 | migrated `DoubleMLAPO` / `DoubleMLAPOS` |
| v0.136.0 | `DoubleMLDIDBinary` attempted, **abandoned on measurement** |
| v0.137.0 | **measured all eleven remaining defaults one by one**, recorded a per-estimator verdict |
| v0.138.0 | acted on the only measured hazard, `DoubleMLSSM` |

v0.137.0's verdict table: `DoubleMLSSM` **HAZARDOUS** (OLS `242.116`, se
`185.4`); `DoubleMLCVAR` / `DoubleMLQTE` / `DoubleMLIIVM` / `DoubleMLPLR` /
the DID family "not demonstrated"; `DoubleMLPQ` carries the separate
quantile-ignoring defect; `DoubleMLLPLR` a degenerate SE.

**Ten "not demonstrated" is a weak verdict, not a proof** — v0.137.0 itself
records the static classifier being refuted once (`DoubleMLIIVM` was predicted
hazardous and measured harmless). If the intended queue is to *harden* those
ten, that is a different and much larger piece of work than migrating them.

## 3. Two defects found while enumerating

### A. Learner observability is inconsistent across estimators

Measured over three axes — does `::new` take the learner, does the struct
**store** it, does the estimator **expose** it — the 14 learner-taking
estimators fall into three groups, not one.

**BEFORE v0.153.0** — the three groups, as measured:

| group | count | estimators |
|---|---|---|
| stores **and** exposes | 10 | APO, APOS, CVAR, DIDCrossSection, DIDMulti, IRM, LPLR, PQ, QTE, RDD |
| stores, does **not** expose | 4 | BLP, DID, IIVM, SSM |
| **neither** | 3 | DIDCS, DIDCSBinary, DIDBinary |

**AFTER v0.153.0 — uniform.** Every learner slot the package takes is now both
stored and exposed: **15 `ml_g` + 15 `ml_m` + 2 `ml_l` + 1 `ml_r` = 33 slots,
33 accessors**, no exceptions. The enumerator's `ml_g` / `ml_m` counts moved
from 12 / 12 to 15 / 15, which is the three DID constructors acquiring the
parameter they never had.

The bottom row had **no** `ml_g` / `ml_m` field on the struct at all. `DoubleMLDIDCS::new` (`did_cs.mbt:312-324`),
`DoubleMLDIDCSBinary::new` (`did_cs_binary.mbt:696`) and
`DoubleMLDIDBinary::new` (`did_binary.mbt:343`) accept no learner parameter;
the learner appears only as a `::fit` argument defaulting to OLS:

- `did_cs.mbt:1126-1127` — `DoubleMLDIDCS::fit`
- `did_cs_binary.mbt:1038-1039` — `DoubleMLDIDCSBinary::fit`
- `did_binary.mbt:750-751` — `DoubleMLDIDBinary::fit`

A caller cannot ask a fitted `DoubleMLDIDCS` which propensity learner produced
it, and a constructor-level audit like this one is structurally blind to those
three. This is an **API gap, not a wrong value** — OLS is defensible for all
three (they are doubly robust, and v0.137.0 found no DID-family hazard). What
is missing is observability afterwards.

### B. Stale learner comments that assert the opposite of the code

Two, both in files this audit had to read, both of the same shape: a comment
claiming a parameter is ignored or hardcoded when the surrounding code routes
it.

**`did_cs.mbt:1129`** — a vestigial `ignore(ml_g)` stood above the v0.146.0
note. `ml_g` has driven the four conditional `(d, t)` outcome nuisances since
v0.146.0 (`did_cs.mbt:1228`, `1235`, `1242`, `1249`, forwarded at `1518`), so
the line claimed a drop that does not exist. **Fixed** in this round.

**`did_cs_binary.mbt:11-23`** — the header's "Simplifications vs. upstream"
bullet read "`ml_g` and `ml_m` are both collapsed to the same closed-form
`LinearRegression` learner ... pluggable learners can be added in a later
release". That was true at v0.51.0 and went stale at **v0.62.0**, which made
both slots pluggable: `fit` routes `ml_g` through `fit_cs_bin_g` for the four
conditional g-functions (`:274-285`) and `ml_m` through
`fit_predict_one_dispatch` (`:290`), and `tune` forwards the grid's best pair
(`:1671`). The file's own inline comments at `:271-273` and `:288-290` already
said so, so the header contradicted the body. **Fixed** in this round.

This one mattered beyond tidiness: the stale header is what makes the default
look like a deliberate design choice rather than the observability gap in
finding A. An auditor who trusts it concludes DIDCSBinary cannot take a
classifier — the opposite of the truth.

## 4. Verification of this round's two fixes

Both changes are comment-only (one deleted line, one rewritten doc block), so
no numeric pin is involved and no cross-backend spread can be introduced.
Proportionate gate run: `moon check` exit 0, `moon test --target native`
**1087 / 1087**. The full four-target run at the released baseline
(`1087 / 1087 / 1093 / 1087`) was confirmed after the `did_cs.mbt:1129` fix.

## 5. v0.153.0 — the fix, and the evidence it discriminates

All three estimators now take `ml_g` / `ml_m` in `::new`, store them, expose
`learner_g()` / `learner_m()`, and default `fit`'s parameters to `self.ml_g` /
`self.ml_m`. **The default VALUES are unchanged (OLS for both)**, so no existing
call site moves — that claim is GATE 4 and is locked, not asserted in prose.

### Gates — `moonbit_doubleML/expand_v153_test.mbt`, 7 gates

| gate | asserts | mutation it is aimed at |
|---|---|---|
| 1 | `fit` uses the recorded `ml_m` (coef **and** se both move) | M1 |
| 2 | `fit`'s implicit default equals the stored learner | M1 |
| 3 | an explicit `fit(ml_m=...)` still overrides the stored one | — (`tune` path) |
| 4 | the implicit default path is identical to an explicit OLS pair | M3 |
| 5 | the accessor's return value reproduces the fit it was recorded for | M2, M1 |
| 6 | `DoubleMLDIDCSBinary` uses its recorded learners | M4 |
| 7 | `DoubleMLDIDBinary` uses its recorded learners + accessor round-trip | M5 |

Every contrast names **both arms explicitly**. The v0.136.0 mechanism probe
compared a value against "the default" and so compared a value with itself.

### Mutation result: 5 / 5 killed, 0 survived, 0 inconclusive

| mutant | what it re-introduces | gates that fired | as declared? |
|---|---|---|---|
| M1 | `DoubleMLDIDCS::fit` hardcoded OLS default | GATE 1, **GATE 2**, **GATE 5** | **no — see below** |
| M2 | `learner_m()` returns hardcoded OLS | GATE 5 | yes |
| M3 | `::new` default `ml_m` silently changed to logistic | GATE 4 | yes |
| M4 | `DoubleMLDIDCSBinary::fit` hardcoded OLS default | GATE 6 | yes |
| M5 | `DoubleMLDIDBinary::fit` hardcoded OLS default | GATE 7 | yes |

**The declaration for M1 was wrong and measurement corrected it.** I predicted
{GATE 1, GATE 2, GATE 3}. In fact GATE 3 never fired and GATE 5 did. The
reason is structural: GATE 3 contrasts `new(logistic).fit(ml_m=ols)` against
`new(ols).fit()`, and both arms pass `ml_m` explicitly (or land on OLS
anyway), so an *implicit*-default mutant cannot separate them. M1 also breaks
GATE 5, whose two arms are `est.fit()` (implicit) against
`est.fit(ml_m = est.learner_m())` (explicit) — that contrast *is* sensitive to
the implicit default. GATE 3 is retained: it covers the `tune` override path,
which no other mutant exercises, not the M1 shape.

### Two harness bugs the run itself caught

1. **M3's mutation pattern was malformed** — the first run reported
   `HARNESS-FAIL / NO-OP`, which is counted as a harness failure and never as a
   kill. A silently-missed mutation is worse than no harness.
2. **`subprocess` decoded with the LOCALE codec** (GBK on this machine), so any
   non-ASCII byte in moon's output raised `UnicodeDecodeError` inside the reader
   thread and lost the output the verdict is parsed from. Pinned
   `encoding="utf-8", errors="replace"`.

### Fixture that could not discriminate — and why

GATE 7 took **two** attempts. The first reused the 4-unit x 2-period fixture
from `did_binary_test.mbt`, where treatment is **deterministic** (units 0-2
have `d = 1`, unit 3 has `d = 0`). The propensity has nothing to learn, so
`m_hat` is a clean 1/0 under either learner and OLS and logistic agree
exactly — the contrast arm returned false on identical numbers. Giving `x` real
covariate spread did **not** help, because the defect is the deterministic
assignment, not the missing signal. The gate now runs on the stochastic CS2021
panel with the canonical `(1, 0, 1)` triple. Recorded because a fixture that
cannot discriminate is indistinguishable from a gate that cannot fail.

## 6. v0.153.0 part 2 — the four "stored but never exposed"

`DoubleMLBLP`, `DoubleMLDID`, `DoubleMLIIVM`, `DoubleMLSSM` each kept their
learner pair on the struct since v0.60.0 and published no accessor. Eight new
accessors: `learner_g` / `learner_m` on all four (only `learner_g` on BLP,
which has no propensity term), plus `learner_r` on IIVM — the package's only
third slot.

Gates: `moonbit_doubleML/expand_v153b_test.mbt`, 4 tests.

### The first version of these gates was measuring the wrong thing

It fitted each estimator twice and compared coefficients. Fitting
`DoubleMLSSM` at `n=400, p=5` **aborts** with a precondition failure at
`logistic.mbt:134`, so the gate was testing the optimiser's convergence, not
the accessor. Rewritten to pattern-match the `LearnerDispatch` enum directly —
`learner_m()` must return the `LogisticRegression` / `LinearRegression`
variant the constructor was given. No fit, no optimiser, no fragile fixture,
and the assertion is precisely the one that matters.

Both arms are still explicit (logistic AND OLS): a hardcoded-OLS accessor
fails the logistic arm, a hardcoded-logistic accessor fails the OLS arm.

Two API details that cost an iteration each, recorded because they are silent
type errors rather than logic bugs:

- `DoubleMLIIVMData::new` takes `x` as a **`Matrix`**, while
  `DoubleMLDIDData::new` takes it as flat `Array[Double]`. Passing the array
  is an `Expr Type Mismatch`, not a coercion.
- `exp` is **not bound** in this package, so a logistic propensity must be
  written as a clipped linear probability. The gate needs stochasticity, not
  the sigmoid shape.

## 7. Still open from the did_cs thread

- `DoubleMLDIDMulti` ignores `t_pre` entirely (`did_multi.mbt:326`, `356`,
  `396`), and its `expand_gt_keyword` (`:210-275`) still encodes the
  pre-v0.150.0 convention (`t_pre = g`, `t > g`), so `"standard"` **aborts** on
  the canonical 2-period fixture via `require(resolved.length() > 0)` at
  `did_multi.mbt:117`.
- The port's `DoubleMLDIDCS` `(group, period)` cell grid vs. upstream's
  panel-level, group-less shape — still unanswered.
