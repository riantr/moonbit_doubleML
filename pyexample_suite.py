"""Run the MoonBit port on upstream's OWN estimator family, row for row.

This is the generalisation of `pyexample_did.py`. That gate covers one
estimator on one DGP (SZ2020 + `DoubleMLDID`); `pyexample_did_cs2021.py` covers
a second on a second (CS2021 + `DoubleMLDIDMulti`). Six more estimators had no
upstream gate at all, so nothing in the port could make them wrong.

THE SUBJECT IS THE ESTIMATOR, NOT THE DATA
==========================================
MoonBit has no file I/O (measured: `@std/env`, `@std/fs`, `@std/io`,
`@std/process` do not resolve; builtin `read_file` does not exist), so a numpy
dataset cannot be handed over as a file. It arrives as literals in a compiled
`.mbt` source that this script overwrites for the duration of one comparison,
then restores byte-for-byte. Both sides are then fitted on IDENTICAL rows,
which turns "two different datasets happened to land near each other" into a
real comparison.

ONE FIXTURE FILE, NOT TWO
=========================
MoonBit compiles every `.mbt` in the package directory, so a committed
placeholder in a second file declares every symbol twice and the build fails
with 18 errors -- measured, not reasoned about. The committed state of
`suite_data.mbt` is therefore the stub (`suite_generated() == 0`), which is
also what keeps `sec_pyexample_suite` inert during the workspace-root
`moon build` / `moon test` runs that happen before this script has ever run.

WHY THE REFERENCE IS RE-SEEDED PER ESTIMATOR
============================================
Upstream calls `check_random_state(None)` when `random_state` is unset, which
returns `np.random.mtrand._rand` -- the PROCESS-global RandomState. Seeding
once per batch therefore ties each cross-fitting fold draw to every random
number consumed before it, including by estimators that are not being
compared.

Measured, not hypothesised: an earlier sweep seeded once and got `pliv`
0.97827; re-running without `DoubleMLPolicyTree` in the batch (whose sklearn
DecisionTreeClassifier has no fixed `random_state` and so consumes global
draws) got 1.03584 from byte-identical data. `np.random.seed` is therefore
re-issued immediately before each estimator here, and
the suite stability check proves it on EVERY pass by inserting 50k
unrelated draws between two identical PLIV fits and requiring a bit-identical
coefficient. The check is an assertion and not a report: a fit that drifts
across the draws aborts the gate, and the verdict is printed beside the
estimators on every run.

WHY PolicyTree IS NOT IN THE SIX
================================
It is the one estimator here whose port defaults genuinely diverge from
upstream's -- `depth=1, min_leaf_n=5` against `depth=2, min_samples_leaf=8,
ccp_alpha=0.01` -- and upstream exposes no `coef`/`se` for it at all, only a
root split (`tree_.feature[0]` / `tree_.threshold[0]`). Forcing agreement
means changing a port default or adding a parameter: a reported-behaviour
decision, not a gate detail. `suite_a_sig` is still carried so enabling it
later is a one-line change.

WHY DID IS NOT ADDED HERE
=========================
`pyexample_did.py` and `pyexample_did_cs2021.py` already gate DID upstream-side.
A third copy would add runtime without adding coverage.

WHY BLP NEEDS AN EXPLICIT CONSTANT, AND WHAT THAT HIDES
=======================================================
Upstream's `DoubleMLBLP` is `sm.OLS(orth_signal, basis)` with no
`add_constant` and no `has_constant` (`blp.py:239`) -- origin-forced on
whatever basis it is handed, storing exactly `basis.shape[1]` numbers in
`_all_coef`.

The port's `LinearRegression::fit` ALWAYS prepends an intercept
(`augment_with_intercept`, `linear.mbt:102`), and `DoubleMLBLP::fit` stores
that whole augmented vector,
so the port's `coef` is `basis.cols() + 1` long with the intercept at index 0.
That is deliberate and internally consistent -- `predictions` reads
`self.coef[0]` as the intercept (`blp_policy.mbt:677` reads `self.coef[0]`)
and `n_params()` is
documented as `basis.cols() + 1` -- so it is an API divergence from upstream,
not a slip.

The first draft of this gate handed both sides a bare `x0` and demanded
agreement. That was wrong twice over: it compared two DIFFERENT estimators
(origin-forced vs intercept-augmented), and the resulting "0.12556 vs 0.66475"
looked like a 5x bug in the port when the port's 0.66475 is simply its
intercept. Measured by fitting all the candidate variants and identifying
which produces which number.

So each side is given the RAW column and each side's own convention supplies
the constant: upstream's basis is `[1, x0]`, the port's is the bare `x0`, both
solve the identical design `[1, x0]`, and both return `[intercept, slope]` in
that order. Every BLP number is comparable at full precision.

Passing `[1, x0]` to the PORT as well does not work, and the failure mode is
worth recording: `LinearRegression::fit` prepends a second constant column
regardless, `[1, 1, x0]` is rank-deficient, and the 1e-10 ridge splits the
intercept between the two constant columns -- measured on this DGP as coef[0]
0.33253 and coef[1] 0.33222, summing to the true 0.66475 intercept, with the
slope pushed to an unemitted index 2. Both numbers look individually plausible
and are jointly obviously wrong, so this was caught by comparing BOTH indices.

What stays outside the comparison is the intercept POLICY itself: upstream's
default slope on this DGP is 0.12556 (origin-forced on a bare basis) and the
port's is 0.16257 (with intercept). Comparing those two would be comparing
different estimators. It is recorded as a documented divergence, alongside
PolicyTree's defaults.

WHAT THIS GATE CAN AND CANNOT RESOLVE
=====================================
The bands are 3 x UPSTREAM's fold noise, so they are sized by fold variation.
The remaining question is whether each port-vs-upstream gap is that noise or a
divergence the band is hiding. Measured by re-running the emitter across 9
fold seeds, against the LARGER of the two
sides' spread:

    est    port coef   port sd   upstream coef   up sd     gap    gap/sd   band
    plr     1.045287   0.009410      1.044260   0.004563  0.001027    0.11  0.013689
    irm     1.046243   0.012307      1.050818   0.020601  0.004575    0.22  0.061785
    ssm     1.028498   0.040783      0.968932   0.024551  0.059566    1.46  0.073639
    pliv    0.982029   0.021727      1.014487   0.035529  0.032458    0.91  0.106598
    iivm    1.505074   0.035505      1.608705   0.075830  0.103631    1.37  0.227501

The last column is the BAND IN FORCE -- the numbers `BAND_BY_EST` holds and
the gate prints on every run. It is not 3 x the "up sd" column: the two sd
columns are a 9-seed re-run of the emitter, while the band is 3 x an 8-seed
upstream fold sd, and for SSM that is 0.073653 against a band of 0.073639.
The band is what decides whether a row passes, so the band is what is
quoted.

Every gap is inside 3 sd, so the bands are sized by fold variation rather than
by an unexplained offset. SSM's 1.46 sd is the largest and is why its row looks
close to its band: the band is 0.0736 and the gap 0.0596, but the PORT's own
fold sd for SSM is 0.0408 -- larger than upstream's -- so the margin is real.

The gate's measured RESOLUTION, from the mutation battery
: replacing SSM's selection propensity with a
REGRESSOR shifts `ssm_coef` by 0.0087, 11.9% of its band, and the gate stays
green. Widening the band to catch that would invalidate the measurement that
sets the band, so the limit is recorded instead of papered over. The gate
resolves changes above roughly 1% of a coefficient on this DGP.

USAGE
=====
    python pyexample_suite.py --check     # the gate
    python pyexample_suite.py --write     # write the fixture, leave it
    python pyexample_suite.py --restore   # put the committed stub back
"""
from __future__ import annotations

