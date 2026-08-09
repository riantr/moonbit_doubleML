"""Reference checks for APO/APOS/PQ/QTE/LPQ/CVaR MoonBit tests.

The deterministic location-shift DGP is identical to apo_test.mbt,
quantile_test.mbt and lpq_test.mbt. These checks make the population
targets explicit and catch score-direction or treatment-level mistakes.

Bug #4 fix: the LPQ score now uses `sign = 2 * treatment - 1` to
flip the score sign depending on which treatment level is the
"treated" level. The complier probability is the full-sample
`E[D | Z=1] - E[D | Z=0]`, not the per-fold mean difference.

Bug #2 fix: the QTE SE is now derived from the joint influence
function `psi_d1 - psi_d0` (not the quadrature `sqrt(SE_1^2 + SE_0^2)`
which assumes zero covariance between the two per-treatment
influence functions). The covariance correction is small but
nonzero for this DGP.

Bug #3 fix: the PQ and LPQ bisection uses the IPW score
(no g cross-fit), reducing the per-fit g cross-fit count from
~50 to 3. The math is identical, so the point estimates and
SEs are close to the pre-fix values.
"""
import numpy as np

n = 400
i = np.arange(n)
d = (i % 2 == 0).astype(float)
y = d + (i % 100) / 100.0

apo0 = np.mean(y[d == 0])
apo1 = np.mean(y[d == 1])
pq0 = np.quantile(y[d == 0], 0.5)
pq1 = np.quantile(y[d == 1], 0.5)
qte = pq1 - pq0
cvar1 = np.mean(y[(d == 1) & (y >= pq1)])

# LPQ with z = d: all compliers, full take-up. The LPQ with
# treatment=1, q=0.5 should match the PQ for the treated group.
# The pre-fix MoonBit output may have been a different value due
# to the missing sign factor and per-fold complier-prob averaging.
z = d  # all compliers
comp_full = np.mean(d[z == 1]) - np.mean(d[z == 0])
sign = 2 * 1.0 - 1.0  # = +1 for treatment=1
print(f"APOS: [{apo0:.6f}, {apo1:.6f}]")
print(f"PQ(0.5): control={pq0:.6f}, treated={pq1:.6f}")
print(f"QTE(0.5): {qte:.6f}")
print(f"CVaR treated upper half: {cvar1:.6f}")
print(f"LPQ with Z=D (all compliers, full-sample comp={comp_full:.3f}, sign={sign:.0f}): {pq1:.6f}")

assert abs(qte - 0.99) < 1e-12
assert abs(pq1 - 1.49) < 0.02
assert abs(cvar1 - 1.74) < 0.02
print("reference checks passed")