"""Is upstream's DoubleMLPQ reproducible ACROSS processes, and does seeding fix it?

`_verify/PQ_CORRECTION_1560.md` records that upstream's `DoubleMLPQ` drifts
~1e-2 across processes on identical data, and that this drift is what forced
four claims in this audit to be retracted: any gap below ~1e-2 could not be
separated from it.

That makes this the highest-value repair available -- fixing the instrument
recovers the ability to measure at all.

Within a single process the pinned-split path was verified bit-reproducible
earlier, so the variation must be process-global state. Two candidates:

  1. unseeded global `numpy.random` (i.e. legacy `np.random.*` somewhere in
     upstream or a dependency), fixable with `np.random.seed(...)`;
  2. Python hash randomisation (`PYTHONHASHSEED`), fixable only by setting the
     env var before the interpreter starts.

This prints one coefficient and nothing else, so two separate invocations can
be diffed directly.

Run:
    python _verify/gen_v1560_repro_check.py
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

# Candidate fix 1. Harmless if it is not the cause.
if os.environ.get("SEED_GLOBAL_RNG", "1") == "1":
    np.random.seed(0)

N, SEED, B = 1000, 20240, 0.9


def main():
    rng = np.random.default_rng(SEED)
    x = rng.normal(size=N)
    ps = 1.0 / (1.0 + np.exp(-(0.5 + B * x)))
    d = (rng.uniform(size=N) < ps).astype(float)
    y = 1.0 * d + 0.5 * x + rng.normal(size=N) * 0.5

    dd = DoubleMLData(pd.DataFrame({"X1": x, "y": y, "d": d}), "y", "d")
    smpls = DoubleMLResampling(n_folds=2, n_rep=1, n_obs=N, stratify=None).split_samples()

    out = []
    for norm in (True, False):
        e = DoubleMLPQ(
            dd,
            LogisticRegression(),
            LogisticRegression(),
            treatment=1,
            quantile=0.5,
            n_folds=2,
            n_rep=1,
            normalize_ipw=norm,
        )
        e.set_sample_splitting(smpls)
        e.fit()
        out.append(f"{norm}:{float(np.asarray(e.coef).ravel()[0])!r}")

    print(f"pyhashseed={os.environ.get('PYTHONHASHSEED', 'unset')} "
          f"seeded={os.environ.get('SEED_GLOBAL_RNG', '1')} "
          f"npseed={np.random.seed.__name__} " + " ".join(out))


if __name__ == "__main__":
    main()