# PolicyTree vs upstream `doubleml.utils.policytree` — measured 2026-10

This closes the last of the five estimator slots on `examples/main` that shipped
with an ANALYTIC oracle only (RDD, PQ, QTE, LPQ, PolicyTree). PQ/QTE/LPQ are
gated in `pyexample_pq.py`; RDD is measured divergent and deliberately has no
gate (`RDD_PARITY_1680.md`); this file is the PolicyTree record, and the gate
lives in `pyexample_policytree.py`.

Everything below is measured. Where a claim could have been assumed, the
measurement that replaces the assumption is named.

## 1. Where upstream's class actually lives

Not on the `doubleml` top level, and not in `doubleml.dml`. It is
`doubleml.utils.policytree.DoubleMLPolicyTree`, and it is a thin wrapper — it
does not implement a policy tree at all, it delegates:

```python
bin_signal = (np.sign(self._orth_signal) + 1) / 2
abs_signal = np.abs(self._orth_signal)
self._policy_tree.fit(X=self._features, y=bin_signal, sample_weight=abs_signal)
```

with `self._policy_tree = DecisionTreeClassifier(max_depth=self._depth, **self._tree_params)`
and two defaults injected by `setdefault`:

```python
self._tree_params.setdefault("ccp_alpha", 0.01)
self._tree_params.setdefault("min_samples_leaf", 8)
```

So upstream's policy tree *is* a **weighted gini** decision tree: gini on the
binarised signal, sample-weighted by the absolute signal.

## 2. Two call-shape traps

| | port | upstream |
|---|---|---|
| signature | `DoubleMLPolicyTree::new(features, orth_signal, depth~)` | `DoubleMLPolicyTree(orth_signal, features, depth=2, **tree_params)` |
| `features` | `Matrix` | **`pandas.DataFrame`** |
| `orth_signal` | `Array[Double]` | **`numpy.ndarray`**, 1-D, else `TypeError`/`ValueError` |
| default depth | **1** | **2** |

The argument order is **reversed**, and the default depths **differ**. Leaving
depth to its default would have compared a depth-1 tree against a depth-2 tree.
Depth is therefore pinned explicitly on both sides.

There is also no `DoubleMLData.from_df` here — upstream takes the frame
positionally, exactly as with the RDD probe.

## 3. Upstream is non-deterministic unless `random_state` is pinned

Measured, two fits of the same data in one process:

```
random_state=None     leaves={1: (139, 0), 2: (161, 1)}  refit identical=False
random_state=0        leaves={1: (139, 0), 2: (161, 1)}  refit identical=True
random_state=12345    leaves={1: (139, 0), 2: (161, 1)}  refit identical=True
```

`random_state` reaches the underlying classifier through `**tree_params`, so it
is pinned at 0 rather than left to the process-global stream. The gate also
re-fits twice under the pinned seed and asserts the two agree **before** using
that seed for any comparison — a control on the control.

## 4. The two builders are different algorithms

This is the finding that shapes the gate. The port's `policy_tree_build`
(`moonbit_doubleML/blp_policy.mbt:1274`) differs from upstream in four ways:

1. **Threshold.** Port: the column **mean**
   (`threshold = sum(x)/n`, then `x < threshold` goes left). Upstream: a
   **midpoint between two consecutive sorted distinct values**, with
   `x <= threshold` going left.
2. **Criterion.** Port: variance reduction on the **raw** signal,
   `-(nl/n)·var_l - (nr/n)·var_r`. Upstream: gini on `bin_signal`.
3. **Leaf label.** Port: the sign of the mean raw signal (`mean >= 0 -> 1`).
   Upstream: `argmax` of the weighted class counts.
4. **Pruning.** Port has no `min_samples_leaf` and no `ccp_alpha`; upstream
   defaults to 8 and 0.01.

There is a fifth, behavioural, difference: the port takes a split whenever
`gain > best`, and `best` starts at `-1.0e308`, so it **splits a pure
zero-gain node** — a leaf whose signal has no variance is split anyway.
sklearn takes no such split.

## 5. On a two-column design the two disagree on the partition

`sec_blp_policy`'s design (n=300, two columns), port vs upstream at depth 1:

