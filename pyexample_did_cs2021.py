"""Run the MoonBit port on upstream's OWN multi-cohort Callaway-Sant'Anna example.

This is the second half of the `pyexample` gate. `pyexample_did.py` covers
`DoubleMLDID` (single cohort, SZ2020). This one covers the multi-cohort
`DoubleMLDIDMulti` on `make_did_CS2021`, which is where the port's DID-CS
machinery actually lives.

WHY THE OLD "NO CS2021 HALF" NOTE WAS WRONG
==========================================
An earlier revision of `pyexample_did.py` recorded two reasons for skipping
CS2021. Both were measured and BOTH ARE FALSE:

  1. "Upstream ships the CS2021 DGP but no CS2021 estimator." False.
     `doubleml.did.DoubleMLDIDMulti` exists, is exported in `__all__`, and
     fits. Its own docstring example is built on `make_did_CS2021`.
  2. "The never-treated conventions disagree, so the port uses a treated
     cohort as its own control." True only for FLOAT `g`. `_get_never_treated_value`
     is dtype-dependent:

         integer dtype  ->  0     <- the port's rule (control = min(g))
         floating dtype ->  inf   <- what broke
         datetime64     ->  NaT

     The CS2021 DGP emits `inf` only because `time_type="float"` makes `g`
     floating. Recoding `g` to INTEGER maps never-treated to 0, which is
     exactly the port's convention. Measured:
     `_get_never_treated_value(g) == 0 == min(g)`, and every `_is_never_treated`
     verdict then matches the port's own `discover_groups_times` (`did_cs.mbt:89-95`).

WHY ONLY 6 OF UPSTREAM'S 12 CELLS
=================================
Upstream's `"standard"` yields 12 `(g, t_pre, t_eval)` cells; the port's DIDCS
yields 6. This is a structural difference, and it is measured rather than
asserted (`_verify/_cs2021_partition_1670.py`):

  * the port's `DoubleMLDIDCS` fixes its base period at `g_value - 1`
    (`did_cs.mbt:1563`) and restricts the panel to
    `(g == g_value) U (g == never_treated)` (`did_cs.mbt:1589`);
  * upstream's `_construct_gt_combinations` picks
    `t_pre = t_values[t_values < g][-1]`, then `min(t_values[i], t_pre)`;
  * so the two agree EXACTLY on the 6 cells where upstream landed on
    `t_pre == g - 1`, and cannot be asked about the other 6.

Those 6 are not a subset chosen for convenience: they are the largest part of
the standard grid, they are every post-treatment cell of every cohort, and each
one is an ATT a practitioner would quote.

`DoubleMLDIDMulti`'s `ignore(t_pre)` (`did_multi.mbt:326`) is a real divergence
from upstream -- but on these 6 cells it is UNREACHABLE, because the requested
`t_pre` is the period the inner estimator would have picked anyway. That is why
this gate is sound and a `gt_combinations`-honouring port would not be needed to
make it meaningful. The remaining 6 stay outside the comparison and are counted
in the output so the gap is visible rather than implied.

THE TOLERANCES ARE MEASURED
===========================
Same structure as the SZ2020 gate: upstream draws folds from numpy's global
RNG, the port from `seed=`, so bit equality is impossible and the band must come
from the fold noise. Measured over 12 upstream fold seeds at the shipped
configuration (`_verify/_cs2021_tol_1670.py`):

    cell        coef     fold_sd   |coef|/sd    3 sd
    (2,1,2)   1.1284     0.05094      22.2     0.1528
    (2,1,3)   1.9093     0.03828      49.9     0.1148
    (2,1,4)   2.9072     0.05118      56.8     0.1535
    (3,2,3)   0.8757     0.03028      28.9     0.0908
    (3,2,4)   1.6710     0.04076      41.0     0.1223
    (4,3,4)   0.8869     0.07496      11.8     0.2249

so 3 sd is a genuinely tight band on a signal 12-57x the noise, not a rubber
stamp. Observed port-vs-upstream offsets on the first green run were 0.12-0.63
sd, i.e. the gate has roughly 5x of headroom left before it turns red on noise
alone.

Every cell is measured individually; see `TOL_BY_CELL` for why that is enforced
rather than left to a fallback.

USAGE
=====
    python pyexample_did_cs2021.py --check     # the gate
    python pyexample_did_cs2021.py --write     # write the fixture, leave it
    python pyexample_did_cs2021.py --restore   # put the placeholder back
"""
from __future__ import annotations

