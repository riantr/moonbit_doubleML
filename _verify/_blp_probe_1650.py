"""Probe: what does `DoubleMLBLP::fit` actually estimate?

The DGP is exactly linear -- `s = 1.5*a + 1.0*b + 0.25*a*b` is linear in
(1, a, b) -- so plain OLS must return (0, 1.5, 1.0). The emitter reports
(0.0683, 1.6057, 0.9668). Either BLP is not plain OLS, or one of these is
wrong. This prints every candidate reference against the emitted values so the
question is answered by arithmetic rather than by reading.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np  # noqa: E402

import parity_helper as ph  # noqa: E402

N = 300


def build():
    a = np.empty(N)
    b = np.empty(N)
    s = np.empty(N)
    for i in range(N):
        ai = ((i * 7919) % 1000) / 500.0 - 1.0
        bi = ((i * 6271) % 997) / 498.5 - 1.0
        a[i] = ai
        b[i] = bi
        s[i] = 1.5 * ai + 1.0 * bi + 0.25 * ai * bi
    return a, b, s


def main():
    sec = ph.section("blp_policy")
    a, b, s = build()
    X = np.column_stack([np.ones(N), a, b])

    print("emitted:")
    for k in ("blp_intercept", "blp_coef_x0", "blp_coef_x1", "blp_se_x0",
              "pt_split_feature", "pt_split_value"):
        print("  %-18s %.17g" % (k, ph.val(sec, k)))
    print()
    print("data check: emitted x0 == python a ? %s"
          % all(x == y for x, y in zip(ph.data(sec, "x0"), a)))
    print("data check: emitted x1 == python b ? %s"
          % all(x == y for x, y in zip(ph.data(sec, "x1"), b)))
    print("data check: emitted s  == python s ? %s"
          % all(x == y for x, y in zip(ph.data(sec, "s"), s)))
    print()

    beta, *_ = np.linalg.lstsq(X, s, rcond=None)
    print("OLS of s on [1,a,b]           : %s" % np.array2string(beta, precision=10))

    resid_full = s - X @ beta
    rss = float((resid_full ** 2).sum())
    n, p = N, 3
    xtx = X.T @ X
    xtx_inv = np.linalg.inv(xtx)
    w = 1.0 / np.diag(xtx)
    meat = np.zeros((p, p))
    for i in range(n):
        xi = X[i][:, None]
        meat += (resid_full[i] ** 2) * (xi @ xi.T)
    hc0 = np.sqrt(np.diag(xtx_inv @ meat @ xtx_inv))
    print("rss = %.17g   n = %d  p = %d" % (rss, n, p))
    print("OLS SE  rss/(n-p)             : %s"
          % np.array2string(np.sqrt(rss / (n - p) * np.diag(xtx_inv)), precision=12))
    print("OLS SE  rss/n                 : %s"
          % np.array2string(np.sqrt(rss / n * np.diag(xtx_inv)), precision=12))
    print("HC0 sandwich                  : %s" % np.array2string(hc0, precision=12))
    print("HC0 * n/(n-p)                 : %s"
          % np.array2string(hc0 * np.sqrt(n / (n - p)), precision=12))
    print("HC0 diag-only, * w            : %s"
          % np.array2string(np.sqrt(w * (X ** 2 * (resid_full ** 2)[:, None]).sum(0)),
                            precision=12))
    print("HC0 diag-only * n/(n-p)       : %s"
          % np.array2string(
              np.sqrt(w * (X ** 2 * (resid_full ** 2)[:, None]).sum(0))
              * np.sqrt(n / (n - p)), precision=12))
    print("emitted blp_se_x0             : %.17g" % ph.val(sec, "blp_se_x0"))
    print("ratio emitted/ols              : %.17g"
          % (ph.val(sec, "blp_se_x0")
             / float(np.sqrt(rss / (n - p) * np.diag(xtx_inv))[1])))

    # The 'precision' reading: pi = E[s^2 x x'] + E[sres^2 x x'], the BLP
    # scaling used for the partial-idiosyncratic-price weight.
    w = s ** 2
    prec = (X * w[:, None]).T @ X / N
    print()
    print("E[x x'] mean                 :\n%s"
          % np.array2string(X.T @ X / N, precision=6))
    print("E[s^2 x x'] (the precision)  :\n%s"
          % np.array2string(prec, precision=6))
    print("its diagonal                  : %s"
          % np.array2string(np.diag(prec), precision=6))
    print("sqrt of its diagonal          : %s"
          % np.array2string(np.sqrt(np.diag(prec)), precision=6))

    # Weighted by the precision instead of OLS.
    try:
        bw = np.linalg.solve(prec, X.T @ s / N)
        print("solve(pi, E[s x])             : %s"
              % np.array2string(bw, precision=10))
    except np.linalg.LinAlgError as e:
        print("solve(pi, E[s x])             : singular (%s)" % e)

    # s/sqrt(pi_jj) normalised, then OLS -- the orthogonal-signal convention.
    sd = np.sqrt(np.diag(prec))
    print()
    print("sd (sqrt diag precision)      : %s" % np.array2string(sd, precision=6))
    beta_sd, *_ = np.linalg.lstsq(X, s / sd[1], rcond=None)
    print("OLS of s/sd_x0 on [1,a,b]     : %s"
          % np.array2string(beta_sd, precision=10))

    # policy tree split rule: threshold = MEAN of the feature, gain =
    # -(nl/n)var_l - (nr/n)var_r, pick the feature with the largest gain.
    print()
    for j, name in ((0, "x0"), (1, "x1")):
        feat = (a, b)[j]
        thr = feat.mean()
        left = feat < thr
        nl, nr = int(left.sum()), int((~left).sum())
        ml, mr = s[left].mean(), s[~left].mean()
        vl = (s[left] ** 2).mean() - ml * ml
        vr = (s[~left] ** 2).mean() - mr * mr
        gain = -(nl / N) * vl - (nr / N) * vr
        print("policy split on %s: mean=%.17g gain=%.17g nl=%d nr=%d"
              % (name, thr, gain, nl, nr))


if __name__ == "__main__":
    main()
