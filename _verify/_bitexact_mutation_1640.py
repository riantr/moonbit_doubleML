"""End-to-end control: mutate the MoonBit emitter, require the gate to go RED.

The comparator's own self-test proves `compare()` can spot a 1-ULP difference in
values it is handed. That is not the same as proving the gate is wired up: the
emitter could be mis-parsed, or the reference could be recomputing from
MoonBit's own output, and the whole thing would still pass while detecting
nothing. So this mutates the EMITTER and requires a non-zero exit.

Restore is in a `finally`, and this script asserts `git diff` is clean
afterwards -- a probe that leaves the tree mutated is worse than no probe.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    ".."))
MAIN = os.path.join(ROOT, "examples", "bitexact", "main.mbt")
VALIDATOR = os.path.join(ROOT, "validate_bitexact_with_python.py")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# (description, original, mutated) -- each changes a NUMBER, not the plumbing.
#
# A NOTE ON ONE MUTATION THAT WAS WRONG, AND WAS REMOVED
# ------------------------------------------------------
# The first draft included "change the seed list from 3141 to 3142". It
# SURVIVED, and the survival was correct: the seed set is the check's *input*,
# not its expected value. Python reimplements `seed_to_bytes` from the spec in
# seed.mbt's doc comment and compares whatever seeds MoonBit chose to print, so
# swapping one seed for another still validates every key it prints. That is an
# equivalent mutation, not a gap in the gate -- and a mutation whose premise is
# wrong is a test written for a behaviour that does not exist.
#
# The two key mutations below are the real ones: they make MoonBit's key
# actually WRONG (truncated, and tiled once instead of eight times), which is
# what the key comparison exists to catch.
MUTATIONS = [
    ("sign flip on the DID contrast",
     '  emit("did_theta", m1 - m0)',
     '  emit("did_theta", m0 - m1)'),
    ("a 1e-12 relative nudge on rdd_sse",
     '  emit("rdd_sse", sse)',
     '  emit("rdd_sse", sse * (1.0 + 1.0e-12))'),
    ("RNG key truncated to 8 of 32 bytes",
     '  for i = 0; i < b.length(); i = i + 1 {\n    s = s + " " + b[i].to_string()',
     '  for i = 0; i < 8; i = i + 1 {\n    s = s + " " + b[i].to_string()'),
    ("RNG key tiled once instead of eight times",
     '  for i = 0; i < b.length(); i = i + 1 {\n    s = s + " " + b[i].to_string()',
     '  let mut k = 0\n  while k < 4 {\n    s = s + " " + b[k].to_string()\n    k = k + 1\n  }\n  let _unused = 0\n  for i = 0; i < 0; i = i + 1 {\n    s = s + " " + b[i].to_string()'),
]


def run_validator():
    return subprocess.run([sys.executable, VALIDATOR], cwd=ROOT,
                          capture_output=True, text=True, timeout=900,
                          encoding="utf-8", errors="replace")


def main():
    baseline = run_validator()
    if baseline.returncode != 0:
        print("BASELINE IS RED -- fix that before trusting any control:")
        print(baseline.stdout[-1500:])
        return 2
    print("baseline: green (exit 0)  [ok]")

    with open(MAIN, "rb") as f:
        original = f.read()

    failed = []
    try:
        for desc, old, new in MUTATIONS:
            text = original.decode("utf-8")
            if text.count(old) != 1:
                failed.append("%s: anchor found %d times"
                              % (desc, text.count(old)))
                print("  SKIP  %-45s (anchor not unique)" % desc)
                continue
            mutated = text.replace(old, new, 1).encode("utf-8")
            with open(MAIN, "wb") as f:
                f.write(mutated)
            r = run_validator()
            tail = [l for l in r.stdout.splitlines()
                    if "DIFFER" in l or "parity:" in l]
            if r.returncode == 0:
                failed.append(desc)
                print("  SURVIVED  %-41s exit=0  <-- the gate cannot fail"
                      % desc)
            else:
                print("  killed    %-41s exit=%d  %s"
                      % (desc, r.returncode, tail[-1][:60] if tail else ""))
            with open(MAIN, "wb") as f:
                f.write(original)
    finally:
        with open(MAIN, "wb") as f:
            f.write(original)

    after = run_validator()
    if after.returncode != 0:
        print("POST-RESTORE IS RED -- the restore did not work")
        return 2
    print("after restore: green (exit 0)  [ok]")

    g = subprocess.run(["git", "diff", "--stat", "--", MAIN], cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    if g.stdout.strip():
        print("TREE LEFT MUTATED:\n" + g.stdout)
        return 2
    print("git diff on the emitter is empty  [ok]")

    if failed:
        print()
        print("CONTROL FAILED: %d mutation(s) survived" % len(failed))
        for d in failed:
            print("  - " + d)
        return 1
    print()
    print("all %d mutations killed; the gate discriminates" % len(MUTATIONS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