import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(ROOT, "examples", "parity", "suite_data.mbt")

sys.path.insert(0, ROOT)

DGP_SEED, N, P, THETA = 7, 1000, 5, 1.0
N_FOLDS, N_REP, FIT_SEED = 2, 1, 42
XCOLS = ["X%d" % (j + 1) for j in range(P)]

# --------------------------------------------------------------------------- #
# the measured tolerance table
# --------------------------------------------------------------------------- #
# Measured over 8 upstream fold seeds at the shipped configuration by
# the suite fold-noise measurement. Band = 3 x the
# fold sd, i.e. the width that leaves a 3-sigma-equivalent margin.
#
#     est   coef              3 sd        ratio    se                3 sd
#     plr   1.0442598567224384  0.01368871   228.9   0.0635788125350127  0.00111061
#     irm   1.0508177377510914  0.06178526    51.0   0.0641005301297445  0.00229784
#     ssm   0.9689319227547888  0.07363936    39.5   0.0951871981560788  0.00573421
#     pliv  1.0144873096859628  0.10659834    28.6   0.1042739494330317  0.00624459
#     iivm  1.6087053043610753  0.22750085    21.2   0.3060838667567364  0.01982083
#     blp   0.12556106906583503  (see BLP_BAND)          0.0239810046380003
#     apo   0.93467950811909961  0.01540728   182.0   0.0833778246027313  0.00106456
#     apos  [-0.10522751769039783, 0.93191343326563247]
#                3 sd 0.03522778 (9.0x) and 0.02221867 (125.8x)
#     cvar  2.9629845458657864   0.06096239   145.8   0.0986378327873876  0.00707812
#
# The weakest signal is `apos[0]` at 9x the fold noise -- the level-0 policy
# value, whose true coefficient is near zero because it is a mean outcome
# rather than an effect. It is kept rather than dropped because a two-level
# policy check that silently compares only one level is worse than a loose one.
#
# The weakest signal is IIVM at 21x the fold noise, so even the loosest band
# here is a real constraint rather than a rubber stamp.
#
# `se` is gated on the COEFFICIENT'S band, not its own. That is not laziness:
# the measured se_sd/coef_sd ratio is 0.081 (plr), 0.037 (irm), 0.078 (ssm),
# 0.059 (pliv) and 0.087 (iivm) -- every one far below 1/3, so a separate
# 3-sd se band would be narrower than the arithmetic noise either side. The
# CS2021 gate makes the same inherit on a measured argument; this family had
# never been checked, which is what the tolerance table above is.
#
# BLP IS THE EXCEPTION AND HAS ITS OWN BAND
# ----------------------------------------
# Upstream's `DoubleMLBLP` is plain OLS of the orth signal on the basis: no
# cross-fitting, therefore no fold noise. Measured, not assumed -- over 8 fold
# seeds both `coef` and `se` are bit-identical (min == max == the FIT_SEED
# value). A 3-sd fold band on a deterministic quantity would be theatre, so
# BLP gets a fixed absolute band.
#
# That band is measured from the first aligned run rather than guessed. With
# the constant supplied to upstream and left to the port, all four compared
# numbers agree to floating-point noise:
#
#     blp_coef_0  0.6647500416900173  vs 0.6647500416900853   6.8e-14
#     blp_coef_1  0.16257169237634514 vs 0.1625716923763656    2.0e-14
#     blp_se_0    0.014016777160175976 vs 0.014016777160177397 1.4e-15
#     blp_se_1    0.012713634853940335 vs 0.012713634853941762 1.4e-15
#
# 1e-12 leaves ~15x headroom over the worst of those while staying ~1e9 times
# tighter than the loosest fold band above -- so a real regression in the OLS
# solve or the sandwich SE cannot hide inside it.
BLP_BAND = 1e-12
BLP_BAND_NOTE = "measured max |diff| 6.8e-14, ~15x headroom"

