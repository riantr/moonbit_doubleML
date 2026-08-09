"""Import + high_median + n_rep5 presence check for all 4 validate_*.py."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CASES = [
    ("irm",  "reference_irm_mimic_moonbit_n_rep5"),
    ("pliv", "reference_pliv_mimic_moonbit_n_rep5"),
    ("iivm", "reference_iivm_mimic_moonbit_n_rep5"),
    ("did",  "reference_did_mimic_moonbit_n_rep5"),
]

for name, nrep5_fn in CASES:
    path = ROOT / f"validate_{name}_with_python.py"
    spec = importlib.util.spec_from_file_location(f"validate_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # high_median: odd n → middle, even n → upper-middle
    h5 = mod.high_median([1, 2, 3, 4, 5])
    h4 = mod.high_median([1, 2, 3, 4])
    has_fn = hasattr(mod, nrep5_fn)
    print(f"{name:5s}  high_median(1..5)={h5} (expect 3)  "
          f"high_median(1..4)={h4} (expect 3)  "
          f"{nrep5_fn} present={has_fn}")
