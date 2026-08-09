"""Cross-check the MoonBit SSM score with a hand-rolled Python implementation.

Bug #1 fix: the g_d1 / g_d0 cross-fitted learners are now trained on
`X` (without the `pi_hat` column) — the upstream MAR score uses the
pre-screening DML, not the augmented `xpi` design. The `pi_hat` is
still estimated, clipped, and used in the score formula, but it is no
longer a feature in `g`.
"""
from __future__ import annotations

import numpy as np
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import KFold


def reference(x, y, d, s, folds, clip=1e-6):
    n = len(y)
    pi = np.zeros(n); m = np.zeros(n); gd1 = np.zeros(n); gd0 = np.zeros(n)
    for tr, te in folds:
        m[te] = LinearRegression().fit(x[tr], d[tr]).predict(x[te])
        xd = np.column_stack((x, d))
        pi[te] = LinearRegression().fit(xd[tr], s[tr]).predict(xd[te])
        # Bug #1 fix: g_d1 / g_d0 use X only (no pi column)
        for dv, out in ((1.0, gd1), (0.0, gd0)):
            ids = tr[(d[tr] == dv) & (s[tr] == 1.0)]
            if len(ids):
                out[te] = LinearRegression().fit(x[ids], y[ids]).predict(x[te])
    pi = np.clip(pi, clip, 1 - clip); m = np.clip(m, clip, 1 - clip)
    pa = -np.ones(n)
    pb = d*s*(y-gd1)/(m*pi)+gd1 - ((1-d)*s*(y-gd0)/((1-m)*pi)+gd0)
    theta = -pb.mean()/pa.mean(); psi = theta*pa+pb
    se = np.sqrt((psi**2).mean()/(pa.mean()**2*n))
    return theta, se


def main():
    rng = np.random.default_rng(1111); n, p = 500, 5
    x = rng.standard_normal((n, p)); d = (rng.uniform(size=n) > .5).astype(float)
    v = rng.standard_normal(n); s = (d + .5*x[:, 0] + v > 0).astype(float)
    y = d + .3*x[:, 0]*d + .3*rng.standard_normal(n)
    folds = list(KFold(2, shuffle=True, random_state=3141).split(x))
    theta, se = reference(x, y, d, s, folds)
    print(f"hand-rolled SSM (Bug #1 fix, no-pi g design): theta={theta:.8f}, se={se:.8f}, ci=[{theta-1.96*se:.8f}, {theta+1.96*se:.8f}]")
    # the SSM reference uses MAR; theta should be near 1.0 with the fix
    assert abs(theta - 1.0) < 0.1, f"theta={theta} too far from 1.0"
    assert 0.0 < se < 0.2, f"se={se} out of band"
    print("SSM reference checks passed")

if __name__ == "__main__":
    main()