import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(ROOT, "examples", "parity", "pyexample_data.mbt")

sys.path.insert(0, ROOT)

# --- fixture, swept for signal-to-noise (`_verify/_cs2021_sweep_1670.py`) ------
#     n_obs  dgp_seed  cell        coef   fold_sd  |coef|/sd
#       500        7  ATT(2,1,3)  2.0296  0.0690      29.4
#      1000        7  ATT(2,1,3)  1.9093  0.0457      41.8
#      2000        7  ATT(2,1,3)  2.1313  0.0125     171.1
# 1000 is the knee: 42x the fold noise, and half the fixture bytes of 2000.
DGP_SEED, N_OBS = 7, 1000
FIT_SEED = 42          # only selects upstream's folds, same role as in SZ2020
DGP_TYPE = 1           # linear in Z for both outcome and propensity
N_FOLDS, N_REP = 2, 1  # both sides; the port cannot do 5 without `propensity_clip`

# Per-cell 3-sd coefficient band, measured over 12 upstream fold seeds at the
# shipped configuration (n_obs=1000, DGP seed 7, LinearRegression /
# LogisticRegression, n_folds=2) by `_verify/_cs2021_tol_1670.py`.
#
#     cell        coef     coef_sd   |coef|/sd    3 sd
#     (2,1,2)   1.1284     0.05094      22.2     0.1528
#     (2,1,3)   1.9093     0.03828      49.9     0.1148
#     (2,1,4)   2.9072     0.05118      56.8     0.1535
#     (3,2,3)   0.8757     0.03028      28.9     0.0908
#     (3,2,4)   1.6710     0.04076      41.0     0.1223
#     (4,3,4)   0.8869     0.07496      11.8     0.2249
#
# Every cell is measured INDIVIDUALLY. An earlier revision of this table
# covered only 3 of the 6 and let the rest inherit a neighbour's number, which
# is the "never ship an unmeasured number" rule broken inside a tolerance --
# the one place it is least visible and most consequential.
#
# SE is gated on the SAME band, not a separately measured one. That is a
# deliberate looseness and it is recorded: the measured SE noise is an order of
# magnitude smaller (se_sd 0.0024-0.0109), so a real SE divergence of the size
# that showed up in the SZ2020 gate -- 8%, which was ~6 SE-noise units -- would
# be caught here, but a ~30% SE divergence on a single cell would not. Widening
# coef's band to cover SE too is what buys that; if the SE rows ever need to
# bite harder, measure a per-cell SE band and split the two.
TOL_BY_CELL = {
    (2, 1, 2): 3 * 0.05094,
    (2, 1, 3): 3 * 0.03828,
    (2, 1, 4): 3 * 0.05118,
    (3, 2, 3): 3 * 0.03028,
    (3, 2, 4): 3 * 0.04076,
    (4, 3, 4): 3 * 0.07496,
}


