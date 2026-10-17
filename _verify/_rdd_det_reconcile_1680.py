"""Reconcile the two determinism claims.

The older note says rdrobust is unseeded with a 2.99e-02 spread over four fits.
The newer one says it is bit-reproducible. Both can be true if the difference is
BANDWIDTH SELECTION: the old measurement let rdrobust pick h (bwselect='mserd',
which resamples), the new one passes h=0.5 explicitly.

If that is the mechanism, omitting h must vary across seeds and passing h must
not -- on the SAME design. Measure both.
"""
import numpy as np
from rdrobust import rdrobust

N = 800
H = 0.5


def design():
    u = np.empty(N); z = np.empty(N); y = np.empty(N)
    for i in range(N):
        uu = (i + 0.5) / 400.0 - 1.0
        zi = ((i * 6271) % 997) / 498.5 - 1.0
        ei = ((i * 2654435761) % 1000003) / 500001.5 - 1.0
        di = 1.0 if uu >= 0.0 else 0.0
        u[i] = uu; z[i] = zi
        y[i] = 2.0 + uu + 0.5 * zi + 2.0 * di + 0.5 * ei
    return u, z, y


u, z, y = design()


def spread(label, **kw):
    vals = []
    for s in (12345, 1, 7, 99999):
        np.random.seed(s)
        e = rdrobust(y=y, x=u, kernel="tri", **kw).Estimate
        vals.append(float(e["tau.bc"].iloc[0]))
    rng = max(vals) - min(vals)
    print("  %-42s spread %.3e   %s" % (label, rng, vals))
    return rng


print("rdrobust determinism, SAME design, four seeds each")
a = spread("h = 0.5 given explicitly", c=0.0, h=H)
b = spread("h OMITTED -> bwselect='mserd'", c=0.0)
c = spread("h OMITTED, bwselect='none'", c=0.0, bwselect="none")

print()
print("mechanism confirmed: explicit h is deterministic, selection is not: %s"
      % (a == 0.0 and b > 0.0))
print("bwselect='none' without an h is also non-reproducible: %s" % (c > 0.0))