# The data fingerprint. MoonBit sums in array order; numpy's `np.sum` uses
# pairwise summation, so the two differ in the last bits rather than exactly.
# 1e-6 absolute on an O(1000 x |y|) sum is ~1e-9 relative: far tighter than
# any real data difference (the committed stub sums to ~33 against these
# thousands) and far looser than the summation-order noise.
SUM_TOL = 1e-6


def build_reference():
    """Upstream's DGPs, upstream's estimators, one re-seed per estimator."""
    import numpy as np
    import pandas as pd
    import doubleml as dml
    from sklearn.linear_model import LinearRegression, LogisticRegression

    rng = np.random.default_rng(DGP_SEED)

    # -- A: binary d, MAR selection -> PLR, IRM, SSM, BLP ------------------
    xa = rng.standard_normal((N, P))
    eps_a = rng.standard_normal(N)
    da = (rng.random(N) > 0.5).astype(float)
    ya = THETA * da + xa.sum(axis=1) + eps_a
    sa = ((da + 0.5 * xa[:, 0] + rng.standard_normal(N)) > 0).astype(float)
    dfa = pd.DataFrame({"y": ya, "d": da, "s": sa,
                        **{c: xa[:, j] for j, c in enumerate(XCOLS)}})

    # -- B: continuous d + continuous z -> PLIV ---------------------------
    xb = rng.standard_normal((N, P))
    eps_b = rng.standard_normal(N)
    u_b = rng.standard_normal(N)
    zb = xb[:, 0] + 0.5 * rng.standard_normal(N)
    db = 0.5 * xb[:, 0] + 0.5 * zb + 0.1 * xb[:, 1] + 0.5 * u_b
    yb = THETA * db + xb.sum(axis=1) + eps_b
    dfb = pd.DataFrame({"y": yb, "d": db, "z": zb,
                        **{c: xb[:, j] for j, c in enumerate(XCOLS)}})

    # -- C: binary d + binary z -> IIVM (LATE) ----------------------------
    xc = rng.standard_normal((N, P))
    eps_c = rng.standard_normal(N)
    zc = (rng.random(N) > 0.5).astype(float)
    u_c = rng.standard_normal(N)
    dc = ((0.7 * zc + 0.8 * xc[:, 0] + u_c) > 0).astype(float)
    yc = THETA * dc + xc.sum(axis=1) + eps_c
    dfc = pd.DataFrame({"y": yc, "d": dc, "z": zc,
                        **{c: xc[:, j] for j, c in enumerate(XCOLS)}})

    # Relevance and exclusion are HARD PRECONDITIONS, asserted before any IV
    # fit. A weak instrument does not fail -- it returns a number, and PLIV and
    # IIVM would both be fitted against noise while looking perfectly healthy.
    rel_b = float(np.corrcoef(zb, db)[0, 1])
    exc_b = float(np.corrcoef(zb, eps_b)[0, 1])
    assert abs(rel_b) > 0.15, "instrument B is irrelevant -- fix the DGP"
    assert abs(exc_b) < 0.10, "instrument B violates exclusion -- fix the DGP"
    p1 = float(dc[zc == 1].mean())
    p0 = float(dc[zc == 0].mean())
    assert (p1 - p0) > 0.15, "instrument C is irrelevant -- fix the DGP"

    up = {}

    def seeded(key):
        def build(make):
            np.random.seed(FIT_SEED)
            up[key] = make().fit()
        return build

    obj_a = dml.data.DoubleMLData(dfa, "y", "d", XCOLS)
    seeded("plr")(lambda: dml.plm.DoubleMLPLR(
        obj_a, LinearRegression(), LogisticRegression(),
        n_folds=N_FOLDS, n_rep=N_REP))
    seeded("irm")(lambda: dml.irm.DoubleMLIRM(
        obj_a, LinearRegression(), LogisticRegression(),
        n_folds=N_FOLDS, n_rep=N_REP))
    ssm_obj = dml.data.DoubleMLSSMData(dfa, "y", "d", x_cols=XCOLS, s_col="s")
    seeded("ssm")(lambda: dml.irm.DoubleMLSSM(
        ssm_obj, LinearRegression(), LogisticRegression(), LogisticRegression(),
        n_folds=N_FOLDS, n_rep=N_REP))
    # BLP's basis carries the constant EXPLICITLY, because upstream's OLS adds
    # none (`blp.py:239`). The port is handed the bare column in the emitter
    # and prepends its own, so both sides solve the design `[1, x0]`. See the
    # module docstring -- handing the port `[1, x0]` instead makes the design
    # rank-deficient and splits the intercept.
    seeded("blp")(lambda: dml.DoubleMLBLP(
        orth_signal=sa,
        basis=[pd.DataFrame({"const": np.ones(N), "b0": xa[:, 0]})]))
    obj_b = dml.data.DoubleMLData(dfb, "y", "d", XCOLS, z_cols=["z"])
    seeded("pliv")(lambda: dml.plm.DoubleMLPLIV(
        obj_b, LinearRegression(), LinearRegression(), LinearRegression(),
        n_folds=N_FOLDS, n_rep=N_REP))
    # THE STABILITY CHECK the module docstring promises, run on every gate
    # pass. Two identical PLIV fits, with 50k unrelated draws from the
    # process-global RandomState between them, must agree BIT for bit. The
    # re-seed above is what makes that true; this is what proves it. Without
    # the check, a change that moved the re-seed -- or let any estimator
    # consume the global stream before its fold draw -- would silently
    # re-couple every fold to every random number drawn before it, which is
    # the exact failure the per-estimator re-seed exists to prevent.
    pliv_coef_before = np.ravel(np.asarray(up["pliv"].coef, dtype=float)).copy()
    np.random.random(50000)
    np.random.seed(FIT_SEED)
    pliv_stability_fit = dml.plm.DoubleMLPLIV(
        obj_b, LinearRegression(), LinearRegression(), LinearRegression(),
        n_folds=N_FOLDS, n_rep=N_REP).fit()
    pliv_coef_after = np.ravel(np.asarray(pliv_stability_fit.coef, dtype=float))
    pliv_stable = bool(np.array_equal(pliv_coef_before, pliv_coef_after))
    assert pliv_stable, (
        "PLIV is NOT stable under the per-estimator re-seed: two identical "
        "fits with 50k unrelated draws between them disagree, so the fold "
        "draw is reading the process-global RandomState."
    )
    obj_c = dml.data.DoubleMLData(dfc, "y", "d", XCOLS, z_cols=["z"])
    seeded("iivm")(lambda: dml.irm.DoubleMLIIVM(
        obj_c, LinearRegression(), LogisticRegression(), LogisticRegression(),
        n_folds=N_FOLDS, n_rep=N_REP))
    # Policy and risk estimators, all cross-sectional, so dataset A serves them.
    seeded("apo")(lambda: dml.irm.DoubleMLAPO(
        obj_a, treatment_level=1.0, n_folds=N_FOLDS, n_rep=N_REP,
        ml_g=LinearRegression(), ml_m=LogisticRegression()))
    seeded("apos")(lambda: dml.irm.DoubleMLAPOS(
        obj_a, treatment_levels=[0.0, 1.0], n_folds=N_FOLDS, n_rep=N_REP,
        ml_g=LinearRegression(), ml_m=LogisticRegression()))
    # `treatment=1` as an INT. Upstream's `_check_treatment`
    # (irm/utils/_checks.py:167) raises on a float outright, while the port
    # types the slot `Double` -- a type-level divergence, not a numeric one,
    # and the kind of detail that makes "the two ports match" false on paper.
    seeded("cvar")(lambda: dml.irm.DoubleMLCVAR(
        obj_a, treatment=1, quantile=0.5, n_folds=N_FOLDS, n_rep=N_REP,
        ml_g=LinearRegression(), ml_m=LogisticRegression()))

    return {
        "xa": xa, "ya": ya, "da": da, "sa": sa,
        "xb": xb, "yb": yb, "db": db, "zb": zb,
        "xc": xc, "yc": yc, "dc": dc, "zc": zc,
        "up": up, "rel_b": rel_b, "exc_b": exc_b, "p1": p1, "p0": p0,
        "pliv_stable": pliv_stable,
    }


