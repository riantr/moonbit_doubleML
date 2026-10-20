"""Two-arm version: is scipy's 1.48e-8 window inhabited, CLAMPED or NOT?

Arm 1 (already measured, shipping config): 0 of 600 solves entered the
window. But that arm has the clamp on, and the clamp caps travel at 0.25 per
step -- so it is NOT the configuration that actually diverges. Arm 2 removes
the clamp, which is the configuration that produced `se = NaN` at fuzz
trial 2 and `se = Infinity` at trial 24.

Claiming the tolerance hypothesis dead on arm 1 alone would be exactly the
error this project's evidence files keep warning about: measuring a
different thing than the one that failed.

Verdict per solve, from min_step (steps shrink as Newton converges):
    min_step <= 1e-9        both stop                          -> dead
    1e-9 < min <= 1.48e-8   upstream stops, port does not      -> SUPPORTED
    min_step > 1.48e-8      neither stops                      -> dead

A MUTATION probe: patches a tracked file, restores it byte-for-byte in a
`finally`, and verifies the on-disk text equals the intended patch exactly.
"""

import io
import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LPLR = os.path.join(REPO, "moonbit_doubleML", "lplr.mbt")
BACKUP = os.path.join(REPO, "_verify", "_tolprobe2_backup.mbt")
OUT = os.path.join(REPO, "_verify", "_tol_probe_unclamped_1680.txt")

DECL_OLD = '      let mut stop_reason = "exhausted_step_budget"\n'
DECL_NEW = ('      let mut stop_reason = "exhausted_step_budget"\n'
            '      let mut probe_min_step = 1.0e308\n'
            '      let mut probe_iters = 0\n')

STEP_OLD = '        let raw_delta = s / sd\n'
STEP_NEW = STEP_OLD   # unused; the block replacement below subsumes it

# The clamp verbatim from lplr.mbt:1126-1131. Replaced as ONE block together
# with the probe insert, because STEP_OLD is a prefix of CLAMP_NEW: doing
# them as separate str.replace calls makes the second pass re-match the text
# the first pass just wrote, and the file silently ends up mangled.
CLAMP_OLD = ('        let raw_delta = s / sd\n'
             '        let mut theta_new = theta - raw_delta\n'
             '        if theta_new.abs() > 5.0 || (theta_new - theta).abs() > 1.0 {\n'
             '          let step = if raw_delta.abs() < 0.25 { raw_delta } else { 0.25 }\n'
             '          theta_new = theta - step * (if s > 0.0 { 1.0 } else { -1.0 })\n'
             '        }\n')
CLAMP_NEW = ('        let raw_delta = s / sd\n'
             '        probe_iters = _step + 1\n'
             '        if raw_delta.abs() < probe_min_step {\n'
             '          probe_min_step = raw_delta.abs()\n'
             '        }\n'
             '        let theta_new = theta - raw_delta\n')

TAIL_OLD = '        theta = theta_new\n      }\n'
TAIL_NEW = ('        theta = theta_new\n'
            '      }\n'
            '      {\n'
            '        let mut in_window = false\n'
            '        if probe_min_step > 1.0e-9 && probe_min_step <= 1.48e-8 {\n'
            '          in_window = true\n'
            '        }\n'
            '        println("NEWTONPROBE iters=" + probe_iters.to_string() +\n'
            '          " min_step_x1e9=" +\n'
            '          (probe_min_step * 1.0e9).round().to_int().to_string() +\n'
            '          " in_window=" + (if in_window { "YES" } else { "no" }) +\n'
            '          " theta_x1e6=" + (theta * 1.0e6).round().to_int().to_string() +\n'
            '          " stop=" + stop_reason)\n'
            '      }\n')


def read(p):
    with io.open(p, encoding="utf-8", newline="") as f:
        return f.read()


def write(p, t):
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(t)


def classify(out):
    rows = [ln.strip() for ln in out.splitlines()
            if ln.strip().startswith("NEWTONPROBE")]
    both = window = neither = 0
    win_rows = []
    for ln in rows:
        d = dict(kv.split("=", 1) for kv in ln.split() if "=" in kv)
        try:
            ms = int(d["min_step_x1e9"])
        except (KeyError, ValueError):
            continue
        if ms <= 1:
            both += 1
        elif ms <= 15:          # 1e-9 < step <= 1.48e-8, rounded in 1e-9 units
            window += 1
            win_rows.append((ms, d.get("iters"), d.get("theta_x1e6"),
                             d.get("stop")))
        else:
            neither += 1
    return len(rows), both, window, neither, win_rows


def main():
    base = read(LPLR)
    for label, anchor in (("decl", DECL_OLD), ("clamp", CLAMP_OLD),
                          ("tail", TAIL_OLD)):
        n = base.count(anchor)
        if n != 1:
            raise SystemExit("anchor %r matched %d times -- not measuring"
                             % (label, n))
    shutil.copyfile(LPLR, BACKUP)
    try:
        patched = (base
                   .replace(CLAMP_OLD, CLAMP_NEW)   # one block: clamp + probe
                   .replace(DECL_OLD, DECL_NEW)
                   .replace(TAIL_OLD, TAIL_NEW))
        write(LPLR, patched)
        on = read(LPLR)
        if on != patched:
            raise SystemExit("on-disk != intended patch; not measuring")
        if on.count(CLAMP_OLD) != 0 or on.count(CLAMP_NEW) != 1:
            raise SystemExit("clamp removal did not land cleanly")
        if on.count("theta_new = theta - step *") != 0:
            raise SystemExit("clamp fallback survived")
        if on.count("NEWTONPROBE") != 1:
            raise SystemExit("probe print not present exactly once")
        print("UNCLAMPED + instrumentation on disk: True")

        chk = subprocess.run(["moon", "check", "--target", "native"],
                             cwd=REPO, capture_output=True, text=True,
                             encoding="utf-8", errors="replace")
        if chk.returncode != 0:
            print("DOES NOT COMPILE -- not a measurement")
            print(((chk.stdout or "") + (chk.stderr or ""))[-1500:])
            return 2
        print("compiles")

        f = subprocess.run(["moon", "run", "examples/fuzz", "--target", "native"],
                           cwd=REPO, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        out = (f.stdout or "") + (f.stderr or "")
        with io.open(OUT, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(out)
        print("fuzz exit %d ; full output -> %s" % (f.returncode, OUT))

        rows, both, window, neither, win_rows = classify(out)
        print()
        print("UNCLAMPED arm, %d solves" % rows)
        print("  both stop (min_step <= 1e-9)            : %d" % both)
        print("  IN THE 14.8x WINDOW (upstream only)     : %d" % window)
        print("  neither stops (min_step > 1.48e-8)      : %d" % neither)
        print()
        if win_rows:
            print("HYPOTHESIS SURVIVES in the unclamped arm:")
            for ms, it, th, stop in win_rows[:30]:
                print("   min_step=%.3g iters=%-4s theta=%-14s stop=%s"
                      % (ms * 1e-9, it, th, stop))
        else:
            print("HYPOTHESIS DEAD in the unclamped arm too: no solve "
                  "entered the window.")
        print()
        for ln in out.splitlines():
            if "FUZZ FAIL" in ln or "ALL FUZZ SURFACES PASSED" in ln:
                print("   fuzz:", ln.strip())
        return 0
    finally:
        shutil.copyfile(BACKUP, LPLR)
        print("restored byte-for-byte:", read(LPLR) == base)
        os.remove(BACKUP)


if __name__ == "__main__":
    sys.exit(main())
