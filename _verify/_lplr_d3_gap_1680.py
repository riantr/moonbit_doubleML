"""Read the LPLR gate gap with D3 in place, WITHOUT touching the repo golden.

`pyexample_lplr.py` refuses to compare when the emitter's `lplr_ns_theta`
differs from the constant in `examples/lplr`. D3 changed that value -- which is
the point, it is a behaviour change to a published coefficient -- so the gate
stops before it reports the gap.

Bypassing the gate to read the number is only safe if the golden is NOT edited
first: editing it would bless whatever D3 produces, including a regression. So
this copies the gate out of the repo, patches the copy's constant, and runs
that. The repo file and `examples/lplr` are untouched.
"""
import io
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE = os.path.join(REPO, "pyexample_lplr.py")
# The patched copy MUST live in the repo root: the gate derives its working
# directory from `HERE = dirname(abspath(__file__))`, so a copy parked in
# _verify/ runs `moon run examples/parity` from the wrong place and fails with
# exit -1. That is what happened the first time round.
PROBE = os.path.join(REPO, "_lplr_d3_probe_tmp.py")

OLD_EXPECTED = "0.46403803469979032"

src = io.open(GATE, encoding="utf-8").read()

# Read the emitter's current value rather than hard-coding it.
out = subprocess.run(["moon", "run", "examples/parity", "--target", "native"],
                     cwd=REPO, capture_output=True, text=True, timeout=3600,
                     encoding="utf-8", errors="replace")
if out.returncode != 0:
    print("emitter failed:", (out.stderr or out.stdout)[:400])
    sys.exit(2)

lines = out.stdout.splitlines()
start = next((i for i, l in enumerate(lines) if l.strip() == "section lplr_upstream"), None)
if start is None:
    print("no section lplr_upstream")
    sys.exit(2)
vals = {}
for l in lines[start + 1:]:
    s = l.strip()
    if s == "end":
        break
    if s.startswith("val "):
        p = s.split()
        vals[p[1]] = p[2]

new_expected = vals["lplr_ns_theta"]
print("emitter lplr_ns_theta : %.17g" % float(new_expected))
print("golden in gate        : %.17g" % float(OLD_EXPECTED))
print("moved                 : %.3e\n" % abs(float(new_expected) - float(OLD_EXPECTED)))

# Patch only the gate's copy: the emitter's own value is substituted so the
# fixture check passes and the gap is printed.
src2 = src.replace('expected = %s' % OLD_EXPECTED, 'expected = %s' % new_expected)
assert src2 != src, "the expected constant was not found -- update OLD_EXPECTED"

io.open(PROBE, "w", encoding="utf-8", newline="\n").write(src2)

try:
    r = subprocess.run([sys.executable, PROBE, "--check"], cwd=REPO,
                       capture_output=True, text=True, timeout=3600,
                       encoding="utf-8", errors="replace")
    print(r.stdout)
    if r.returncode != 0:
        print("probe exit", r.returncode)
        print(r.stderr[-800:])
finally:
    if os.path.exists(PROBE):
        os.remove(PROBE)
        print("\n(removed the temporary repo-root copy)")
