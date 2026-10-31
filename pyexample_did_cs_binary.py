"""Run the MoonBit port against upstream's `DoubleMLDIDCSBinary`, cell by cell.

`pyexample_did_cs2021.py` covers `DoubleMLDIDMulti`; this covers
`DoubleMLDIDCSBinary`, which is what `examples/did_cs_binary` constructs and
which the port implements in `did_cs_binary.mbt`. Neither had coverage of the
other: they are different upstream classes with different defaults, so
agreement with one is not evidence about the other.

WHY THIS ONE IS EASY AND THE OTHER ONE IS NOT
============================================
Both sides take an EXPLICIT `(g_value, t_value_pre, t_value_eval)` -- same
argument names, same order:

    upstream  (obj_dml_data, g_value, t_value_pre, t_value_eval, ml_g, ml_m=None,
               control_group=never_treated, anticipation_periods=0, n_folds=5,
               n_rep=1, score=observational, in_sample_normalization=True, ...)
    port      (data, g_value, t_value_pre, t_value_eval,
               control_group~="never_treated", anticipation_periods~=0,
               n_folds~=5, n_rep~=1, ..., score~="observational",
               in_sample_normalization~=false, ...)

So there is NO grid-derivation question here, and no cell is being skipped for
structural reasons. That is the whole difference from the CS2021 gate, which
could only compare 6 of upstream's 12 `"standard"` cells because the port fixes
its base period at `g - 1` while upstream picks `t_pre` from the period grid.
Here both sides are told the cell, and all 6 are compared.

WHY NOT `DoubleMLDIDCS`
=======================
Upstream's `DoubleMLDIDCS` is deprecated -- "will be removed with version
0.12.0. Please use DoubleMLDIDCSBinary instead" -- and it refuses the modern
container: "For repeated cross sections the data must be of DoubleMLDIDData
type", raised against a `DoubleMLPanelData` argument. Gating a port method
against a class upstream is deleting would put an expiry date on this gate.
The notice is in the installed upstream already -- `doubleml` 0.11.4 carries
it in `doubleml/did/did_cs.py` -- so the removal is not a rumour.

THE DATA IS THE CS2021 PANEL, NOT A NEW DGP
===========================================
This gate imports `pyexample_did_cs2021` and reuses its builder, its cell list
and its fixture writer. Two gates that independently rebuilt the CS2021 DGP
would agree today and drift tomorrow, and the integer never-treated recode is
exactly the part most likely to be re-derived wrongly: it maps upstream's
float `inf` sentinel onto the port's `min(g)` rule, and without it the two
sides silently disagree about which cohort is the control.

Sharing the fixture also means sharing the sentinel: `sec_did_cs_binary` reads
`cs2021_generated()`, not a sentinel of its own, because there is no separate
data to guard.

UPSTREAM TRAPS, both measured rather than guessed
=================================================
  * `make_did_CS2021` defaults `return_type="DoubleMLDIDData"`, NOT a
    DataFrame. The failure surfaces as "'DoubleMLDIDData' object has no
    attribute 'shape'" -- far from the real cause.
  * `draw_sample_splitting=False` works for `DoubleMLDIDMulti` and FAILS for
    `DoubleMLDIDCSBinary`, which then dies in `double_ml.py:519` with
    "'NoneType' object is not subscriptable" because `_smpls` was never drawn.
    Same flag, opposite contract, no warning.

TOLERANCES
==========
Measured over 12 upstream fold seeds, re-seeded before EVERY cell so that
adding or removing a cell cannot move the others' numbers (upstream draws its
folds from the process-global RandomState when `random_state` is unset):

    cell        coef      coef_sd   3 sd     |coef|/sd
    ATT(2,1,2)  1.15791   0.05520  0.16560     21.0
    ATT(2,1,3)  1.90497   0.06674  0.20022     28.5
    ATT(2,1,4)  2.89866   0.06655  0.19965     43.6
    ATT(3,2,3)  0.93715   0.04748  0.14244     19.7
    ATT(3,2,4)  1.67532   0.04245  0.12735     39.5
    ATT(4,3,4)  0.87986   0.04570  0.13710     19.3

The "3 sd" column is the BAND IN FORCE -- the same numbers `TOL_BY_CELL`
below holds and the same ones the gate prints on every run -- and it is
3 x the "coef_sd" column, not 3 x the unrounded sd. Those two differ in the
last digit on five of the six rows (3 x 0.06674 is 0.20022, while 3 x the
unrounded sd rounds to 0.20021), and it is the band that decides whether a
cell passes, so the band is what is quoted here.

Every cell is measured INDIVIDUALLY. The weakest signal is 19.3x the fold
noise, so even the loosest band is a real constraint.

USAGE
=====
    python pyexample_did_cs_binary.py --check
    python pyexample_did_cs_binary.py --write
    python pyexample_did_cs_binary.py --restore
"""
from __future__ import annotations

import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

import pyexample_did_cs2021 as cs  # noqa: E402  the CS2021 fixture machinery

FIXTURE = cs.FIXTURE

