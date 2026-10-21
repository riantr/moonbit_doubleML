#!/usr/bin/env python3
"""Round 26 verifier: the upstream-provenance GROUPING, derived from source.

WHY THIS EXISTS
===============
Rounds 21-25 audited the README's numbers, its test-verification claims, its
shape, its count referents and its names.  This one audits a claim the README
makes *about upstream*, which no number check can reach: which of the port's
22 estimators correspond to an upstream class, and which do not.

Round 26 read the whole README end to end and then asked the repository's own
authority -- `_verify/UPSTREAM_PROVENANCE.md`, re-audited 2026-10-20 against
the v0.164.10 tree -- what the grouping is.  The published README already said
it correctly (19 name-identical + 2 renamed + 1 with no 1:1 upstream class).
Three OTHER tracked documents did not:

  * `doc/001_introduction/readme.mbt.md` named `DoubleMLDIDCrossSection` as
    "the one port-only estimator".  It is not: it is upstream's
    `DoubleMLDIDCS` under another name.  The port-only one is `DoubleMLDIDCS`.
  * `doc/004_estimators/readme.mbt.md` stated the same wrong grouping (20
    name-matched, one renamed, one port-only) and described the port's
    `DoubleMLDIDCS` as "DID with repeated cross-sections" -- which is
    UPSTREAM's `DoubleMLDIDCS`, the estimator the port calls
    `DoubleMLDIDCrossSection`.  The port's `DoubleMLDIDCS` is the
    multi-period CS-DID grid.
  * `skills/moonbit_doubleML.md` said "20 mirror upstream by name" and that
    `DoubleMLDIDCrossSection` "has no upstream counterpart (port-only)".

All three predate `_verify/UPSTREAM_PROVENANCE.md`, which was first tracked
in v0.164.11 -- so they were never reconciled with it.

THE DERIVATION -- no list of names is hard-coded
================================================
  1  the upstream estimator classes are read from the INSTALLED `doubleml`
     package (one estimator class per upstream estimator module);
  2  the port's estimators are read from the library source (a `DoubleML*`
     struct with a public `::new`, less the `*Data` containers);
  3  a shared NAME is a genuine pairing only if the two sides implement the
     same DESIGN.  The design is read from each side's own data container:
     a container with a per-unit `id` is MULTI-PERIOD, one without is
     CROSS-SECTION;
  4  upstream's `DoubleMLDIDCS` consumes the id-less `DoubleMLDIDData` --
     the repeated-cross-sections design -- while the port's `DoubleMLDIDCS`
     consumes `DoubleMLDIDCSData`, which carries a per-unit `id` and a group
     `g`.  So the shared NAME `DoubleMLDIDCS` is a COINCIDENCE, not a
     pairing;
  5  upstream's id-less `DoubleMLDIDCS` therefore pairs with the port's only
     unmatched CROSS-SECTION estimator, `DoubleMLDIDCrossSection`; upstream's
     `RDFlex` pairs with the port's `DoubleMLRDD` by elimination; and the
     port's `DoubleMLDIDCS` is left with no 1:1 upstream class.

WHAT IS CHECKED
===============
  A  the derivation itself holds against the installed upstream package and
     the port's own source
  B  every tracked document that states the grouping states THIS one
  C  the withdrawn forms are gone -- scoped to the file they were corrected
     in, because a correction entry legitimately QUOTES the withdrawn
     wording
  D  the DID-family descriptions agree across documents, scoped to the
     table row that carries them

Run: python _verify/_verify_provenance_grouping_1650.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-62s %s" % (label, detail))
    else:
        FAILS.append(label)
        print("  *** FAIL ***  %-56s %s" % (label, detail))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def clip(s, n=52):
    """Shorten a phrase for a label, WITHOUT cutting a word in half.

    A label that ends mid-word is a typo in the captured log, and the
    pinned `typos` gate reads the captured log.
    """
    if len(s) <= n:
        return s
    cut = s[:n]
    sp = cut.rfind(" ")
    return (cut[:sp] if sp > 0 else cut).rstrip()


def flat(p):
    """Read a document with its line wrapping and blockquote markers collapsed."""
    body = "\n".join(re.sub(r"^\s*>\s?", "", ln)
                     for ln in read(p).split("\n"))
    return re.sub(r"\s+", " ", body).strip()


# ---------------------------------------------------------------------------
# 1. the upstream estimator classes, from the INSTALLED package
# ---------------------------------------------------------------------------
print("== 1. upstream estimator classes, from the installed package ==")

try:
    import inspect
    import doubleml
    UP = os.path.dirname(inspect.getfile(doubleml))
except Exception as exc:                      # pragma: no cover
    print("  *** FAIL ***  the installed `doubleml` package is not importable: %s" % exc)
    print()
    print("checks: 1, failed: 1")
    print("VERDICT: FAIL")
    sys.exit(1)

UP_MODULES = [
    "plm/plr.py", "plm/pliv.py", "plm/lplr.py", "plm/plpr.py",
    "irm/irm.py", "irm/iivm.py", "irm/apo.py", "irm/apos.py",
    "irm/pq.py", "irm/qte.py", "irm/lpq.py", "irm/cvar.py", "irm/ssm.py",
    "did/did.py", "did/did_binary.py", "did/did_cs.py",
    "did/did_cs_binary.py", "did/did_multi.py",
    "rdd/rdd.py", "utils/blp.py", "utils/policytree.py",
]

UP_CLASS = {}          # class -> module
UP_SRC = {}            # module -> source text
for rel in UP_MODULES:
    p = os.path.join(UP, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    txt = read(p)
    UP_SRC[rel] = txt
    found = re.findall(r"^class (\w+)\b", txt, re.M)
    if found:
        UP_CLASS[found[0]] = rel

print("  upstream estimator modules found: %d of %d" % (len(UP_SRC), len(UP_MODULES)))
print("  upstream estimator classes: %d" % len(UP_CLASS))

# the upstream data classes, and whether they carry a per-unit id
UP_DATA_SRC = {}
data_dir = os.path.join(UP, "data")
if os.path.isdir(data_dir):
    for fn in sorted(os.listdir(data_dir)):
        if fn.endswith(".py"):
            UP_DATA_SRC[fn] = read(os.path.join(data_dir, fn))


def upstream_data_init(dc):
    for txt in UP_DATA_SRC.values():
        m = re.search(r"class %s\b.*?def __init__\((.*?)\):" % re.escape(dc),
                      txt, re.S)
        if m:
            return m.group(1)
    return ""


def upstream_data_class(cls):
    """The data class the upstream estimator consumes, or None."""
    mod = UP_SRC.get(UP_CLASS.get(cls, ""), "")
    names = sorted({n for n in re.findall(r"\b(DoubleML\w*Data)\b", mod)
                    if n != "DoubleMLData"})
    return names[0] if names else None


def upstream_kind(cls):
    """CROSS-SECTION / MULTI-PERIOD / None, from the consumed data class."""
    dc = upstream_data_class(cls)
    if dc is None:
        return None
    if dc not in ("DoubleMLDIDData", "DoubleMLPanelData"):
        return None
    return "MULTI-PERIOD" if "id_col" in upstream_data_init(dc) else "CROSS-SECTION"


# ---------------------------------------------------------------------------
# 2. the port's estimators, from the library source
# ---------------------------------------------------------------------------
print()
print("== 2. the port's estimators, from the library source ==")

est_file = {}
for name in sorted(os.listdir(LIB)):
    if not name.endswith(".mbt"):
        continue
    src = read(os.path.join(LIB, name))
    for m in re.finditer(r"pub fn (DoubleML\w+)::new\(", src):
        est_file.setdefault(m.group(1), name)

PORT = sorted(s for s in est_file if not s.endswith("Data"))
print("  port estimators: %d (in %d source files)"
      % (len(PORT), len(set(est_file[s] for s in PORT))))


def port_struct_body(est):
    src = read(os.path.join(LIB, est_file[est]))
    m = re.search(r"pub struct %s \{(.*?)\n\}" % re.escape(est), src, re.S)
    return m.group(1) if m else ""


def port_container(est):
    """The data container the estimator consumes, or None."""
    types = re.findall(r":\s*(DoubleML\w*Data)\b", port_struct_body(est))
    return types[0] if types else None


PORT_CONTAINER_SRC = {}
for _est, _file in est_file.items():
    _c = port_container(_est)
    if _c and _c not in PORT_CONTAINER_SRC:
        PORT_CONTAINER_SRC[_c] = read(os.path.join(LIB, _file))


def port_kind(est):
    """CROSS-SECTION / MULTI-PERIOD / None, from the consumed container."""
    dc = port_container(est)
    if dc is None:
        return None
    src = PORT_CONTAINER_SRC.get(dc, "")
    m = re.search(r"pub struct %s \{(.*?)\n\}" % re.escape(dc), src, re.S)
    body = m.group(1) if m else ""
    fields = set(re.findall(r"^\s+(\w+)\s*:", body, re.M))
    if not fields:
        return None
    return "MULTI-PERIOD" if "id" in fields else "CROSS-SECTION"


# ---------------------------------------------------------------------------
# 3. the grouping, derived
# ---------------------------------------------------------------------------
print()
print("== 3. the grouping, derived ==")

UP_CLASSES = set(UP_CLASS)
PORT_SET = set(PORT)

shared = sorted(UP_CLASSES & PORT_SET)
print("  names shared by an upstream class and a port estimator: %d %s"
      % (len(shared), shared))

# a shared name is a coincidence when the two sides implement different designs
COINCIDENCE = []
for name in shared:
    uk, pk = upstream_kind(name), port_kind(name)
    if uk and pk and uk != pk:
        COINCIDENCE.append(name)
        print("  coincidence: %s -- upstream %s vs the port's %s"
              % (name, uk, pk))

NAME_IDENTICAL = [n for n in shared if n not in COINCIDENCE]
N = len(NAME_IDENTICAL)

UP_UNCLAIMED = sorted(UP_CLASSES - set(NAME_IDENTICAL))
PORT_UNCLAIMED = sorted(PORT_SET - set(NAME_IDENTICAL))
print("  name-identical            : %d %s" % (N, NAME_IDENTICAL))
print("  upstream classes unclaimed: %d %s" % (len(UP_UNCLAIMED), UP_UNCLAIMED))
print("  port estimators unmatched : %d %s" % (len(PORT_UNCLAIMED), PORT_UNCLAIMED))

# Pair each unclaimed upstream class with a port estimator.  Two rules, in
# order: the DESIGN first (inside the DID family, where CROSS-SECTION and
# MULTI-PERIOD are the two designs that share a name), then the SOURCE FILE
# (upstream's `rdd/rdd.py` pairs with the port's `rdd.mbt`).
#
# The design rule is scoped to the DID family on purpose: an RDD estimator's
# container has no per-unit id either, so "CROSS-SECTION" would otherwise
# match an estimator that has nothing to do with the DID family.
RENAMED = []
used = set()
for u in sorted(UP_UNCLAIMED):
    if not UP_CLASS[u].startswith("did/"):
        continue
    uk = upstream_kind(u)
    cands = [p for p in PORT_UNCLAIMED
             if p not in used
             and est_file[p].startswith("did")
             and port_kind(p) == uk]
    if len(cands) == 1:
        RENAMED.append((u, cands[0]))
        used.add(cands[0])
for u in sorted(UP_UNCLAIMED):
    if u in [a for a, _b in RENAMED]:
        continue
    stem = os.path.basename(UP_CLASS[u])[:-3]
    cands = [p for p in PORT_UNCLAIMED
             if p not in used and est_file[p].startswith(stem)]
    if len(cands) == 1:
        RENAMED.append((u, cands[0]))
        used.add(cands[0])

PORT_ONLY = [p for p in PORT_UNCLAIMED if p not in used]
RENAMED_N = len(RENAMED)
PORT_ONLY_N = len(PORT_ONLY)

print("  derived renamed pairs     : %s" % RENAMED)
print("  derived port-only         : %s" % PORT_ONLY)

# the DID facts, read from source
up_cs_init = re.search(r"def __init__\((.*?)\):", UP_SRC.get("did/did_cs.py", ""), re.S)
up_multi_init = re.search(r"def __init__\((.*?)\):", UP_SRC.get("did/did_multi.py", ""), re.S)
port_cs_src = read(os.path.join(LIB, "did_cs.mbt"))
port_xsec_src = read(os.path.join(LIB, "did_cross_section.mbt"))
port_multi_src = read(os.path.join(LIB, "did_multi.mbt"))

FACT_UP_CS_NO_PANEL = (up_cs_init is not None
                       and "control_group" not in up_cs_init.group(1)
                       and "anticipation_periods" not in up_cs_init.group(1))
FACT_UP_MULTI_HAS_PANEL = (up_multi_init is not None
                            and "gt_combinations" in up_multi_init.group(1))
FACT_PORT_CS_ID_G = ("id : Array[Int32]" in port_cs_src
                     and "g : Array[Int32]" in port_cs_src)
FACT_PORT_XSEC_NO_ID_G = ("id : Array[Int32]" not in port_xsec_src
                          and "g : Array[Int32]" not in port_xsec_src)
FACT_PORT_MULTI_HAS_GT = "gt_combinations" in port_multi_src
FACT_PORT_CS_NO_GT = "gt_combinations" not in port_cs_src

print("  upstream DIDCS has no DID-control parameters      : %s" % FACT_UP_CS_NO_PANEL)
print("  upstream DIDMulti carries gt_combinations         : %s" % FACT_UP_MULTI_HAS_PANEL)
print("  the port's DIDCSData carries id AND g             : %s" % FACT_PORT_CS_ID_G)
print("  the port's DIDCrossSectionData carries neither    : %s" % FACT_PORT_XSEC_NO_ID_G)
print("  the port's DIDMulti carries gt_combinations        : %s" % FACT_PORT_MULTI_HAS_GT)
print("  the port's DIDCS does not                          : %s" % FACT_PORT_CS_NO_GT)

# ---------------------------------------------------------------------------
# 4. the derivation holds
# ---------------------------------------------------------------------------
print()
print("== 4. the derivation holds against the source ==")

check("the installed upstream package yields 21 estimator classes",
      len(UP_CLASSES) == 21, "got %d" % len(UP_CLASSES))
check("the port yields 22 estimators", len(PORT) == 22, "got %d" % len(PORT))
check("upstream's DIDCS consumes the id-less DoubleMLDIDData",
      upstream_data_class("DoubleMLDIDCS") == "DoubleMLDIDData",
      "got %s" % upstream_data_class("DoubleMLDIDCS"))
check("upstream's DIDMulti consumes the id-bearing DoubleMLPanelData",
      upstream_data_class("DoubleMLDIDMulti") == "DoubleMLPanelData",
      "got %s" % upstream_data_class("DoubleMLDIDMulti"))
check("upstream's DIDCS has no DID-control parameters", FACT_UP_CS_NO_PANEL)
check("upstream's DIDMulti carries gt_combinations", FACT_UP_MULTI_HAS_PANEL)
check("the port's DIDCSData carries a per-unit id and a group", FACT_PORT_CS_ID_G)
check("the port's DIDCrossSectionData carries neither id nor group",
      FACT_PORT_XSEC_NO_ID_G)
check("the port's DIDMulti carries gt_combinations", FACT_PORT_MULTI_HAS_GT)
check("the port's DIDCS does not carry gt_combinations", FACT_PORT_CS_NO_GT)
check("exactly one shared name is a coincidence", len(COINCIDENCE) == 1,
      "got %s" % COINCIDENCE)
check("that coincidence is the name DoubleMLDIDCS",
      COINCIDENCE == ["DoubleMLDIDCS"], "got %s" % COINCIDENCE)
check("upstream's DIDCS pairs with the port's DIDCrossSection",
      ("DoubleMLDIDCS", "DoubleMLDIDCrossSection") in RENAMED,
      "renamed=%s" % RENAMED)
check("upstream's RDFlex pairs with the port's DoubleMLRDD",
      ("RDFlex", "DoubleMLRDD") in RENAMED, "renamed=%s" % RENAMED)
check("exactly 19 estimators are name-identical", N == 19, "got %d" % N)
check("exactly 2 are upstream's under another name", RENAMED_N == 2,
      "got %d" % RENAMED_N)
check("exactly 1 has no 1:1 upstream class", PORT_ONLY_N == 1,
      "got %d" % PORT_ONLY_N)
check("the port-only estimator is DoubleMLDIDCS",
      PORT_ONLY == ["DoubleMLDIDCS"], "got %s" % PORT_ONLY)

# ---------------------------------------------------------------------------
# 5. every document that states the grouping states THIS one
# ---------------------------------------------------------------------------
print()
print("== 5. every document that states the grouping states THIS one ==")

WRONG_N = N + 1          # the withdrawn grouping: only ONE renamed estimator

DOCS = [
    ("README.mbt.md", [
        ["**%d** match a class of the same name in upstream" % N,
         "**%d** are marked *(upstream)*" % N,
         "Upstream's %d name-matched estimator" % N,
         "`DoubleMLDIDCrossSection` is upstream's `DoubleMLDIDCS`",
         "`DoubleMLDIDCS`; and **1**, `DoubleMLDIDCS`, has **no 1:1 upstream class**"],
        ["**%d** match a class of the same name in upstream" % WRONG_N,
         "**%d** are marked *(upstream)*" % WRONG_N,
         "Upstream's %d name-matched estimator" % WRONG_N],
    ]),
    ("moonbit_doubleML/README.mbt.md", [
        ["**%d** match a class of the same name in upstream" % N,
         "**%d** are marked *(upstream)*" % N,
         "Upstream's %d name-matched estimator" % N,
         "`DoubleMLDIDCrossSection` is upstream's `DoubleMLDIDCS`",
         "`DoubleMLDIDCS`; and **1**, `DoubleMLDIDCS`, has **no 1:1 upstream class**"],
        ["**%d** match a class of the same name in upstream" % WRONG_N,
         "**%d** are marked *(upstream)*" % WRONG_N,
         "Upstream's %d name-matched estimator" % WRONG_N],
    ]),
    ("ENGINEERING.md", [
        ["**%d name-identical + %d renamed + 1 with no 1:1 upstream class**"
         % (N, RENAMED_N),
         "Upstream's %d name-matched estimator" % N],
        [],
    ]),
    ("doc/001_introduction/readme.mbt.md", [
        ["%d under the same name" % N,
         "`DoubleMLDIDCrossSection` for upstream's `DoubleMLDIDCS`",
         "one port-only estimator (`DoubleMLDIDCS`)"],
        ["%d under the same name" % WRONG_N,
         "plus one port-only estimator (`DoubleMLDIDCrossSection`)"],
    ]),
    ("doc/004_estimators/readme.mbt.md", [
        ["Of the 22, **%d** match a class of the same name upstream" % N,
         "`DoubleMLDIDCrossSection` is upstream's `DoubleMLDIDCS`",
         "One has no 1:1 upstream class: `DoubleMLDIDCS`"],
        ["Of the 22, **%d** match a class of the same name upstream" % WRONG_N,
         "`DoubleMLDIDCrossSection` has no upstream estimator",
         "`DoubleMLDIDCS` has no upstream estimator"],
    ]),
    ("skills/moonbit_doubleML.md", [
        ["%d mirror upstream `doubleml-for-py` by name" % N,
         "`DoubleMLDIDCrossSection` is upstream's `DoubleMLDIDCS`",
         "`DoubleMLDIDCS` is the one with no 1:1 upstream class"],
        ["%d mirror upstream `doubleml-for-py` by name" % WRONG_N,
         "`DoubleMLDIDCrossSection` has no upstream counterpart (port-only)"],
    ]),
]

for rel, (required, forbidden) in DOCS:
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(path):
        check("%s exists" % rel, False, "missing")
        continue
    body = flat(path)
    for phrase in required:
        check("%s states %r" % (rel, clip(phrase)), phrase in body)
    for phrase in forbidden:
        check("%s does not state %r" % (rel, clip(phrase)), phrase not in body)

check("the shipped README copy is byte-identical to the root README",
      read(os.path.join(ROOT, "README.mbt.md")) ==
      read(os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")))

# ---------------------------------------------------------------------------
# 6. the DID-family descriptions agree -- scoped to the row that carries them
# ---------------------------------------------------------------------------
print()
print("== 6. the DID-family descriptions agree, scoped to their table row ==")


def row_for(rel, estimator):
    """The markdown table row whose first cell names `estimator`."""
    for line in read(os.path.join(ROOT, rel.replace("/", os.sep))).split("\n"):
        if re.match(r"^\|\s*`%s`\s*\|" % re.escape(estimator), line):
            return line
    return None


for rel in ("README.mbt.md", "doc/004_estimators/readme.mbt.md"):
    row = row_for(rel, "DoubleMLDIDCS")
    check("%s has a table row for DoubleMLDIDCS" % rel, row is not None)
    if row:
        check("%s's DIDCS row describes the staggered-adoption design" % rel,
              "staggered adoption" in row, row[:90])
        check("%s's DIDCS row does not call it repeated cross-sections" % rel,
              "repeated cross-sections" not in row, row[:90])
    row = row_for(rel, "DoubleMLDIDCrossSection")
    check("%s has a table row for DoubleMLDIDCrossSection" % rel, row is not None)
    if row:
        check("%s's DIDCrossSection row names the cross-section design" % rel,
              "cross-section" in row, row[:90])

# ---------------------------------------------------------------------------
print()
print("=" * 78)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
for f in FAILS:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))
sys.exit(1 if FAILS else 0)
