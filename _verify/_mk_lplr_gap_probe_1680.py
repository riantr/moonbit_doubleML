"""Make a patched copy of `pyexample_lplr.py` that REPORTS the gap even when
the emitter stops reproducing the pinned example value.

`pyexample_lplr.py:285` refuses to compare and returns 1 when the port's
emitted `lplr_ns_theta` no longer equals the pin. That refusal is correct
in normal use -- it is the signal that the example's rows stopped being
reproduced -- but it hides exactly the number needed to judge a candidate
change: whether the new port value is CLOSER to upstream or further.

So this copy replaces the refusal with a loud warning and continues into
sections 1-4, which is where upstream is fitted on the same rows and the
gap is computed. It changes no measurement, only whether the script stops
before reporting.

The copy lives in the REPO ROOT because the parity scripts derive their
working directory from `HERE = dirname(abspath(__file__))`; a copy in
`_verify/` would resolve paths against the wrong place.
"""

import io
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "pyexample_lplr.py")
DST = os.path.join(REPO, "_lplr_gap_probe_1680.py")

REFUSAL = '''    if not selfcheck:
        print("    REFUSING to compare: the fixture is not the example's data.")
        print("LPLR upstream parity: FAIL")
        return 1
'''

PATCHED = '''    if not selfcheck:
        print("    PIN MOVED -- continuing anyway so the gap can be judged.")
        print("    The rows are unchanged; the PORT moved. Comparing is still")
        print("    valid here, and whether it moved TOWARD or AWAY from")
        print("    upstream is what sections 2-3 measure.")
'''


def main():
    with io.open(SRC, encoding="utf-8", newline="") as f:
        src = f.read()
    n = src.count(REFUSAL)
    if n != 1:
        raise SystemExit("refusal anchor matched %d times" % n)
    out = src.replace(REFUSAL, PATCHED)
    with io.open(DST, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    with io.open(DST, encoding="utf-8", newline="") as f:
        chk = f.read()
    print("written:", os.path.basename(DST))
    print("refusal removed:", REFUSAL not in chk)
    print("patch applied:", PATCHED in chk)
    print("bytes:", len(chk))


if __name__ == "__main__":
    main()
