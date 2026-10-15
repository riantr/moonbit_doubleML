"""Staggered DID (Callaway-Sant'Anna) checked cell by cell against CPython.

WHAT THIS USED TO BE
====================
The old file ran a hand-rolled numpy CS-DID on its own `default_rng` draw,
checked each cell was "within 0.5 of true", printed

    print("Reference: run `moon run examples/did_cs` for the MoonBit output.")
    print("PASS: did_cs reference")

and exited 0. As with `did_binary`, running MoonBit was an instruction in a
print statement.

THE CELL SEMANTICS, AND WHY THEY HAD TO BE MEASURED
====================================================
Two facts about `did_cs.mbt` determine what every cell means, and both are
load-bearing enough that guessing them produces a convincing false alarm:

1. **The control group is the MINIMUM group label.** `discover_groups_times`
   (`did_cs.mbt`:77-78) builds `groups` as "the sorted list of unique `g`
   values EXCLUDING the never-treated sentinel (the minimum of `g`)". So
   `group_idx` indexes `groups` (the adopting cohorts), and the control is
   whichever cohort label happens to be smallest -- which the caller must
   make genuinely untreated.

2. **`pre_period = g_value - 1`, fixed per group**, and every eval period
   `> pre_period` is compared against that one baseline (`did_cs.mbt`:1552-1568).
   So the six valid cells here are, with adoption at `k >= cohort`:

       g=0 (label 1, base 0):  t=1, t=2, t=3
       g=1 (label 2, base 1):             t=2, t=3
       g=2 (label 3, base 2):                     t=3

   Cells at or before the baseline are empty and documented to return 0.0.

HOW THAT WAS ESTABLISHED
========================
By getting it wrong twice and reading the numbers, not the source. A first
DGP put the never-treated cohort at the LAST label, so the port used a cohort
that that DGP treated as its control and returned `coef_at(0, 1) = -1.493`
against an effect of `+1.5` -- a sign error that looked exactly like a port
bug. Shifting adoption by one period did not fix it, because the mislabelled
control was still the minimum label. The port was right in both cases.

That is worth stating plainly, because the alternative -- keeping the first
"finding" and reporting a DID-CS sign bug -- would have been a confident,
well-formatted, wrong report produced entirely by a bad fixture.

WHAT IS COMPARED
================
For each valid cell, the reference is the plain difference in mean outcome
change between the adopting cohort and the control, over the same
`(base, eval)` period pair, computed on the outcome data the port itself used.
No model, no cross-fitting. MoonBit's number comes from a 2-fold cross-fit
with regression adjustment, so the two agree closely but not identically --
that residual gap IS the cross-fitting's contribution, and it is reported.

RUN
===
    python validate_did_cs_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parity_helper as ph  # noqa: E402

import numpy as np  # noqa: E402

N_PER_COHORT = 20
N_PERIODS = 4
N_UNITS = N_PER_COHORT * N_PERIODS
N = N_UNITS * N_PERIODS
TRUE_ATT = 1.5
ATT_TOL = 0.05


def panel_index():
    return lambda u, k: u * N_PERIODS + k  # noqa: E731


def independent_att(y, g, base_period, eval_period, g_label, g_control):
    """Difference in mean outcome change, adopting cohort vs control.

    The unit list is built by scanning unit indices and reading each unit's
    cohort at period 0. An earlier draft did `set(g[t == 0]) & {g_label}`,
    which intersects cohort VALUES and yields a single element that is a
    cohort label rather than a unit index -- it silently averaged one
    arbitrary row and returned ~0 for every cell.
    """
    idx = panel_index()
    a = [u for u in range(N_UNITS) if g[idx(u, 0)] == g_label]
    c = [u for u in range(N_UNITS) if g[idx(u, 0)] == g_control]
    da = np.array([y[idx(u, eval_period)] - y[idx(u, base_period)] for u in a])
    dc = np.array([y[idx(u, eval_period)] - y[idx(u, base_period)] for u in c])
    return float(da.mean() - dc.mean()), len(a), len(c)


def main() -> int:
    sec = ph.section("did_cs")
    y = np.array(ph.data(sec, "did_cs_y"))
    d = np.array(ph.data(sec, "did_cs_d"))
    t = np.array(ph.data(sec, "did_cs_t"), dtype=int)
    g = np.array(ph.data(sec, "did_cs_g"), dtype=int)
    uid = np.array(ph.data(sec, "did_cs_id"), dtype=int)
    idx = panel_index()

    # Discover the same way the port does: unique labels, control = minimum.
    all_groups = sorted(set(int(v) for v in g))
    g_control = all_groups[0]
    groups = [x for x in all_groups if x != g_control]

    rows = [
        ("data did_cs_y", len(y), N, len(y) == N),
        ("data did_cs_d", len(d), N, len(d) == N),
        ("n_groups", ph.val(sec, "n_groups"), float(len(groups)),
         ph.val(sec, "n_groups") == float(len(groups))),
        ("n_periods", ph.val(sec, "n_periods"), float(N_PERIODS),
         ph.val(sec, "n_periods") == float(N_PERIODS)),
    ]

    # The structure must be self-consistent: cohort 0 is the control and is
    # untreated throughout, adoption is at k >= cohort, every unit has all
    # four periods, and the control really is the minimum label.
    struct_ok = True
    for u in range(N_UNITS):
        c = u // N_PER_COHORT
        for k in range(N_PERIODS):
            row = idx(u, k)
            want = 0.0 if (c == 0 or k < c) else 1.0
            if (d[row] != want or t[row] != k or g[row] != c
                    or uid[row] != u):
                struct_ok = False
    rows.append(("panel structure matches d rule", struct_ok, True, struct_ok))
    rows.append(("control group is min label", float(g_control),
                 float(min(all_groups)), g_control == min(all_groups)))

    control_diff_max = max(
        float(np.max(np.abs(d[(g == g_control)])))
        for _ in [0])
    rows.append(("control cohort never treated", control_diff_max, 0.0,
                 control_diff_max == 0.0))

    print("panel: %d units x %d periods, %d cohorts"
          % (N_UNITS, N_PERIODS, N_UNITS // N_PER_COHORT))
    print("control cohort = min label = %d (must be untreated throughout)" % g_control)
    print("adopting cohorts %s, adoption at k >= cohort, effect +%.1f"
          % (groups, TRUE_ATT))
    print()
    print("%-4s %-4s %-6s %-18s %-18s %-10s"
          % ("g", "t", "base", "moonbit coef_at", "independent (CPython)",
             "verdict"))

    n_valid = 0
    for gi, g_label in enumerate(groups):
        base = g_label - 1
        for ti, t_label in enumerate(range(N_PERIODS)):
            got = ph.val(sec, "att_g%d_t%d" % (gi, ti))
            if t_label <= base:
                # Documented as empty; the port returns the 0.0 it was
                # initialised with.
                ok = got == 0.0
                print("%-4d %-4d %-6s %-18.10g %-18s %s"
                      % (gi, ti, base, got, "(empty)", "ok" if ok else "NOT EMPTY"))
                rows.append(("att_g%d_t%d (empty)" % (gi, ti), got, 0.0, ok))
                continue
            ref, n_a, n_c = independent_att(y, g, base, t_label,
                                            g_label, g_control)
            n_valid += 1
            ok = abs(got - ref) <= ATT_TOL
            print("%-4d %-4d %-6d %-18.10g %-18.10g %s"
                  % (gi, ti, base, got, ref, "ok" if ok else "MISMATCH"))
            rows.append(("att_g%d_t%d" % (gi, ti), got, ref, ok))
            rows.append(("att_g%d_t%d vs 1.5" % (gi, ti), got, TRUE_ATT,
                         abs(got - TRUE_ATT) <= ATT_TOL))

    print()
    print("valid cells compared: %d (every one should recover the +%.1f effect)"
          % (n_valid, TRUE_ATT))
    se = ph.val(sec, "att_se_g0_t1")
    rows.append(("att_se_g0_t1 > 0", se, "> 0", se > 0.0))
    print()

    return ph.report("staggered DID parity", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
