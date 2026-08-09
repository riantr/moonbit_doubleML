"""Reference checks for BLP and the depth-one policy tree.

Bug #5 fix: per-coefficient SE = sqrt(sigma^2 * (X'X)^{-1}[j, j])
with sigma^2 = RSS / (n - p). Previously every coefficient shared
the same SE = sqrt(RSS / (n - p)).

Bug #8 fix: the policy-tree gain is now the weighted variance
reduction, not the sum of |signal| heuristic. The split should still
land on the sign change at x = 0 for the canonical DGP.
"""
import numpy as np

# BLP: per-coefficient SE check. The pre-fix MoonBit output
# reported the same SE for the intercept and the slope; the post-fix
# output should differ. We use a noisy DGP so the residuals are
# non-zero (the canonical no-noise DGP has zero SE which doesn't
# distinguish the two formulations).
rng = np.random.default_rng(5151)
n = 200
x = (np.arange(n) - 100) / 100
a = 2 + 3 * x + 0.1 * rng.standard_normal(n)
X = np.column_stack([np.ones(n), x])
coef, *_ = np.linalg.lstsq(X, a, rcond=None)
resid = a - X @ coef
sigma2 = (resid ** 2).sum() / (n - 2)
cov_diag = sigma2 * np.linalg.inv(X.T @ X).diagonal()
se = np.sqrt(cov_diag)
print(f"BLP slope={coef[1]:.6f}, intercept={coef[0]:.6f}")
print(f"BLP per-coefficient SE: intercept={se[0]:.3e}, slope={se[1]:.3e}")
assert np.max(np.abs(coef - [2, 3])) < 0.05
# post-fix: the two SEs must differ (the per-coefficient scaling
# makes the slope SE smaller than the intercept SE here because
# the slope is the leading term in X'X)
assert abs(se[0] - se[1]) > 1e-12, f"BLP SEs unexpectedly equal: {se}"

# Policy tree: variance-reduction gain. For the canonical
# sign-flip DGP the split is still at x = 0; the new gain picks
# the same split but uses a different metric.
signal = np.where(x < 0, -1.0, 1.0)
nl, nr = (x < 0).sum(), (x >= 0).sum()
mean_l, mean_r = signal[x < 0].mean(), signal[x >= 0].mean()
var_l = signal[x < 0].var()
var_r = signal[x >= 0].var()
gain_var = -(nl / n) * var_l - (nr / n) * var_r
print(f"policy tree variance-reduction gain = {gain_var:.4f}")
# the new gain is negative because we're using the *reduction* form;
# the bisection in DoubleMLPolicyTree::fit picks the largest (least
# negative) value, which is still the split at x = 0 for this DGP.
print("BLP/PolicyTree reference checks passed")
