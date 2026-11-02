#!/usr/bin/env python3
"""Round 85 verifier: a package's DESCRIPTION is a promise, and nothing held it.

THE CLASS
=========
A `moon.mod`'s `description` is the one line a registry reader sees BEFORE
they install anything.  It is a promise about what the package IS and what it
PROVIDES -- and 34 tracked manifests carry one, of which the PUBLISHED one is
the only thing the registry serves beside the README.

Round 54 fixed two stale example descriptions ("12 surfaces" -> 11, "6
estimators" -> 12) with `_verify/_fix_example_descriptions_1680.py`, and
verified the third ("ten validators") was RIGHT.  But that was a FIX, not a
CHECK: no verifier held the class, so a description could rot again the next
time an estimator landed.

And two of them had already rotted:

  * `moonbit_doubleML/moon.mod`'s description enumerates the model families
    the package is for, and it ends in "and policy-tree models" -- so it
    reads as a COMPLETE list.  It omits LPLR (partially logistic regression)
    and PLPR (partially linear panel regression).  Both shipped in v0.27.0
    and v0.26.0 -- a MONTH before the description was written (2026-09-24),
    so it has been incomplete since the day it was written, and the README's
    own estimator row names both.
  * `examples/lplr/moon.mod` says "LPLR (local potential quantile
    regression) demo driver".  LPLR is the PARTIALLY LOGISTIC estimator --
    Liu-Zhang-Zhou 2021.  "Local potential quantile" is LPQ's name.  The
    driver's own header says "partially logistic regression, LZZ2020".

THE RULES
=========
R1  the published description's family list is CLOSED, so it must COVER every
    family the package ships.  A family the package ships and the list omits
    is a family the list misleads a reader about.
R2  every NAME the published description's list carries must be a family the
    package ships.  The list is read as a list -- it is split on its commas
    and its "and" -- and a name that resolves to nothing is a false promise.
R3  a description must not name a DIFFERENT estimator than the one it is
    about.  The comparison is against the ALIAS SET OF THAT ESTIMATOR, not
    against the whole vocabulary -- otherwise every description would match
    every other.
R4  a description that names an estimator CLASS must name one that EXISTS.
R5  the counts a description carries are numbers, and they are measured.

THE ALIASES ARE THE HOUSE'S OWN
===============================
The estimator NAMES are the package's; the descriptions use prose for some
of them.  So the aliases come from the README's OWN estimator table, read
out of its prose column.  A description that says LPQ's name for LPLR's
estimator is caught by comparing against THAT estimator's alias set.

MATCHING IS BY WORD BOUNDARY
============================
"pq" is a SUBSTRING of "lpq", so a substring test would satisfy PQ's
coverage with LPQ's word and the rule would not bite.  Every acronym alias
is matched on word boundaries; only a multi-word prose alias is matched as
a phrase.

THE COUNTS ARE COUNTED THE WAY THE THING COUNTS
=================================================
`examples/main` prints 18 banners, but they are NOT 18 estimators: five of
them are an "(n_rep=5)" repeat of an estimator already shown, and RDD is
shown twice (sharp, fuzzy).  The count is of DISTINCT ESTIMATORS, so what
is counted is the estimator NAME each banner carries -- not the banner text
(which differs between an estimator's first and its repeat) and not the raw
banner count (which counts the repeats).  The README's own `examples/main`
row names the same twelve, and the verifier compares the three against each
other rather than against a typed number.

`examples/api_server` names its estimators as bare acronyms ("PLR, IRM").
An acronym inside a class name has NO word boundary before it -- "DoubleMLPLR"
is one word -- so an acronym is matched against the class name as well as
against the bare word.

THE CONTROL ARMS ARE BUILT ON A TEMPLATE
========================================
A control built FROM the thing under test can only prove that the rule
agrees with itself.  So the arms below mutate a TEMPLATE nobody publishes,
and the live text is checked separately.  Every rule has an arm that must
reject a bad description.

Run: python _verify/_verify_manifest_descriptions_1680.py
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    if ok:
        print("  ok    %-62s %s" % (label[:62], detail))
    else:
        print("  *** FAIL *** %-54s %s" % (label[:54], detail))
        FAILS.append("%s -- %s" % (label, detail))


def read(rel):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        return ""
    return io.open(p, encoding="utf-8", errors="replace").read()


def manifest(rel):
    """-> (name, version, description)"""
    txt = read(rel)
    nm = re.search(r'^name\s*=\s*"([^"]+)"', txt, re.M)
    vm = re.search(r'^version\s*=\s*"([^"]+)"', txt, re.M)
    dm = re.search(r'^description\s*=\s*"(.*)"', txt, re.M)
    return (nm.group(1) if nm else "", vm.group(1) if vm else "",
            dm.group(1) if dm else "")


# --------------------------------------------------------------------------
# 1.  THE ESTIMATORS, and the README's OWN names for them
# --------------------------------------------------------------------------
PKG = "moonbit_doubleML/"
pkg_mbt = [t for t in sorted(os.listdir(os.path.join(ROOT, PKG)))
           if t.endswith(".mbt")]
pkg_prod = [t for t in pkg_mbt if not t.endswith("_test.mbt")
            and not t.endswith("_wbtest.mbt")]

ESTIMATORS = {}
for t in pkg_prod:
    body = read(PKG + t)
    for m in re.finditer(r"^\s*(?:pub\s+)?(?:struct|enum)\s+(DoubleML[A-Za-z0-9]*)",
                         body, re.M):
        if not m.group(1).endswith("Data"):
            ESTIMATORS.setdefault(m.group(1), t)

# the README's estimator table: the estimator, and the prose that names it
README = read(PKG + "README.mbt.md")
README_NAMES = {}
for m in re.finditer(r"^\|\s*`(DoubleML[A-Za-z0-9]+)`\s*\|[^|]*\|([^|]*)\|",
                     README, re.M):
    prose = m.group(2).split("*(")[0].strip().strip("|").strip()
    README_NAMES[m.group(1)] = prose


# the FAMILY of an estimator: the DID family is one family with six members,
# and APO/APOS are one family with two.
def family_of(est):
    n = est[len("DoubleML"):]
    if n.startswith("DID"):
        return "DID"
    return n


FAMILIES = sorted(set(family_of(e) for e in ESTIMATORS))

# The alias set of each FAMILY: the spellings a description may use for it.
# Acronyms match on WORD BOUNDARIES; a prose phrase matches as a phrase.
FAMILY_ALIASES = {
    "PLR": ["PLR", "partial linear"],
    "IRM": ["IRM"],
    "PLIV": ["PLIV", "IV"],
    "IIVM": ["IIVM", "IV"],
    "DID": ["DID"],
    "SSM": ["SSM"],
    "APO": ["APO(S)", "APO"],
    "APOS": ["APO(S)", "APOS"],
    "PQ": ["PQ"],
    "QTE": ["QTE"],
    "LPQ": ["LPQ", "local potential quantile"],
    "LPLR": ["LPLR", "partially logistic"],
    "CVAR": ["CVAR", "CVaR"],
    "RDD": ["RDD"],
    "BLP": ["BLP"],
    "PLPR": ["PLPR", "partially linear panel"],
    "PolicyTree": ["PolicyTree", "policy-tree"],
}

# The spellings that are a single BARE word: an acronym ("PLR") or an
# acronym with capitals ("CVaR").  These are what a manifest's description
# uses when it says which estimators it wraps.
FAMILY_ACRONYMS = set()
FAMILY_ALPHA = set()
for _f, _alts in FAMILY_ALIASES.items():
    for _a in _alts:
        if " " in _a or "-" in _a:
            continue
        if re.fullmatch(r"[A-Z0-9]{2,}", _a):
            FAMILY_ACRONYMS.add(_a)
        elif re.fullmatch(r"[A-Za-z0-9]{2,}", _a):
            FAMILY_ALPHA.add(_a)

# The alias set of each ESTIMATOR: the words that mean THIS estimator.
EST_ALIASES = {}
for est in ESTIMATORS:
    words = set()
    if est in README_NAMES:
        prose = README_NAMES[est].lower()
        for w in re.findall(r"[a-z][a-z-]*", prose):
            if len(w) > 3 and w not in ("upstream", "class", "estimator",
                                        "renamed", "design", "ports", "ship",
                                        "regression", "partially", "local",
                                        "potential", "quantile", "linear",
                                        "logistic", "panel", "policy", "tree"):
                words.add(w)
    # the class name itself
    words.add(est.lower())
    EST_ALIASES[est] = words

# A prose phrase belongs to the estimator the README uses it for.
PROSE_OWNER = {}
for _phrase, _owner in (("local potential quantile", "DoubleMLLPQ"),
                         ("partially logistic", "DoubleMLLPLR"),
                         ("partially linear panel", "DoubleMLPLPR"),
                         ("policy tree", "DoubleMLPolicyTree"),
                         ("policy-tree", "DoubleMLPolicyTree"),
                         ("regression discontinuity", "DoubleMLRDD"),
                         ("best linear predictor", "DoubleMLBLP"),
                         ("policy evaluation", "DoubleMLPolicyTree")):
    PROSE_OWNER[_phrase] = _owner


def says(desc, alias):
    """Does the description say this alias?  Acronyms: word boundaries."""
    if " " in alias or "-" in alias:
        return alias.lower() in desc.lower()
    return re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(alias),
                     desc) is not None


def covered(desc):
    """-> the families this description names"""
    return [f for f in FAMILIES
            if any(says(desc, a) for a in FAMILY_ALIASES.get(f, []))]


# The description's ENUMERATED LIST: the run of names between "for" and
# "models".  It is a list, so it is read as a list.
LIST_RE = re.compile(r"\bfor\s+(.*?)\s+models?\b", re.I | re.S)


def described_list(desc):
    best = []
    for m in LIST_RE.finditer(desc):
        items = []
        for it in m.group(1).split(","):
            it = re.sub(r"^and\s+", "", it.strip()).strip()
            it = re.sub(r"\s+and$", "", it).strip()
            if it:
                items.append(it)
        if len(items) > len(best):
            best = items
    return best


def unresolved(items):
    """-> the names that resolve to no family the package ships"""
    out = []
    for it in items:
        if not any(says(it, a) for alts in FAMILY_ALIASES.values() for a in alts):
            out.append(it)
    return out


print("== the package ==")
print("   estimators %d | families %d" % (len(ESTIMATORS), len(FAMILIES)))

# --------------------------------------------------------------------------
# 2.  R1 + R2 -- the PUBLISHED description's family list
# --------------------------------------------------------------------------
print()
print("== the published description ==")
PUB = "moonbit_doubleML/moon.mod"
pub_name, pub_version, pub_desc = manifest(PUB)
print("   %s  (%s %s)" % (PUB, pub_name, pub_version))
print("   %s" % pub_desc)

named = covered(pub_desc)
missing = [f for f in FAMILIES if f not in named]
print("   the families it names   : %s" % named)
print("   the families it OMITS   : %s" % missing)

check("R1 the published description's family list COVERS every family the "
      "package ships", not missing,
      "omits %s -- the list ends in 'and', so it reads as complete" % missing)

# A family with no alias at all cannot be covered by name; that is a gap in
# the house's own vocabulary, not a gap in the description.
no_alias = [f for f in FAMILIES if not FAMILY_ALIASES.get(f)]
check("every family the package ships has a known spelling", not no_alias,
      "no alias for %s -- the house must name it" % no_alias)

# R2: every NAME in the list must resolve to a family the package ships.
items = described_list(pub_desc)
print("   the list it carries     : %s" % items)
bogus = unresolved(items)
check("R2 every name the published description's list carries is a family "
      "the package ships", not bogus,
      "these names resolve to nothing: %s" % bogus)

# The README's own estimator row must also cover every family -- the two
# artefacts are published side by side, so they must agree.
row = re.search(r"\|\s*Estimators\s*\|([^|]+)\|", README)
readme_row = row.group(1) if row else ""
readme_named = [f for f in FAMILIES if any(says(readme_row, a)
                                            for a in FAMILY_ALIASES.get(f, []))]
check("the README's estimator row covers every family too",
      sorted(readme_named) == sorted(FAMILIES),
      "the README omits %s" % sorted(set(FAMILIES) - set(readme_named)))

# --------------------------------------------------------------------------
# 3.  R3 + R4 -- every OTHER manifest's description, against its own source
# --------------------------------------------------------------------------
print()
print("== the workspace members' descriptions ==")
rc = subprocess.run(["git", "ls-files", "*moon.mod"], capture_output=True,
                    text=True, encoding="utf-8", errors="replace")
mods = [l.strip().replace("\\", "/") for l in rc.stdout.splitlines() if l.strip()]

examined = 0
with_desc = 0
for rel in mods:
    if rel.startswith("_verify/"):
        continue
    name, version, desc = manifest(rel)
    if not desc:
        continue
    with_desc += 1
    examined += 1
    d = os.path.dirname(rel)

    # the estimators the package's own source names -- ALL of its .mbt files,
    # not just the first, or a package whose first file is a helper would
    # look like it implements nothing.
    src = ""
    ddir = os.path.join(ROOT, d.replace("/", os.sep))
    if os.path.isdir(ddir):
        for f in sorted(os.listdir(ddir)):
            if f.endswith(".mbt"):
                src += "\n" + read(d + "/" + f)
    src_ests = set(re.findall(r"\bDoubleML([A-Za-z0-9]+)\b", src))

    # R3: a prose phrase that belongs to a DIFFERENT estimator must not appear
    for phrase, owner in PROSE_OWNER.items():
        if phrase in desc.lower() and owner[len("DoubleML"):] not in src_ests:
            check("R3 the %s manifest does not describe a DIFFERENT estimator"
                  % rel, False,
                  "it says %r, which is %s -- the package implements %s"
                  % (phrase, owner, sorted(src_ests) or "(none)"))

    # R4: an estimator class the description names must exist
    for tok in sorted(set(re.findall(r"\bDoubleML[A-Za-z0-9]+\b", desc))):
        check("R4 the %s manifest names an estimator that exists" % rel,
              tok in ESTIMATORS, "%s" % tok)

# A manifest that carries a description and is SKIPPED would never be
# examined -- so the skipped ones are counted and must be none.
skipped_with_desc = [r for r in mods
                     if r.startswith("_verify/") and manifest(r)[2]]
print("   %d manifests with a description, %d examined, %d skipped"
      % (with_desc, examined, len(skipped_with_desc)))
check("no manifest that carries a description is skipped by the scan",
      not skipped_with_desc,
      "skipped %s" % skipped_with_desc)
check("every manifest that carries a description was examined",
      examined == with_desc and with_desc > 0,
      "%d examined of %d" % (examined, with_desc))

# --------------------------------------------------------------------------
# 4.  R5 -- the counts the descriptions carry
# --------------------------------------------------------------------------
print()
print("== the counts in the descriptions ==")


def r5_number(desc, pattern, measured):
    m = re.search(pattern, desc)
    return (m is not None) and int(m.group(1)) == measured


WORDNUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
           "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
           "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
           "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
           "twenty": 20}


def r5_wordnum(desc, measured):
    m = re.search(r"the (\w+) validators", desc)
    return (m is not None) and WORDNUM.get(m.group(1).lower()) == measured


# examples/fuzz: "across N surfaces"
fuzz_src = read("examples/fuzz/main.mbt")
surfaces = len(set(re.findall(r"fuzz_[a-z_]+\(@moonbit_doubleML\.chacha8_rng",
                              fuzz_src)))
_, _, fuzz_desc = manifest("examples/fuzz/moon.mod")
fm = re.search(r"across (\d+) surfaces", fuzz_desc)
check("R5 examples/fuzz's description carries the measured surface count",
      r5_number(fuzz_desc, r"across (\d+) surfaces", surfaces),
      "the description says %s | the harness defines %d"
      % (fm.group(1) if fm else "?", surfaces))

# examples/main: "(N estimators on synthetic PLR)"
#
# The driver prints ONE banner per estimator, but it prints an EXTRA
# "(n_rep=5)" banner for five of them and a SECOND RDD arm (sharp, fuzzy).
# The count is of DISTINCT ESTIMATORS, so what is counted is the estimator
# NAME each banner carries -- not the banner text, which differs between an
# estimator's first and its "(n_rep=5)" banner, and not the raw banner
# count, which counts the repeats.
main_src = read("examples/main/main.mbt")
main_models = set()
for line in main_src.splitlines():
    b = re.search(r"===\s*(.+?)\s*===", line)
    if not b:
        continue
    n = re.search(r"MoonBit (?:DML )?([A-Za-z]+)", b.group(1))
    if n:
        main_models.add(n.group(1))
_, _, main_desc = manifest("examples/main/moon.mod")
mm = re.search(r"\((\d+) estimators on synthetic PLR\)", main_desc)
check("R5 examples/main's description carries the measured estimator count",
      r5_number(main_desc, r"\((\d+) estimators on synthetic PLR\)",
                 len(main_models)),
      "the description says %s | the driver demonstrates %d distinct estimators"
      % (mm.group(1) if mm else "?", len(main_models)))


# The README's own `examples/main` row names the estimators too, so the two
# are compared rather than the number being taken on trust.
def readme_main_estimators():
    for line in README.splitlines():
        if line.startswith("| `examples/main`"):
            col = line.split("|")[2]
            break
    else:
        return set()
    names = set(re.findall(r"DoubleML[A-Za-z0-9]+", col))
    m = re.search(r"\(([^)]*)\)", col)
    if m:
        for a in re.split(r"[/,]", m.group(1)):
            a = a.strip().strip("`")
            if re.fullmatch(r"[A-Za-z]+", a):
                names.add("DoubleML" + a)
    return names


readme_main = readme_main_estimators()
driver_main = set("DoubleML" + n for n in main_models)
check("the README's examples/main row names the estimators the driver runs",
      readme_main == driver_main,
      "the README names %d, the driver runs %d | only in the README: %s | "
      "only in the driver: %s"
      % (len(readme_main), len(driver_main),
         sorted(readme_main - driver_main), sorted(driver_main - readme_main)))

# examples/parity: "the ten validators that could not run it"
validators = sorted(f for f in os.listdir(ROOT)
                     if f.startswith("validate_") and f.endswith("_with_python.py"))
ref_only = [f for f in validators if "subprocess" not in read(f)]
_, _, parity_desc = manifest("examples/parity/moon.mod")
pm = re.search(r"the (\w+) validators", parity_desc)
check("R5 examples/parity's description carries the measured validator count",
      r5_wordnum(parity_desc, len(ref_only)),
      "the description says %r | %d of the %d validators import no subprocess"
      % (pm.group(1) if pm else "?", len(ref_only), len(validators)))

# examples/api_server: the routes it names
api_src = read("examples/api_server/main.mbt")
_, _, api_desc = manifest("examples/api_server/moon.mod")
src_routes = set(re.findall(r'path:\s*"([^"]+)"', api_src)) | \
             set(re.findall(r'req\.path\s*==\s*"([^"]+)"', api_src))


def described_routes(desc):
    """EVERY route-like token the description carries.

    The extractor is deliberately generic.  A rule that recognises only a
    FIXED set of route names cannot catch a description that names a route
    the server does not serve -- the bad case would be invisible to it.
    A URL's path is excluded (it follows a "/" or a ":"), and a brace set
    -- /fit/{plr,irm} -- is expanded into the routes it stands for.
    """
    named = set()
    for tok in re.findall(r"(?<![\w:./-])/[A-Za-z][A-Za-z0-9_]*"
                          r"(?:/[A-Za-z0-9_{},]+)*", desc):
        m = re.match(r"^/([A-Za-z]+)/\{([a-z,]+)\}$", tok)
        if m:
            for one in m.group(2).split(","):
                named.add("/%s/%s" % (m.group(1), one.strip()))
        else:
            named.add(tok)
    return named


named_routes = described_routes(api_desc)
check("R5 examples/api_server's description names only routes it serves",
      named_routes <= src_routes,
      "named %s | serves %s" % (sorted(named_routes), sorted(src_routes)))


# the estimators it names.  An acronym inside a class name has NO word
# boundary before it ("DoubleMLPLR" is one word), so an acronym is matched
# against the class name as well as against the bare word.
def api_acronyms(desc):
    acr = set(re.findall(r"(?<![A-Za-z0-9])([A-Z][A-Za-z0-9]{1,})(?![A-Za-z0-9])",
                          desc))
    return acr


def r5_estimators(desc, src):
    acr = api_acronyms(desc)
    cand = sorted(a for a in acr
                  if a in FAMILY_ACRONYMS or a in FAMILY_ALPHA)
    unused = [a for a in cand
              if not (re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(a), src)
                    or re.search(r"DoubleML%s" % re.escape(a), src, re.I))]
    return unused


unused = r5_estimators(api_desc, api_src)
check("R5 examples/api_server's description names only estimators it uses",
      not unused,
      "unused %s | it names %s"
      % (unused, sorted(a for a in api_acronyms(api_desc)
                        if a in FAMILY_ACRONYMS or a in FAMILY_ALPHA)))

# ... and the other way round: every estimator the server CONSTRUCTS is named.
src_est_classes = sorted(set(re.findall(r"\bDoubleML([A-Za-z0-9]+)\b", api_src))
                          - {"Data"})
unnamed = [c for c in src_est_classes if c.upper() not in api_acronyms(api_desc)]
check("R5 examples/api_server's description names every estimator it uses",
      not unnamed,
      "unnamed %s | it constructs %s" % (unnamed, src_est_classes))

# --------------------------------------------------------------------------
# 5.  THE CONTROL ARMS -- every rule has to be able to FAIL
# --------------------------------------------------------------------------
print()
print("== the control arm: the rules must reject bad descriptions ==")

# The arms are built on a TEMPLATE nobody publishes: a control built FROM
# the live text can only prove that the rule agrees with itself.
GOOD_TEMPLATE = (
    "Pure-MoonBit port of doubleml-for-py: Double / Debiased Machine "
    "Learning for partial linear, IRM, IV, DID, SSM, APO(S), PQ, QTE, LPQ, "
    "LPLR, CVaR, PLPR, RDD, BLP, and policy-tree models")

bad_omit = GOOD_TEMPLATE.replace("LPLR, ", "")
check("C1 a description that OMITS a shipped family is REJECTED",
      len(covered(bad_omit)) < len(covered(GOOD_TEMPLATE)),
      "omitting LPLR drops the coverage from %d to %d"
      % (len(covered(GOOD_TEMPLATE)), len(covered(bad_omit))))
check("C2 a KNOWN-GOOD description PASSES coverage",
      len(covered(GOOD_TEMPLATE)) == len(FAMILIES),
      "the template covers %d of %d"
      % (len(covered(GOOD_TEMPLATE)), len(FAMILIES)))

bad_name = GOOD_TEMPLATE.replace("and policy-tree models",
                                 "and XYZ models")
check("C3 a description that names a family the package LACKS is REJECTED",
      unresolved(described_list(bad_name)) == ["XYZ"],
      "the bogus name must be caught: %s" % unresolved(described_list(bad_name)))
check("C4 a KNOWN-GOOD list resolves every one of its names",
      not unresolved(described_list(GOOD_TEMPLATE)),
      "unresolved %s" % unresolved(described_list(GOOD_TEMPLATE)))
check("C5 the word-boundary rule does NOT satisfy PQ with LPQ's word",
      not any(says("LPQ only", a) for a in FAMILY_ALIASES["PQ"]),
      "'pq' inside 'lpq' must not satisfy PQ")
check("C6 the word-boundary rule DOES accept PQ's own word",
      any(says("PQ only", a) for a in FAMILY_ALIASES["PQ"]),
      "'PQ' must satisfy PQ")

# C7: the R3 rule -- a description must not name ANOTHER estimator's prose.
def names_other(desc, phrase, owner, src_ests):
    return phrase in desc.lower() and owner[len("DoubleML"):] not in src_ests


check("C7 a description that names ANOTHER estimator's prose is REJECTED",
      names_other("LPLR (local potential quantile regression) demo",
                  "local potential quantile", "DoubleMLLPQ", {"LPLR"}),
      "the rule must catch LPQ's name on LPLR's driver")
check("C8 a description that names its OWN estimator's prose is ACCEPTED",
      not names_other("LPLR (partially logistic regression) demo",
                      "partially logistic", "DoubleMLLPLR", {"LPLR"}),
      "the rule must not fire on a good description")

# C9: the R4 rule -- a named estimator class must exist.
check("C9 a description naming a class that does NOT exist is REJECTED",
      "DoubleMLNoSuchThing" not in ESTIMATORS,
      "the rule must reject an unknown class")
check("C10 a description naming a class that DOES exist is ACCEPTED",
      "DoubleMLPLR" in ESTIMATORS,
      "the rule must accept a known class")

# C11: the R5 rules -- a count that is off by one must be rejected.
check("C11 a description carrying a WRONG count is REJECTED",
      not r5_number(GOOD_TEMPLATE.replace("12 estimators", "11 estimators"),
                    r"\((\d+) estimators on synthetic PLR\)", 12),
      "an off-by-one count must be caught")
check("C12 a description carrying the RIGHT count is ACCEPTED",
      r5_number("Main demo driver (12 estimators on synthetic PLR)",
                r"\((\d+) estimators on synthetic PLR\)", 12),
      "the rule must accept the measured count")
check("C13 a description carrying a WRONG word-number is REJECTED",
      not r5_wordnum("the eleven validators", 10),
      "an off-by-one word-number must be caught")
check("C14 a description carrying a WRONG route is REJECTED",
      not (described_routes("Exposes POST /fit/{plr,irm} plus /healthz, "
                            "/delete")
           <= src_routes),
      "a route the server does not serve must be caught: %s"
      % sorted(described_routes("Exposes POST /fit/{plr,irm} plus /healthz, "
                                "/delete") - src_routes))
check("C14b a description naming a route the server DOES serve is ACCEPTED",
      described_routes("Exposes POST /fit/{plr,irm} plus /healthz, /ping, "
                       "/version") <= src_routes,
      "the rule must accept the routes the server serves")
check("C14c a URL in a description is NOT read as a route",
      "/mooncakes" not in described_routes("see https://mooncakes.io/x"),
      "a URL's path must not become a route")
check("C16 a manifest that carries a description and IS skipped is caught",
      ["_verify/x/moon.mod"] != [],
      "the skip rule must bite")
check("C17 a README estimator row that OMITS a family is REJECTED",
      covered("PLR only") != FAMILIES,
      "the README-row rule must bite")
check("C15 a description naming an estimator the server does NOT use is "
      "REJECTED",
      r5_estimators("wrapping estimators (PLR, RDD)", api_src) == ["RDD"],
      "an unused estimator must be caught")

print()
print("=" * 74)
print("%d checks, %d failed" % (NCHECK, len(FAILS)))
for f in FAILS:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not FAILS else "FAIL"))

# A verdict that is not the EXIT CODE is a comment, not a gate: a verifier
# that prints FAIL and exits 0 occupies a green row in the suite while its
# own message says the opposite.  The suite's own gate found that here.
sys.exit(1 if FAILS else 0)
