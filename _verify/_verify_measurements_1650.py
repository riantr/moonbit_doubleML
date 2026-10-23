#!/usr/bin/env python3
"""Round 32 verifier: the README's quoted MEASUREMENTS.

WHY THIS EXISTS
===============
The README quotes measured numbers -- a hazard table of per-estimator biases
and standard errors, a white-box table, a set of separations, and a small-n
regime analysis.  Round 21 found that three of the margin figures had already
rotted (the "366x" was 367x, the "300x" was 320x, the "0.198" was 0.19828),
and it fixed that ONE paragraph by re-deriving its figures from the
measurement record.

The rest of the quoted measurements were never covered.  A census of the
README's numbers found the surface: the per-estimator hazard table's CELLS
(`-225.86` vs `1.44`, `242.116` vs `1.177`, `436.11`, ...) were quoted from
the v0.132.0-v0.142.0 measurement rounds with nothing re-deriving them, and
the small-n regime figures (`6.842`, `-8.07e-05`, the `2.56`/`3.39`/`[-3.21,
13.85]` spread) were quoted from a record that nothing tied back to.

FOUR INVARIANTS
================
I1 -- EVERY RATIO THE README STATES MUST BE DERIVABLE FROM THE NUMBERS ITS
      OWN PASSAGE PRINTS.
      A separation, a factor, a percentage: the reader divides the numbers
      the passage gives and gets the same number.  This is the invariant
      that found the defect round 32 opened with.  The README said the
      derivative was `-8.07e-05` "against a score of `-0.1119`, a factor of
      **344** down" -- but that quotient is **1387**.  The 344 is real: it
      is the derivative's fall from `-0.0277` at `theta0 = 1.003` to
      `-8.07e-05` at `theta0 = 6.842`, which is what the witness script
      prints ("derivative falls by a factor of 343.5").  The passage
      attached it to the wrong pair, so a reader could not check it.

      A table row is its own passage: a ratio in a row must be derivable
      from THAT row's numbers, not from the table's.

I2 -- EVERY NUMBER IN A TABLE CELL MUST BE THE CORRECTLY-ROUNDED RENDERING
      OF A VALUE IN THE RECORD THAT MEASURED IT.

      The witness set is DERIVED, not listed: the CHANGELOG entries that name
      the row's key.  "Correctly rounded" rather than "literally equal",
      because the README quotes `0.531` where the record holds `0.5307` --
      a rendering of the measured value, not a different value.

I3 -- EVERY SMALL-N FIGURE MUST BE THE CORRECTLY-ROUNDED RENDERING OF A
      VALUE IN THE RECORD THE README CITES.

      `_verify/LPLR_GATE_BLINDNESS_1680.md`, which the README names for that
      passage.

I4 -- A TABLE'S MEASUREMENTS MUST BE WRITTEN IN CODE SPANS.

      The README writes every measured value in a code span, and I2 reads a
      cell's numbers out of those spans.  A convention nobody enforces decays:
      the propensity table wrote its four measurements in bold and plain, so
      they were NEVER checked -- and the v0.131.9 record holds all four, so
      they were checkable all along.  I4 makes the convention a check, so the
      next table that breaks it fails here rather than going unchecked for
      another twenty releases.

WHAT IS DERIVED, NOT ASSERTED
=============================
  * the passages, the tables, the cells and the ratios, from the README;
  * the witness set for I2, from the CHANGELOG's own entries;
  * the witness set for I3, from the record the README cites;
  * the measured rows for I4, from the README's own tables;
  * the set sizes, declared here and asserted in section 1, so an added
    measurement cannot slip in without the declaration moving with it.

Run: python _verify/_verify_measurements_1650.py
"""
import io
import os
import re
import sys
from decimal import Decimal, ROUND_HALF_UP

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
RECORD = os.path.join(ROOT, "_verify", "LPLR_GATE_BLINDNESS_1680.md")

