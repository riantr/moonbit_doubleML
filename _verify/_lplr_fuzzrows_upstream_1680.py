"""Does UPSTREAM also fail on the fuzz rows where the unclamped port diverges?

Section 25f established that `examples/fuzz`'s LPLR surface only ever runs at
`n` in [60, 160] -- never n=500 -- and that section 20 measured upstream as
non-finite on 7/25 draws at n=60 and 1/25 at n=100 and n=160. So "unclamped
fails fuzz" cannot be read as a port defect without putting upstream on the
SAME rows. That is what this does.

Why it is cheap, and why it is sound
===================================
The fuzz DGP (`examples/fuzz/main.mbt:412-459`) is a pure function of `trial`:
`n`, `seed`, then `x`, `y`, `d` all come from `ch_rng = chacha8_rng(seed)` and
the trial index. Nothing in it reads the clamp. So the rows for a given trial
are IDENTICAL whether the port is clamped or not -- only the fit's outcome
differs. The rows can therefore be dumped from the SHIPPED build and fed to
upstream, with no need to also un-clamp the port and hope the trial indices
line up.

A temporary dump was added to `fuzz_lplr` for trials 2 and 7, reverted in the
same commit that consumed it.

The verdict that matters
========================
  upstream non-finite here  -> the port is not worse than upstream on these
                               rows, the clamp is unjustified as a fidelity
                               measure, and dropping it would make n=100 agree
                               with upstream to 0.085
  upstream finite here      -> the port diverges where upstream does not, the
                               clamp is doing real work, and the status quo
                               stands

Run: python _verify/_lplr_fuzzrows_upstream_1680.py
"""

import os
import re
import subprocess
import sys
import warnings

import numpy as np

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import (  # noqa: E402
    LOGDIR, use_vendored_upstream,
)
use_vendored_upstream()

LOG = os.path.join(LOGDIR, "_fuzz_dump_1680.log")
TARGET_TRIALS = (2, 7)


def capture():
    print("capturing fuzz output with the dump probe ...")
    r = subprocess.run(["moon", "run", "examples/fuzz", "--target", "native"],
                       cwd=REPO, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=5400)
    with open(LOG, "w", encoding="utf-8", newline="\n") as fh:
        fh.write((r.stdout or "") + (("\n[stderr]\n" + r.stderr) if r.stderr else ""))
    return (r.stdout or "")


def parse(out):
    """Pull every FZZMETA + its three `data lplrfuzz_*` lines."""
    lines = out.splitlines()
    cases = {}
    i = 0
    while i < len(lines):
        m = re.match(r"FZZMETA trial=(\d+) n=(\d+) p=(\d+) seed=(\d+)", lines[i].strip())
        if not m:
            i += 1
            continue
        rec = {"trial": int(m.group(1)), "n": int(m.group(2)),
               "p": int(m.group(3)), "seed": int(m.group(4))}
        j = i + 1
        while j < len(lines) and len(rec) < 7:
            s = lines[j].strip()
            parts = s.split()
            if len(parts) >= 3 and parts[0] == "data" and parts[1].startswith("lplrfuzz_"):
                key = {"lplrfuzz_x": "x", "lplrfuzz_y": "y", "lplrfuzz_d": "d"}[parts[1]]
                k = int(parts[2])
                arr = [float(v) for v in parts[3:3 + k]]
                if len(arr) == k:
                    rec[key] = np.array(arr, dtype=float)
            j += 1
        if all(k in rec for k in ("x", "y", "d")):
            cases[rec["trial"]] = rec
        i = j
    return cases


def main():
    out = capture()
    cases = parse(out)
    if not cases:
        print("no FZZMETA blocks found -- was the dump probe reverted?")
        return 3

    from sklearn.linear_model import LinearRegression, LogisticRegression
    from doubleml.plm import DoubleMLLPLR
    from doubleml.data import DoubleMLData
    import pandas as pd

    def mk():
        return LogisticRegression(C=1e6, max_iter=500, solver="lbfgs")

    print("")
    print("parsed %d trial(s): %s"
          % (len(cases), sorted(cases)))
    print("")
    print("=== upstream on the IDENTICAL fuzz rows ===")
    for t in sorted(cases):
        rec = cases[t]
        n, p = rec["n"], rec["p"]
        x = rec["x"].reshape(n, p)
        y, d = rec["y"], rec["d"]
        cols = ["x%d" % (j + 1) for j in range(p)]
        df = pd.DataFrame(np.column_stack([x, y, d]), columns=cols + ["y", "d"])
        print("")
        print("  trial %d   n=%d  p=%d  seed=%d" % (t, n, p, rec["seed"]))
        print("    treatment mean d = %.4f   outcome mean y = %.4f"
              % (d.mean(), y.mean()))
        for label, fn in (("nuisance_space", "nuisance_space"),
                          ("instrument", "instrument")):
            try:
                obj = DoubleMLData(df, "y", "d", cols)
                m = DoubleMLLPLR(obj, ml_M=mk(), ml_t=LinearRegression(),
                                 ml_m=mk(), ml_a=mk(), n_folds=2,
                                 n_folds_inner=2, score=fn,
                                 draw_sample_splitting=True)
                with warnings.catch_warnings(record=True) as w:
                    warnings.simplefilter("always")
                    m.fit()
                    rootwarn = [str(x.message) for x in w
                                if "root" in str(x.message).lower()]
                c, s = float(m.coef[0]), float(m.se[0])
                fin = np.isfinite(c) and np.isfinite(s)
                print("    upstream %-14s coef=%14.6g se=%14.6g  %s"
                      % (label, c, s, "finite" if fin else "NON-FINITE"))
                if rootwarn:
                    print("        root warning: %s" % rootwarn[0][:80])
            except Exception as e:
                print("    upstream %-14s RAISED %s: %s"
                      % (label, type(e).__name__, str(e)[:90]))

    print("")
    print("=== the port on the same rows (from the unclamped A/B) ===")
    print("    trial 2, unclamped:           se=NaN, th=-440.15956528046615")
    print("    trial 7, unclamped+conditioned: se=8.883758984028203e+59, th=139.786")
    print("    (the shipped clamped build passes both -- 11/11)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
