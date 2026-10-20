# Port-vs-upstream constructor default divergences — v0.154.x

> **Re-audited 2026-10-20 against the `v0.164.9` tree.** Written in the
> v0.154.0 round; committed 2026-10-20 in `5b0b364` (v0.164.4). The
> **divergence table itself is exact** — every row and every site count still
> measures true. What had rotted is the **scope**, the **line pointers**, and
> the `score` callout, which quoted §2 of
> `SCORE_VOCABULARY_1550.md` before that document was corrected.
> Method (shipped, tracked): `_verify/_audit_r15_defaults_1650.py`.
>
> | | as written (v0.154.0) | now (`v0.164.9`) |
> |---|---|---|
> | `.mbt` files scanned | 216 | **220** |
> | `DoubleMLXxx::new` definitions | 34 | 34, unchanged |
> | the divergence table | 6 diverging parameters | **unchanged** — every row re-measured |
> | `did.mbt` `require(n_folds <= data.n_obs())` | `:245` | **`:276`** |
> | `did_cs.mbt` — `nu2` / `rr` formulas | `:1388` / `:1394` | **`:1390` / `:1394`** (`:1394` unchanged) |
> | `did_cs.mbt` — the `1 / mean(d1t0)` division | `:1328` | **`:1407`** |
> | `did_cs.mbt` — `let ti = self.data.t[i].to_double()` | `:1347` | **`:1426`** (also `:1455`, `:1489`) |
> | `did_cs.mbt` — the four condition masks | `:1259-1275` | **`:1334-1345`** |
> | `did_cs.mbt` — the "MAY be NaN" note | `:635` | **`:667`** |
> | the `score` callout | "the port's accepted set and upstream's intersect only at `\"IV-type\"`" | **withdrawn** — see §"the score callout" below |
>
> **What is NOT verified here.** No estimator was re-run. The `nu2` / `sigma2`
> / ATT measurements below are quoted from the original record and were not
> reproduced. The method scripts the record names
> (`_verify/_upstream_defaults_1540.py`, `_verify/_enum_all_defaults_1540.py`)
> and the raw capture (`_verify/_upstream_defaults_1540.txt`) were **not
> tracked**; they are now tracked, and the capture was re-encoded UTF-8 and
> regenerated so it is byte-identical to the script's current output.

**Measured, not recalled.** Upstream values come from
`_verify/_upstream_defaults_1540.py`, which calls `inspect.signature` on the
**installed** `doubleml 0.11.3`. Port values come from
`_verify/_enum_all_defaults_1540.py`, which parses every
`pub fn DoubleMLXxx::new(` body in **220** `.mbt` files with balanced-paren
slicing (comments stripped first, so a commented-out default cannot be
counted).

Raw upstream capture: `_verify/_upstream_defaults_1540.txt`.

## Why this document exists

The learner-default audit only ever looked at `ml_g` / `ml_m` / `ml_l` /
`ml_r`. But the objective is "the remaining defaults", and these are defaults
too — and several of them are places where the port **measurably diverges from
upstream**, not merely chooses differently.

Reading the upstream library rather than recalling it is the whole point. The
first version of the upstream script imported `doubleml.dml.did` and died with
`ModuleNotFoundError`: 0.11.3 does not use a `doubleml.dml.*` layout at all
(submodules are `double_ml`, `did`, `irm`, `plm`, `rdd`, …, with every
estimator re-exported at the top level). A remembered layout would have
produced the same confident, wrong answer.

## Divergences

| parameter | upstream 0.11.3 | this port | port sites |
|---|---|---|---|
| `n_folds` | **5** | **2** | **17 of 19** |
| `in_sample_normalization` | **True** | **false** | **6** |
| `trimming_threshold` → `propensity_clip` | **0.01** | **1.0e-6** | **14** |
| `n_folds_inner` | **5** | **2** | 1 |
| `normalize_ipw` | `False` (IRM/IIVM/APO/SSM), `True` (CVAR/PQ/QTE) | `false` ×2, `true` ×1 | 3 |
| `score` | per-estimator (`'ATE'`, `'LATE'`, `'CVaR'`, `'PQ'`, `'missing-at-random'`, `'observational'`, `'nuisance_space'`) | `'observational'` ×4, `'nuisance_space'` ×1, `'partialling out'` ×1 | 6 |

