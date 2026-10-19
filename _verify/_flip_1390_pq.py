#!/usr/bin/env python3
"""v0.139.0 -- flip BOTH `DoubleMLPQ` and `DoubleMLQTE` default `ml_m`
from a regressor to a classifier.

Both or neither: they share `solve_pq` with `ml_m` in the identical role, and
v0.139.0 measured the SAME freeze on both entry points --

    PQ   (OLS): -0.38571498836568785 at tau = 0.10 / 0.25 / 0.50 / 0.75 / 0.90
                -> 0 distinct values across 4 steps
    QTE  (OLS): -1.5829876410256796 at tau = 0.50 / 0.75 / 0.90
                -> frozen to 14 significant digits, SEs equal to the 8th

so flipping one and not the other would leave the defect live on one of them.

Byte-level discipline, as everywhere in this repo: no BOM, no CRLF, each anchor
must match EXACTLY ONCE. The anchors are disambiguated by the return type that
follows them (`) -> DoubleMLPQ {` / `) -> DoubleMLQTE {`), which is what keeps
the script from touching either the inner forwarding constructor or a future
sibling.

`ml_l` deliberately stays OLS on QTE -- it models the conditional quantile
function of the outcome, not a probability.
"""

import io
import sys

PATH = "moonbit_doubleML/quantile.mbt"

# (suffix, name) -- the suffix is what makes each anchor unique.
SITES = [
    (") -> DoubleMLPQ {", "DoubleMLPQ"),
    (") -> DoubleMLQTE {", "DoubleMLQTE"),
]

OLD_TAIL = ("""  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
%s
""" % "").strip()


def build(suffix: str):
    """The exact two lines before the disambiguating return-type line."""
    return (
        "  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),\n"
        + suffix + "\n"
    )


NEW_TAIL = (
    "  ml_m? : LearnerDispatch = LearnerDispatch::logistic_regression(\n"
    "    LogisticRegression::new(),\n"
    "  ),\n"
)


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "forward"
    with io.open(PATH, "rb") as fh:
        raw = fh.read()

    if raw.startswith(b"\xef\xbb\xbf"):
        print("FAIL: %s has a UTF-8 BOM" % PATH)
        return 1
    if b"\r\n" in raw:
        print("FAIL: %s contains CRLF; the package is LF-only" % PATH)
        return 1

    text = raw.decode("utf-8")

    for suffix, name in SITES:
        old = build(suffix)
        new = old.replace(
            "  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),\n",
            NEW_TAIL,
        )
        if mode == "revert":
            new = (
                "  ml_m? : LearnerDispatch = LearnerDispatch::logistic_regression(\n"
                "    LogisticRegression::new(),\n"
                "  ),\n" + suffix + "\n"
            )
            old = new
            new = build(suffix)
        n = text.count(old)
        if n != 1:
            print("FAIL: %s anchor matched %d times (need exactly 1)" % (name, n))
            return 1
        text = text.replace(old, new, 1)
        print("  %s: %s" % (name, "-> logistic_regression" if mode != "revert"
                            else "-> linear_regression"))

    # Post-conditions, checked on the FINAL text so a partial application
    # cannot slip through.
    if mode != "revert":
        for suffix, name in SITES:
            if build(suffix) in text:
                print("FAIL: %s still defaults to the regressor" % name)
                return 1
            if NEW_TAIL + suffix + "\n" not in text:
                print("FAIL: %s classifier default not present" % name)
                return 1
    else:
        for suffix, name in SITES:
            if NEW_TAIL + suffix + "\n" in text:
                print("FAIL: %s still defaults to the classifier" % name)
                return 1

    with io.open(PATH, "wb") as fh:
        fh.write(text.encode("utf-8"))

    print("OK: %s (%s)" % (PATH, mode))
    return 0


if __name__ == "__main__":
    sys.exit(main())