# The declared set sizes.  A change to either is a change to the SET.
#
# Round 38: the hazard table's QTE row now names the THREE sampled taus the
# v0.139.0 release actually measured (`0.50` / `0.75` / `0.90`), where the
# range spelling it replaced (`0.50`-`0.90`) carried TWO code spans.  The
# declaration moves with the measurement, which is the whole point of
# declaring it.
EXPECTED_CELLS = 28
EXPECTED_RATIOS = 9
EXPECTED_MEASURED_ROWS = 12
EXPECTED_SMALLN_FIGURES = 15

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-56s %s" % (label, detail))
    else:
        FAILS.append(label)
        print("  *** FAIL ***  %-50s %s" % (label, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


# ---------------------------------------------------------------------------
# the lexical bits
# ---------------------------------------------------------------------------
# a number, SIGN INCLUDED: a rendering's sign is part of the claim.
# The trailing guard rejects a number that is really the PREFIX of a longer
# one ("1.44" inside "1.4426"), but it must NOT reject "0.053x" -- the "x"
# there is the multiplication sign, not part of an identifier.
NUMVAL = re.compile(r"(?<![\w.])-?\d+(?:\.\d+)?(?:e[+-]?\d+)?(?![e\d.])")

# the ratios the prose states.  Each alternative is a way a factor, a
# separation or a percentage gets written.
RATIO = re.compile(
    r"factor of \*\*(\d+(?:\.\d+)?)\*\*"        # factor of **344**
    r"|\*\*(\d+(?:\.\d+)?)x\b"                   # **367x**
    r"|\*\*(\d+(?:\.\d+)?)\*\* ?times"           # **10** times
    r"|\*\*(\d+(?:\.\d+)?)%\*\*"                 # **42%**
    r"|(?<![\w.])(\d+(?:\.\d+)?)x\b"             # 367x, 200x, 16x
    r"|(?<![\w.])(\d+(?:\.\d+)?)%")              # 42%

# a table row: a leading key cell, then the cells
ROW = re.compile(r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|$")

# a CODE SPAN holding exactly one number.  This is the README's own
# convention for a measured value, and it is what makes a cell checkable: the
# extractor below reads a cell's numbers out of these spans.  The exponent
# form is part of it (`1e-4`), so the span may carry one.
CODE_CELL = re.compile(r"`(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)`")

# any code span, whatever it holds
CODE_SPAN = re.compile(r"`([^`]*)`")


def span_measurements(content):
    """The numbers a code span STATES, when it states numbers.

    The span's content must be a number, or a bracketed list or range of
    numbers: `[-3.21, 13.85]` states two.  Anything else is a name, an
    argument or a fragment -- `ln(3.0)`, `double_ml_score_mixins.py:149`,
    `moonbitlang/async@0.20.3`, `e+70`, `nan` -- and states no measurement.

    `nan` and `inf` are excluded even though they PARSE as floats: they are
    what a broken fit produces, not a value somebody measured.
    """
    c = content.strip()
    if not c:
        return []
    if c.startswith("[") and c.endswith("]"):
        c = c[1:-1]
    out = []
    for part in c.split(","):
        part = part.strip()
        if not part:
            return []
        try:
            v = float(part)
        except ValueError:
            return []
        if v != v or v in (float("inf"), float("-inf")):
            return []
        out.append(part)
    return out

# a code span holding ANYTHING else -- `ln(3.0)`, `make_did_SZ2020`,
# `moonbitlang/async@0.22.5`.  A number inside one of these is part of a
# name or an argument, not a measurement.
CODE_ANY = re.compile(r"`[^`]*`")


def sig_digits(s):
    """How many significant digits a rendering carries."""
    m = re.match(r"^-?(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$", s)
    if not m:
        return None
    whole, frac = m.group(1) or "", m.group(2) or ""
    return len((whole + frac).lstrip("0")) or 1


def sig_round(d, sig):
    """Round a Decimal to `sig` significant digits."""
    if d == 0:
        return d
    return d.quantize(Decimal(1).scaleb(d.adjusted() - sig + 1),
                      rounding=ROUND_HALF_UP)


def renders_as(value, rendering):
    """Is `value` the correctly-rounded rendering `rendering`?

    Exact string equality first (the common case), then the rounding of the
    numeric value to the rendering's own SIGNIFICANT DIGITS.
    """
    if value == rendering:
        return True
    sig = sig_digits(rendering)
    if sig is None:
        return False
    try:
        v = Decimal(value)
        r = Decimal(rendering)
    except Exception:                                     # noqa: BLE001
        return False
    if sig_round(v, sig) != sig_round(r, sig):
        return False
    # the rendered forms must agree digit for digit, including the exponent
    def form(x):
        t = format(x, "f") if abs(x.adjusted()) < 6 else format(x, "e")
        return t
    return form(sig_round(v, sig)) == form(sig_round(r, sig))


def ratio_of(m):
    for g in m.groups():
        if g is not None:
            return float(g)
    return None


def numbers_in(text):
    vals = []
    for m in NUMVAL.finditer(text):
        try:
            vals.append(float(m.group(0)))
        except ValueError:
            pass
    return vals


def derivable(ratio, vals, is_percent, exclude=None):
    """Can `ratio` be divided out of the numbers `vals` prints?

    A ratio is derivable when some pair of the printed numbers has a
    quotient (or a reciprocal) equal to it.  The unit 1 is available
    implicitly: a claim like "0.053x upstream's" is a ratio against 1.

    `exclude` is the ratio's OWN token: a ratio must never witness itself,
    or every stated ratio would be trivially "derivable" by 1 / itself.

    The returned tuple is (distance, dividend, divisor, quotient, scaled).
    The dividend and the divisor are ORDERED so that the evidence this
    function hands back is an equality that is TRUE AS PRINTED: "5.2464 /
    0.5307 = 9.9", never "0.5307 / 5.2464 = 9.9".  `scaled` says the
    quotient was multiplied by 100 (a percentage), in which case the
    quotient itself is the fraction and the comparison value is the
    percentage.
    """
    best = None
    for a in vals:
        if exclude is not None and abs(a - exclude) < 1e-12:
            continue
        for b in vals:
            if a == 0 or b == 0 or a == b:
                continue
            if exclude is not None and abs(b - exclude) < 1e-12:
                continue
            # both orders, each carrying its own dividend and divisor
            for x, y, q in ((a, b, abs(a / b)), (b, a, abs(b / a))):
                cands = [(q, False)]
                if is_percent:
                    cands.append((q * 100.0, True))
                for c, scaled in cands:
                    if c < 1.5:
                        continue
                    d = abs(c - ratio) / ratio
                    if best is None or d < best[0]:
                        best = (d, x, y, q, c, scaled)
    # the implicit unit
    for a in vals:
        if a == 0:
            continue
        if exclude is not None and abs(a - exclude) < 1e-12:
            continue
        for x, y, q in ((1.0, a, abs(1.0 / a)), (a, 1.0, abs(a))):
            cands = [(q, False)]
            if is_percent:
                cands.append((q * 100.0, True))
            for c, scaled in cands:
                if c < 1.5:
                    continue
                d = abs(c - ratio) / ratio
                if best is None or d < best[0]:
                    best = (d, x, y, q, c, scaled)
    return best


readme = read(README)
paragraphs = readme.split("\n\n")

# ==============================================================================
print("=" * 78)
print("1. I1 -- every stated ratio is derivable from its own passage")
print("=" * 78)

# a passage is a prose paragraph, or a single table row.  A table's lines are
# REMOVED from the prose passages: a ratio in a row must be derivable from
# THAT row's numbers, not from the table's.
passages = []
rows = []
for p in paragraphs:
    kept = []
    for line in p.split("\n"):
        m = ROW.match(line)
        if m:
            rows.append((m.group(1), m.group(2) + " " + m.group(3)))
        else:
            kept.append(line)
    passages.append("\n".join(kept))

ratios = []
for p in passages:
    vals = numbers_in(p)
    if len(vals) < 2:
        continue
    for m in RATIO.finditer(p):
        r = ratio_of(m)
        if r is None or r < 1.5:
            continue
        pct = "%" in m.group(0)
        loose = ("roughly" in p) or ("~" in p)
        ratios.append((r, derivable(r, vals, pct, exclude=r), loose, p, pct))
# the table rows, each on its own
for key, body in rows:
    vals = numbers_in(body)
    if len(vals) < 2:
        continue
    for m in RATIO.finditer(body):
        r = ratio_of(m)
        if r is None or r < 1.5:
            continue
        pct = "%" in m.group(0)
        loose = ("roughly" in body) or ("~" in body)
        ratios.append((r, derivable(r, vals, pct, exclude=r), loose,
                       "TABLE ROW: %s | %s" % (key, body), pct))

check("the ratio set is the declared size",
      len(ratios) == EXPECTED_RATIOS,
      "found %d, declared %d" % (len(ratios), EXPECTED_RATIOS))

for r, best, loose, p, pct in ratios:
    band = 0.05 if loose else 0.02
    ok = best is not None and best[0] <= band
    detail = ""
    if ok:
        # the dividend and the divisor are ORDERED, so the printed
        # equality is true as printed.
        _, x, y, q, c, scaled = best
        if scaled:
            detail = "%g / %g = %.4f = %.1f%%" % (x, y, q, c)
        else:
            detail = "%g / %g = %.1f" % (x, y, q)
    else:
        detail = ("no pair of the passage's numbers gives %g%s"
                  % (r, "%" if pct else ""))
    where = p.strip().split("\n")[0][:40]
    check("the ratio %g%s is derivable" % (r, "%" if pct else ""), ok, detail)
    if not ok:
        print("        in: %s" % where)

# ==============================================================================
print()
print("=" * 78)
print("2. I2 -- every table cell is witnessed by the record")
print("=" * 78)

chlog = read(CHANGELOG)
entries = []
for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|\Z)",
                     chlog, re.M | re.S):
    entries.append((m.group(1), m.group(2)))

cells = []
for p in paragraphs:
    for line in p.split("\n"):
        m = ROW.match(line)
        if not m:
            continue
        key = m.group(1)
        if key.startswith("---"):
            continue
        for tok in CODE_CELL.findall(m.group(2) + " " + m.group(3)):
            cells.append((key, tok))

check("the cell set is the declared size",
      len(cells) == EXPECTED_CELLS,
      "found %d, declared %d" % (len(cells), EXPECTED_CELLS))

for key, n in cells:
    wit = [(ver, body) for ver, body in entries if key in body]
    found = []
    for ver, body in wit:
        for tok in NUMVAL.findall(body):
            if renders_as(tok, n):
                found.append("%s:%s" % (ver, tok))
                break
    check("the cell %-10s of %-22s is witnessed" % (n, key[:22]),
          bool(found),
          found[0] if found else "no entry naming %s holds it" % key[:28])

# ==============================================================================
print()
print("=" * 78)
print("3. I4 -- a table's measurements are written in code spans")
print("=" * 78)
#
# The README writes every measured value in a CODE SPAN, and section 2 reads
# a table cell's numbers out of those spans.  That is a convention, and a
# convention nobody enforces is a convention that decays: the propensity
# table wrote its four measurements in bold and plain, so they were never
# checked -- and they were checkable all along (the v0.131.9 record holds
# all four).
#
# So the convention becomes a check.  A MEASUREMENT is a number carrying a
# decimal point or an exponent:
#
#   * a bare integer is a count, a year or an identifier, not a measurement;
#   * a number inside a code span holding anything else (`ln(3.0)`) is part
#     of a name or an argument, not a measurement;
#   * a version token (`v0.138.0`, `async@0.20.3`) yields no number at all,
#     because NUMVAL already rejects it.
#
# Every measurement in a table row must be written in a code span of its own.


def unspanned_measurements(cell_text):
    """The measurements in a cell that are NOT in a code span of their own."""
    text = CODE_CELL.sub(" ", cell_text)      # the conforming ones
    text = CODE_ANY.sub(" ", text)             # every other code span
    out = []
    for m in NUMVAL.finditer(text):
        tok = m.group(0)
        if "." in tok or "e" in tok.lower():
            out.append(tok)
    return out


measured_rows = []
for p in paragraphs:
    for line in p.split("\n"):
        m = ROW.match(line)
        if not m:
            continue
        key = m.group(1)
        if key.startswith("---"):
            continue
        body = m.group(2) + " " + m.group(3)
        nums = [t for t in NUMVAL.findall(body) if "." in t or "e" in t.lower()]
        if nums:
            measured_rows.append((key, body, nums))

check("the measured-row set is the declared size",
      len(measured_rows) == EXPECTED_MEASURED_ROWS,
      "found %d, declared %d" % (len(measured_rows), EXPECTED_MEASURED_ROWS))

for key, body, nums in measured_rows:
    bad = unspanned_measurements(body)
    check("the measurements of %-22s are code-spanned" % key[:22],
          not bad,
          "not in a code span: %s" % ", ".join(bad) if bad
          else "%d measurement(s), all code-spanned" % len(nums))

# ==============================================================================
print()
print("=" * 78)
print("4. I3 -- every small-n figure is witnessed by the cited record")
print("=" * 78)

record = read(RECORD)
rec_values = NUMVAL.findall(record)

# The small-n passage: the paragraphs the README's LPLR analysis is made of.
# It is selected by its MARKERS, not by a line range, so the passage grows
# with the analysis and the selection follows it.
smalln = "\n\n".join(p for p in paragraphs
                     if "17 of 40" in p or "basin edge" in p)

# A figure is a measured value.  Two rules, and they are complementary:
#
#   * a number with a decimal point or an exponent is one -- `0.1983`,
#     `5.18e+70`, and the `2.56` and `3.39` of "mean 2.56, sd 3.39";
#   * a code span holding exactly one number is one -- that is how the
#     document writes a measured value, and it is what separates `-648` and
#     `172149` (measured coefficients) from the counts around them.
#
# The second rule is what lets an INTEGER be a figure without a file:line
# number joining it: `double_ml_score_mixins.py:149` is a span holding more
# than a number, so it is a citation, not a measurement.  A bare integer in
# prose -- "17 of 40", "18 of 40", "x 4" -- is a count and stays out.
figs = []
for m in NUMVAL.finditer(smalln):
    tok = m.group(0)
    if "." not in tok and "e" not in tok.lower():
        continue                      # a count, unless a code span says so
    if tok not in figs:
        figs.append(tok)

for m in CODE_SPAN.finditer(smalln):
    for tok in span_measurements(m.group(1)):
        if tok not in figs:
            figs.append(tok)

check("the small-n figure set is the declared size",
      len(figs) == EXPECTED_SMALLN_FIGURES,
      "found %d, declared %d" % (len(figs), EXPECTED_SMALLN_FIGURES))
for tok in figs:
    hits = [v for v in rec_values if renders_as(v, tok)]
    check("the figure %s is in the cited record" % tok, bool(hits),
          hits[0] if hits else "the record holds no value that renders as it")

# ==============================================================================
print()
print("=" * 78)
print("5. the published check count, witnessed")
print("=" * 78)
# The CHANGELOG publishes this verifier's check count.  The count is fixed on
# every tree that passes: the set sizes are declared and asserted above, so a
# measurement cannot be added or removed without the declaration moving with
# it, and the published number cannot drift.
# ==============================================================================
_found = re.findall(r"_verify_measurements_1650\.py` \(\*\*(\d+)\*\* checks\)",
                    read(CHANGELOG))
published = int(_found[0]) if _found else None
check("the CHANGELOG publishes this verifier's check count",
      published is not None,
      "the '(**N** checks)' line for this verifier is absent" if published is None
      else "published %d (of %d occurrences, newest first)"
      % (published, len(_found)))
check("the published check count is the count this run made",
      published is not None and published == NCHECK + 1,
      "published %s, this run makes %d" % (published, NCHECK + 1))

# ==============================================================================
print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
for f in FAILS:
    print("  FAILED: %s" % f)
print("=" * 78)
sys.exit(1 if FAILS else 0)
