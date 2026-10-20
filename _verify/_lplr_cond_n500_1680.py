"""What does the CONDITIONED m_pred do to the port's n=500 answer?

Why this exists
===============
`pyexample_lplr.py` FAILS CLOSED when the emitter's `lplr_ns_theta` does not
equal the example's published constant, and it refuses to compare. That fired
when the conditioning was switched on:

    lplr_ns_theta = 0.41361558678817151
    example prints 0.46033435469463013
    identical: False
    REFUSING to compare: the fixture is not the example's data.

The self-check's wording is misleading here and worth separating: the ROWS are
unchanged (same DGP, same seed, same emitter). What changed is the port's
ANSWER, by 0.0467. So the gate is refusing for the right reason but naming the
wrong thing -- it is guarding fixture reproduction and reporting it as a data
mismatch.

This probe asks the question the refusal blocked, without touching the gate:
take the same 5 match-seeds the gate's section 3 uses, read the port's
coefficients straight out of the emitter, and compare them against upstream on
the same rows and the same pinned partition.

Baseline (unconditioned, shipped):
    port mean 0.399521   upstream 0.392214   gap 0.007307   band 0.206242

If the conditioned mean moves toward 0.392214 the change is a fidelity gain
worth shipping. If it moves away, it is D2/D3 all over again.

Run: python _verify/_lplr_cond_n500_1680.py
"""

import importlib.util
import os
import sys
import warnings

import numpy as np

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import use_vendored_upstream  # noqa: E402
use_vendored_upstream()

N_SEEDS = 5
BASE_SEED = 7000
N_FOLDS_INNER = 2
BAND_SIGMA = 3.0


def load_pyexample():
    path = os.path.join(REPO, "pyexample_lplr.py")
    spec = importlib.util.spec_from_file_location("pyexample_lplr", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    pe = load_pyexample()
    print("emitting the gate's rows ...")
    out = pe.run_emitter()
    vals, by_name = pe.parse_section(out, "lplr_upstream")

    n = int(vals["lplr_n"])
    p = int(vals["lplr_p"])
    x = by_name["lplr_x"].reshape(n, p)
    y = by_name["lplr_y"]
    d = by_name["lplr_d"]
    fold_id = by_name["lplr_fold"].astype(int)

    print("")
    print("--- the example's single published fit ---")
    print("    emitter lplr_ns_theta = %.17g" % vals["lplr_ns_theta"])
    print("    example expects        = 0.46033435469463013")
    print("    moved by               = %+.6f"
          % (vals["lplr_ns_theta"] - 0.46033435469463013))

    port = np.array([vals["lplr_match_seed%d" % (3141 + i)]
                     for i in range(N_SEEDS)], dtype=float)

    print("")
    print("--- the gate's section 3, recomputed ---")
    up_c, up_s = [], []
    for i in range(N_SEEDS):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            c, s = pe.upstream_fit(x, y, d, fold_id, N_FOLDS_INNER,
                                   BASE_SEED + 13 * i, "nuisance_space")
        up_c.append(c)
        up_s.append(s)
    up = np.array(up_c)

    sd_port = port.std(ddof=1)
    sd_up = up.std(ddof=1)
    band = BAND_SIGMA * float(np.hypot(sd_port, sd_up))
    gap = abs(port.mean() - up.mean())
    base_gap = 0.007307

    print("    port     mean=%.6f  sd=%.6f" % (port.mean(), sd_port))
    print("    upstream mean=%.6f  sd=%.6f" % (up.mean(), sd_up))
    print("    gap = %.6f   band = %.6f   -> %s"
          % (gap, band, "OK" if gap < band else "OUT"))
    print("")
    print("    BASELINE (unconditioned): port mean 0.399521, gap %.6f" % base_gap)
    print("    delta in the gate gap    : %+.6f" % (gap - base_gap))
    verdict = "CLOSER to upstream" if gap < base_gap else "FARTHER from upstream"
    print("    => the conditioning makes the n=500 answer %s." % verdict)
    print("")
    print("    NOTE: upstream is unchanged at 0.392214 by construction -- this")
    print("    comparison isolates the port's own movement.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
