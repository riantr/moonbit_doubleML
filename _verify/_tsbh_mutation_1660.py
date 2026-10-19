"""Mutation battery for the new tsbh lambda search.

A gate that has only ever been seen green does not know whether it can go
red. Every mutation below must turn validate_padjust_with_python.py red;
a survivor means either the mutation is equivalent (document it, don't
"fix" it) or the gate has a hole (fix the gate).

Restore is in `finally` AND verified by sha256, and the clean hash is
checked BEFORE the backup is written -- backing up an already-dirty file
promotes the previous round's damage into this round's baseline.
"""
import hashlib
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "moonbit_doubleML", "p_adjust.mbt")
SIDECAR = TARGET + ".cleanhash"

MUTATIONS = [
    # (label, old, new, expected)
    ("M1 drop /n0 from alpha_star",
     "let alpha_star = alpha * n_d / n0",
     "let alpha_star = alpha * n_d",
     "equivalent"),
    ("M2 n0 = m instead of m - r1",
     "let n0 = 1.0 * n_d - r1.to_double()",
     "let n0 = n_d",
     "kill"),
    ("M3 drop the n0/m rescale",
     "let scale = n0 * 1.0 / n_d",
     "let scale = 1.0",
     "kill"),
    ("M4 ULP: *n/(k+1) instead of /ecdf",
     "let raw = p_sorted[i] / ecdf",
     "let raw = p_sorted[i] * n_d / (i + 1).to_double()",
     "kill"),
    ("M5 off-by-one rejection count",
     "let n_rejected = if rejectmax < 0 { 0 } else { rejectmax + 1 }",
     "let n_rejected = if rejectmax < 0 { 0 } else { rejectmax }",
     "kill"),
    ("M6 count raw comparisons, not the step-up closure",
     "let n_rejected = if rejectmax < 0 { 0 } else { rejectmax + 1 }",
     "let n_rejected = if rejectmax < 0 { 0 } else { 1 }",
     "kill"),
]

# M1 is an EXPECTED survivor, and the reason is structural rather than
# convenient: `bh_step_up_sorted` computes `corrected[i]` from `p_sorted[i]`
# and the ECDF factor only. Its `alpha` parameter feeds exactly one thing --
# `rejectmax`, and therefore `n_rejected`. The stage-2 call discards that
# count, so `alpha_star` cannot reach the returned p-values. Measured
# confirmation in `_tsbh_survivor_analysis_1660.py`: the corrected array is
# bit-identical at alpha_star = 0.0875 and at 0.35.
#
# This is worth stating rather than quietly tolerating, because it becomes a
# LIVE mutation the moment the rejection array is ever returned from this
# module. If you add a rejecting variant of tsbh, re-check M1.
EQUIVALENT = {
    "M1": ("stage-2 alpha_star reaches only the discarded rejection count, "
           "so the returned p-values are unchanged; measured bit-identical"),
}


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run_validator():
    r = subprocess.run([sys.executable, "validate_padjust_with_python.py"],
                       cwd=ROOT, capture_output=True, encoding="utf-8",
                       errors="replace")
    tail = (r.stdout or "").strip().splitlines()[-1:] or [""]
    return r.returncode, tail[0]


def main():
    clean = sha(TARGET)
    if os.path.exists(SIDECAR):
        with open(SIDECAR) as f:
            prev = f.read().strip()
        if prev != clean:
            print("REFUSING TO RUN: %s is not in its clean state." % TARGET)
            print("  on-disk sha256 : %s" % clean)
            print("  recorded sha256: %s" % prev)
            print("  restore with: git checkout -- moonbit_doubleML/p_adjust.mbt")
            return 3

    with open(TARGET, "rb") as f:
        original = f.read().decode("utf-8")

    rc, verdict = run_validator()
    print("baseline: rc=%d %r" % (rc, verdict))
    if rc != 0:
        print("BASELINE IS RED -- fix that before trusting any result here.")
        return 1

    results = []
    try:
        for label, old, new, expected in MUTATIONS:
            key = label.split()[0]
            if original.count(old) != 1:
                print("%-52s ANCHOR MISS (%d occurrences)"
                      % (label, original.count(old)))
                results.append((label, "ANCHOR-MISS", expected))
                continue
            mutated = original.replace(old, new)
            with open(TARGET, "w", encoding="utf-8", newline="\n") as f:
                f.write(mutated)
            try:
                rc, verdict = run_validator()
                killed = (rc != 0)
                status = "KILLED" if killed else "SURVIVED"
                results.append((label, status, expected))
                verdict_txt = "" if expected == "kill" else (
                    "  <- expected %s" % expected)
                print("%-52s %-9s rc=%d%s" % (label, status, rc, verdict_txt))
            finally:
                with open(TARGET, "w", encoding="utf-8", newline="\n") as f:
                    f.write(original)
                after = sha(TARGET)
                if after != clean:
                    print("  !! RESTORE FAILED for %s, sha=%s" % (label, after))
                    return 4
    finally:
        with open(TARGET, "w", encoding="utf-8", newline="\n") as f:
            f.write(original)

    final = sha(TARGET)
    print()
    print("restore verified by sha256: %s" % (final == clean))
    if final != clean:
        return 4
    with open(SIDECAR, "w") as f:
        f.write(clean)

    killed = sum(1 for _, s, _ in results if s == "KILLED")
    unexpected = []
    for label, status, expected in results:
        key = label.split()[0]
        if status == "SURVIVED" and key not in EQUIVALENT:
            unexpected.append(label)
    print("KILLED %d / %d" % (killed, len(results)))
    print("documented-equivalent survivors: %d" % len(EQUIVALENT))
    for key, why in EQUIVALENT.items():
        print("  %s: %s" % (key, why))
    if unexpected:
        print("UNEXPECTED SURVIVORS (each needs a written justification or a "
              "gate fix):")
        for l in unexpected:
            print("  - %s" % l)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