# Measured over 12 upstream fold seeds by the did-cs-binary fold-noise
# measurement.
TOL_BY_CELL = {
    (2, 1, 2): 3 * 0.05520,
    (2, 1, 3): 3 * 0.06674,
    (2, 1, 4): 3 * 0.06655,
    (3, 2, 3): 3 * 0.04748,
    (3, 2, 4): 3 * 0.04245,
    (4, 3, 4): 3 * 0.04570,
}


def fit_upstream(obj, cells, fold_seed):
    """Upstream's `DoubleMLDIDCSBinary` on each cell, seeded per cell."""
    import numpy as np
    from doubleml.did import DoubleMLDIDCSBinary
    from sklearn.linear_model import LinearRegression, LogisticRegression

    out = {}
    for (gv, tp, te) in cells:
        np.random.seed(fold_seed)
        est = DoubleMLDIDCSBinary(
            obj_dml_data=obj,
            g_value=gv, t_value_pre=tp, t_value_eval=te,
            ml_g=LinearRegression(), ml_m=LogisticRegression(),
            n_folds=cs.N_FOLDS, n_rep=cs.N_REP,
            in_sample_normalization=True,
            # `draw_sample_splitting` is LEFT AT ITS DEFAULT. False works for
            # DoubleMLDIDMulti and breaks here with "'NoneType' object is not
            # subscriptable" from double_ml.py:519.
        )
        est.fit()
        out[(gv, tp, te)] = (float(np.ravel(est.coef)[0]),
                             float(np.ravel(est.se)[0]))
    return out


def snapshot_fixture():
    with open(FIXTURE, "rb") as fh:
        return fh.read()


def restore_fixture_bytes(blob):
    with open(FIXTURE, "wb") as fh:
        fh.write(blob)


def restore_fixture():
    rel = os.path.relpath(FIXTURE, ROOT)
    if not os.path.isfile(FIXTURE):
        raise SystemExit("fixture missing; restore with: git checkout -- " + rel)
    r = subprocess.run(["git", "checkout", "--", rel], cwd=ROOT,
                       capture_output=True)
    if r.returncode != 0:
        raise SystemExit("could not restore via git: %s"
                         % (r.stderr or b"").decode("utf-8", "replace"))


def main(argv):
    import parity_helper as ph

    mode = argv[1] if len(argv) > 1 else "--check"
    if mode == "--restore":
        restore_fixture()
        print("restored the committed placeholder")
        return 0
    if mode not in ("--check", "--write"):
        print(__doc__)
        return 2

    panel = cs.build_cs2021()
    cells = cs.comparable_cells()
    missing = [c for c in cells if c not in TOL_BY_CELL]
    if missing:
        raise SystemExit(
            "no MEASURED fold-noise band for cell(s) %s; measure them "
            "rather than borrowing a "
            "neighbour's" % (missing,))

    upstream = fit_upstream(panel["obj"], cells, cs.FIT_SEED)
    print("upstream DoubleMLDIDCSBinary on the CS2021 panel")
    print("  %d rows, cohorts g=%s, never-treated=%d"
          % (panel["y"].shape[0], sorted(set(panel["g"].tolist())),
             panel["never_treated"]))
    print("  %d cell(s), each REQUESTED explicitly on both sides -- no cell is"
          % len(cells))
    print("  skipped for structural reasons, unlike the CS2021 gate")
    for (g, tp, te) in cells:
        c, s = upstream[(g, tp, te)]
        print("    ATT(%d,%d,%d)  coef % .6f  se %.6f  band %.5f"
              % (g, tp, te, c, s, TOL_BY_CELL[(g, tp, te)]))
    print()

    snapshot = snapshot_fixture()
    nbytes = cs.write_fixture(panel, cells)
    if mode == "--write":
        print("wrote %d bytes to %s (leave with --restore)"
              % (nbytes, os.path.relpath(FIXTURE, ROOT)))
        return 0

    try:
        sec = ph.parse(ph.run_parity())["did_cs_binary"]
    finally:
        restore_fixture_bytes(snapshot)

    if sec["val"].get("csb_generated") != 1.0:
        print("FAIL: the emitter did not see the generated CS2021 fixture")
        return 1

    rows = []
    n_cells = int(sec["val"]["csb_n_cells"])
    if n_cells != len(cells):
        print("FAIL: the port fitted %d cells, expected %d"
              % (n_cells, len(cells)))
        return 1

    for i, (g, tp, te) in enumerate(cells):
        want_c, want_s = upstream[(g, tp, te)]
        got_c = sec["val"]["csb_coef_%d" % i]
        got_s = sec["val"]["csb_se_%d" % i]
        tol = TOL_BY_CELL[(g, tp, te)]
        rows.append(("csb_coef ATT(%d,%d,%d) (3sd=%.4f)" % (g, tp, te, tol),
                     got_c, want_c, abs(got_c - want_c) <= tol))
        rows.append(("csb_se   ATT(%d,%d,%d) (3sd=%.4f)" % (g, tp, te, tol),
                     got_s, want_s, abs(got_s - want_s) <= tol))

    rc = ph.report("pyexample: port vs upstream DoubleMLDIDCSBinary "
                   "(%d cells, CS2021 panel)" % len(cells), rows, ok=True)
    with open(FIXTURE, "rb") as fh:
        same = fh.read() == snapshot
    print()
    print("fixture restored byte for byte: %s" % same)
    return rc if same else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
