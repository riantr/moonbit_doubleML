#!/usr/bin/env python3
"""Round 86 verifier: the CITATION YEAR a live document states for a DGP.

THE GAP
=======
`doc/005_dgps`'s Quick reference table names every DGP factory with
`<model>, <authors> <year>` -- "PLR, Chernozhukov et al. 2018", "PLPR,
Clarke-Polselli 2025", "LPLR, Liu-Zhang-Zhou 2020".

Upstream names each DGP MODULE with a year too: `dgp_plr_CCDDHNR2018`,
`dgp_plpr_CP2025`, `dgp_lplr_LZZ2020`.  For every DGP but one, the module's
year IS the citation year.  For LPLR it is not: upstream's own docstring
cites

    Liu, Molei, Yi Zhang, and Doudou Zhou. 2021.
    "Double/Debiased Machine Learning for Logistic Partially Linear Model."
    The Econometrics Journal 24 (3): 559-88.

so the name says 2020 and the paper is 2021.  The table copied the NAME's
year into the CITATION slot and published "Liu-Zhang-Zhou 2020", while the
README's own estimator table said 2021 -- one paper, two years, in two
documents a reader can open side by side.

Nothing held it.  The checks that read `doc/005` hold its factory SET, its
SIGNATURES and its accessor EXCEPTION; none of them reads the year.

THE RULE
========
  Y1  a live document that states a citation year for a DGP states the year
      the UPSTREAM source cites -- not the year in the factory's NAME.
  Y2  a DGP's NAME carries a year, and a reader cannot tell it from a
      citation year.  So a table row that names the DGP's year-carrying
      NAME must ALSO state the citation year somewhere outside that name.
  Y3  the two ESTIMATOR tables -- the README's and `doc/004`'s -- state the
      SAME year for the same estimator: two documents that disagree about a
      citation year are the same defect seen from two sides.

THE DERIVATION
==============
  * the upstream module for each factory comes from OUR OWN port's
    `moonbit_doubleML/dgp_*.mbt` header, which names the upstream module it
    ports;
  * the citation year is read out of that module's OWN docstring;
  * the upstream SOURCE is chosen the way the house chooses it: the pinned
    sdist, else the tree named by `DOUBLEML_UPSTREAM_TREE`, else the
    INSTALLED `doubleml` package.  With no source at all this is a reported
    SKIP, never a pass.

THE CONTROL ARM
===============
  C1  a row that states the NAME's year where the CITATION's year belongs is
      REJECTED;
  C2  the corrected row is ACCEPTED;
  C3  a row that states no year is ACCEPTED -- a document is not obliged to
      cite a year;
  C4  a row that names the DGP's year-carrying NAME and states no other year
      is REJECTED;
  C5  the same row with the citation year added is ACCEPTED.

Run: python _verify/_verify_dgp_citation_years_1680.py
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
DOC5 = os.path.join(ROOT, "doc", "005_dgps", "readme.mbt.md")
DOC4 = os.path.join(ROOT, "doc", "004_estimators", "readme.mbt.md")
README = os.path.join(ROOT, "README.mbt.md")
SHIPPED = os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")

N = 0
FAILS = []
SKIPS = []


def check(label, ok, detail=""):
    global N
    N += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "FAIL", label, detail))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))


def skip(label, detail=""):
    global N
    N += 1
    print("  %-4s %-62s SKIP" % ("SKIP", label))
    print("      %s" % detail)
    SKIPS.append("%s -- %s" % (label, detail))


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def live_documents():
    """The house's LIVE document set: the READMEs, the skill, the api
    service's own README, and every `doc/*/readme.mbt.md`."""
    out = [README, SHIPPED,
           os.path.join(ROOT, "skills", "moonbit_doubleML.md"),
           os.path.join(ROOT, "examples", "api_server", "README.md")]
    docdir = os.path.join(ROOT, "doc")
    if os.path.isdir(docdir):
        for d in sorted(os.listdir(docdir)):
            p = os.path.join(docdir, d, "readme.mbt.md")
            if os.path.isfile(p):
                out.append(p)
    return [p for p in out if os.path.isfile(p)]


# ---------------------------------------------------------------- the upstream
class Source(object):
    def __init__(self, kind, version, files):
        self.kind = kind
        self.version = version
        self.files = files          # module basename -> text


