#!/usr/bin/env python3
"""v0.154.x -- read upstream doubleml's ACTUAL default values. Do not assert from memory.

The port diverges from upstream on several constructor defaults. Before any of
those divergences is called a defect, the upstream value has to be READ, not
recalled -- the v0.136.0 lesson was that a contract-fidelity argument that
looked airtight did not survive measurement.

Uses `inspect.signature` on the installed package, so this is a measurement of
what the library will actually do, not of what its docs say.
"""
import inspect

import doubleml

# doubleml 0.11.3 does NOT use a `doubleml.dml.*` layout -- that was an older
# arrangement. Measured: submodules are `double_ml`, `did`, `irm`, `plm`,
# `rdd`, ... and every estimator is re-exported at the TOP LEVEL. The first
# version of this file imported `doubleml.dml.did` and died with
# `ModuleNotFoundError`, so the layout is read, not assumed.
from doubleml import (
    DoubleMLAPO,
    DoubleMLCVAR,
    DoubleMLDID,
    DoubleMLDIDCS,
    DoubleMLIIVM,
    DoubleMLIRM,
    DoubleMLLPLR,
    DoubleMLPQ,
    DoubleMLQTE,
    DoubleMLSSM,
)

TARGETS = [
    ("DoubleMLDID", DoubleMLDID),
    ("DoubleMLDIDCS", DoubleMLDIDCS),
    ("DoubleMLIRM", DoubleMLIRM),
    ("DoubleMLIIVM", DoubleMLIIVM),
    ("DoubleMLAPO", DoubleMLAPO),
    ("DoubleMLCVAR", DoubleMLCVAR),
    ("DoubleMLSSM", DoubleMLSSM),
    ("DoubleMLLPLR", DoubleMLLPLR),
    ("DoubleMLPQ", DoubleMLPQ),
    ("DoubleMLQTE", DoubleMLQTE),
]

WATCH = [
    "n_folds", "n_rep", "score", "cov_type", "trimming_threshold",
    "in_sample_normalization", "normalize_ipw", "quantile", "treatment",
    "honest", "approach", "kernel", "bandwidth", "fuzzy", "n_folds_inner",
]

print(f"upstream doubleml {doubleml.__version__}")
print()
for name, cls in TARGETS:
    try:
        sig = inspect.signature(cls.__init__)
    except (TypeError, ValueError) as e:
        print(f"{name}: signature unavailable ({e})")
        continue
    params = sig.parameters
    row = []
    for p in WATCH:
        if p in params:
            d = params[p].default
            row.append(f"{p}={d!r}" if d is not inspect._empty else f"{p}=<required>")
    print(f"{name}")
    if row:
        for r in row:
            print(f"    {r}")
    else:
        print("    (none of the watched parameters present)")
    print()

# The learner defaults upstream actually uses for each nuisance slot.
print("=" * 70)
print("upstream learner defaults (ml_g / ml_m / ml_l / ml_r)")
print("=" * 70)
for name, cls in TARGETS:
    try:
        sig = inspect.signature(cls.__init__)
    except (TypeError, ValueError):
        continue
    for p in ("ml_g", "ml_m", "ml_l", "ml_r"):
        if p in sig.parameters:
            d = sig.parameters[p].default
            kind = type(d).__name__
            print(f"  {name:<16} {p} = {kind}")
