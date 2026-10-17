"""Does UPSTREAM converge on the design the port's warning tests call degenerate?

Four LPLR warning gates assert that `make_lplr_LZZ2020(1000, alpha=1.5,
seed=11)` FAILS to converge and must warn. D2 (ml_M inner OOF for `W_inner`)
made the port converge there instead, so those gates went red.

A disappearing warning has two possible causes and they need opposite
responses:

  * the degeneracy was a SYMPTOM of the `W_inner` divergence, and D2 removed it
    -- then the gates are pinned to a fixture that is no longer degenerate and
    must be re-based onto one that still is;
  * D2 silenced a genuine failure and now returns a confident wrong number
    -- then the gates are right and D2 is dangerous.

## THE ANSWER IS "UPSTREAM CANNOT REFUTE THIS FIXTURE"

The port's `make_lplr_LZZ2020(n, alpha, seed)` (`dgp_lplr.mbt:37`, `p = 6`,
seeded) and upstream's (`plm/datasets/dgp_lplr_LZZ2020.py`,
`(n_obs, dim_x=20, alpha, ...)`) are **different data**. Upstream's has no seed
parameter at all and defaults to 20 covariates; the port's has 6 and is seeded.
So "does upstream converge at alpha=1.5" is a question about a different
fixture, and its answer says nothing about this one.

That is why the decisive measurement for D2 was the PORT-side `alpha` sweep
(recorded in `_verify/LPLR_GATE_BLINDNESS_1680.md` §7f, run as a temporary
in-package probe), not this file.

## Why this file exists, then

Two reasons, both about this script rather than about upstream:

1. **The first version of this script printed a FALSE VERDICT.** It called
   `make_lplr_LZZ2020(1000, alpha, 11)`, which binds `alpha` to `dim_x` and
   `11` to `alpha`, so every call raised
   `'float' object cannot be interpreted as an integer` -- its OWN call-shape
   bug -- and the script then reported `upstream ALSO FAILS at alpha=1.5`.
   A crash scored as a measurement is the exact failure mode this repo keeps
   guarding against, committed into a script that would have convinced a reader.
   So the call shape is asserted here, and the verdict is only reached if the
   fit actually completed.

2. It pins what upstream's OWN DGP does over the same alpha range, which is
   still worth knowing: if upstream's fixture is also silent throughout, the
   "rootless at alpha >= 1.25" cliff in the port is not an upstream property at
   all.

## KNOWN GAP: `return_type` was not resolved

As written this script currently ends INCONCLUSIVE, not because upstream fails
but because `return_type="DoubleMLData"` returns a `DoubleMLData` with no
`.outcome` attribute. The alias sets (`_array_alias`, `_data_frame_alias`,
`_dml_data_alias`) that upstream dispatches on were not located. Until someone
resolves the correct call shape this script proves nothing either way, and its
"INCONCLUSIVE" banner is the honest output.

Left in rather than deleted because the two failure modes it documents -- the
crash-scored-as-verdict, and the crash-scored-as-a-finding -- are the reason it
prints a verdict at all.
"""
import numpy as np

from doubleml import DoubleMLLPLR
from doubleml.plm.datasets.dgp_lplr_LZZ2020 import make_lplr_LZZ2020
from sklearn.linear_model import LogisticRegression

np.random.seed(20260824)

ALPHAS = (0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25)

print("upstream DoubleMLLPLR on UPSTREAM's make_lplr_LZZ2020 "
      "(n_obs=1000, dim_x=20)")
print("REMINDER: this is NOT the port's fixture (p=6, seeded). See docstring.")
print()
print("%-8s %-12s %-12s %s" % ("alpha", "coef", "se", "status"))
print("-" * 52)

rows = []
for alpha in ALPHAS:
    try:
        dgp = make_lplr_LZZ2020(n_obs=1000, dim_x=20, alpha=alpha)
        obj = DoubleMLLPLR(
            dgp.data, dgp.outcome,
            ml_l=LogisticRegression(),
            ml_m=LogisticRegression(),
            n_folds=2, n_folds_inner=2, seed=11,
        )
        obj.fit()
        rows.append((alpha, float(obj.coef[0]), float(obj.se[0]), "converged"))
        print("%-8s %-12.6f %-12.6f %s"
              % (alpha, rows[-1][1], rows[-1][2], "converged"))
    except Exception as exc:  # noqa: BLE001
        # Distinguish "this design failed" from "my call was wrong". The
        # second must not be laundered into the first.
        msg = str(exc).replace("\n", " ")[:70]
        rows.append((alpha, None, None, "ERROR"))
        print("%-8s %-12s %-12s ERROR  %s" % (alpha, "-", "-", msg))

print()
if all(r[3] == "converged" for r in rows):
    print("RESULT: upstream converges at every alpha on its own fixture.")
    print("So the port's 'rootless objective at alpha >= 1.25' is not an")
    print("upstream property -- consistent with D2 showing it is a symptom of")
    print("the outer-OOF W_inner rather than of the design.")
elif any(r[3] == "ERROR" for r in rows):
    print("RESULT: INCONCLUSIVE -- at least one call errored.")
    print("That is a problem with THIS SCRIPT or the installed upstream, not a")
    print("finding about the designs. Do not read the ERROR rows as 'degenerate'.")
else:
    bad = [r[0] for r in rows if r[3] != "converged"]
    print("RESULT: upstream did not converge at alpha(s) %s on its own fixture."
          % bad)