> **CORRECTED by `_verify/SCORE_VOCABULARY_1550.md`.** The `score` row above
> counts only constructor defaults (bodies of `::new`), which is why it lists
> `'partialling out'` ×1 and misses the three `'partialling-out'` (hyphen)
> sites in `plr.mbt:417`, `plr.mbt:676` and `tune.mbt:355` — those are `fit`
> parameters, not constructor defaults. That scoping choice was never stated in
> this table and reads as a complete census; it is not. Upstream's real
> `valid_scores` per estimator are in `SCORE_VOCABULARY_1550.md`.
>
> **The sentence that quoted a single intersection is WITHDRAWN.** It claimed
> that the port's accepted set and upstream's shared only the `"IV-type"`
> spelling. That was the `DoubleMLPLR`-scoped intersection, when the port's
> accepted set was `{partialling-out, iv-type, IV-type}`. The port now also
> accepts `"partialling out"` (v0.155.0, `8308f09`), so for `DoubleMLPLR` the
> intersection is `{partialling out, IV-type}` — two spellings, not one. The
> intersection is **per estimator**, and `SCORE_VOCABULARY_1550.md` now
> tabulates it that way.

Matching upstream already: `n_rep = 1` (16 sites), `seed = 3141` (19 sites,
port-specific), `quantile = 0.5`, `treatment = 1`, `anticipation_periods = 0`,
`control_group = 'never_treated'`.

## The one that is already known to be wrong, and is still shipping

**`in_sample_normalization`** is upstream `True` and this port `false` at all
6 sites — and this repository has already measured that the port's value
selects the wrong branch. `expand_v131_test.mbt`, GATE 1 header:

> This is the `observational`, `in_sample_normalization = false` branch -- the
> one the port's default arguments select, i.e. **the one that was wrong**.

It is currently masked because every gate that checks the sensitivity elements
passes the flag explicitly.

### MEASURED blast radius of flipping it — and it cuts BOTH ways

`did_cs.mbt:1390` and `:1394` select between two materially different formulas
for `m_alpha` and `rr`. Measured on `make_did_cs_CS2021(800, 3, 1.0, seed)`,
true ATT = 1.0:

| seed | `nu2` false (port default) | `nu2` true (upstream) | `sigma2` both | ATT false | ATT true |
|---|---|---|---|---|---|
| 3141 | 21.3216 | **NaN** | 1.8855 | 2.7275 | **1.1862** |
| 7 | 20.8715 | **NaN** | 1.8882 | −8.0879 | **−3.4174** |
| 314 | 20.7751 | **NaN** | 2.1904 | 6.5136 | **2.6220** |
| 2024 | 20.1136 | **NaN** | 2.3307 | 1.0986 | 1.0904 |

**A flip is NOT a clean improvement, and must not be presented as one.**

*For* the flip: the ATT moves sharply toward the true 1.0 at every seed
(2.73 → 1.19, −8.09 → −3.42, 6.51 → 2.62). The `false` branch's ATTs are the
same values v0.152.0 measured when it found `max |att − 1.0| = 14.41`.

*Against* the flip: **`nu2` is NaN on all four seeds** under the upstream
branch. The `true` formula divides by `mean(d1t0)` (`did_cs.mbt:1407`), which is
zero on this fixture's empty `(d=1, t=0)` cell — the structural emptiness
recorded in the v0.147.0 header. So the flip would trade a finite `nu2` for a
NaN one, on the very estimator whose sensitivity analysis this release thread
has been building.

`sigma2` is **identical** under both settings at every seed, so it is
unaffected either way.

**Therefore: do not flip this default on the evidence so far.** The
`in_sample_normalization = true` branch is the upstream-faithful one *and* it is
broken on staggered panels with an empty `(d=1, t=0)` cell. Fixing the NaN (or
documenting when it is correct — `did_cs.mbt:667` already argues NaN can be
correct here) has to come before the default can move.

### Is the NaN a formula bug, or a consequence of the empty cell? — MEASURED

