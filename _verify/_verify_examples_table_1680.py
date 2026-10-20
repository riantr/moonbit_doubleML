"""Check the Examples table's DGP and true-value columns against the drivers.

The table has a DGP column (`n=5000`, `400 units`, `4 cohorts x 4 periods`)
and a "True theta" column. Both are claims about what each driver actually
does, so both are read from the driver SOURCE and, where the driver prints
it, from its OUTPUT.

The five rows that were wrong when this table was last written:
  datasets   n=5000   -> the source says `let n = 4000`
  cvar       1.0      -> the driver asserts against 1.74
  splitting  1.0      -> the DGP is `y = 1.5 * d + ...`
  lplr       1.0      -> the logit-scale alpha is 0.5
  pava       1.0      -> the driver prints no true value at all
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

fails = []


def check(label, cond, detail=""):
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


def row(driver):
    """The table row for one example, or None."""
    for ln in readme.splitlines():
        if ln.startswith("| `examples/%s`" % driver) or \
           ln.startswith("| `examples/%s`, " % driver):
            return ln
    return None


def src(driver, fname="main.mbt"):
    p = os.path.join(ROOT, "examples", driver, fname)
    return io.open(p, encoding="utf-8", errors="replace").read() if os.path.isfile(p) else ""


print("== the table's DGP and true-value claims, per driver ==")

# datasets: n
r = row("datasets")
check("datasets row says n=4000", r is not None and "n=4000" in r, r or "")
check("datasets source says `let n = 4000`", "let n = 4000" in src("datasets"))

# cvar
r = row("cvar")
check("cvar row says 1.74", r is not None and "1.74" in r, r or "")
check("cvar source asserts against 1.74", "1.74" in src("cvar"))

# splitting
r = row("splitting")
check("splitting row says 1.5", r is not None and "| 1.5 |" in r, r or "")
check("splitting DGP is y = 1.5 * d", "1.5 * d[i]" in src("splitting"))

# lplr
r = row("lplr")
check("lplr row says 0.5", r is not None and "0.5" in r, r or "")
check("lplr source has alpha = 0.5", "alpha = 0.5" in src("lplr"))

# pava
r = row("pava")
check("pava row says n/a", r is not None and "n/a" in r, r or "")

# apo / apos are now separate rows
check("apo and apos have SEPARATE rows",
      row("apo") is not None and row("apos") is not None
      and row("apo") != row("apos"))

# did_cs cohorts x periods
r = row("did_cs")
s = src("did_cs")
check("did_cs row says 4 cohorts x 4 periods",
      r is not None and "4 cohorts x 4 periods" in r, r or "")
check("did_cs source: cohort_count = 4, n_periods = 4",
      "cohort_count = 4" in s and "n_periods = 4" in s)

# main: n, p
r = row("main")
s = src("main")
check("main row says n=500, p=5", r is not None and "`n=500`, `p=5`" in r, r or "")
check("main source: n = 500, p = 5", "let n = 500" in s and "let p = 5" in s)

# did_binary / did_cross_section unit counts
check("did_binary row says 400 units", "400 units" in (row("did_binary") or ""))
check("did_binary source: n_units = 400 and 2 periods",
      "let n_units = 400" in src("did_binary")
      and "let n = n_units * 2" in src("did_binary"))
check("did_cross_section row says 500 units", "500 units" in (row("did_cross_section") or ""))
check("did_cross_section source: n=500", "let n = 500" in src("did_cross_section"))

# plpr
check("plpr row says 60 units x 4 periods",
      "60 units x 4 periods" in (row("plpr") or ""), row("plpr") or "")

print("")
print("== the prose above the table ==")
check("prose says 14 of the 16 print a true value", "**14** of the 16" in readme)
check("prose says 12 of the 16 print a 95 % CI", "**12** of the 16" in readme)
check("the old blanket claim is gone",
      "demos (print true-vs-estimated theta and a 95 % CI)" not in readme)
check("the CLI-demos heading no longer overclaims",
      "each prints true-vs-estimated theta and a 95 % CI" not in readme)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