```
port  split_feature = 0        split_value = 0.001        left 149 / right 151
upstr feature=x0               threshold   = -0.069      leaf1 139 -> 0 / leaf2 161 -> 1
rows shared with port-left:      leaf1 = 139   leaf2 = 10
```

The split **feature** agrees. The **partition does not**: 10 rows land on
opposite sides, because the port cuts at the column mean and sklearn cuts at
the sorted-value midpoint.

At depth 2 upstream's `min_samples_leaf=8` binds (one leaf of 12 survives, one
of 31), and the port's depth-2 structure departs further still.

**Consequence: nothing structural can be compared.** A gate asserting equal
thresholds or equal leaf sizes would be permanently red.

## 6. What *is* comparable — and it agrees on the shipped design

The gate compares the **label vector over every row**, the split feature, and
the threshold. The label vector is invariant to all four differences in §4,
including the zero-gain split: a pure node's two halves both carry the same
sign, so splitting it changes the tree and changes no prediction.

The design is `examples/main`'s own PolicyTree design — one column on a
symmetric grid, `signal = sign(z)` — chosen deliberately. It is the
configuration the repository **ships**, and on it the two threshold conventions
coincide, because the grid mean and the midpoint of the two values straddling
zero are the same number.

Measured, both depths:

| quantity | port | upstream | verdict |
|---|---|---|---|
| split feature | 0 | 0 | equal |
| split value (d=1) | -0.0020000000000000087 | -0.0020000000949949026 | rel gap **4.750e-08** |
| split value (d=2) | -0.0020000000000000087 | -0.0020000000949949026 | rel gap **4.750e-08** |
| partition | left 250 / right 250 | leaf1 250 / leaf2 250 | **identical** |
| leaf labels | 0, 1 | 0, 1 | equal |
| probe [-0.5, 0.5] | [0, 1] | [0, 1] | equal |
| label vector, all 500 rows | — | — | **all 500 agree**, ones=250, first 1 at row 250 |

The residual 4.75e-8 is **not** a convention difference. sklearn stores node
thresholds as **float32**; its eps is 1.192e-7, and the observed gap is 0.4× of
that. The port computes in f64. The gate therefore compares the threshold with
a bound of `1e-6` — about 8× the storage gap — and the battery perturbs it by
`1e-4` to prove that bound can actually go red, because the label comparison
alone would **not** catch a threshold that moved without crossing a row.

## 7. What is deliberately *not* compared

**`policy_value()`.** It requires `honest = true`, and its own docstring proves
it telescopes to the plain sample mean of `orth_signal`:

```
sum_k (n_k/n)·theta_k = (1/n)·sum_j y_j = mean(y)
```

so agreeing on it would mean nothing.

**Structure** — leaf ids, leaf counts, per-leaf means. §5 shows the two
disagree on a two-column design, and §4 shows why. Comparing them would assert
a property of neither.

## 8. Battery

`_verify/_pt_battery_1680.py`, **8/8 as expected**, baseline PASS:

| arm | breaks | gate |
|---|---|---|
| M1 | emitter perturbs `split_value` by 1e-4 | FAIL — the 1e-6 bound bites |
| M2 | Python rebuilds `z` with a wrong divisor | FAIL (refused) |
| M3 | emitter reports a wrong fingerprint | FAIL (refused) |
| M4 | emitter flips the depth-1 label vector | FAIL |
| M5 | emitter reports the wrong `split_feature` | FAIL |
| M6 | emitter corrupts the probe vector | FAIL |
| M7 | **one** row of the depth-2 labels flipped | FAIL |
| M8 | CONTROL — `DEPTHS` reordered | PASS |

M7 is the arm that catches a gate looping over depths but comparing only the
first. M1 is the arm that catches a threshold check that cannot go red.

## 9. The claim this gate makes, stated honestly

It establishes that **the shipped configuration agrees exactly**: same feature,
same partition, same leaf labels, same predictions on every row, threshold
equal to float32 storage. It does **not** establish that the port's
`DoubleMLPolicyTree` is the same estimator as upstream's — §5 is the
measurement that says it is not, and closing that gap would mean changing the
port's builder, which is a behavioural change to a shipped estimator and not
something a parity gate may do on its own.