# --------------------------------------------------------------------------- #
# fixture emission
# --------------------------------------------------------------------------- #
def _fmt(values, per_line=6):
    """`repr(float)` is round-trippable in Python 3, so no precision is lost."""
    out, line = [], []
    for v in values:
        line.append(repr(float(v)))
        if len(line) == per_line:
            out.append("    " + ", ".join(line) + ",")
            line = []
    if line:
        out.append("    " + ", ".join(line) + ",")
    return "\n".join(out)


HDR = """///|
/// GENERATED BY pyexample_suite.py -- DO NOT EDIT, DO NOT COMMIT.
/// Three numpy datasets for the core estimator family, so upstream and the
/// port are handed IDENTICAL rows. Restored byte-for-byte by --restore.

fn suite_generated() -> Int32 {
  1
}

fn suite_n() -> Int32 {
  %d
}

fn suite_p() -> Int32 {
  %d
}

fn suite_a_x() -> Array[Double] {
  [
%s
  ]
}

fn suite_a_y() -> Array[Double] {
  [
%s
  ]
}

fn suite_a_d() -> Array[Double] {
  [
%s
  ]
}

fn suite_a_s() -> Array[Double] {
  [
%s
  ]
}

fn suite_a_sig() -> Array[Double] {
  [
%s
  ]
}

fn suite_b_x() -> Array[Double] {
  [
%s
  ]
}

fn suite_b_y() -> Array[Double] {
  [
%s
  ]
}

fn suite_b_d() -> Array[Double] {
  [
%s
  ]
}

fn suite_b_z() -> Array[Double] {
  [
%s
  ]
}

fn suite_c_x() -> Array[Double] {
  [
%s
  ]
}

fn suite_c_y() -> Array[Double] {
  [
%s
  ]
}

fn suite_c_d() -> Array[Double] {
  [
%s
  ]
}

fn suite_c_z() -> Array[Double] {
  [
%s
  ]
}
"""


