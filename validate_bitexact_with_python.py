"""Per-item BIT-EXACT parity between MoonBit and CPython.

WHAT THIS IS FOR
================
The other `validate_*_with_python.py` scripts compare MoonBit's output to a
Python reference under a *tolerance*. A tolerance cannot distinguish "the port
is arithmetically identical to the reference" from "the port happens to land
inside 1e-4 of it", and it cannot detect a sign flip that happens to be small
relative to the effect size. This one compares IEEE-754 bit patterns: the
64-bit patterns must be identical, item by item.

WHAT IS BIT-EXACT-ABLE, AND WHAT IS NOT -- MEASURED
====================================================
IEEE-754 requires `+ - * /` and `sqrt` to be correctly rounded. Two independent
implementations given the same operands in the same order MUST therefore agree
bit-for-bit. `ln`, `cos`, `sin`, `exp` and `pow` are NOT correctly rounded in
any implementation, and the difference is real and was measured on this pair of
toolchains (`moon 0.1.20261012` vs CPython 3.14, 6 arguments each):

    sqrt  6/6 bit-exact      guaranteed by IEEE-754
    cos   6/6 bit-exact      agreement observed, NOT guaranteed
    sin   6/6 bit-exact      agreement observed, NOT guaranteed
    ln    5/6 bit-exact      ln(3.0) differs by exactly 1 ULP
                             moon  1.0986122886681096
                             python 1.0986122886681098

That measurement is the reason this file asserts what it asserts. `ln` is used
by `box_muller_pair` (`ln`, `cos`, `sin`), so EVERY random-number DGP in the
package is one transcendental away from being non-reproducible at the bit
level. There is no tolerance that fixes this and no amount of care in either
implementation: it is a property of libm.

So the honest scope is:

  * ASSERTED bit-exact -- closed-form arithmetic built only from `+ - * / sqrt`
    over data that is exact in binary, plus the pure-integer RNG key.
  * NOT ASSERTED, and named here so the absence is not mistaken for an
    oversight: every DGP routed through Box-Muller, and every estimator that
    goes through BLAS/LAPACK (numpy reductions use pairwise summation and
    LAPACK uses blocked pivoting, so their operation ORDER differs from any
    hand-written loop).

SUMMATION ORDER IS PART OF THE CONTRACT
=======================================
Everything below accumulates with explicit Python loops. This is deliberate and
must not be "optimised" into numpy: `numpy.sum` switches to pairwise summation
at n >= 8, which reassociates the additions and changes the last bits. Doing
that would turn this from a parity test into a red herring that fails for a
reason that has nothing to do with the port.

Exit code 0 only if every item matched bit-for-bit.
"""
from __future__ import annotations

import struct
import subprocess
import sys
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
EXAMPLE = "examples/bitexact"


# --------------------------------------------------------------------------- #
# IEEE-754 helpers
# --------------------------------------------------------------------------- #
def bits(x: float) -> bytes:
    return struct.pack("<d", x)


def ulp_gap(a: float, b: float) -> int:
    """Distance between two doubles in units in the last place."""
    ia = struct.unpack("<q", bits(a))[0]
    ib = struct.unpack("<q", bits(b))[0]
    # Map to a monotone integer ordering across the sign boundary.
    if ia < 0:
        ia = -0x8000000000000000 - ia
    if ib < 0:
        ib = -0x8000000000000000 - ib
    return abs(ia - ib)


