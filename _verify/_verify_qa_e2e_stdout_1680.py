#!/usr/bin/env python3
"""Hold the CI e2e gate to the rule that a program's output is its stdout.

THE DEFECT
==========
On 2026-10-29 the stable MoonBit toolchain moved from 0.1.20261028 to
0.1.20261029 and started printing

    Warning: Package `moonbitlang/async/internal/event_loop` dep...

on STDERR for every `moon run`.  The QA harness's `run()` helper merges
stderr into stdout, so the merged text ended with the toolchain's warning.
The e2e check read the LAST line of that merged text and compared it with
the example's expected final line -- so the toolchain's diagnostic was read
as the example's last word, and all twenty examples failed on a line that no
example ever printed.

v0.164.63 was blocked by exactly this.  The tag was pushed, CI ran on the
new toolchain, the e2e check went red for all twenty examples, and the
registry never received the package.

WHAT THIS VERIFIER HOLDS
=========================
The gate must DECIDE from the example's stdout -- not merely "pass today".
A gate that happens to be green while it reads a merged stream is one
toolchain diagnostic away from blocking the next release, and the merge is
invisible in the verdict.

The rules are checked against the REAL harness module
(`.github/scripts/qa_loop/checks.py`), never against a copy of it: a
verifier that re-implements the rule proves only that the rule agrees with
itself.

WHAT IS NOT CLAIMED
===================
Nothing here runs an example.  This verifier is about the gate's SEMANTICS.
The examples' own output is asserted by the e2e check itself, which CI runs
on every push and on the publish path, and whose final-line templates were
measured against this tree (all twenty examples: exit 0, stderr empty, and
the stdout final line matching its row's prefix and length).

Run: python _verify/_verify_qa_e2e_stdout_1680.py
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QA = os.path.join(ROOT, ".github", "scripts", "qa_loop")
sys.path.insert(0, QA)

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-62s %s" % (label[:62], detail))
    else:
        print("  *** FAIL *** %-54s %s" % (label[:54], detail))
        FAILS.append("%s -- %s" % (label, detail))


try:
    import checks as C
except Exception as _e:  # noqa: BLE001
    print("  *** FAIL *** %-54s %s" % ("the harness module must be importable",
                                      repr(_e)))
    print("%d checks, 1 failed" % 1)
    print("VERDICT: FAIL")
    sys.exit(1)

# The diagnostic observed on CI on 2026-10-29 (run 41497496882).  A constant,
# not a reading of the live toolchain, so the arms keep working on a machine
# whose toolchain does not emit it.
TOOLCHAIN_WARNING = "Warning: Package `moonbitlang/async/internal/event_loop` dep..."

# A template nobody publishes: hand-written, so the arms cannot be satisfied
# by the expectation table and the code under test being wrong in the same
# way.  "alpha = 7" templates to "alpha = <n>", which is 11 characters.
HAND_PREFIX = "alpha = <n>"
HAND_LEN = len(HAND_PREFIX)
HAND_STDOUT = "alpha = 7\n"


def synth_stdout(prefix, want_len, min_lines, break_final=False):
    # The row marker is a 60-character PREFIX of the templatised line plus
    # that line's exact length (for `bitexact`: 60 of 295).  So the line is
    # built from the prefix and EXTENDED to the expected length.  The filler
    # is a letter and never a digit, because a digit would template to `<n>`
    # and change the length the filler is there to establish.
    if break_final:
        final = "the example printed something else"
    else:
        final = prefix.replace("<n>", "1") + "x" * max(0, want_len - len(prefix))
    pad = ["pad line %d" % (i + 1) for i in range(max(0, min_lines - 1))]
    return "\n".join(pad + [final]) + "\n"


def row_for(name):
    for n, prefix, want_len, min_lines in C._EXAMPLES:
        if n == name:
            return prefix, want_len, min_lines
    return None


print("verifying: the e2e gate decides from the example's stdout")
print("-" * 74)

# --------------------------------------------------------------------------- #
# R1 -- run_split really keeps the two streams apart.
#
# `run()` merges on purpose: its callers scan the merged text for a summary
# line.  So the separation has to live in the function that promises it, and
# this is the arm that notices if the merge ever moves back inside it.
# --------------------------------------------------------------------------- #
try:
    _rc, _out, _err = C.run_split(
        [sys.executable, "-c",
         "import sys; sys.stdout.write('OUT'); sys.stderr.write('ERR')"])
except Exception as _e:  # noqa: BLE001
    _out, _err = "", repr(_e)
check("R1 run_split keeps stdout and stderr apart",
      _out == "OUT" and _err == "ERR", "out=%r err=%r" % (_out, _err))

# --------------------------------------------------------------------------- #
# R2 -- every example's own stdout satisfies its row.
# --------------------------------------------------------------------------- #
n_ok = 0
for _n, _p, _wl, _ml in C._EXAMPLES:
    if C._e2e_verdict(_p, _wl, _ml, 0, synth_stdout(_p, _wl, _ml)) is None:
        n_ok += 1
check("R2 every example's own stdout satisfies its row",
      n_ok == len(C._EXAMPLES), "%d/%d" % (n_ok, len(C._EXAMPLES)))

# --------------------------------------------------------------------------- #
# R3 -- the assertion still bites: a wrong final line, a short output and a
# non-zero exit are each rejected.
# --------------------------------------------------------------------------- #
_p, _wl, _ml = C._EXAMPLES[0][1], C._EXAMPLES[0][2], C._EXAMPLES[0][3]
_why = C._e2e_verdict(_p, _wl, _ml, 0, synth_stdout(_p, _wl, _ml, break_final=True))
check("R3a a wrong final line is rejected",
      _why is not None and "final line starts" in _why, str(_why)[:60])
_why = C._e2e_verdict(_p, _wl, _ml, 0, synth_stdout(_p, _wl, 1))
check("R3b too few output lines are rejected",
      _why is not None and "line(s)" in _why, str(_why)[:60])
_why = C._e2e_verdict(_p, _wl, _ml, 3, synth_stdout(_p, _wl, _ml))
check("R3c a non-zero exit is rejected", _why == "exit=3", str(_why)[:60])

# --------------------------------------------------------------------------- #
# R4 -- the REAL c_e2e, with run_split stubbed.
#
# The stub is called once per example and the count is checked: without that,
# an `e2e` that had gone back to the merged `run()` would silently run the
# real examples and could still come out green.
# --------------------------------------------------------------------------- #
_calls = []


def c_e2e_with(stub):
    saved = C.run_split
    try:
        C.run_split = stub
        return C.c_e2e()
    finally:
        C.run_split = saved


def stub_for(break_final):
    def _stub(cmd, **kw):
        _calls.append(os.path.basename(cmd[-1]))
        row = row_for(os.path.basename(cmd[-1]))
        if row is None:
            return 0, "", ""
        prefix, want_len, min_lines = row
        err = "" if break_final else (TOOLCHAIN_WARNING + "\n")
        return 0, synth_stdout(prefix, want_len, min_lines,
                                break_final=break_final), err
    return _stub


_calls.clear()
_r = c_e2e_with(stub_for(False))
check("R4a c_e2e PASSES with the toolchain's warning on stderr",
      _r.verdict == C.PASS, "%s: %s" % (_r.verdict, _r.evidence[-60:]))
check("R4b c_e2e REPORTS the stderr it did not assert on",
      "reported not asserted" in _r.evidence, _r.evidence[-60:])
check("R4c c_e2e went through run_split for every example",
      len(_calls) == len(C._EXAMPLES), "%d/%d" % (len(_calls), len(C._EXAMPLES)))

_calls.clear()
_r = c_e2e_with(stub_for(True))
check("R4d c_e2e FAILS when the example's own stdout is wrong",
      _r.verdict == C.FAIL, "%s" % _r.verdict)

# --------------------------------------------------------------------------- #
# R5 -- the MERGED stream really would have failed.  The fix is not a no-op:
# the pre-fix semantics rejected a correct example whose toolchain printed a
# diagnostic, and this is that rejection, shown rather than described.
# --------------------------------------------------------------------------- #
_merged = synth_stdout(_p, _wl, _ml) + TOOLCHAIN_WARNING + "\n"
_mlines = [l.strip() for l in _merged.splitlines() if l.strip()]
_got = C._templatise(_mlines[-1])
check("R5 the MERGED stream would have failed (the bug was real)",
      not _got.startswith(_p) and _got.startswith("Warning:"), _got[:48])

# --------------------------------------------------------------------------- #
# C1-C5 -- control arms on a template nobody publishes.  Each one says: the
# rule MUST reject this.  If the rule accepted any of them, the gate would be
# decorative and this verifier would be green for the wrong reason.
# --------------------------------------------------------------------------- #
check("C1 the hand-written template is ACCEPTED",
      C._e2e_verdict(HAND_PREFIX, HAND_LEN, 1, 0, HAND_STDOUT) is None,
      "alpha = 7 -> alpha = <n> (%d chars)" % HAND_LEN)

_why = C._e2e_verdict(HAND_PREFIX, HAND_LEN, 1, 0, "beta = 7\n")
check("C2 a wrong final line on the hand-written template is REJECTED",
      _why is not None and "final line starts" in _why, str(_why)[:60])

_why = C._e2e_verdict(HAND_PREFIX, HAND_LEN, 1, 0,
                      HAND_STDOUT + "trailing = 9\n")
check("C3 the LAST line decides, not any matching line",
      _why is not None and "final line starts" in _why, str(_why)[:60])

_why = C._e2e_verdict(HAND_PREFIX, HAND_LEN, 2, 0, HAND_STDOUT)
check("C4 too few lines on the hand-written template are REJECTED",
      _why is not None and "line(s)" in _why, str(_why)[:60])

_why = C._e2e_verdict(HAND_PREFIX, HAND_LEN, 1, 4, HAND_STDOUT)
check("C5 a non-zero exit on the hand-written template is REJECTED",
      _why == "exit=4", str(_why)[:60])

check("C6 the harness exposes the seam the arms use",
      hasattr(C, "_e2e_verdict") and hasattr(C, "run_split")
      and hasattr(C, "_EXAMPLES") and hasattr(C, "c_e2e"),
      "_e2e_verdict / run_split / _EXAMPLES / c_e2e")

print()
print("=" * 74)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
for f in FAILS:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))

# A verdict that is not the EXIT CODE is a comment, not a gate.
sys.exit(1 if FAILS else 0)