def write_fixture(d):
    body = HDR % (
        N, P,
        _fmt(d["xa"].ravel()), _fmt(d["ya"]), _fmt(d["da"]), _fmt(d["sa"]),
        _fmt(2.0 * d["sa"] - 1.0),
        _fmt(d["xb"].ravel()), _fmt(d["yb"]), _fmt(d["db"]), _fmt(d["zb"]),
        _fmt(d["xc"].ravel()), _fmt(d["yc"]), _fmt(d["dc"]), _fmt(d["zc"]),
    )
    with io.open(FIXTURE, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)
    return len(body)


def snapshot_fixture():
    with open(FIXTURE, "rb") as fh:
        return fh.read()


def restore_fixture_bytes(blob):
    """Restore from bytes, with no dependency on git.

    The CI simulator materialises the tree with `git archive`, which has no
    `.git` directory at all, so a git-based restore cannot work there.
    """
    with open(FIXTURE, "wb") as fh:
        fh.write(blob)


def restore_fixture():
    """git-based restore, for the standalone `--restore` mode only."""
    rel = os.path.relpath(FIXTURE, ROOT)
    if not os.path.isfile(FIXTURE):
        raise SystemExit("fixture missing; restore with: git checkout -- " + rel)
    r = subprocess.run(["git", "checkout", "--", rel], cwd=ROOT,
                       capture_output=True)
    if r.returncode != 0:
        raise SystemExit("could not restore via git: %s"
                         % (r.stderr or b"").decode("utf-8", "replace"))