def from_sdist():
    """The pinned sdist, when this tree carries one."""
    import tarfile
    for name in sorted(os.listdir(os.path.join(ROOT, "_verify"))):
        if not (name.startswith("doubleml-") and name.endswith(".tar.gz")):
            continue
        path = os.path.join(ROOT, "_verify", name)
        try:
            with tarfile.open(path) as tf:
                files = {}
                for m in tf.getmembers():
                    if not m.isfile() or not m.name.endswith(".py"):
                        continue
                    fh = tf.extractfile(m)
                    if fh is None:
                        continue
                    files[m.name.rsplit("/", 1)[-1]] = fh.read().decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            continue
        m = re.search(r"(\d+\.\d+\.\d+)", name)
        if files:
            return Source("the pinned %s sdist" % (m.group(1) if m else "?"),
                          m.group(1) if m else "unknown", files)
    return None


def from_tree():
    """The tree the owner named, via DOUBLEML_UPSTREAM_TREE."""
    tree = os.environ.get("DOUBLEML_UPSTREAM_TREE")
    if not tree or not os.path.isdir(tree):
        return None
    pkg = os.path.join(tree, "doubleml")
    if not os.path.isdir(pkg):
        pkg = tree
    files = {}
    for root, dirs, names in os.walk(pkg):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for n in names:
            if n.endswith(".py"):
                with io.open(os.path.join(root, n), encoding="utf-8",
                             errors="replace") as fh:
                    files[n] = fh.read()
    m = re.search(r"(\d+\.\d+\.\d+)", os.path.basename(os.path.abspath(tree)))
    if files:
        return Source("the tree %s" % tree, m.group(1) if m else "unknown", files)
    return None


def from_installed():
    """The INSTALLED `doubleml` package -- what CI has."""
    try:
        import doubleml
    except Exception:  # noqa: BLE001
        return None
    base = os.path.dirname(os.path.abspath(doubleml.__file__))
    files = {}
    for root, dirs, names in os.walk(base):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for n in names:
            if n.endswith(".py"):
                with io.open(os.path.join(root, n), encoding="utf-8",
                             errors="replace") as fh:
                    files[n] = fh.read()
    version = getattr(doubleml, "__version__", "unknown")
    if files:
        return Source("the installed `doubleml` package", version, files)
    return None


# ------------------------------------------------------------------ the rules
YEAR = re.compile(r"\b((?:19|20)\d{2})\b")
YEAR_IN = re.compile(r"((?:19|20)\d{2})")
PORT_REF = re.compile(r"doubleml\.[a-z_]+\.datasets\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)")


def citation_year(module_text):
    """The year the upstream module's OWN docstring cites."""
    if not module_text:
        return None
    idx = module_text.rfind("References")
    tail = module_text[idx:idx + 900] if idx >= 0 else module_text[:2500]
    years = YEAR.findall(tail)
    if years:
        return years[0]
    m = re.search(r"\(\s*((?:19|20)\d{2})\s*\)", module_text[:2500])
    return m.group(1) if m else None


def name_form(module):
    """The year-carrying NAME of an upstream module: `LZZ2020`, `CP2025`.

    It is the module name's LAST underscore-separated segment -- the part
    after the family -- and it is the part that carries the year.  The whole
    module name is not the form: `dgp_lplr_LZZ2020` is a path, and `LZZ2020`
    is the label a reader would mistake for a year.
    """
    if not module:
        return None
    for seg in reversed(module.split("_")):
        if YEAR_IN.search(seg):
            return seg
    return None


def name_year(module):
    """The year inside the NAME: `2020` for `LZZ2020`."""
    f = name_form(module)
    if not f:
        return None
    m = YEAR_IN.search(f)
    return m.group(1) if m else None


def years_outside(row, names):
    """The 4-digit years a row states OUTSIDE the given names."""
    text = row
    for n in names:
        text = text.replace(n, " ")
    return set(YEAR.findall(text))


def table_rows(text):
    """The table rows of a markdown document: `| a | b |` lines."""
    out = []
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith("|") and s.endswith("|") and s.count("|") >= 3:
            cells = [c.strip() for c in s.strip("|").split("|")]
            out.append(cells)
    return out


def cells(row):
    return [c.strip("`").strip() for c in row]


def strip_backtick(c):
    return c.strip().strip("`").strip()


# ============================================================ the port's DGPs
print()
print("the port's DGP factories, and the upstream each one ports")
port_dgps = {}
if os.path.isdir(LIB):
    for name in sorted(os.listdir(LIB)):
        if not name.startswith("dgp_") or name.endswith("_test.mbt"):
            continue
        src = read(os.path.join(LIB, name))
        m = PORT_REF.search(src)
        if m:
            port_dgps[name] = (m.group(1), m.group(2))
