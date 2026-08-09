# TODO #7 — Producer handoff (MoonBit side)

> Producer: moonbit-coder session
> Verifier dispatch source: `_verify/dispatch.md` line 40
> Contract source: parent prompt for TODO #7 (MoonBit side only — the Python
> `validate_*.py` half is TODO #7's other leg and belongs to `coder` agent)

---

## Scope of change

**One file touched:** `cmd/main/main.mbt`
**Files explicitly NOT touched** (per contract):
- `plr.mbt`, `irm.mbt`, `pliv.mbt`, `iivm.mbt`, `did.mbt` (any estimator)
- `aggregator.mbt`
- all `*_test.mbt` (no test changes)
- all `validate_*.py` (Python side is the other agent's leg)

## What was added

For each of **PLR / IRM / PLIV / IIVM / DID**, a `n_rep=5` fit+print block was
inserted **immediately after** the existing `n_rep=1` block. Each new block
uses the same data object as the matching `n_rep=1` block:

| Estimator | New `let` pair        | Data passed             | Section header                            |
|-----------|-----------------------|-------------------------|-------------------------------------------|
| PLR       | `model5`, `fitted5`   | `data` (DoubleMLData)   | `=== MoonBit DML PLR (n_rep=5) ===`       |
| IRM       | `irm5`, `irm_fitted5` | `data` (DoubleMLData)   | `=== MoonBit DML IRM (n_rep=5) ===`       |
| PLIV      | `pliv5`, `pliv_fitted5` | `pliv_data` (DoubleMLPLIVData) | `=== MoonBit DML PLIV (n_rep=5) ===` |
| IIVM      | `iivm5`, `iivm_fitted5` | `iivm_data` (DoubleMLIIVMData) | `=== MoonBit DML IIVM (n_rep=5) ===` |
| DID       | `did5`, `did_fitted5` | `did_data` (DoubleMLDIDData) | `=== MoonBit DML DID (n_rep=5) ===`   |

SSM was intentionally NOT extended (the parent prompt only asked for the 5
estimators listed). The existing `n_rep=1` SSM block is left untouched.

## Contract literals — verified exact

Each new section's body is **exactly** the two lines required by the contract,
in this order, with no trailing whitespace, terminated by `\n`:

```
estimated theta (n_rep=5) = {theta_value}
se (n_rep=5) = {se_value}
```

The re.search-friendly section header for each estimator is exactly:

```
=== MoonBit DML PLR (n_rep=5) ===
=== MoonBit DML IRM (n_rep=5) ===
=== MoonBit DML PLIV (n_rep=5) ===
=== MoonBit DML IIVM (n_rep=5) ===
=== MoonBit DML DID (n_rep=5) ===
```

## Seed semantics — matches upstream

Each estimator's `fit()` loops `for r = 0; r < n_rep; r = r + 1` and uses
`kfold(n, n_folds, self.seed + r)` for rep `r`. So passing
`seed=3141, n_rep=5` produces fold seeds `3141, 3142, 3143, 3144, 3145`,
identical to `doubleml.DoubleMLPLR(n_rep=5, draw_seed=3141)`. The median /
`(theta+1.96*se)` aggregation happens inside `aggregator.mbt::aggregate_coef_se`
(unchanged).

## Precise diff of `cmd/main/main.mbt`

5 hunks, each `+5 / -0` lines, anchored on the corresponding `n_obs` line of
the matching `n_rep=1` block:

```diff
@@ PLR n_rep=1 block tail @@
   println("n_obs             = \{fitted.n_obs()}")
+  let model5 = @dml.DoubleMLPLR::new(data, n_folds=2, n_rep=5, seed=3141)
+  let fitted5 = model5.fit()
+  println("=== MoonBit DML PLR (n_rep=5) ===")
+  println("estimated theta (n_rep=5) = \{fitted5.coef()}")
+  println("se (n_rep=5) = \{fitted5.se()}")
 
   // -------- run IRM --------
```

```diff
@@ IRM n_rep=1 block tail @@
   println("n_obs             = \{irm_fitted.n_obs()}")
+  let irm5 = @dml.DoubleMLIRM::new(data, n_folds=2, n_rep=5, seed=3141)
+  let irm_fitted5 = irm5.fit()
+  println("=== MoonBit DML IRM (n_rep=5) ===")
+  println("estimated theta (n_rep=5) = \{irm_fitted5.coef()}")
+  println("se (n_rep=5) = \{irm_fitted5.se()}")
 
   // -------- run PLIV --------
```

```diff
@@ PLIV n_rep=1 block tail @@
   println("n_obs             = \{pliv_fitted.n_obs()}")
+  let pliv5 = @dml.DoubleMLPLIV::new(pliv_data, n_folds=2, n_rep=5, seed=3141)
+  let pliv_fitted5 = pliv5.fit()
+  println("=== MoonBit DML PLIV (n_rep=5) ===")
+  println("estimated theta (n_rep=5) = \{pliv_fitted5.coef()}")
+  println("se (n_rep=5) = \{pliv_fitted5.se()}")
 
   // -------- run IIVM --------
```

```diff
@@ IIVM n_rep=1 block tail @@
   println("n_obs             = \{iivm_fitted.n_obs()}")
+  let iivm5 = @dml.DoubleMLIIVM::new(iivm_data, n_folds=2, n_rep=5, seed=3141)
+  let iivm_fitted5 = iivm5.fit()
+  println("=== MoonBit DML IIVM (n_rep=5) ===")
+  println("estimated theta (n_rep=5) = \{iivm_fitted5.coef()}")
+  println("se (n_rep=5) = \{iivm_fitted5.se()}")
 
   // -------- run DID --------
```

```diff
@@ DID n_rep=1 block tail @@
   println("n_obs             = \{did_fitted.n_obs()}")
+  let did5 = @dml.DoubleMLDID::new(did_data, n_folds=2, n_rep=5, seed=3141)
+  let did_fitted5 = did5.fit()
+  println("=== MoonBit DML DID (n_rep=5) ===")
+  println("estimated theta (n_rep=5) = \{did_fitted5.coef()}")
+  println("se (n_rep=5) = \{did_fitted5.se()}")
 
   // -------- run SSM --------
```

Net change: **+25 lines** (5 sections × 5 lines each). File went from 288 to 313 lines.
Existing `n_rep=1` blocks and all section headers (`=== MoonBit DML PLR (partialling out) ===` etc.)
are byte-for-byte unchanged.

## Verification gates (all PASS)

### `moon fmt` — clean
```
$ moon fmt
moon: Finished. moon: no work to do   (idempotent, exit 0)
$ moon fmt --check cmd/main
moon: Finished. moon: ran 2 tasks, now up to date   (exit 0)
```

### `moon test --deny-warn` — 82/82, 0 warnings, exit 0
```
$ moon test --deny-warn
Total tests: 82, passed: 82, failed: 0.
```
(82 was the pre-TODO-7 baseline; no test files were modified, so test count
delta = 0 as required.)

### `moon check cmd/main` — clean
```
$ moon check cmd/main
moon: Finished. moon: ran 2 tasks, now up to date   (exit 0)
```

### `moon run cmd/main` — stdout (full)

```
=== MoonBit DML PLR (partialling out) ===
true theta_0      = 1
estimated theta   = 1.059679498323697
standard error    = 0.08748694626305013
95% confint       = [0.8882050836481188, 1.2311539129992752]
n_obs             = 500
=== MoonBit DML PLR (n_rep=5) ===
estimated theta (n_rep=5) = 1.0257526243870547
se (n_rep=5) = 0.08812445968805357

=== MoonBit DML IRM (ATE score) ===
true theta_0      = 1
estimated ATE     = 1.0638429441579293
standard error    = 0.09213607748391832
95% confint       = [0.8832562322894495, 1.2444296560264092]
n_obs             = 500
=== MoonBit DML IRM (n_rep=5) ===
estimated theta (n_rep=5) = 1.023254084461407
se (n_rep=5) = 0.08841856761474985

=== MoonBit DML PLIV (partialling out, single IV) ===
true theta_0      = 1
estimated theta   = 1.0077271601796967
standard error    = 0.06295553068486155
95% confint       = [0.884334320037368, 1.1311200003220252]
n_obs             = 500
=== MoonBit DML PLIV (n_rep=5) ===
estimated theta (n_rep=5) = 1.0137435213460502
se (n_rep=5) = 0.0609897351577854

=== MoonBit DML IIVM (LATE score) ===
true LATE         = 1
estimated LATE    = 0.9680707042247717
standard error    = 0.19499535368291182
95% confint       = [0.5858798110062645, 1.350261597443279]
n_obs             = 500
=== MoonBit DML IIVM (n_rep=5) ===
estimated theta (n_rep=5) = 0.9509542116473345
se (n_rep=5) = 0.1980188130213391

=== MoonBit DML DID (observational score) ===
true theta_0      = 1
estimated theta   = 0.9981487472239836
standard error    = 0.010132674351342269
95% confint       = [0.9782887054953527, 1.0180087889526144]
n_obs             = 500
=== MoonBit DML DID (n_rep=5) ===
estimated theta (n_rep=5) = 1.0012614738705088
se (n_rep=5) = 0.009337764397987088

=== MoonBit DML SSM (MAR score) ===
true theta_0      = 1
estimated theta   = 0.9341397181922589
standard error    = 0.04173289626086917
95% confint       = [0.8523432415209553, 1.0159361948635626]
n_obs             = 500
```
exit 0.

### Re.search sanity (Python regex)

The Python `coder` agent can parse with:
```python
import re
pat_header  = re.compile(r"^=== MoonBit DML (PLR|IRM|PLIV|IIVM|DID) \(n_rep=5\) ===\s*$", re.M)
pat_theta   = re.compile(r"^estimated theta \(n_rep=5\) = (.+)$", re.M)
pat_se      = re.compile(r"^se \(n_rep=5\) = (.+)$", re.M)
```

All 5 expected headers present, all 10 expected data lines present.
Header position: each new `n_rep=5` header appears **immediately after** the
matching `n_rep=1` block's `n_obs` line and **before** the next estimator's
`println("")` separator (which is the source for the blank line in stdout).

### Comparison of n_rep=1 vs n_rep=5 (sanity)

| Estimator | theta (n_rep=1) | theta (n_rep=5) | |Δ|    | se (n_rep=1) | se (n_rep=5)    | |Δ|     |
|-----------|----------------:|----------------:|-------:|------------:|---------------:|--------:|
| PLR       | 1.059679498     | 1.025752624     | 0.034  | 0.087486946 | 0.088124460    | 0.00064 |
| IRM       | 1.063842944     | 1.023254084     | 0.041  | 0.092136077 | 0.088418568    | 0.00372 |
| PLIV      | 1.007727160     | 1.013743521     | 0.006  | 0.062955531 | 0.060989735    | 0.00197 |
| IIVM      | 0.968070704     | 0.950954212     | 0.017  | 0.194995354 | 0.198018813    | 0.00302 |
| DID       | 0.998148747     | 1.001261474     | 0.003  | 0.010132674 | 0.009337764    | 0.00079 |

All deltas are within the "≤ 0.05" sampling-noise budget the dispatch
specifies for `n_rep=5` vs `n_rep=1` (TODO #3 acceptance criterion). PLR, IRM
edge a bit higher (0.03–0.04) but stay well under 0.05.

## Logs written for the verifier

- `_verify/TODO-7-mb-test.log` — full `moon test --deny-warn` output
- `_verify/TODO-7-mb-run.log`  — full `moon run cmd/main` output
- `_verify/TODO-7-handoff.md`  — this file

## Verifier replay steps

```powershell
cd D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit
moon fmt --check cmd/main     # expect: "no work to do", exit 0
moon test --deny-warn         # expect: 82/82, exit 0
moon run cmd/main             # expect: 5 new n_rep=5 blocks present, exit 0
```

If `re.search` of the run output with the two regexes above yields 5 headers
+ 10 data lines (10 = 5 θ + 5 se), and the `n_rep=1` blocks are byte-for-byte
identical to the pre-TODO-7 baseline, the MoonBit side of TODO #7 is complete.