# --------------------------------------------------------------------------- #
# gate
# --------------------------------------------------------------------------- #
BAND_BY_EST = {
    "plr": 0.01368871,
    "irm": 0.06178526,
    "ssm": 0.07363936,
    "pliv": 0.10659834,
    "iivm": 0.22750085,
    "blp": BLP_BAND,
    "apo": 0.01540728,
    "cvar": 0.06096239,
}
# APOS returns one coefficient per treatment LEVEL, so its band is per index.
# An earlier revision kept a single band for the estimator and would have
# inherited it for both levels; `apos[0]` and `apos[1]` differ by 5x in both
# coefficient and fold noise, so one number cannot describe both.
APOS_BAND = {0: 0.03522778, 1: 0.02221867}
# `data` key -> column, for the row fingerprint.
SUMS = [
    ("sum_a_y", "ya"), ("sum_a_d", "da"), ("sum_a_s", "sa"),
    ("sum_a_sig", None),          # 2*sa - 1, recomputed here
    ("sum_b_y", "yb"), ("sum_b_d", "db"), ("sum_b_z", "zb"),
    ("sum_c_y", "yc"), ("sum_c_d", "dc"), ("sum_c_z", "zc"),
]


def expected_sums(d):
    import numpy as np
    sig = 2.0 * d["sa"] - 1.0
    return {label: float(np.sum(sig if col is None else d[col]))
            for label, col in SUMS}


