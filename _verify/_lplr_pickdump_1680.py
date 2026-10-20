"""Pick the port's n=66 dump that belongs to fuzz trial 2.

The `if n == 66` probe in `lplr.mbt` fired 14 times over the 300-trial LPLR
surface, so the dump has to be disambiguated. `_fuzz_dump_1680.log` is the
permanent record of trial 2's DGP rows (n=66, p=6, seed=96696), and the probe
also dumped x/y/d, so the right block is found by EXACT row equality rather
than by trusting an occurrence index.

The identified block (x, y, d, t, m, a, b) is written to
`_verify/_port_dump_1680.log` in the same `data port_lplr_* <tag> <k> ...`
format `_lplr_formula_vs_nuisance_1680.py` already parses.

Run: python _verify/_lplr_pickdump_1680.py
"""

import io
import os
import re
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V = os.path.join(REPO, "_verify")
sys.path.insert(0, V)
from _lplr_env_1680 import (  # noqa: E402
    FUZZ_RUN_LOG, LOGDIR, PORT_DUMP,
)

FUZZ_LOG = FUZZ_RUN_LOG   # this run, 14 dumps
DUMP_LOG = os.path.join(LOGDIR, "_fuzz_dump_1680.log")  # permanent trial record
OUT = PORT_DUMP
TARGET_TRIAL = 2


def read_lines(p):
    return io.open(p, encoding="utf-8", errors="replace").read().splitlines()


def parse_port_blocks(lines):
    """Every `PORTMETA n=.. p=..` followed by its `data port_lplr_*` lines."""
    blocks = []
    i = 0
    while i < len(lines):
        m = re.match(r"PORTMETA n=(\d+) p=(\d+)", lines[i].strip())
        if not m:
            i += 1
            continue
        rec = {"n": int(m.group(1)), "p": int(m.group(2))}
        j = i + 1
        while j < len(lines) and len(rec) < 9:
            s = lines[j].strip()
            parts = s.split()
            if len(parts) >= 3 and parts[0] == "data" and parts[1].startswith("port_lplr_"):
                key = parts[1][len("port_lplr_"):]
                k = int(parts[2])
                arr = [float(v) for v in parts[3:3 + k]]
                if len(arr) == k:
                    rec[key] = np.array(arr, dtype=float)
            j += 1
        if all(k in rec for k in ("x", "y", "d", "t", "m", "a", "b")):
            blocks.append(rec)
        i = j
    return blocks


def parse_trial_record(lines, trial):
    """The FZZMETA block for `trial` from the permanent record."""
    i = 0
    while i < len(lines):
        m = re.match(r"FZZMETA trial=(\d+) n=(\d+) p=(\d+) seed=(\d+)",
                     lines[i].strip())
        if not m:
            i += 1
            continue
        if int(m.group(1)) != trial:
            i += 1
            continue
        rec = {"n": int(m.group(2)), "p": int(m.group(3)),
               "seed": int(m.group(4))}
        j = i + 1
        while j < len(lines) and len(rec) < 6:
            s = lines[j].strip()
            parts = s.split()
            if len(parts) >= 3 and parts[0] == "data" and parts[1].startswith("lplrfuzz_"):
                key = {"lplrfuzz_x": "x", "lplrfuzz_y": "y",
                       "lplrfuzz_d": "d"}[parts[1]]
                k = int(parts[2])
                arr = [float(v) for v in parts[3:3 + k]]
                if len(arr) == k:
                    rec[key] = np.array(arr, dtype=float)
            j += 1
        return rec
    return None


