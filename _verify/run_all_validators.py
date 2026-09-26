#!/usr/bin/env python3
"""Drive all 23 validate_*.py cross-validators sequentially and
aggregate PASS/FAIL counts.

Each script is invoked as `python validate_*.py 2>&1`. The
script's exit code 0 means PASS; non-zero means FAIL. We also
look for the literal strings "PASS", "OK", "Traceback" in the
output to disambiguate "ran fine but printed PASS" vs
"crashed with Traceback".

Output goes to console AND to `_verify/validate_results.txt`.
"""

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML")
OUT = ROOT / "_verify" / "validate_results.txt"
OUT.parent.mkdir(parents=True, exist_ok=True)

scripts = sorted(ROOT.glob("validate_*_with_python.py"))
print(f"Found {len(scripts)} validator scripts")
sys.stdout.flush()

results = []
start = time.time()
for i, script in enumerate(scripts, 1):
    t0 = time.time()
    print(f"\n[{i:02d}/{len(scripts)}] {script.name} ...", end=" ", flush=True)
    try:
        proc = subprocess.run(
            [sys.executable, str(script)],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            timeout=180,  # each script ≤ 3 min
        )
        dt = time.time() - t0
        out = (proc.stdout or "") + (proc.stderr or "")
        last_lines = "\n".join(out.strip().splitlines()[-12:])
        passed = proc.returncode == 0 and "Traceback" not in out
        status = "PASS" if passed else "FAIL"
        results.append((script.name, status, dt, proc.returncode, last_lines))
        print(f"{status} ({dt:.1f}s, exit={proc.returncode})")
    except subprocess.TimeoutExpired:
        dt = time.time() - t0
        results.append((script.name, "TIMEOUT", dt, -1, "<timeout after 180s>"))
        print(f"TIMEOUT ({dt:.1f}s)")
    except Exception as e:
        dt = time.time() - t0
        results.append((script.name, "ERROR", dt, -1, repr(e)))
        print(f"ERROR ({dt:.1f}s): {e!r}")

elapsed = time.time() - start

# Aggregate
n_pass = sum(1 for _, s, *_ in results if s == "PASS")
n_fail = sum(1 for _, s, *_ in results if s != "PASS")

# Write report
with OUT.open("w", encoding="utf-8") as f:
    f.write(f"Total: {len(results)}, PASS: {n_pass}, FAIL: {n_fail}\n")
    f.write(f"Elapsed: {elapsed:.1f}s\n\n")
    for name, status, dt, rc, last in results:
        f.write(f"[{status:7s}] {name:50s} {dt:6.1f}s exit={rc}\n")
        if status != "PASS":
            f.write("--- last 12 lines ---\n")
            f.write(last + "\n")
            f.write("-" * 60 + "\n")

print(f"\n=== AGGREGATE ===")
print(f"Total: {len(results)}, PASS: {n_pass}, FAIL: {n_fail}")
print(f"Elapsed: {elapsed:.1f}s")
print(f"Report: {OUT}")
sys.stdout.flush()