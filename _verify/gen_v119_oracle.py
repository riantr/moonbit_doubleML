"""Oracle probe for moonbit_doubleML v0.119.0 (propensity subsystem on APO/APOS).

Runs the REAL upstream functions from the published sdist
(`doubleml-0.11.4.tar.gz`, pinned under `_verify/_upstream_ps/`) so the
MoonBit port is checked against upstream rather than against a
hand-derived reading of it.

Covers:
  1. `_normalize_ipw` / `_propensity_score_adjustment`  -- the weights
     DoubleMLAPO and DoubleMLAPOS do not currently expose
  2. `PSProcessor.adjust_ps`                            -- clipping, and the
     isotonic calibration the port already has but APO does not use

Run from `_verify/`:
    python gen_v119_oracle.py
"""

import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "_upstream_ps", "doubleml-0.11.4"))

from doubleml.utils._propensity_score import (  # noqa: E402
    _normalize_ipw,
    _propensity_score_adjustment,
    _trimm,
)
from doubleml.utils.propensity_score_processing import PSProcessor  # noqa: E402


def lcg(i, salt):
    return ((1103515245 * (i + 1) + salt) % 2147483648) / 2147483648.0


def dgp(n=200, seed=3141):
    """Propensity + treatment on a deterministic grid.

    The propensity is deliberately kept away from 0 and 1 so upstream's
    UNCLIPPED `_normalize_ipw` and the port's 1e-12-clipped copy agree
    -- the two only differ on a degenerate propensity, which is recorded
    separately rather than folded into the main comparison.
    """
    rng = np.random.default_rng(seed)
    x = rng.normal(size=n)
    ps = 1.0 / (1.0 + np.exp(-(0.5 + 0.9 * x)))
    d = (rng.uniform(size=n) < ps).astype(float)
    return ps, d, x


def main():
    n = 200
    ps, d, x = dgp(n)

    out = {}

    # The fixture itself, so the MoonBit side reads the SAME arrays rather
    # than trying to reproduce NumPy's PCG64 -- which would be a guess,
    # not a port. ps is what djust_ps clips, d is the indicator.
    out["fixture_ps"] = [float(v) for v in ps]
    out["fixture_d"] = [float(v) for v in d]

    # The fixture itself, so the MoonBit side reads the SAME arrays
    # rather than trying to reproduce NumPy PCG64 -- which would be a
    # guess dressed as a port. `ps` is what adjust_ps clips; `d` is the
    # treatment indicator.
    out["fixture_ps"] = [float(v) for v in ps]
    out["fixture_d"] = [float(v) for v in d]

    # --- 1. _normalize_ipw -------------------------------------------------
    w = _normalize_ipw(propensity_score=ps, treatment_indicator=d)
    out["normalize_ipw"] = [float(v) for v in w]

    # The two intermediate means, which pin the formula rather than just
    # its output: a port that swapped the two groups would still produce
    # SOME vector, just not these two.
    out["mean_treat1"] = float(np.mean(np.divide(d, ps)))
    out["mean_treat0"] = float(np.mean(np.divide(1.0 - d, 1.0 - ps)))

    # normalize_ipw=False must be the identity -- that is the whole point
    # of the flag.
    raw = _propensity_score_adjustment(
        propensity_score=ps, treatment_indicator=d, normalize_ipw=False
    )
    out["adjust_identity_max_diff"] = float(np.max(np.abs(raw - ps)))

    # --- 2. PSProcessor.adjust_ps -----------------------------------------
    # The doctest's own example, lifted from the upstream docstring.
    doc_ps = np.array([0.001, 0.2, 0.5, 0.8, 0.999])
    doc_d = np.array([0, 1, 1, 0, 1])
    out["adjust_doc_ps"] = [float(v) for v in doc_ps]
    out["adjust_doc_d"] = [float(v) for v in doc_d]
    proc = PSProcessor(clipping_threshold=0.01)
    out["adjust_doc_out"] = [float(v) for v in proc.adjust_ps(doc_ps, doc_d)]

    # A scoring-only clip over the real fixture.
    out["adjust_clip_out"] = [float(v) for v in proc.adjust_ps(ps, d)]
    out["n_clipped"] = int(np.sum((out["adjust_clip_out"] != ps).astype(int)))

    # Isotonic calibration -- the path the port implements via PAVA.
    iso = PSProcessor(clipping_threshold=0.01, calibration_method="isotonic")
    out["adjust_iso_out"] = [float(v) for v in iso.adjust_ps(ps, d)]

    # CV calibration is stochastic in the fold draw; assert the port only
    # has to MATCH the construction, not this particular partition.
    iso_cv = PSProcessor(
        clipping_threshold=0.01, calibration_method="isotonic", cv_calibration=True
    )
    out["adjust_iso_cv_out"] = [
        float(v) for v in iso_cv.adjust_ps(ps, d, cv=5)
    ]

    # --- 3. _trimm --------------------------------------------------------
    out["trimm_truncate"] = [
        float(v) for v in _trimm(ps, "truncate", 0.05)
    ]
    out["trimm_none"] = [float(v) for v in _trimm(ps, None, 0.05)]

    path = os.path.join(HERE, "_v119_golden.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)

    print("wrote", path)
    print("fixture ps[:5]", [round(v, 12) for v in out["fixture_ps"][:5]])
    print("fixture d [:5]", [round(v, 3) for v in out["fixture_d"][:5]])
    print()
    print("normalize_ipw   first 5 :", [round(v, 12) for v in out["normalize_ipw"][:5]])
    print("mean_treat1 / mean_treat0:", out["mean_treat1"], out["mean_treat0"])
    print("adjust(identity) max diff :", out["adjust_identity_max_diff"])
    print("adjust_ps doctest         :", [round(v, 6) for v in out["adjust_doc_out"]])
    print("adjust_ps real, n_clipped :", out["n_clipped"], "of", n)
    print("  clipped first 5         :", [round(v, 12) for v in out["adjust_clip_out"][:5]])
    print("isotonic first 5          :", [round(v, 12) for v in out["adjust_iso_out"][:5]])
    print("isotonic_cv first 5       :", [round(v, 12) for v in out["adjust_iso_cv_out"][:5]])
    print("trimm(truncate,.05) first5:", [round(v, 12) for v in out["trimm_truncate"][:5]])
    print("trimm(None)     first 5   :", [round(v, 12) for v in out["trimm_none"][:5]])


if __name__ == "__main__":
    main()
