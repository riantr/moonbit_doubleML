"""Create a patched COPY of pyexample_lplr.py in the repo ROOT.

So the LPLR gap can be measured on changed port code WITHOUT touching the
repo's own golden -- editing `pyexample_lplr.py`'s `expected` first would
have blessed the change and reported it as agreement.

Why the repo root and not `_verify/`: the gates derive their working
directory from `HERE = dirname(abspath(__file__))`, so a copy parked in
`_verify/` runs `moon run` from there and exits -1.
"""

import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SRC = os.path.join(REPO, "pyexample_lplr.py")
ANCHOR = "    expected = "
DST = os.path.join(REPO, "_pyexample_lplr_d1gap_1680.py")


def main():
    new_value = sys.argv[1]
    with io.open(SRC, encoding="utf-8", newline="") as f:
        lines = f.readlines()
    hits = [i for i, l in enumerate(lines) if l.startswith(ANCHOR)]
    if len(hits) != 1:
        raise SystemExit("expected-pin anchor found %d times" % len(hits))
    lines[hits[0]] = "    expected = %s\n" % new_value
    banner = (
        "# *** PARCHED COPY -- not the CI gate. Expected value re-pinned to\n"
        "# *** measure the port/upstream gap on changed code. Delete after use.\n"
    )
    with io.open(DST, "w", encoding="utf-8", newline="\n") as f:
        f.write(banner + "".join(lines))
    print("wrote %s with expected = %s" % (DST, new_value))


if __name__ == "__main__":
    main()