# --------------------------------------------------------------------------- #
# run the emitter
# --------------------------------------------------------------------------- #
def run_moonbit() -> str:
    result = subprocess.run(
        ["moon", "run", EXAMPLE, "--target", "native"],
        cwd=ROOT, capture_output=True, text=True, timeout=900,
        encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        err = result.stderr or result.stdout
        raise RuntimeError(
            "moon run %s exited %d: %s" % (EXAMPLE, result.returncode, err[:400]))
    return result.stdout


def parse(out: str) -> tuple[dict, dict, dict]:
    arrays: dict[str, list[float]] = {}
    items: dict[str, float] = {}
    keys: dict[int, bytes] = {}
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "array":
            arrays[parts[1]] = [float(t) for t in parts[3:]]
        elif parts[0] == "item":
            items[parts[1]] = float(parts[2])
        elif parts[0] == "key":
            seed = int(parts[1])
            keys[seed] = b"".join(
                _byte_literal(t) for t in parts[2:])
    return arrays, items, keys


def _byte_literal(tok: str) -> bytes:
    """MoonBit prints a Byte as a Python bytes literal, e.g. `b'\\x45'`."""
    body = tok.strip()
    if body.startswith("b'") and body.endswith("'"):
        body = body[2:-1]
    return bytes(int(body[i + 2:i + 4], 16)
                 for i in range(0, len(body), 4))


# --------------------------------------------------------------------------- #
# the reference. Mirrors examples/bitexact/main.mbt operation for operation.
# --------------------------------------------------------------------------- #
def ref_mean(a: list[float], n: int) -> float:
    s = 0.0
    for i in range(n):
        s = s + a[i]
    return s / float(n)


def ref_popvar(a: list[float], n: int, m: float) -> float:
    s = 0.0
    for i in range(n):
        d = a[i] - m
        s = s + d * d
    return s / float(n)


def ref_popcov(a, b, n, ma, mb) -> float:
    s = 0.0
    for i in range(n):
        s = s + (a[i] - ma) * (b[i] - mb)
    return s / float(n)


def ref_group_mean(y, z, n, g):
    s = 0.0
    c = 0
    for i in range(n):
        if z[i] == g:
            s = s + y[i]
            c = c + 1
    return s / float(c), c


def ref_group_var(y, z, n, g, m) -> float:
    s = 0.0
    c = 0
    for i in range(n):
        if z[i] == g:
            d = y[i] - m
            s = s + d * d
            c = c + 1
    return s / float(c)


def ref_tss(t, cnt) -> float:
    mt = 0.0
    for i in range(cnt):
        mt = mt + t[i]
    mt = mt / float(cnt)
    s = 0.0
    for i in range(cnt):
        d = t[i] - mt
        s = s + d * d
    return s


def ref_local_linear(t, y, n):
    cnt = 0
    mt = 0.0
    my = 0.0
    for i in range(n):
        if t[i] >= 0.0:
            cnt += 1
            mt = mt + t[i]
            my = my + y[i]
    c = float(cnt)
    mt = mt / c
    my = my / c
    stt = 0.0
    sty = 0.0
    for i in range(n):
        if t[i] >= 0.0:
            dt = t[i] - mt
            stt = stt + dt * dt
            sty = sty + dt * (y[i] - my)
    slope = sty / stt
    inter = my - slope * mt
    sse = 0.0
    for i in range(n):
        if t[i] >= 0.0:
            e = y[i] - (inter + slope * t[i])
            sse = sse + e * e
    return slope, inter, sse, cnt


def ref_seed_key(seed: int) -> bytes:
    """The 32-byte ChaCha8 key: seed_to_bytes' documented layout.

    Little-endian 32-bit view, tiled eight times. Pure integer, so this is a
    reimplementation from the SPEC in seed.mbt's doc comment, not a copy of the
    MoonBit code -- which is what makes it an independent check.
    """
    s = seed & 0xFFFFFFFF
    quad = bytes([s & 0xFF, (s >> 8) & 0xFF, (s >> 16) & 0xFF, (s >> 24) & 0xFF])
    return quad * 8


def reference(arrays: dict) -> dict:
    x = arrays["data_x"]
    z = arrays["data_z"]
    u = arrays["data_u"]
    y = arrays["data_y"]
    t = arrays["data_t"]
    n = len(x)

    out = {}
    mx = ref_mean(x, n)
    mu = ref_mean(u, n)
    my = ref_mean(y, n)
    out["mean_x"] = mx
    out["mean_u"] = mu
    out["mean_y"] = my
    vx = ref_popvar(x, n, mx)
    vu = ref_popvar(u, n, mu)
    out["popvar_x"] = vx
    out["popvar_u"] = vu
    out["sd_x"] = vx ** 0.5
    out["sd_u"] = vu ** 0.5
    out["cov_xu"] = ref_popcov(x, u, n, mx, mu)
    out["cov_xy"] = ref_popcov(x, y, n, mx, my)
    out["corr_xu"] = ref_popcov(x, u, n, mx, mu) / (vx ** 0.5 * vu ** 0.5)

    m1, c1 = ref_group_mean(y, z, n, 1.0)
    m0, c0 = ref_group_mean(y, z, n, 0.0)
    out["did_theta"] = m1 - m0
    out["did_n1"] = float(c1)
    out["did_n0"] = float(c0)
    v1 = ref_group_var(y, z, n, 1.0, m1)
    v0 = ref_group_var(y, z, n, 0.0, m0)
    out["did_var1"] = v1
    out["did_var0"] = v0
    out["did_se_cr0"] = (v1 / float(c1) + v0 / float(c0)) ** 0.5

    slope, inter, sse, cnt = ref_local_linear(t, y, n)
    out["rdd_slope"] = slope
    out["rdd_intercept"] = inter
    out["rdd_sse"] = sse
    out["rdd_n"] = float(cnt)
    sd_t = ref_tss(t, cnt) / (float(cnt) - 1.0)
    out["rdd_slope_se"] = (sse / (float(cnt) - 2.0) / sd_t) ** 0.5

    ss = 0.0
    for i in range(n):
        psi = -1.0 * -1.0 + y[i]
        ss = ss + psi * psi
    out["sandwich_sum_psi2"] = ss
    out["varest_se"] = (ss / float(n) / 1.0) ** 0.5
    out["hc0_se"] = (ss / 1.0 / float(n)) ** 0.5
    out["hc0_minus_varest"] = ((ss / 1.0 / float(n)) ** 0.5
                               - (ss / float(n) / 1.0) ** 0.5)
    return out


# --------------------------------------------------------------------------- #
# comparison
# --------------------------------------------------------------------------- #
def compare(got: dict, want: dict) -> list[tuple]:
    """Returns [(name, got_repr, want_repr, ulp)] for every item that differs.

    Bit comparison, not a tolerance: `struct.pack` equality IS the assertion.
    """
    bad = []
    for name in sorted(want):
        if name not in got:
            bad.append((name, "<missing>", repr(want[name]), -1))
            continue
        if bits(got[name]) != bits(want[name]):
            bad.append((name, repr(got[name]), repr(want[name]),
                        ulp_gap(got[name], want[name])))
    for name in sorted(got):
        if name not in want:
            bad.append((name, repr(got[name]), "<not in reference>", -1))
    return bad


def self_test(items: dict) -> int:
    """Control arm: a comparator that cannot fail must never pass.

    Perturbs each item by exactly one ULP and requires the comparator to notice.
    A 1-ULP perturbation is the smallest possible disagreement, so if this
    passes silently, the check is measuring nothing.
    """
    ok = True
    ref = dict(items)
    clean = compare(items, ref)
    if clean:
        print("  CONTROL BROKEN: identity compare reported %d differences"
              % len(clean))
        ok = False
    else:
        print("  control: identical inputs -> 0 differences  [ok]")

    for name in sorted(items):
        orig = items[name]
        nudged = struct.unpack("<d", struct.pack("<q",
                        struct.unpack("<q", bits(orig))[0] + 1))[0]
        trial = dict(items)
        trial[name] = nudged
        found = compare(trial, ref)
        if not any(f[0] == name for f in found):
            print("  CONTROL BROKEN: a 1-ULP change to %r went undetected" % name)
            ok = False
    print("  control: every item flagged at 1 ULP  [%s]"
          % ("ok" if ok else "BROKEN"))
    return 0 if ok else 1


def main() -> int:
    argv = sys.argv[1:]
    if "--self-test" in argv:
        out = run_moonbit()
        _, items, _ = parse(out)
        print("bit-exact comparator self-test")
        return self_test(items)

    print("=" * 74)
    print("Bit-exact parity: MoonBit vs CPython, by IEEE-754 bit pattern")
    print("=" * 74)
    out = run_moonbit()
    arrays, items, keys = parse(out)
    if not items:
        print("the emitter produced no items; refusing to pass")
        return 1
    want = reference(arrays)

    print()
    print("--- data ---")
    for k in sorted(arrays):
        print("  %-8s n=%d  first=%s  last=%s"
              % (k, len(arrays[k]), arrays[k][0], arrays[k][-1]))
    print("  all five series are exact in binary (small integers times powers "
          "of two),")
    print("  so the only rounding anywhere is the rounding under test.")

    print()
    print("--- items: %d, compared by bit pattern ---" % len(want))
    bad = compare(items, want)
    for name in sorted(want):
        if any(b[0] == name for b in bad):
            continue
        print("  bit-exact  %-20s %r" % (name, items[name]))
    for name, g, w, u in bad:
        print("  DIFFER     %-20s moon=%s python=%s ulp=%d"
              % (name, g, w, u))

    print()
    print("--- RNG keys: %d, compared byte-for-byte ---" % len(keys))
    key_bad = 0
    for seed in sorted(keys):
        mine = keys[seed]
        theirs = ref_seed_key(seed)
        if mine == theirs:
            print("  bit-exact  key(%-12d) %s..." % (seed, mine[:8].hex()))
        else:
            key_bad += 1
            print("  DIFFER     key(%-12d) %s vs %s"
                  % (seed, mine.hex(), theirs.hex()))

    print()
    print("--- deliberately NOT asserted, and why ---")
    print("  Every Box-Muller DGP. `ln(3.0)` already differs by 1 ULP between")
    print("  these toolchains, and box_muller_pair uses ln/cos/sin, so no")
    print("  random DGP can be bit-exact. A gate asserting otherwise would be")
    print("  a gate that could not pass.")
    print("  Every BLAS/LAPACK path. numpy reduces with pairwise summation and")
    print("  LAPACK blocks its pivots, so the operation order differs from any")
    print("  hand-written loop.")

    ok = not bad and not key_bad
    print()
    print("items %d/%d bit-exact, keys %d/%d byte-identical"
          % (len(want) - len(bad), len(want),
             len(keys) - key_bad, len(keys)))
    print("bit-exact parity: %s" % ("PASS" if ok else "FAIL"))
    if not ok:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
