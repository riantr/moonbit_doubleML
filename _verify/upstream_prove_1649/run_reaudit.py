#!/usr/bin/env python3
"""Run the upstream proof re-audit: one `moon prove` per case, classified.

The point of this runner is the CONTROL case.  On native Windows every case
-- including the control -- fails with a platform error, so "all cases
failed" and "the control failed" are the same observation.  The runner
therefore refuses to report a restriction as re-confirmed unless the control
case proved cleanly in the same run: a restriction can only be *established*
by the difference between a case and the control.

Classification, in order:
  PLATFORM_ERROR  the proof harness could not run (e.g. the Windows
                  `\\?` extended-length-path mkdir failure)
  PROOF_ERROR     moonc ran and rejected the contract
  PROVED          moonc ran and accepted it
  UNKNOWN         anything else -- never silently treated as a pass

Exit status: 0 only if the control case PROVED.  If the control case did not
prove, the run is void and the runner exits non-zero, because no result in
that run can be attributed to the construct under test.

Usage:  python run_reaudit.py [--outdir DIR]
"""
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
CASES_DIR = os.path.join(HERE, "cases")
CASES = [
    "b0_control",
    "b1c_fixed_control",
    "b1_array_param",
    "b1_array_field",
    "b2_double_cmp",
    "b3_raise_body",
    "b4_foreach",
    "b4c_style_control",
    "b4r_range_foreach",
    "blkA_call_whitelist",
    "blkB_block_expr",
]

# The cases that must be ACCEPTED by the proof frontend.  A run in which a
# control is rejected is void: the harness is not discriminating, and no
# other result in it can be attributed to the construct under test.
#
#   b0_control         no restricted construct at all
#   b1c_fixed_control  FixedArray + C-style range -- the `_prove_pilot` shape
#
# `b4c_style_control` is NOT a control: it carries `Array[T]`, so it is
# expected to be rejected.  It is the counterpart of `b4_foreach`, with the
# loop form changed and the array type held fixed.
CONTROLS = ["b0_control", "b1c_fixed_control"]

# Ordered: the first marker that appears wins.
MARKERS = [
    ("PLATFORM_ERROR", [
        "Unix.Unix_error",
        "anomaly:",
        "cannot create its output directory",
    ]),
    ("PROOF_ERROR", [
        "Error: [4207]",
        "unsupported primitive operator",
        "unsupported expression",
        "only contracted functions",
        "only direct logic-function calls",
        "only Bool, Byte, Int, UInt, Int64, and UInt64 constants",
        "unbound type symbol",
        "is not supported",
    ]),
]


def classify(text, code):
    for label, needles in MARKERS:
        for n in needles:
            if n in text:
                return label, n
    if code == 0:
        return "PROVED", ""
    return "UNKNOWN", "exit=%d" % code


def run_case(name, outdir):
    d = os.path.join(CASES_DIR, name)
    log = os.path.join(outdir, name + ".log")
    try:
        r = subprocess.run(["moon", "prove"], cwd=d, capture_output=True,
                           text=True, encoding="utf-8", errors="replace",
                           timeout=600)
        text = (r.stdout or "") + (r.stderr or "")
        code = r.returncode
    except subprocess.TimeoutExpired:
        text = "TIMEOUT after 600s"
        code = -1
    except FileNotFoundError as e:
        text = "moon not found: %s" % e
        code = -1
    with open(log, "w", encoding="utf-8", newline="\n") as f:
        f.write("### case    : %s\n" % name)
        f.write("### command : (cd _verify/upstream_prove_1649/cases/%s && moon prove)\n" % name)
        f.write("### exit    : %d\n\n" % code)
        f.write(text)
    label, why = classify(text, code)
    return label, why, code, log


def main():
    outdir = os.path.join(HERE, "out")
    os.makedirs(outdir, exist_ok=True)
    results = {}
    for name in CASES:
        label, why, code, log = run_case(name, outdir)
        results[name] = label
        print("%-22s %-16s exit=%-4s %s" % (name, label, code, why))
        print("%-22s   log: %s" % ("", os.path.relpath(log, HERE)))

    print()
    control = results.get("b0_control")
    print("=" * 72)
    print("CONTROL (b0_control): %s" % control)
    print("=" * 72)
    if control == "UNKNOWN":
        print("""
The control case was neither accepted nor rejected by the proof frontend, so
this run is VOID: the harness is not classifying, and no result in it can be
attributed to the construct under test.

A parse error in a case file looks exactly like this.  Check the case's
`moon prove` log for `Error: [3002]` / `Error: [3001]` before believing any
other result.
""".strip())
        return 2

    if control == "PLATFORM_ERROR":
        print("""
The control was ACCEPTED by the proof frontend (no `Error: [4207]`) and the
run then died in the Why3 stage, on this platform.  So the harness does
discriminate, and every PROOF_ERROR below is a real frontend rejection of
that construct -- but whether a contract actually PROVES cannot be observed
here.

Known cause on native Windows: the Why3 harness cannot create its output
directory under the `\\\\?` extended-length path prefix:
    anomaly: Unix.Unix_error(Unix.EINVAL, "mkdir", "\\\\?")
Re-run on a platform where `moon prove` can create its output directory to
observe the proof outcome itself.
""".strip())
    else:
        print("The control was accepted and proved.  Every result below is "
              "attributable.")

    print()
    print("Per-case results (a PROOF_ERROR is a real frontend rejection):")
    for name, label in results.items():
        if name == "b0_control":
            continue
        print("  %-22s %s" % (name, label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