def main():
    for p, what in ((FUZZ_LOG, "the 300-trial run with the dump probe applied"),
                    (DUMP_LOG, "the permanent FZZMETA row record")):
        if not os.path.isfile(p):
            print("FAIL: %s is not present: %s" % (os.path.basename(p), what))
            print("      expected at %s" % p)
            print("      This script SELECTED trial 2's block out of 14 and wrote")
            print("      %s -- that selected output IS committed." % os.path.basename(OUT))
            print("      The two INPUTS were not: the dump probe was reverted in")
            print("      the same commit that consumed it, and the row record was")
            print("      never committed.  So the SELECTION is not reproducible from")
            print("      the tree; only its result is.  See section 27a of")
            print("      _verify/LPLR_GATE_BLINDNESS_1680.md.")
            return 2

    blocks = parse_port_blocks(read_lines(FUZZ_LOG))
    print("port dumps with n=66 : %d" % len(blocks))

    rec = parse_trial_record(read_lines(DUMP_LOG), TARGET_TRIAL)
    if not rec or "x" not in rec:
        print("FAIL: trial %d record not found in %s"
              % (TARGET_TRIAL, os.path.basename(DUMP_LOG)))
        print("      %s holds no FZZMETA block.  It is BYTE-IDENTICAL to the"
              % os.path.basename(DUMP_LOG))
        print("      harness transcript %s (sha256 prefix 6903e784), because"
              % os.path.basename(FUZZ_LOG))
        print("      the dump probe was reverted in the same commit that")
        print("      consumed it, so the capture holds the transcript and")
        print("      nothing else.  Re-running")
        print("      _verify/_lplr_fuzzrows_upstream_1680.py reproduces that.")
        print("")
        print("      This script SELECTED trial 2's block out of 14 and wrote")
        print("      %s -- that selected output IS committed." % os.path.basename(OUT))
        print("      The two INPUTS were not: the probe was reverted and the row")
        print("      record was never committed.  So the SELECTION is not")
        print("      reproducible from the tree; only its result is.  See")
        print("      section 27a of _verify/LPLR_GATE_BLINDNESS_1680.md.")
        return 2
    print("target record        : trial=%d n=%d p=%d seed=%d"
          % (TARGET_TRIAL, rec["n"], rec["p"], rec["seed"]))

    hits = []
    for bi, b in enumerate(blocks):
        if b["n"] != rec["n"] or b["p"] != rec["p"]:
            continue
        same = (b["x"].shape == rec["x"].shape
                and np.array_equal(b["x"], rec["x"])
                and np.array_equal(b["y"], rec["y"])
                and np.array_equal(b["d"], rec["d"]))
        if same:
            hits.append(bi)
        print("  block %2d : rows %s" % (bi, "MATCH" if same else "differ"))

    if not hits:
        print("FAIL: no block matches trial %d's rows" % TARGET_TRIAL)
        return 3

    # More than one match is expected and not an error: the port fits the same
    # rows more than once (repetitions / both score modes), and each fit has
    # its own nuisances. Every matching block is a valid (rows, nuisances) pair.
    print("")
    print("MATCHED %d block(s) for trial %d -> %s" % (len(hits), TARGET_TRIAL, hits))
    for k in ("x", "y", "d", "t", "m", "a", "b"):
        print("  port_lplr_%-2s n=%d" % (k, blocks[hits[0]][k].shape[0]))
    print("  m == a (port assigns m_pred = a_pred) : %s"
          % np.array_equal(blocks[hits[0]]["m"], blocks[hits[0]]["a"]))
    for bi in hits:
        b = blocks[bi]
        print("    block %2d : beta distinct=%d  t range=[%9.4g, %9.4g]"
              % (bi, len(np.unique(b["b"])), b["t"].min(), b["t"].max()))

    with io.open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# port's own fit(s) on fuzz trial %d rows (n=%d p=%d seed=%d)\n"
                 % (TARGET_TRIAL, rec["n"], rec["p"], rec["seed"]))
        for bi in hits:
            b = blocks[bi]
            fh.write("PORTMETA block=%d n=%d p=%d seed=%d\n"
                     % (bi, rec["n"], rec["p"], rec["seed"]))
            for k in ("x", "y", "d", "t", "m", "a", "b"):
                a = b[k]
                fh.write("data port_lplr_%s %d %s\n"
                         % (k, a.shape[0], " ".join(repr(float(v)) for v in a)))
    print("")
    print("wrote %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