# --------------------------------------------------------------------------- #
# data + reference
# --------------------------------------------------------------------------- #
def build_cs2021():
    """Upstream's DGP, upstream's estimator, on both sides' common convention."""
    import numpy as np
    import doubleml as dml
    from doubleml.did.datasets import make_did_CS2021
    from doubleml.did.utils import _did_utils
    from sklearn.linear_model import LinearRegression, LogisticRegression

    np.random.seed(DGP_SEED)
    df = make_did_CS2021(n_obs=N_OBS, dgp_type=DGP_TYPE, time_type="float")

    # The integer recode. `inf` -> 0 puts never-treated at the minimum label,
    # which is the port's rule AND upstream's rule for integer dtype. ATT is
    # invariant to the labelling; this changes only which number names it.
    g = np.where(np.isinf(df["d"].to_numpy()), 0.0, df["d"].to_numpy()).astype(np.int64)
    t = df["t"].to_numpy().astype(np.int64)
    ntv = _did_utils._get_never_treated_value(np.unique(g))
    assert int(ntv) == int(g.min()), "never-treated recode did not land on min(g)"

    # The port's `d` is the per-ROW treatment indicator, not the group label.
    # Upstream's `is_exposed = exposure_time > 0`, and `exposure_time` is
    # `clip(t - tau_g + 1, 0, None)`, so exposure is exactly `t >= tau_g`, and
    # the never-treated cohort is never exposed.
    #
    # NOTE, measured: this column is DECORATIVE for the port's DID-CS fit.
    # `did_cs.mbt:1594` recomputes the sub-DID indicator from the panel itself
    # (`if gv == g_value && tv == eval_period`) and overwrites whatever `d` the
    # caller passed. A mutation battery confirmed it: permuting `d` left every
    # coefficient bit-identical, while permuting `g` killed the gate.
    #
    # So the `cs_d` round-trip row below proves the port RECEIVED the right
    # data, and `cs_g` / `cs_t` are the rows that actually carry weight for the
    # fit. All three are checked because the distinction is exactly the kind of
    # thing a reader gets wrong from the output alone.
    d = ((t >= g) & (g > 0)).astype(float)

    x = np.column_stack([df["Z%d" % k].to_numpy() for k in (1, 2, 3, 4)])
    y = df["y"].to_numpy(dtype=float)
    idc = df["id"].to_numpy().astype(np.int64)

    panel = dml.data.DoubleMLPanelData(
        df.assign(d=g, t=t), y_col="y", d_cols="d", id_col="id", t_col="t",
        x_cols=["Z1", "Z2", "Z3", "Z4"],
    )
    np.random.seed(FIT_SEED)
    est = dml.did.DoubleMLDIDMulti(
        obj_dml_data=panel,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(),
        gt_combinations="standard",
        control_group="never_treated",
        n_folds=N_FOLDS,
        n_rep=N_REP,
        draw_sample_splitting=False,
    )
    est.fit()
    upstream = {}
    for lab, c, s in zip(est.gt_labels, np.atleast_1d(est.coef), np.atleast_1d(est.se)):
        parts = lab[len("ATT("):-1].split(",")
        upstream[(int(parts[0]), int(parts[1]), int(parts[2]))] = (float(c), float(s))

    return {
        "x": x, "y": y, "d": d, "t": t, "id": idc, "g": g,
        "upstream": upstream,
        "never_treated": int(ntv),
    }


def comparable_cells():
    """The 6 cells both sides can express. Derived, then asserted against the
    measured partition so a change in either side shows up as a failure."""
    import numpy as np
    import doubleml as dml
    from doubleml.did.datasets import make_did_CS2021
    from doubleml.did.utils import _did_utils

    np.random.seed(DGP_SEED)
    df = make_did_CS2021(n_obs=N_OBS, dgp_type=DGP_TYPE, time_type="float")
    g = np.where(np.isinf(df["d"].to_numpy()), 0.0, df["d"].to_numpy()).astype(np.int64)
    t = df["t"].to_numpy().astype(np.int64)
    ntv = _did_utils._get_never_treated_value(np.unique(g))
    combos = _did_utils._construct_gt_combinations(
        "standard", np.sort(np.unique(g)), np.sort(np.unique(t)), ntv, 0)
    out = []
    for gv, tp, te in combos:
        gv, tp, te = int(gv), int(tp), int(te)
        # The port's base is g-1 (`did_cs.mbt:1563`); upstream must have landed
        # there too, or the two are estimating different things.
        if tp == gv - 1 and te >= gv:
            out.append((gv, tp, te))
    return out


# --------------------------------------------------------------------------- #
# fixture emission
# --------------------------------------------------------------------------- #
def _fmt(values, render, per_line):
    out, line = [], []
    for v in values:
        line.append(render(v))
        if len(line) == per_line:
            out.append("    " + ", ".join(line) + ",")
            line = []
    if line:
        out.append("    " + ", ".join(line) + ",")
    return "\n".join(out)


def fmt_doubles(values, per_line=6):
    """Round-trippable: repr() of a float is exact in Python 3."""
    return _fmt(values, lambda v: repr(float(v)), per_line)


def fmt_ints(values, per_line=12):
    return _fmt(values, lambda v: str(int(v)), per_line)


CS_HEADER = """
fn cs2021_generated() -> Int32 {
  1
}

fn cs2021_n_obs() -> Int32 {
  %d
}

fn cs2021_n_feat() -> Int32 {
  %d
}

fn cs2021_x() -> Array[Double] {
  [
%s
  ]
}

fn cs2021_y() -> Array[Double] {
  [
%s
  ]
}

fn cs2021_d() -> Array[Double] {
  [
%s
  ]
}

fn cs2021_t() -> Array[Int32] {
  [
%s
  ]
}

fn cs2021_id() -> Array[Int32] {
  [
%s
  ]
}

fn cs2021_g() -> Array[Int32] {
  [
%s
  ]
}

fn cs2021_n_cells() -> Int32 {
  %d
}

fn cs2021_cell_g(i : Int32) -> Int32 {
  [%s][i]
}

fn cs2021_cell_t_pre(i : Int32) -> Int32 {
  [%s][i]
}

fn cs2021_cell_t_eval(i : Int32) -> Int32 {
  [%s][i]
}
"""


