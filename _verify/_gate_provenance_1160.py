"""GATE: the README's estimator-provenance labels must match the upstream sdist.

Exists because the provenance labels were wrong twice -- first marking PLPR /
LPLR / DIDCSBinary as MoonBit-only extras when all three ship upstream, then
"correcting" that to "all 22 are upstream" when 20 are name-identical,
`DoubleMLRDD` is upstream's `RDFlex`, and `DoubleMLDIDCrossSection` has no
counterpart at all.

What it checks:
  1. measure provenance from the 0.11.4 sdist: name-identical class / renamed
     / absent;
  2. parse every estimator row of the README's table and read its marker;
  3. the two sets must agree, for all 22;
  4. no text anywhere may assert a flat "all 22 ... upstream".

Control arm: a runtime-generated estimator name must be classified as ABSENT
by the sdist scan, proving that branch is reachable.

The sdist is authoritative over the installed wheel on purpose: the wheel is
0.11.3, and the README pins 0.11.4 as the version its claims are checked
against.
"""
import os, re, sys, random, tarfile
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

def find_root(start):
    """Locate the repo root from this file's own path, not a hardcoded literal.

    A hardcoded ROOT makes the gate untestable: a copy placed in a temp dir
    still reads the real README, so a positive control that mutates the copy
    proves nothing. The first version of this gate had exactly that bug, and
    the control caught it -- both mutations were reported MISSED while the
    untouched README also passed, which is the signature of a gate that never
    looked at the input at all.
    """
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "moonbit_doubleML", "moon.mod")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            sys.exit("ABORT: could not locate repo root (no moonbit_doubleML/moon.mod above)")
        d = parent


ROOT = find_root(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
DOC = os.path.join(ROOT, "doc", "004_estimators", "readme.mbt.md")
TAR = os.path.join(ROOT, "doubleml-0.11.4.tar.gz")   # or _verify/, whichever exists
if not os.path.isfile(TAR):
    TAR = os.path.join(ROOT, "_verify", "doubleml-0.11.4.tar.gz")

# ---- port's estimators ----------------------------------------------------
owners = {}
for base, dirs, files in os.walk(PKG):
    dirs[:] = [d for d in dirs if d not in ("_build", "_verify", "target", ".git")]
    for fn in files:
        if fn.endswith(".mbt") and "_test" not in fn:
            src = open(os.path.join(base, fn), encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"struct\s+(DoubleML\w+)", src):
                if not m.group(1).endswith("Data"):
                    owners[m.group(1)] = fn
est = sorted(owners)

# ---- upstream truth -------------------------------------------------------
tf = tarfile.open(TAR)
upstream = {}
for m in tf.getnames():
    if m.endswith(".py"):
        s = tf.extractfile(m).read().decode("utf-8", "replace")
        for name in re.findall(r"^class\s+(DoubleML\w+)", s, re.M):
            upstream.setdefault(name, m)
rdd_src = tf.extractfile("doubleml-0.11.4/doubleml/rdd/rdd.py").read().decode("utf-8", "replace")
rdd_classes = re.findall(r"^class\s+(\w+)", rdd_src, re.M)
RDD_UPSTREAM = "RDFlex" if "RDFlex" in rdd_classes else None

# The README now says upstream ships the Sant'Anna-Zhao DGP even though the
# estimator is not ported. That nuance is the whole reason the wording changed,
# so back it with a measurement instead of leaving it as prose: if `make_did_SZ2020`
# ever disappears upstream, the sentence becomes wrong and this gate must say so.
sz_src = None
try:
    sz_src = tf.extractfile("doubleml-0.11.4/doubleml/did/datasets/dgp_did_SZ2020.py") \
        .read().decode("utf-8", "replace")
except KeyError:
    pass
SZ_UPSTREAM = bool(sz_src and "make_did_SZ2020" in sz_src)
CS_TOKEN_HITS = 0
for m in tf.getnames():
    if m.endswith(".py"):
        try:
            CS_TOKEN_HITS += tf.extractfile(m).read().decode("utf-8", "replace") \
                .count("cross_sectional_data")
        except Exception:
            pass

# sanity: the scanner must find a known class
assert "DoubleMLPLR" in upstream, "sdist scan is broken -- cannot gate on it"

truth = {}
for n in est:
    if n in upstream:
        truth[n] = "upstream"
    elif n == "DoubleMLRDD" and RDD_UPSTREAM:
        truth[n] = "renamed"
    else:
        truth[n] = "none"

rng = random.Random(1160)
ctrl = "DoubleML" + "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ") for _ in range(9))
ctl_ok = ctrl not in upstream
print(f"control arm: `{ctrl}` -> {'absent (correct)' if ctl_ok else 'FOUND <-- BROKEN'}")
if not ctl_ok:
    sys.exit(1)

