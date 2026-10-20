"""CONTROL ARM: does upstream really fail this often, with nothing instrumented?

`_lplr_startval_bias_1680.py` measured that on trial 2's rows upstream's own fits
fail to converge on 18/40 pinned redraws, returning coefficients like 5.2e+53
and NaN. If that stands, it OVERTURNS section 25g, which concluded from ONE
upstream draw that "the port diverges where upstream does not".

That claim now carries the weight of a whole investigation, so it gets a control
with none of my code in the path:

  * no `_double_dml_cv_predict` spy, no `_dml_cv_predict` spy
  * no hand-rebuilt `beta`, no `score_terms`, no re-run of `root_scalar`
  * no `np.errstate`, no threshold comparisons
  * just `DoubleMLLPLR(...).fit()` and read `.coef[0]` / `.se[0]`, exactly as a
    user would

and count non-finite / absurd answers. If the failure rate holds up here, it is
upstream's behaviour, not an artefact of my harness. If it collapses to zero, the
instrumentation was manufacturing the failures and the 45% is worthless.

Pinned: each draw seeds the global NumPy RNG so it is reproducible.

Run: python _verify/_lplr_upstream_fragility_control_1680.py
"""

import os
import sys
import warnings

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import use_vendored_upstream  # noqa: E402
use_vendored_upstream()
sys.path.insert(0, os.path.join(REPO, "_verify"))

from _lplr_nuisance_causal_1680 import parse_blocks  # noqa: E402

from _lplr_env_1680 import PORT_DUMP  # noqa: E402
DRAWS = 40


def main():
    from sklearn.linear_model import LinearRegression, LogisticRegression
    from doubleml.plm import DoubleMLLPLR
    from doubleml.data import DoubleMLData

    blocks = parse_blocks(PORT_DUMP)
    b0 = blocks[0]
    n, p = b0["n"], b0["p"]
    x = b0["x"].reshape(n, p)
    y, d = b0["y"], b0["d"]
    cols = ["x%d" % (j + 1) for j in range(p)]
    df = pd.DataFrame(np.column_stack([x, y, d]), columns=cols + ["y", "d"])

    def mk():
        return LogisticRegression(C=1e6, max_iter=500, solver="lbfgs")

    bad, warned = [], 0
    print("trial 2 rows, n=%d p=%d -- %d clean upstream fits, nothing instrumented"
          % (n, p, DRAWS))
    print("")
    for k in range(DRAWS):
        np.random.seed(20260824 + k)
        obj = DoubleMLData(df, "y", "d", cols)
        mdl = DoubleMLLPLR(obj, ml_M=mk(), ml_t=LinearRegression(), ml_m=mk(),
                           ml_a=mk(), n_folds=2, n_folds_inner=2,
                           score="nuisance_space", draw_sample_splitting=True)
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            mdl.fit()
            if any("root" in str(x_.message).lower() for x_ in w):
                warned += 1
        c = float(mdl.coef[0])
        s = float(mdl.se[0])
        ok = np.isfinite(c) and np.isfinite(s) and abs(c) < 100.0
        if not ok:
            bad.append((k, c, s))
        print("  draw %2d  coef=%14.6g  se=%14.6g  %s"
              % (k, c, s, "" if ok else "<-- not a plausible estimate"))

    print("")
    print("=== control result ===")
    print("    draws                                   : %d" % DRAWS)
    print("    implausible / non-finite coefficients   : %d  (%.0f%%)"
          % (len(bad), 100.0 * len(bad) / DRAWS))
    print("    fits that raised a root warning         : %d" % warned)
    if bad:
        print("    example failures:")
        for k, c, s in bad[:5]:
            print("      draw %d  coef=%g se=%g" % (k, c, s))
    print("")
    if len(bad) >= 5:
        print("CONFIRMED on the uninstrumented control: upstream's own LPLR")
        print("returns non-finite or absurd coefficients on %d/%d partitions of"
              % (len(bad), DRAWS))
        print("these exact rows.")
        print("")
        print("Section 25g's claim -- 'the port diverges where upstream does")
        print("not' -- rested on ONE draw and does not survive. Upstream is at")
        print("least as fragile as the port on this row set, so the clamp is NOT")
        print("covering a port defect: it is covering a fragility upstream")
        print("shares and does not guard against either.")
    else:
        print("The instrumentation WAS manufacturing failures -- %d/%d here"
              % (len(bad), DRAWS))
        print("against 18/40 with the spies in place. Discard the 45%.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