A control run settles it. `make_did_CS2021(1600, 3, 1.0, 3141)` has occupancy
**300 / 200 / 100 / 200** — all four `(d, t)` cells occupied — against the
canonical fixture's **400 / 200 / 0 / 200**.

| panel | `(d=1,t=0)` cell | `nu2` isn=true | `nu2` isn=false | `sigma2` (both) |
|---|---|---|---|---|
| 4-period | **occupied** | **−112652.994** | −60.071 | 2.4989 |
| 2-period | **empty** | **NaN** | 21.322 | 1.8855 |

**The NaN is caused by the empty cell, not by a broken formula.** The upstream
branch returns a finite value wherever `mean(d1t0)` is defined. So
`did_cs.mbt:667`'s "MAY be NaN, AND THAT IS CORRECT" survives — with the
mechanism stated precisely: it is structural, not arithmetic error.

**But the control run raises a second, larger problem.** Where the branch *is*
finite it returns **−112652.99** against the `false` branch's **−60.07** — a
factor of **~1875×**, and negative where a variance-like element should be
positive. So the upstream branch is not merely NaN on empty cells; where it does
produce a number, that number is on a scale that makes it unusable as a
variance estimate. Both ATTs also move toward truth under `true`
(4-period 1.154 vs 1.417; 2-period 1.186 vs 2.728, true ATT 1.0), so the
trade-off is now fully characterised:

| | ATT quality | `nu2` quality |
|---|---|---|
| `false` (port default) | worse recovery | finite and moderate |
| `true` (upstream default) | **better recovery** | NaN on empty cells, ~1875x out of scale otherwise |

That is a genuine unresolved modelling question, not a default flip. It needs
its own investigation of the `true` formula's normalisation before the default
is worth changing.

## ROOT CAUSE FOUND — and it is not a normalisation bug

`did_cs.mbt:1426` reads

```moonbit
let ti = self.data.t[i].to_double()
```

and then uses `ti` as if it were a **0/1 post-treatment indicator**:

```moonbit
let b = (1.0 - di) * ti
let c = di * (1.0 - ti)
let e = di * ti
_s11 += e            ->  _m11 = mean(d * t)
_s10 += c            ->  _m10 = mean(d * (1 - t))
```

That is exact on a 2-period panel, where the period labels happen to be
`[0, 1]`. It is **meaningless on a multi-period panel**, where `t` is the period
label `0, 1, 2, 3` and `1 - ti` is *negative* for `t = 2, 3`.

MEASURED by accumulating the same sums directly from the panel's `d` and `t`
(no fitting, so this is pure arithmetic):

| panel | `t` range | `_m11` | `_m10` | `1/_m11` | `1/_m10` |
|---|---|---|---|---|---|
| 4-period | **[0, 3]** | 1.0625 | **−0.5** | 0.9412 | **−2** |
| 2-period | [0, 1] | 0.25 | **0** | 4 | **Infinity** |

So **both** symptoms have one cause:

* **2-period + `isn=true` → NaN**: `_m10 = 0` (the `(d=1, t=0)` cell is empty),
  so `1/_m10 = Infinity`.
* **4-period + `isn=true` → −112653**: `_m10 = −0.5`, a *negative* denominator
  where a positive frequency was assumed.

### CORRECTION: this is NOT a one-line fix, and I was wrong to say it was

An earlier report in this file described the fix as narrow — "make `t[i]` yield
a 0/1 post-treatment indicator". Reading the g-function construction refutes
that. `did_cs.mbt:1334-1345` builds the four condition masks like this:

```moonbit
let ti = self.data.t[i]
if ti == 0 {
  ... cond_d0_t0 / cond_d1_t0
} else if ti == 1 {
  ... cond_d0_t1 / cond_d1_t1
}
// ti >= 2 falls through and is DISCARDED
```

The masks are **hardcoded to periods 0 and 1**. On the 4-period panel every row
with `t >= 2` enters no condition at all and is dropped from all four
g-functions. That matches the v0.147.0 census exactly: occupancy
300 / 200 / 100 / 200 = **800** of a **1600**-row panel — exactly half.

So the panel-level sensitivity path is not mis-normalised on a multi-period
panel; it is **structurally inapplicable** to one. It silently discards half the
panel and then treats the surviving period labels as binary. Fixing it is
therefore a redesign — per-cell conditions on `t == t_value_pre` /
`t == t_value_eval` — not a one-line substitution, and it would change reported
numbers.