counts = {k: sum(1 for v in truth.values() if v == k) for k in ("upstream", "renamed", "none")}
print(f"measured provenance: {counts['upstream']} name-identical, "
      f"{counts['renamed']} renamed, {counts['none']} without a counterpart "
      f"(of {len(est)})")
print(f"upstream cross-sectional material: make_did_SZ2020={SZ_UPSTREAM}, "
      f"cross_sectional_data x{CS_TOKEN_HITS} "
      f"(so 'no upstream ESTIMATOR', not 'nothing upstream')")
print()

# ---- what the README claims ----------------------------------------------
# The estimator table has THREE columns (Estimator | Score | Description); an
# earlier version of this gate expected four, parsed 0/22 rows and failed
# loudly -- which is the correct behaviour for a broken parse, but useless as
# a gate. Guard against the same thing recurring: refuse to judge unless every
# estimator actually produced a row.
txt = open(README, encoding="utf-8").read()
rows = dict(re.findall(r"^\|\s*`(DoubleML\w+)`\s*\|[^|]*\|([^|]*)\|", txt, re.M))
missing_rows = [n for n in est if n not in rows]
if missing_rows:
    print(f"ABORT: only {len(rows)}/{len(est)} estimator rows parsed; "
          f"missing e.g. {missing_rows[:3]}. A broken parser must not be "
          f"reported as 'all rows agree'.")
    sys.exit(1)
print(f"table rows parsed = {len(rows)}/{len(est)}")
claimed = {}
for n in est:
    cell = rows.get(n, "")
    if "no upstream counterpart" in cell:
        claimed[n] = "none"
    elif "upstream, renamed" in cell:
        claimed[n] = "renamed"
    elif "*(upstream)" in cell:
        claimed[n] = "upstream"
    else:
        claimed[n] = "UNLABELLED"

bad = [(n, truth[n], claimed[n]) for n in est if truth[n] != claimed[n]]
if bad:
    print("\nMISMATCH (measured vs README):")
    for n, t, c in bad:
        print(f"    {n:<24} measured={t:<10} README={c}")
else:
    print("all 22 rows agree with the sdist")

# ---- flat assertions ------------------------------------------------------
# Every wording by which the docs have previously overstated this, including
# the ones this audit itself introduced and the one it never noticed:
#   "Every one of the 22 has a counterpart"  (README L1403, v0.103.0 note)
#   "All 22 have an upstream ... counterpart"(doc/004_estimators, commit
#                                                6f584cd -- disproved by 4141bab)
#   "all 22 ... upstream" / "19 upstream"
#   "no textual occurrence anywhere in the sdist" (README L1415 -- false:
#       upstream ships make_did_SZ2020, and cross_sectional_data appears 25x)
FLAT = [
    r"every one of the 22 has a counterpart",
    r"all 22 have an upstream",
    r"all 22 are marked",
    r"all 22 models in upstream",
    r"\b19 (?:upstream|models)\b",
    r"no textual occurrence anywhere",
]
flat = []
for path in (README, DOC):
    for i, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        low = line.lower()
        for pat in FLAT:
            if re.search(pat, low):
                flat.append((os.path.basename(path), i, pat, line.strip()[:100]))

if flat:
    print("\nOVERSTATED PROVENANCE ASSERTION still present:")
    for f, i, pat, l in flat:
        print(f"    {f}:{i}  /{pat}/")
        print(f"        {l}")
else:
    print("no overstated provenance assertion remains in either file")

sys.exit(0 if (not bad and not flat) else 1)