print("   %d DGP source files name an upstream module" % len(port_dgps))
for name in sorted(port_dgps):
    print("      %-30s -> %s" % (name, port_dgps[name]))

src = from_sdist() or from_tree() or from_installed()
if src is None:
    print()
    print("SKIP: no upstream source is available here (no pinned sdist, no")
    print("      DOUBLEML_UPSTREAM_TREE, no installed `doubleml`).")
    print()
    print("=" * 74)
    print("%d checks, %d failed, %d skipped" % (N, len(FAILS), len(SKIPS)))
    sys.exit(0)

print("   upstream source: %s (version %s, %d python files)"
      % (src.kind, src.version, len(src.files)))

# the citation year and the name-form of every DGP we port
info = {}
for port_file, (module, factory) in sorted(port_dgps.items()):
    text = src.files.get(module + ".py")
    if text is None:
        # the module may be named differently in the source tree
        for k, v in src.files.items():
            if k.endswith(module + ".py"):
                text = v
                break
    if text is None:
        continue
    info[port_file] = {
        "module": module,
        "factory": factory,
        "cite": citation_year(text),
        "form": name_form(module),
        "nyear": name_year(module),
    }

DIVERGENT = sorted(p for p, i in info.items()
                    if i["cite"] and i["nyear"] and i["cite"] != i["nyear"])
print("   the DGPs whose NAME year differs from their CITATION year: %d"
      % len(DIVERGENT))
for p in DIVERGENT:
    print("      %-30s name %s / citation %s"
          % (p, info[p]["nyear"], info[p]["cite"]))

# =========================================================== Y1 -- doc/005's
print()
print("== Y1: doc/005's factory table states the upstream CITATION year ==")

if not os.path.isfile(DOC5):
    skip("doc/005's factory table is present", "the file is missing")
else:
    rows = table_rows(read(DOC5))
    factory_rows = []
    for r in rows:
        c = cells(r)
        if not c:
            continue
        if c[0].startswith("make_"):
            factory_rows.append((c[0], c))
    check("doc/005's factory table was found", bool(factory_rows),
          "%d factory row(s)" % len(factory_rows))
    checked = 0
    for factory, c in factory_rows:
        # the file the row names, and through it the upstream module
        port_file = None
        for cand in info:
            if cand == strip_backtick(c[-1]):
                port_file = cand
                break
        if port_file is None:
            # the row's file cell may be absent; fall back to the factory name
            for cand, i in info.items():
                if cand.replace("dgp_", "").lower() in factory.lower():
                    port_file = cand
                    break
        if port_file is None:
            skip("the row for %s names a DGP file" % factory,
                 "no port DGP file matches %r" % strip_backtick(c[-1]))
            continue
        i = info[port_file]
        stated = years_outside(c[0] + " | " + c[1], [factory, i["module"]])
        if not stated:
            continue                     # no claim: nothing to hold
        checked += 1
        if not i["cite"]:
            skip("the row for %s states a year" % factory,
                 "upstream %s cites no year to compare with" % i["module"])
            continue
        check("the row for %s states the upstream citation year" % factory,
              stated == set([i["cite"]]),
              "states %s, upstream cites %s" % (sorted(stated), i["cite"]))
    check("Y1 actually compared some rows", checked > 0,
          "%d row(s) state a year" % checked)

# ====================================================== Y2 -- the NAME is read
print()
print("== Y2: a table row that names a DGP's year-carrying NAME states the "
      "citation year too ==")

live = live_documents()
forms = []
ALL_NAMES = []
for p, i in sorted(info.items()):
    ALL_NAMES.append(i["module"])
    ALL_NAMES.append(i["factory"])
    if i["form"] and i["cite"]:
        forms.append((i["form"], i))
print("   %d DGP name-form(s) carry a year: %s"
      % (len(forms), ", ".join(sorted(f for f, _ in forms))))


def bare_forms(line, forms, all_names):
    """The (form, info) a row states as a BARE label.

    A form inside a factory or module NAME is an identifier -- the reader is
    being told which factory to call, not what year the paper is.  A form
    inside any other identifier (`pyexample_did_cs2021.py`) is the same
    thing.  So the form must STAND ALONE -- not glued to letters, digits,
    an underscore, a dot or a hyphen -- to count as a label standing on its
    own, and that is where a reader reads a YEAR.
    """
    stripped = line
    for n in all_names:
        stripped = stripped.replace(n, " ")
    out = []
    for form, i in forms:
        if not re.search(r"(?<![A-Za-z0-9_.\-])" + re.escape(form)
                         + r"(?![A-Za-z0-9_.\-])", stripped, re.I):
            continue
        if i["cite"] in years_outside(stripped, [form]):
            continue
        out.append((form, i))
    return out