### The finding that outranks both the default and the fix

`DoubleMLDIDCS` currently reports `sigma2` and `nu2` **on a multi-period panel
computed from half the rows with a malformed indicator**. That is a live
correctness problem for any staggered-adoption user, and it is invisible
because every existing gate either uses the canonical 2-period fixture or only
asserts that the sensitivity values are finite and non-degenerate.

`sigma2` feeds the sensitivity interval, so this outranks the
`in_sample_normalization` default question entirely: the default is a tuning
choice, whereas this is a number that is wrong on a whole class of panels.

**Recommended order: restrict or document this path to 2-period panels first
(a small, honest, non-behavioural change), and treat multi-period sensitivity
elements as unimplemented until the per-cell redesign lands.**

## `n_folds` — MEASURED, and it is not a preference

Upstream `5` at every estimator read; this port `2` at 17 of 19 sites. The
obvious reading is "the port chose 2 over upstream's 5". **Measurement refutes
that.**

`n_folds = 5` **aborts** on the canonical fixture, at `did.mbt:276`:

```
precondition failed at did.mbt:276:5-276:37
    require(n_folds <= data.n_obs())
```

`DoubleMLDIDCS` builds a per-`(group, period)` `DoubleMLDIDBinary`, each of
which builds an inner `DoubleMLDID` on its **wide-format** subset, and `fit`
aborts if ANY cell has fewer rows than `n_folds`. Probing the bound: `n_folds`
2, 3 and 4 all succeed; 5 aborts. So the binding cell has **exactly 4 rows**.

Upstream's own default is therefore **unattainable** on this fixture. The
port's `2` is not a contract-fidelity deviation, it is what the data forces.
**Verdict: not a defect.**

### The more interesting finding underneath

The estimate is far more sensitive to `n_folds` than to the seed
(true ATT 1.0, canonical cell):

| seed | `n_folds=2` | `n_folds=3` | `n_folds=4` |
|---|---|---|---|
| 3141 | 2.7275 | −0.1145 | 0.3493 |
| 7 | −8.0879 | −7.0415 | −7.9683 |
| 314 | 6.5136 | 0.6427 | −0.9882 |

Seed 3141 swings `2.73 -> -0.11 -> 0.35` purely on the fold split; seed 314
swings `6.51 -> 0.64 -> -0.99`. With a 4-row cell, "which units are held out"
*is* the estimator.

**This retroactively explains v0.152.0.** That release measured
`max |att - 1.0| = 14.41` across 12 seeds and adopted an SE-relative band
(`|att - 1| < 5*se`) instead of an absolute one. With a 4-unit cell the
absolute error is dominated by fold assignment, not by estimator quality — so
the SE-relative band was the only defensible way to assert on this fixture, and
the v0.152.0 decision was right for a reason that was not visible at the time.

**What this means for the fixture, not the estimator.** A 4-unit DIDCS cell
cannot support a meaningful ATT at ANY fold count. The recovery numbers on this
fixture should be read as "the SE correctly widens to cover the instability",
not as "the estimator has 14 units of error". A larger-cell fixture is needed
before any accuracy claim about `DoubleMLDIDCS` is worth making.

## The other divergences

- **`n_folds = 2` vs upstream `5` is not called a defect.** Fewer folds is a
  deliberate, defensible choice (and v0.152.0 already measured that the
  cross-fit is stable across seeds on this package's fixtures). It is a
  divergence, and it needs a decision, not a verdict.
- **`propensity_clip = 1.0e-6` vs `trimming_threshold = 0.01` is a rename plus
  a value change**, and the rename is deliberate — the port's `propensity_clip`
  is the inner `cross_fit_did` numerical-safety clip, whereas upstream's
  deprecated `trimming_threshold` is a different quantity. The 1e-6 value was
  chosen to make `DoubleMLPQ` well-behaved (v0.139.0). So: different meaning,
  not simply a wrong number.
- Nothing here has been changed. Every row is a **measurement**, and the only
  one carrying a "wrong" label is the one the repository had already measured.
