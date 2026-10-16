# The quantile estimators: a gate, and an unexplained SE gap that is not a flag gap

_1680 series, continuing from `LPLR_GATE_BLINDNESS_1680.md`._

## What this closes

The coverage census in `FIVE_GATES_FEASIBLE_1680.md` put 12 estimator slots
on an analytic oracle with no upstream gate at all. LPLR took one. This
takes two more:

| slot | was | now |
|---|---|---|
| `DoubleMLPQ` | analytic only | `pyexample_pq.py` |
| `DoubleMLQTE` | analytic only | `pyexample_pq.py` |

Still open on `examples/main`: RDD, LPQ, PolicyTree.

## A different comparison shape from every other gate here

Nothing is emitted and no partition is pinned, because the DGP is **integer
arithmetic only** — every draw is a modulo. Both sides build the arrays from
the same formulas and compare a per-column fingerprint. Per the parity
emitter's own header that is the stronger shape: *two independent
constructions of the same numbers, not one copied from the other*.

The two DGP facts the design doc had already measured are load-bearing and
were carried over unchanged:

* `1.0 * d` in `y`. Without it the true effect is zero, `DoubleMLQTE`
  correctly returns ~0, and that reads as a broken estimator.
* the uniform draw `(i * 104729 + 12345) % 999983`. The original
  `(i * 48271) % 2147483647` never wraps for i < 1000 and correlates with the
  `x` columns, so a fold held one class and every upstream fit raised.

Both learners are classifiers on **both** sides. Upstream's `pq.py:174-175`
checks `ml_g` then `ml_m` with `classifier=True`, and the argument names are
inherited from the PLR family where `ml_g` is the outcome learner — in the
quantile estimators the roles are swapped and the names did not follow. The
port's `ml_l` defaults to a **regressor**, so leaving it alone would not fit
the same problem.

## Results (12 seeds, same list both sides)

Coefficients — the estimand — ride the measured seed-spread band:

| quantity | port | upstream | gap | band | % of band |
|---|---|---|---|---|---|
| `pq_coef` | 1.018888787 | 1.016168926 | 2.720e-03 | 9.726e-03 | 28% |
| `qte[0]_coef` | 1.041323011 | 1.055867575 | 1.454e-02 | 1.966e-02 | 74% |
| `qte[1]_coef` | 1.012140655 | 1.005914376 | 6.226e-03 | 1.157e-02 | 54% |
| `qte[2]_coef` | 0.999378053 | 0.992083343 | 7.295e-03 | 1.147e-02 | 64% |

The upstream means reproduce `PQ_QTE_GATE_DESIGN_1680.md` independently:
`pq_se` 0.019753090 against the doc's 0.0197531, `pq_coef` 1.016168926
against 1.016169. Two separate scripts, same numbers.

**Twelve seeds, not five.** At five seeds `qte[0]_coef` sat at **92% of its
band**. A band estimated from a 5-sample sd is a poor estimate of the spread
itself, and a gate at 92% is a coin flip dressed as a gate.

## The SE gap is systematic, and it is not a flag gap

Every reported standard error is **below** upstream, in the same direction,
across four independent quantities whose seed spread is ~1e-4:

| | port | upstream | ratio |
|---|---|---|---|
| `pq_se` | 0.019393374 | 0.019753090 | 0.9818 |
| `qte[0]_se` | 0.021903492 | 0.024137679 | **0.9074** |
| `qte[1]_se` | 0.020526421 | 0.021223703 | 0.9671 |
| `qte[2]_se` | 0.022076176 | 0.023380184 | 0.9442 |

A consistent direction against a small spread is bias, not noise. Two
candidate causes were measured (`_verify/_pq_se_flag_1680.py`):

| upstream config | `se` mean | `coef[0]` | \|se − port\| |
|---|---|---|---|
| defaults | 0.024086 | 1.0563 | 2.34e-03 |
| `normalize_ipw=False` | 0.024156 | 1.0572 | 2.41e-03 — **wrong way** |
| `trimming_threshold=0.10` | 0.024084 | 1.0563 | 2.34e-03 — no change |
| `trimming_threshold=0.40` | 0.023320 | 1.0753 | 1.57e-03 — breaks the coef |
| `normalize_ipw=False` + `trimming=0.40` | 0.022607 | 1.0701 | 8.61e-04 — breaks the coef |

* **`trimming` is ruled out.** The design doc named it as the likely dominant
  source "while stating that the explanation is a hypothesis and was never
  tested". It was tested. The port's `propensity_clip` is inert below 0.1 on
  this DGP — measured bit-identical output at 1e-6, 1e-2, 0.05 and 0.1, first
  moving at 0.2 — and upstream's `trimming_threshold=0.01` would drop
  nothing. Raising it to 0.40 does close the SE gap, but moves the
  coefficient to 1.0753 against the port's 1.0391, so it is a different
  estimator, not a better-matched one.
* **`normalize_ipw` is ruled out.** It was measured before only on the
  **coefficient**, where the gap was 3.8e-13 — which says nothing about the
  SE. Flipping it upstream moves `se` the *wrong* way.

⇒ The remaining explanation is a genuine difference in how the port computes
the standard error for the quantile estimators. It is **not** a missing
flag. Investigating it is its own piece of work; what matters here is that it
is now bounded and visible rather than absent.

## How the SE is gated, and why not with the seed band

A seed-spread band on the SE is red on every run — a permanently failing CI,
which is worse than recording the defect. The SE rides a **ratio envelope**
`[0.85, 1.05]` around the measured 0.90–0.99, so an SE regression is still
red. Arm M6 exists to prove the envelope is not a rubber stamp: it halves
every reported `se`, and the gate goes red.

## The battery found a real hole

First run: **5/7**. M2 survived.

> M2 changed the `x2` divisor from `498.5` to `499.5`. The self-check
> compared only `pq_treated`, which stayed **447** — the perturbed
> covariates produced the same class count — so the gate went ahead,
> comparing the port's correct rows against upstream's perturbed rows, and
> the coefficient difference landed inside the band. **PASS.**

A class count says "roughly the right number of treated". It does not say the
rows are the rows.

The check is now a per-column fingerprint (`pq_sum_x1`, `pq_sum_x2`,
`pq_sum_d`, `pq_sum_y`) compared to machine epsilon. It caught a real slip on
its first run — the emitter was summing the **control** count where Python
sums `d`, and the gate refused to compare. Second run: **7/7**.

| arm | breaks | result |
|---|---|---|
| M1 | emitter scales a coefficient | KILLED |
| M2 | Python rebuilds `x2` with a wrong divisor | KILLED (fingerprint) |
| M3 | Python rebuilds a different treatment | KILLED (fingerprint) |
| M4 | emitter reports a wrong fingerprint | KILLED (refused) |
| M6 | port halves every `se` | KILLED (envelope bites) |
| M7 | upstream quantile levels permuted | KILLED (index mapping) |
| M5 | CONTROL: seed list reordered | PASS |

M4's first form *weakened* the check and then expected a FAIL. A weakened
check correctly still passes, so that arm could not tell a working gate from
a broken one. It was re-targeted at corrupting the fingerprint, which is the
question that actually matters: is the check load-bearing?

M7 guards a specific hazard — QTE returns one coefficient per quantile, and
pairing `port[k]` with `upstream[k+1]` compares the wrong numbers on both
sides and can still look plausible.
