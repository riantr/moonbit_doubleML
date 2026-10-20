"""Section 27f: where exactly is the Newton basin, and why is it flat?

Section 27f of `_verify/LPLR_GATE_BLINDNESS_1680.md` reports a grid of
starting values, a fine scan for the basin edge, and a derivative collapse --
and the shipped README quotes the collapse ("a factor of 344 down", "overshoots
to about -1381") on the strength of it.

That section had **no method script**: the numbers came from an ad-hoc run
that was never committed, so the README's figure had no witness at all. This
is that witness.

It uses REAL `scipy.optimize.root_scalar(..., method="newton")` -- the same
call upstream makes at `doubleml/double_ml_score_mixins.py:149` -- on
upstream's OWN pinned nuisances, so nothing about the port is assumed.

Run: python _verify/_lplr_basin_scan_1680.py
"""

import os
import sys
import warnings

import numpy as np

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import use_vendored_upstream  # noqa: E402
use_vendored_upstream()

from _lplr_nuisance_causal_1680 import (  # noqa: E402
    parse_blocks, upstream_nuisances, PORT_DUMP,
)
from _lplr_bag_direction_1680 import score_terms  # noqa: E402

from scipy.optimize import root_scalar  # noqa: E402

GRID = [-20, -10, -5, -3, -2, -1, 0, 0.5, 1.003, 2, 3,
        4, 5, 6, 6.842, 8, 10, 15, 20]
FINE_LO, FINE_HI, FINE_STEP = 0.0, 20.0, 0.5


def make_score(y, d, t, m, a, b):
    """Upstream's nuisance_space score and its derivative, on one theta.

    Same elements upstream builds in `plm/lplr.py:_score_elements`:
    `d_tilde = d - m_hat`, `psi_hat = expit(-r_hat)`,
    `score_const = d_tilde * (1 - y) * exp(r_hat)`.
    """
    r_hat = t - b * a

    def score(theta):
        psi, _ = score_terms(theta, y, d, r_hat, m, b, a)
        return float(psi.mean())

    def deriv(theta):
        _, pd = score_terms(theta, y, d, r_hat, m, b, a)
        return float(pd.mean())

    return score, deriv


def run_newton(score, deriv, x0, true_root=None, tol=1e-6):
    """scipy's newton, exactly as upstream calls it.  Returns (root, ok).

    "converged" means converged **to the root** -- a finite number that is
    not the root is a runaway, not a solution.  Starts 4, 5 and 6 return
    -26.9, -165.0 and -542.0, all finite and all wrong; they are failures
    with a finite-looking answer, which is the whole point of this section.
    """
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            r = root_scalar(score, x0=x0, fprime=deriv, method="newton",
                            maxiter=50)
        root = float(r.root)
    except Exception:
        return float("nan"), False
    if not np.isfinite(root):
        return root, False
    if true_root is not None:
        return root, bool(abs(root - true_root) <= tol)
    return root, True


def main():
    blocks = parse_blocks(PORT_DUMP)
    if not blocks:
        raise SystemExit("no blocks in %s" % PORT_DUMP)
    blk0 = blocks[0]
    n, p = blk0["n"], blk0["p"]
    x = blk0["x"].reshape(n, p)
    y, d = blk0["y"], blk0["d"]

    up, up_coef, up_se = upstream_nuisances(x, y, d, p)
    score, deriv = make_score(y, d, up["t"], up["m"], up["a"], up["b"])

    up_start = float(up["b"].mean())
    port_start = float(blk0["b"].mean())

    print("rows n=%d p=%d seed=%d   (upstream's own nuisances, pinned)"
          % (n, p, blk0["seed"]))
    print("upstream's own start mean(beta) = %.6f" % up_start)
    print("the port's start       mean(beta) = %.6f" % port_start)
    print("")

    print("=== grid of starts, real scipy newton ===")
    print("%-10s %-16s %s" % ("x0", "root", "converged"))
    for x0 in GRID:
        root, ok = run_newton(score, deriv, x0, up_coef)
        print("%-10s %-16s %s" % (x0, "%.6f" % root,
                                  "yes" if ok else "**no**"))

    print("")
    print("=== fine scan %.1f .. %.1f step %.1f ===" % (FINE_LO, FINE_HI, FINE_STEP))
    xs = [round(FINE_LO + i * FINE_STEP, 10) for i in
          range(int(round((FINE_HI - FINE_LO) / FINE_STEP)) + 1)]
    good = []
    for x0 in xs:
        root, ok = run_newton(score, deriv, x0, up_coef)
        if ok:
            good.append(x0)
    print("converged %d/%d   range [%s, %s]"
          % (len(good), len(xs),
             ("%.1f" % good[0]) if good else "-",
             ("%.1f" % good[-1]) if good else "-"))

    print("")
    print("=== the derivative collapse ===")
    for label, x0 in (("upstream's start", up_start),
                      ("the port's start", port_start)):
        s, dv = score(x0), deriv(x0)
        print("at x0 = %-12.6f : score = %-14.7g deriv = %-14.7g"
              % (x0, s, dv))
    s_up, d_up = score(up_start), deriv(up_start)
    s_po, d_po = score(port_start), deriv(port_start)
    if d_po != 0.0:
        factor = abs(d_up / d_po)
        first = port_start - s_po / d_po
        print("derivative falls by a factor of %.1f" % factor)
        print("first step theta - score/deriv at %.6f = %.1f"
              % (port_start, first))
    return 0


if __name__ == "__main__":
    sys.exit(main())