def write_fixture(panel, cells):
    """Rewrite ONLY the cs2021 block, leaving the sz2020 block byte-identical.

    Both gates share one fixture file because one MoonBit build has to serve
    both, and a second placeholder file would need a second symbol set in
    `main.mbt` for no benefit. Splicing by anchor rather than regenerating the
    whole file is what makes that safe: `--check` rewrites the CS2021 half and
    restores it, and the SZ2020 half must come back untouched.
    """
    with io.open(FIXTURE, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()
    # The anchor is `cs2021_generated`, the FIRST symbol of the CS2021 block, so
    # the whole block including the sentinel is replaced. Anchoring one symbol
    # later (at `cs2021_n_obs`) emitted the sentinel twice and failed to compile
    # with "declared twice" -- measured, not reasoned about.
    anchor = "\nfn cs2021_generated() -> Int32 {"
    head, sep, _tail = text.partition(anchor)
    if not sep:
        raise SystemExit("could not find the cs2021 anchor in %s" % FIXTURE)
    body = CS_HEADER % (
        panel["y"].shape[0], panel["x"].shape[1],
        fmt_doubles(panel["x"].ravel()),
        fmt_doubles(panel["y"]),
        fmt_doubles(panel["d"]),
        fmt_ints(panel["t"]),
        fmt_ints(panel["id"]),
        fmt_ints(panel["g"]),
        len(cells),
        ", ".join(str(c[0]) for c in cells),
        ", ".join(str(c[1]) for c in cells),
        ", ".join(str(c[2]) for c in cells),
    )
    out = head + body
    io.open(FIXTURE, "w", encoding="utf-8", newline="\n").write(out)
    return len(out)


def snapshot_fixture():
    with open(FIXTURE, "rb") as fh:
        return fh.read()


def restore_fixture_bytes(blob):
    """Restore from bytes, with no dependency on git.

    The CI simulator materialises the tree with `git archive`, which contains no
    `.git` directory at all, so a git-based restore cannot work there.
    """
    with open(FIXTURE, "wb") as fh:
        fh.write(blob)


def restore_fixture():
    """git-based restore, for the standalone `--restore` mode only."""
    rel = os.path.relpath(FIXTURE, ROOT)
    if not os.path.isfile(FIXTURE):
        raise SystemExit("fixture missing; restore with: git checkout -- " + rel)
    r = subprocess.run(["git", "checkout", "--", rel], cwd=ROOT, capture_output=True)
    if r.returncode != 0:
        raise SystemExit("could not restore via git: %s"
                         % (r.stderr or b"").decode("utf-8", "replace"))


# --------------------------------------------------------------------------- #
# gate
# --------------------------------------------------------------------------- #
def run_emitter():
    import parity_helper as ph
    return ph.parse(ph.run_parity())["did_pyexample_cs2021"]


def main(argv):
    mode = argv[1] if len(argv) > 1 else "--check"
    if mode == "--restore":
        restore_fixture()
        print("restored the committed placeholder")
        return 0
    if mode not in ("--check", "--write"):
        print(__doc__)
        return 2

    panel = build_cs2021()
    cells = comparable_cells()
    # Every derived cell must have its OWN measured band. A silent fallback
    # would let a newly added cell be gated by an unrelated number, which is
    # precisely how the first version of this table went wrong (3 of 6 measured,
    # 3 inherited). Fail loudly instead.
    missing = [c for c in cells if c not in TOL_BY_CELL]
    if missing:
        raise SystemExit(
            "no MEASURED fold-noise band for cell(s) %s; measure them "
            "(_verify/_cs2021_tol_1670.py) rather than borrowing a neighbour's"
            % (missing,))
    n_upstream = len(panel["upstream"])
    print("upstream CS2021 example regenerated")
    print("  make_did_CS2021(n_obs=%d, dgp_type=%d) + int never-treated recode -> %d rows"
          % (N_OBS, DGP_TYPE, panel["y"].shape[0]))
    print("  cohorts g = %s, never-treated = %d (the minimum label)"
          % (sorted(set(panel["g"].tolist())), panel["never_treated"]))
    print("  upstream DoubleMLDIDMulti -> %d cells; %d are comparable with the port"
          % (n_upstream, len(cells)))
    for (g, tp, te) in cells:
        c, s = panel["upstream"][(g, tp, te)]
        print("    ATT(%d,%d,%d)  coef % .6f  se %.6f" % (g, tp, te, c, s))
    print()

    snapshot = snapshot_fixture()
    nbytes = write_fixture(panel, cells)
    if mode == "--write":
        print("wrote %d bytes to %s (leave with --restore)"
              % (nbytes, os.path.relpath(FIXTURE, ROOT)))
        return 0

    try:
        sec = run_emitter()
    finally:
        restore_fixture_bytes(snapshot)

    if sec["val"].get("cs_generated") != 1.0:
        print("FAIL: the emitter did not see the generated CS2021 fixture")
        return 1

    import parity_helper as ph
    rows = []
    n_cells = int(sec["val"]["cs_n_cells"])
    if n_cells != len(cells):
        print("FAIL: the port returned %d cells, expected %d" % (n_cells, len(cells)))
        return 1
    for i, (g, tp, te) in enumerate(cells):
        want_c, want_s = panel["upstream"][(g, tp, te)]
        got_c = sec["val"]["cs_coef_%d" % i]
        got_s = sec["val"]["cs_se_%d" % i]
        # Direct indexing, not .get() with a default. `main` has already
        # refused to start if any derived cell lacks a measured band, so a
        # silent fallback here would be unreachable -- and when this was a
        # `.get(..., DEFAULT_TOL)` the default had been deleted, which turned
        # the whole gate into a NameError. The control arm of the mutation
        # battery caught it; the 7 "killed" mutations in that run were being
        # scored against a gate that could not pass.
        tol = TOL_BY_CELL[(g, tp, te)]
        rows.append(("cs_coef ATT(%d,%d,%d) vs upstream (3sd=%.4f)" % (g, tp, te, tol),
                     got_c, want_c, abs(got_c - want_c) <= tol))
        rows.append(("cs_se   ATT(%d,%d,%d) vs upstream (3sd=%.4f)" % (g, tp, te, tol),
                     got_s, want_s, abs(got_s - want_s) <= tol))

    # The dataset travels with the estimate, so the validator can confirm the
    # port fitted the rows it was handed rather than some other panel.
    import numpy as np
    exp = {
        "cs_y": panel["y"], "cs_d": panel["d"],
        "cs_g": panel["g"].astype(float), "cs_t": panel["t"].astype(float),
    }
    for name, want in exp.items():
        got = np.asarray(sec["data"].get(name, []), dtype=float)
        rows.append(("%s round-trip (%d rows)" % (name, len(want)),
                     float(len(got)), float(len(want)), len(got) == len(want)))
        if len(got) == len(want):
            rows.append(("%s max |diff|" % name,
                         float(np.max(np.abs(got - want))), 0.0,
                         bool(np.max(np.abs(got - want)) == 0.0)))

    # The convention check, stated so it cannot pass circularly. `groups` is the
    # port's OWN discovery, with the never-treated sentinel already removed, so
    # `groups[0]` is the second-smallest label: 2 here, because 0 is the control
    # and 1 is absent from the CS2021 grid. A port that picked the wrong cohort
    # as control would move this row AND wreck the ATT rows -- a treated cohort
    # used as its own control returns ~0 or flips sign, which is exactly what
    # was measured before the integer recode (ATT(g=2, t=4) = -12.96 against a
    # realised truth of +2.96).
    rows.append(("cs_n_groups == 3 (control cohort excluded)",
                 sec["val"]["cs_n_groups"], 3.0, sec["val"]["cs_n_groups"] == 3.0))
    rows.append(("cs_min_group == 2 (0 is the control)",
                 sec["val"]["cs_min_group_excluded"], 2.0,
                 sec["val"]["cs_min_group_excluded"] == 2.0))
    rows.append(("cs_n_periods == 5",
                 sec["val"]["cs_n_periods"], 5.0, sec["val"]["cs_n_periods"] == 5.0))
    rows.append(("cs comparable cells (%d of upstream's %d)" % (len(cells), n_upstream),
                 float(len(cells)), float(n_upstream), len(cells) == 6 and n_upstream == 12))

    rc = ph.report("pyexample: port vs upstream make_did_CS2021", rows, ok=True)
    with open(FIXTURE, "rb") as fh:
        after = fh.read()
    same = after == snapshot
    print()
    print("fixture restored byte for byte: %s" % same)
    return rc if same else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
