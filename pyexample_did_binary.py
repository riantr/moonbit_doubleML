"""Run the MoonBit port against upstream's `DoubleMLDIDBinary`, cell by cell.

This is the gate that `_verify/DID_BINARY_PANIC_1680.md` said could not exist.
It could: the recorded "defect" was a misdiagnosis, and this file is the
evidence. The short version --

    `DoubleMLDIDBinary::new` builds a FOUR-ROW dummy inner model
    (`DoubleMLDIDData::new(Matrix::zeros(4, ...), ...)`, `did_binary.mbt:440-441`)
    so that construction does not trip `require(n_folds <= data.n_obs())`.
    That caps `n_folds` at 4 on this type.

The first attempt at this gate passed upstream's default `n_folds = 5`, hit
that ceiling, and aborted at `did.mbt:276`. It was recorded as a row-count
defect on the CS2021 panel -- "the eligible subset must be smaller than
n_folds". Measured, that is false:

    ATT(2,1,2) on CS2021, `preprocess_did_binary` emits 515 wide rows
    out of a 5000-row panel, and
        n_folds=2 -> constructs AND fits, coef 1.14480
        n_folds=3 -> constructs AND fits, coef 1.14611
        n_folds=4 -> constructs AND fits, coef 1.11875
        n_folds=5 -> aborts DURING CONSTRUCTION
    against upstream's 1.13860.

`n_folds = 5` aborts before `preprocess_did_binary` is ever reached, so the
`DoubleMLDID::new` that raised is the 4-row dummy, not the real one. Both
raise at the same line and print the same message, which is exactly why the
call site could not be identified from the panic text.

So the ceiling is a property of the CONSTRUCTOR, not of the sample, and both
sides are fitted at `n_folds = 2` here -- under the ceiling on the port side,
and matching `cs.N_FOLDS` on the upstream side.

WHY THIS ONE IS EASY
====================
Like `DoubleMLDIDCSBinary`, both sides take an EXPLICIT
`(g_value, t_value_pre, t_value_eval)`. No cell is skipped for structural
reasons; all six are compared. Unlike `DoubleMLDIDMulti` (the CS2021 gate),
which could only compare 6 of upstream's 12 "standard" cells because the port
fixes its base period at `g - 1`.

THE DATA IS THE CS2021 PANEL, NOT A NEW DGP
===========================================
Imports `pyexample_did_cs2021` and reuses its builder, cell list and fixture
writer, for the same reason `pyexample_did_cs_binary.py` does: two gates that
independently rebuilt the CS2021 DGP would agree today and drift tomorrow.
Sharing the fixture also means sharing the sentinel -- `sec_did_binary_upstream`
reads `cs2021_generated()`, because there is no separate data to guard.

TOLERANCES
==========
Measured, not derived from a formula and not copied from the sibling gate.
`sd_up` is upstream's own fold sd over 12 seeds
(re-seeded before EVERY cell so adding or
removing a cell cannot move the others -- upstream draws folds from the
process-global RandomState when `random_state` is unset; see
the stability check). `sd_port` is the PORT's own
fold sd over 9 seeds. The band is
3 x sqrt(sd_up^2 + sd_port^2) -- the spread of the DIFFERENCE, because the two
sides draw folds independently. The full table, including what an upstream-only
band would have done, is at `TOL_BY_CELL` below.

Every cell is measured INDIVIDUALLY; the weakest upstream signal is 16.9x its
own fold noise.

UPSTREAM TRAPS
==============
  * `ml_m` must be a CLASSIFIER. The port DEFAULTS IT TO A REGRESSOR
    (`did_binary.mbt:376`), so the emitter passes a logistic explicitly.
    Upstream trims extreme weights by default
    (`trimming_rule="truncate"`, `trimming_threshold=0.01`) and the port has no
    such argument -- whether the port's untrimmed configuration lands on
    upstream's trimmed estimator on this panel is what the comparison answers.
  * `make_did_CS2021` defaults `return_type="DoubleMLDIDData"`, not a
    DataFrame.
  * `draw_sample_splitting=False` breaks the Binary variants with
    "'NoneType' object is not subscriptable" (`double_ml.py:519`).

USAGE
=====
    python pyexample_did_binary.py --check
    python pyexample_did_binary.py --write
    python pyexample_did_binary.py --restore
    python pyexample_did_binary.py --probe     # print port vs upstream, no verdict
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

# WHY THE BANDS ARE NOT UPSTREAM'S OWN NOISE
# ==========================================
# The obvious band is 3 x upstream's fold sd. It is wrong here, and measuring is
# what showed it: the port re-draws its own folds from `seed`, and a re-draw
# moved ATT(3,2,3)'s standard error to 93.5% of the upstream-only band. A gate
# that fails on a different seed is not measuring parity, it is measuring fold
# noise -- and `seed` is an argument, not a defect.
#
# Both sides draw folds independently, so the difference has
# sd = sqrt(sd_up^2 + sd_port^2). The band below is 3 x THAT, per cell:
#
#   cell        sd_up   sd_port    3sd_up   3sd_diff   ratio
#   ATT(2,1,2) coef  0.06757  0.05412   0.20270   0.25971    1.28x
#   ATT(2,1,3) coef  0.06098  0.04483   0.18294   0.22706    1.24x
#   ATT(2,1,4) coef  0.05882  0.06457   0.17646   0.26202    1.48x
#   ATT(3,2,3) coef  0.03163  0.03987   0.09489   0.15268    1.61x
#   ATT(3,2,4) coef  0.05831  0.03842   0.17493   0.20949    1.20x
#   ATT(4,3,4) coef  0.03048  0.03343   0.09144   0.13573    1.48x
#   ATT(2,1,2) se    0.01069  0.00500   0.03207   0.03540    1.10x
#   ATT(2,1,3) se    0.00755  0.00452   0.02265   0.02641    1.17x
#   ATT(2,1,4) se    0.01046  0.00511   0.03138   0.03492    1.11x
#   ATT(3,2,3) se    0.00208  0.00276   0.00623   0.01037    1.66x
#   ATT(3,2,4) se    0.00297  0.00265   0.00892   0.01196    1.34x
#   ATT(4,3,4) se    0.00266  0.00277   0.00799   0.01152    1.44x
#
# `sd_port` is over 9 seeds (42, 7, 13, 99, 3, 5, 11, 21, 33); `sd_up` is over
# 12 upstream fold seeds. The two are NOT interchangeable and neither
# alone is the band.
TOL_BY_CELL = {
    (2, 1, 2): 0.25971,
    (2, 1, 3): 0.22706,
    (2, 1, 4): 0.26202,
    (3, 2, 3): 0.15268,
    (3, 2, 4): 0.20949,
    (4, 3, 4): 0.13573,
}

# Measured separately because `se` is not `coef` rescaled -- the two carry
# different fold noise (see the table above: ATT(3,2,3)'s coefficient band
# widens 1.61x but its standard-error band 1.66x, off different raw numbers).
SE_TOL_BY_CELL = {
    (2, 1, 2): 0.03540,
    (2, 1, 3): 0.02641,
    (2, 1, 4): 0.03492,
    (3, 2, 3): 0.01037,
    (3, 2, 4): 0.01196,
    (4, 3, 4): 0.01152,
}


def fit_upstream(obj, cells, fold_seed):
    """Upstream's `DoubleMLDIDBinary` on each cell, seeded per cell."""
    import numpy as np
    from doubleml.did import DoubleMLDIDBinary
    from sklearn.linear_model import LinearRegression, LogisticRegression

    out = {}
    for (gv, tp, te) in cells:
        np.random.seed(fold_seed)
        est = DoubleMLDIDBinary(
            obj_dml_data=obj,
            g_value=gv, t_value_pre=tp, t_value_eval=te,
            ml_g=LinearRegression(), ml_m=LogisticRegression(),
            n_folds=cs.N_FOLDS, n_rep=cs.N_REP,
            in_sample_normalization=True,
            # `draw_sample_splitting` LEFT AT ITS DEFAULT -- False works for
            # DoubleMLDIDMulti and breaks the Binary variants with
            # "'NoneType' object is not subscriptable" (double_ml.py:519).
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
    if mode not in ("--check", "--write", "--probe"):
        print(__doc__)
        return 2

    panel = cs.build_cs2021()
    cells = cs.comparable_cells()
    missing = [c for c in cells
               if c not in TOL_BY_CELL or c not in SE_TOL_BY_CELL]
    if missing:
        raise SystemExit(
            "no MEASURED fold-noise band for cell(s) %s; measure them "
            "rather than borrowing a "
            "neighbour's" % (missing,))

    upstream = fit_upstream(panel["obj"], cells, cs.FIT_SEED)
    print("upstream DoubleMLDIDBinary on the CS2021 panel")
    print("  %d rows, cohorts g=%s, never-treated=%d"
          % (panel["y"].shape[0], sorted(set(panel["g"].tolist())),
             panel["never_treated"]))
    print("  %d cell(s), all REQUESTED explicitly on both sides" % len(cells))
    for (g, tp, te) in cells:
        c, s = upstream[(g, tp, te)]
        print("    ATT(%d,%d,%d)  coef % .6f  se %.6f  band %.5f/%.5f"
              % (g, tp, te, c, s, TOL_BY_CELL[(g, tp, te)],
                 SE_TOL_BY_CELL[(g, tp, te)]))
    print()

    snapshot = snapshot_fixture()
    nbytes = cs.write_fixture(panel, cells)
    if mode == "--write":
        print("wrote %d bytes to %s (leave with --restore)"
              % (nbytes, os.path.relpath(FIXTURE, ROOT)))
        return 0

    try:
        secs = ph.parse(ph.run_parity())
    finally:
        restore_fixture_bytes(snapshot)

    sec = secs["did_binary_upstream"]
    if sec["val"].get("db_generated") != 1.0:
        print("FAIL: the emitter did not see the generated CS2021 fixture")
        return 1

    n_cells = int(sec["val"]["db_n_cells"])
    if n_cells != len(cells):
        print("FAIL: the port fitted %d cells, expected %d"
              % (n_cells, len(cells)))
        return 1

    rows = []
    print("port vs upstream, per cell")
    print("  %-12s %10s %10s %9s %7s | %10s %10s %9s %7s"
          % ("cell", "coef_port", "coef_up", "diff", "sd/band",
             "se_port", "se_up", "diff", "sd/band"))
    for i, (g, tp, te) in enumerate(cells):
        want_c, want_s = upstream[(g, tp, te)]
        got_c = sec["val"]["db_coef_%d" % i]
        got_s = sec["val"]["db_se_%d" % i]
        for kind, got, want, tol in (
            ("coef", got_c, want_c, TOL_BY_CELL[(g, tp, te)]),
            ("se", got_s, want_s, SE_TOL_BY_CELL[(g, tp, te)]),
        ):
            d = got - want
            frac = abs(d) / tol if tol > 0 else float("inf")
            rows.append(("db_%s ATT(%d,%d,%d) (3sd=%.4f, %.1f%% of band)"
                         % (kind, g, tp, te, tol, 100 * frac),
                         got, want, abs(d) <= tol))
        print("  ATT(%d,%d,%d)  %10.6f %10.6f %+9.5f %6.1f%% |"
              " %10.6f %10.6f %+9.5f %6.1f%%"
              % (g, tp, te, got_c, want_c, got_c - want_c,
                 100 * abs(got_c - want_c) / TOL_BY_CELL[(g, tp, te)],
                 got_s, want_s, got_s - want_s,
                 100 * abs(got_s - want_s) / SE_TOL_BY_CELL[(g, tp, te)]))
    print()

    if mode == "--probe":
        print("--probe: no verdict emitted, fixture untouched")
        return 0

    rc = ph.report("pyexample: port vs upstream DoubleMLDIDBinary "
                   "(%d cells, CS2021 panel)" % len(cells), rows, ok=True)
    with open(FIXTURE, "rb") as fh:
        same = fh.read() == snapshot
    print()
    print("fixture restored byte for byte: %s" % same)
    return rc if same else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
