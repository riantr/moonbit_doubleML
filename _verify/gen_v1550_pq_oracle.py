"""Oracle probe for the `normalize_ipw` divergence on DoubleMLPQ.

Question: upstream `pq.py:124` defaults `normalize_ipw=True` and applies it
at `pq.py:367-368` (inside the bisection that solves for theta) and
`:414-415` (the final nuisance). The MoonBit port has no `normalize_ipw` on
`DoubleMLPQ` at all and never normalizes.

How much does that actually cost? This runs upstream's OWN `DoubleMLPQ` twice
-- once at the default `normalize_ipw=True`, once at `False` -- on identical
data with PINNED splits, across a range of confounding strengths.

Two things this must establish before the number means anything:

  1. Upstream does not seed its splits. Measured run-to-run noise on the
     first fixture was 2.7e-3. That is the yardstick: a gap smaller than
     that is not a difference a user could observe.
  2. `_normalize_ipw` reweights, so the gap should grow as the propensity
     gets more extreme. A single DGP cannot distinguish "this never matters"
     from "this matters here by luck".

Run from the repo root:
    python _verify/gen_v1550_pq_oracle.py
"""

import os
import sys

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "_upstream_ps", "doubleml-0.11.4"))

from doubleml import DoubleMLData, DoubleMLPQ  # noqa: E402
from doubleml.utils.resampling import DoubleMLResampling  # noqa: E402
from sklearn.linear_model import LogisticRegression  # noqa: E402

# Added after `_verify/REPRO_REPAIR_1560.md` established that upstream's
# DoubleMLPQ is not reproducible across processes without numpy's GLOBAL rng
# seeded. The first run of this sweep was contaminated; every `|gap|` and
# `fold_noise` number it produced is void and is being re-measured.
np.random.seed(0)


def dgp(n=2000, seed=3141, b=0.9):
    """Confounded DGP with a known conditional median.

    ps = sigmoid(0.5 + b*x);  d ~ Bernoulli(ps)
    y  = 1.0*d + 0.5*x + eps,  eps ~ N(0, 0.5)

    `b` is the confounding STRENGTH. Larger b pushes the propensity toward
    0 and 1, which is the regime where IPW normalization has the most to do.
    The conditional median of Y given (D=1, X=x) is 1.0 + 0.5x.
    """
    rng = np.random.default_rng(seed)
    x = rng.normal(size=(n, 1))
    ps = 1.0 / (1.0 + np.exp(-(0.5 + b * x.ravel())))
    d = (rng.uniform(size=n) < ps).astype(float)
    y = 1.0 * d + 0.5 * x.ravel() + rng.normal(size=n) * 0.5
    return x, y, d, ps


def scalar(v):
    """`coef` / `se` are shape-(1,) numpy arrays in this version."""
    return float(np.asarray(v).ravel()[0])


def run(n, b, seed):
    x, y, d, ps = dgp(n, seed, b)
    dd = DoubleMLData(pd.DataFrame({"X1": x.ravel(), "y": y, "d": d}), "y", "d")

    def make(normalize):
        # Upstream's own tests use plain sklearn learners for PQ
        # (tests/test_model_defaults.py:33), so nothing here is invented.
        return DoubleMLPQ(
            dd,
            LogisticRegression(),
            LogisticRegression(),
            treatment=1,
            quantile=0.5,
            n_folds=2,
            n_rep=1,
            normalize_ipw=normalize,
        )

    sampler = DoubleMLResampling(n_folds=2, n_rep=1, n_obs=n, stratify=None)
    smpls = sampler.split_samples()

    def pinned(normalize):
        e = make(normalize)
        e.set_sample_splitting(smpls)
        return e

    t = pinned(True)
    t.fit()
    f = pinned(False)
    f.fit()

    # One un-pinned pair, to measure this fixture's own fold noise. Without
    # this the gap below has no scale: a 4e-4 gap means nothing without
    # knowing that an unpinned re-run moves 2.7e-3.
    u1 = make(True)
    u1.fit()
    u2 = make(True)
    u2.fit()

    return {
        "c_true": scalar(t.coef),
        "c_false": scalar(f.coef),
        "se_true": scalar(t.se),
        "ps_min": float(ps.min()),
        "ps_max": float(ps.max()),
        "fold_noise": abs(scalar(u1.coef) - scalar(u2.coef)),
    }


def main():
    n = 2000
    print(f"upstream DoubleMLPQ, n={n}, seed=3141, q=0.5, n_folds=2, pinned splits")
    print()
    print("b     ps range            coef(True)     coef(False)    |gap|      fold_noise  gap/noise")
    for b in [0.5, 0.9, 1.5, 2.5, 4.0]:
        r = run(n, b, 3141)
        gap = abs(r["c_true"] - r["c_false"])
        noise = r["fold_noise"]
        ratio = gap / noise if noise > 0 else float("inf")
        print(
            f"{b:<5} [{r['ps_min']:.4f}, {r['ps_max']:.4f}]  "
            f"{r['c_true']:.10f}  {r['c_false']:.10f}  "
            f"{gap:.3e}  {noise:.3e}   {ratio:.3f}"
        )
    print()
    print("READING THE TABLE")
    print("  |gap|        is the size of the port-vs-upstream divergence at this b.")
    print("  fold_noise  is how much upstream moves when you merely re-draw the")
    print("               folds with everything else identical. It is the floor.")
    print("  gap/noise < 1 means the divergence is BELOW the estimator's own")
    print("               run-to-run variability: real, but not observable.")


if __name__ == "__main__":
    main()