flagged = 0
for path in live:
    rel = os.path.relpath(path, ROOT).replace("\\", "/")
    text = read(path)
    for r in table_rows(text):
        line = " | ".join(r)
        for form, i in bare_forms(line, forms, ALL_NAMES):
            flagged += 1
            check("%s: the row naming %s states the citation year" % (rel, form),
                  False, "the row says %r" % line.strip()[:110])
check("Y2 found no row that names a DGP's year without the citation year",
      flagged == 0, "%d flagged" % flagged)

# ================================================= Y3 -- the estimator tables
print()
print("== Y3: the two estimator tables agree about the citation year ==")


def estimator_year_rows(text):
    """{estimator: {years}} -- the union of the years an estimator's rows
    state.  An estimator appears in more than one table (the API reference
    lists it too), so the years are collected rather than overwritten."""
    out = {}
    for r in table_rows(text):
        c = cells(r)
        if not c or not c[0].startswith("DoubleML"):
            continue
        est = c[0]
        out.setdefault(est, set()).update(years_outside(" | ".join(c), [est]))
    return out


if os.path.isfile(DOC4) and os.path.isfile(README):
    r_rows = estimator_year_rows(read(README))
    d_rows = estimator_year_rows(read(DOC4))
    both = sorted(set(r_rows) & set(d_rows))
    compared = 0
    for est in both:
        if not r_rows[est] or not d_rows[est]:
            continue
        compared += 1
        check("the two tables state the same year for %s" % est,
              r_rows[est] == d_rows[est],
              "README %s vs doc/004 %s" % (sorted(r_rows[est]),
                                           sorted(d_rows[est])))
    check("Y3 actually compared some estimators", compared > 0,
          "%d estimator(s)" % compared)
else:
    skip("the two estimator tables are present", "a file is missing")

# ============================================================== the control arm
print()
print("== the control arm: the rules must reject a wrong year, and accept a "
      "right one ==")

T = info.get("dgp_lplr.mbt")
if T is None or not T["cite"]:
    skip("the control arm has a DGP to work with", "no upstream citation year")
else:
    cite, form, module = T["cite"], T["form"], T["module"]
    nyear = T["nyear"] or "0000"
    factory = "make_lplr_LZZ2020"
    wrong = "| `%s` | LPLR, Liu-Zhang-Zhou %s | `(n, alpha, seed)` | `dgp_lplr.mbt` |" % (
        factory, nyear)
    right = "| `%s` | LPLR, Liu-Zhang-Zhou %s | `(n, alpha, seed)` | `dgp_lplr.mbt` |" % (
        factory, cite)
    bare = "| `examples/lplr` | `DoubleMLLPLR` | Partially logistic regression, %s | 0.5 |" % form
    bare_ok = "| `examples/lplr` | `DoubleMLLPLR` | Partially logistic regression, %s %s | 0.5 |" % (
        form, cite)

    def y1_fails(row):
        stated = years_outside(row, [factory, module])
        return bool(stated) and stated != set([cite])

    check("C1 a row that states the NAME's year is REJECTED",
          y1_fails(wrong), "the rule must catch it")
    check("C2 the corrected row is ACCEPTED",
          not y1_fails(right), "the rule must not fire on a good row")
    check("C3 a row that states no year is ACCEPTED",
          not y1_fails("| `%s` | LPLR, Liu-Zhang-Zhou | `(n, alpha, seed)` | `dgp_lplr.mbt` |"
                       % factory),
          "a document is not obliged to cite a year")

    def y2_fails(row):
        return bool(bare_forms(row, [(form, T)], [factory, module]))

    check("C4 a row naming the DGP's year-form and no other year is REJECTED",
          y2_fails(bare), "the rule must catch it")
    check("C5 the same row with the citation year added is ACCEPTED",
          not y2_fails(bare_ok), "the rule must not fire on a good row")

print()
print("=" * 74)
print("%d checks, %d failed, %d skipped" % (N, len(FAILS), len(SKIPS)))
for f in FAILS:
    print("  FAIL %s" % f)
for s in SKIPS:
    print("  SKIP %s" % s)
if FAILS:
    sys.exit(1)
print("VERDICT: PASS")