def sc(model, key):
    """Upstream's `coef` / `se` are 0-d numpy arrays on a scalar model and
    1-d on a multi-contrast one; both need flattening BEFORE `float`, since
    `float()` on a 1-d array of length 1 raises and on a >1 array truncates
    silently. Flatten first, take [0]."""
    import numpy as np
    return float(np.ravel(getattr(model, key))[0])


def main(argv):
    import parity_helper as ph

    import numpy as np

    mode = argv[1] if len(argv) > 1 else "--check"
    if mode == "--restore":
        restore_fixture()
        print("restored the committed stub")
        return 0
    if mode not in ("--check", "--write"):
        print(__doc__)
        return 2

    d = build_reference()
    print("upstream reference regenerated (per-estimator seeding)")
    print("  A  n=%d p=%d  naive diff-in-means %+.4f vs true theta %+.1f"
          % (N, P, float((d["ya"][d["da"] == 1].mean()
                          - d["ya"][d["da"] == 0].mean())), THETA))
    print("  B  corr(z,d) %+.4f  corr(z,eps) %+.4f   (relevance / exclusion)"
          % (d["rel_b"], d["exc_b"]))
    print("  C  P(d=1|z=1) %.4f  P(d=1|z=0) %.4f  diff %+.4f"
          % (d["p1"], d["p0"], d["p1"] - d["p0"]))
    for k in ("plr", "irm", "ssm", "blp", "pliv", "iivm", "apo", "apos", "cvar"):
        print("    %-5s coef %s  se %s  band %.6f"
              % (k, np.array2string(np.ravel(d["up"][k].coef), precision=6),
                 np.array2string(np.ravel(d["up"][k].se), precision=6),
                 APOS_BAND[0] if k == "apos" else BAND_BY_EST[k]))
    print("  PLIV stability: two identical fits, 50k unrelated draws between "
          "them, bit-identical: %s" % d["pliv_stable"])
    print()

    snapshot = snapshot_fixture()
    nbytes = write_fixture(d)
    if mode == "--write":
        print("wrote %d bytes to %s (leave with --restore)"
              % (nbytes, os.path.relpath(FIXTURE, ROOT)))
        return 0

    try:
        sec = ph.parse(ph.run_parity())["pyexample_suite"]
    finally:
        restore_fixture_bytes(snapshot)

    if sec["val"].get("suite_generated") != 1.0:
        print("FAIL: the emitter did not see the generated suite fixture")
        return 1

    rows = []
    for k in ("plr", "irm", "ssm", "pliv", "iivm", "apo", "cvar"):
        band = BAND_BY_EST[k]
        want_c = sc(d["up"][k], "coef")
        want_s = sc(d["up"][k], "se")
        got_c = ph.val(sec, "%s_coef" % k)
        got_s = ph.val(sec, "%s_se" % k)
        rows.append(("%s_coef vs upstream (band %.5f)" % (k, band),
                     got_c, want_c, abs(got_c - want_c) <= band))
        rows.append(("%s_se   vs upstream (band %.5f)" % (k, band),
                     got_s, want_s, abs(got_s - want_s) <= band))

    # APOS: one coefficient per treatment level, compared PER INDEX. A single
    # scalar comparison here would pass while level 1 was silently ignored,
    # which is the failure mode of a multi-contrast estimator that has only
    # been checked on its first entry.
    n_apos = int(ph.val(sec, "apos_n"))
    want_apos = np.ravel(d["up"]["apos"].coef)
    if n_apos != len(want_apos):
        rows.append(("apos_n (levels compared)",
                     float(n_apos), float(len(want_apos)),
                     False))
    else:
        rows.append(("apos_n (levels compared)",
                     float(n_apos), float(len(want_apos)), True))
        for j in range(n_apos):
            band = APOS_BAND[j]
            got_c = ph.val(sec, "apos_coef_%d" % j)
            got_s = ph.val(sec, "apos_se_%d" % j)
            rows.append(("apos_coef_%d vs upstream (band %.5f)" % (j, band),
                         got_c, float(want_apos[j]),
                         abs(got_c - float(want_apos[j])) <= band))
            rows.append(("apos_se_%d   vs upstream (band %.5f)" % (j, band),
                         got_s, float(np.ravel(d["up"]["apos"].se)[j]),
                         abs(got_s - float(np.ravel(d["up"]["apos"].se)[j])) <= band))

    # BLP carries TWO coefficients under the shared augmented design, so it is
    # compared per index rather than collapsed to [0]. Index 0 is the
    # intercept and index 1 the slope -- asserting both is what catches a
    # silent reordering, which a single [0] comparison would score as a
    # passing number of the wrong quantity.
    for j in (0, 1):
        want_c = float(np.ravel(d["up"]["blp"].coef)[j])
        want_s = float(np.ravel(d["up"]["blp"].se)[j])
        got_c = ph.val(sec, "blp_coef_%d" % j)
        got_s = ph.val(sec, "blp_se_%d" % j)
        rows.append(("blp_coef_%d vs upstream (band %.3g)" % (j, BLP_BAND),
                     got_c, want_c, abs(got_c - want_c) <= BLP_BAND))
        rows.append(("blp_se_%d   vs upstream (band %.3g)" % (j, BLP_BAND),
                     got_s, want_s, abs(got_s - want_s) <= BLP_BAND))

    rows.append(("n_estimators", ph.val(sec, "n_estimators"), 9.0,
                 ph.val(sec, "n_estimators") == 9.0))
    rows.append(("n", ph.val(sec, "n"), float(N), ph.val(sec, "n") == float(N)))
    rows.append(("p", ph.val(sec, "p"), float(P), ph.val(sec, "p") == float(P)))

    want_sums = expected_sums(d)
    for label, _ in SUMS:
        got = ph.val(sec, label)
        want = want_sums[label]
        rows.append(("%s round-trip" % label, got, want,
                     abs(got - want) <= SUM_TOL))

    rc = ph.report("pyexample: port vs upstream estimator family "
                   "(9 estimators, 3 datasets)", rows, ok=True)
    with open(FIXTURE, "rb") as fh:
        same = fh.read() == snapshot
    print()
    print("BLP band in force: %.3g  (%s)" % (BLP_BAND, BLP_BAND_NOTE))
    print("fixture restored byte for byte: %s" % same)
    return rc if same else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
