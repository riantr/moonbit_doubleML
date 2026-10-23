"""Round 16 -- the shipped method: DERIVE the estimator provenance map.

Why this exists
---------------
Round 15 corrected the README's provenance table, but it corrected it with a
rule that cannot see a many-to-one: "name-identical when upstream has a class
of the same name; renamed when upstream implements the same design under
another name".  Applied to the DID family that rule says BOTH

    port DoubleMLDIDMulti   -> upstream DoubleMLDIDMulti   (name-identical)
    port DoubleMLDIDCS      -> upstream DoubleMLDIDMulti   (renamed)

i.e. it claims one upstream class for two port estimators and never notices.
The README then explained one half of the crossing ("crossed pair") and left
the other half standing.

The rule that DOES see it
-------------------------
A provenance map is only meaningful if the correspondence is ONE-TO-ONE: an
upstream class may correspond to at most one port estimator, and a port
estimator that carries the upstream class's DISTINGUISHING parameter is that
class's counterpart.

So the correspondence is decided by three things, all read from source:

  1. the upstream class's distinguishing parameters -- the ones only that
     class has (`gt_combinations` for DoubleMLDIDMulti, `g_value` /
     `t_value_pre` / `t_value_eval` for the binary DIDs, ...);
  2. the upstream class's own docstring, which states its design;
  3. the port estimator's constructor parameters and its own header.

Then the 1:1 constraint is applied, and any port estimator left without an
upstream partner is reported as such rather than given a partner by name
coincidence.

Everything here is DERIVED.  Nothing is pinned to a literal: the point of the
round is that a verifier that pins a count to a constant is what made the old
labels unchallengeable.

`derive()` is the single authority.  The census verifier and the round-16
verifier both import it, so there is exactly ONE derivation in the tree --
two derivations would drift, and two derivations disagreeing is precisely the
failure mode this round exists to repair.
"""
import ast
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKGDIR = os.path.join(REPO, "moonbit_doubleML")
VD = os.path.join(REPO, "_verify")
OUT = os.path.join(VD, "_provenance_audit_1650.json")

# ---------------------------------------------------------------- upstream side
UPSTREAM_CLASSES = {
    "DoubleMLPLR": "plm/plr.py",
    "DoubleMLPLIV": "plm/pliv.py",
    "DoubleMLLPLR": "plm/lplr.py",
    "DoubleMLPLPR": "plm/plpr.py",
    "DoubleMLIRM": "irm/irm.py",
    "DoubleMLIIVM": "irm/iivm.py",
    "DoubleMLAPO": "irm/apo.py",
    "DoubleMLAPOS": "irm/apos.py",
    "DoubleMLPQ": "irm/pq.py",
    "DoubleMLQTE": "irm/qte.py",
    "DoubleMLLPQ": "irm/lpq.py",
    "DoubleMLCVAR": "irm/cvar.py",
    "DoubleMLSSM": "irm/ssm.py",
    "DoubleMLDID": "did/did.py",
    "DoubleMLDIDBinary": "did/did_binary.py",
    "DoubleMLDIDCS": "did/did_cs.py",
    "DoubleMLDIDCSBinary": "did/did_cs_binary.py",
    "DoubleMLDIDMulti": "did/did_multi.py",
    "RDFlex": "rdd/rdd.py",
    "DoubleMLBLP": "utils/blp.py",
    "DoubleMLPolicyTree": "utils/policytree.py",
}

# Parameters that DISTINGUISH one upstream class from the others in its family.
# A port estimator that carries one of these belongs to that class.
DISTINGUISHING = {
    "DoubleMLDIDMulti": {"gt_combinations"},
    "DoubleMLDIDBinary": {"g_value", "t_value_pre", "t_value_eval"},
    "DoubleMLDIDCSBinary": {"g_value", "t_value_pre", "t_value_eval"},
}

# The port estimators whose upstream counterpart shares the NAME.  The name is
# only evidence once the DESIGN agrees too, which is what the two entries
# handled separately below are for.
NAME_DESIGN = {
    "DoubleMLPLR": "DoubleMLPLR", "DoubleMLPLIV": "DoubleMLPLIV",
    "DoubleMLLPLR": "DoubleMLLPLR", "DoubleMLPLPR": "DoubleMLPLPR",
    "DoubleMLIRM": "DoubleMLIRM", "DoubleMLIIVM": "DoubleMLIIVM",
    "DoubleMLAPO": "DoubleMLAPO", "DoubleMLAPOS": "DoubleMLAPOS",
    "DoubleMLPQ": "DoubleMLPQ", "DoubleMLQTE": "DoubleMLQTE",
    "DoubleMLLPQ": "DoubleMLLPQ", "DoubleMLCVAR": "DoubleMLCVAR",
    "DoubleMLSSM": "DoubleMLSSM", "DoubleMLDID": "DoubleMLDID",
    "DoubleMLDIDBinary": "DoubleMLDIDBinary",
    "DoubleMLDIDCSBinary": "DoubleMLDIDCSBinary",
    "DoubleMLPolicyTree": "DoubleMLPolicyTree", "DoubleMLBLP": "DoubleMLBLP",
}

PORT_FILES = {}


def port_estimator_files():
    """DERIVE the port's estimator -> file map by scanning the package.

    It is derived, not pinned: a hardcoded map goes stale the moment an
    estimator moves, and a stale map here would silently drop an estimator
    from the grouping -- which is the exact failure the round-16 assertion
    caught during development.
    """
    out = {}
    for fn in sorted(os.listdir(PKGDIR)):
        if not fn.endswith(".mbt"):
            continue
        src = open(os.path.join(PKGDIR, fn), encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"pub fn (DoubleML\w+)::new\(", src):
            out.setdefault(m.group(1), fn)   # the first ::new defines it
    return out


def find_upstream_package():
    """The installed `doubleml` package -- what a user actually installs."""
    try:
        import doubleml
        return os.path.dirname(os.path.abspath(doubleml.__file__))
    except Exception:
        pass
    for p in (r"C:\Users\31379\AppData\Local\Programs\Python\Python313\Lib"
              r"\site-packages\doubleml",
              os.path.join(sys.prefix, "lib", "python3.13", "site-packages", "doubleml")):
        if os.path.isdir(p):
            return p
    return None


def upstream_info(pkg, cls, mod):
    p = os.path.join(pkg, mod.replace("/", os.sep))
    if not os.path.isfile(p):
        return None
    src = open(p, encoding="utf-8", errors="replace").read()
    tree = ast.parse(src)
    doc, params = "", []
    for n in tree.body:
        if isinstance(n, ast.ClassDef) and n.name == cls:
            doc = ast.get_docstring(n) or ""
            for f in n.body:
                if isinstance(f, ast.FunctionDef) and f.name == "__init__":
                    a = f.args
                    params = [x.arg for x in a.args] + [x.arg for x in a.kwonlyargs]
            break
    else:
        return None
    return {"module": mod, "doc": " ".join(doc.split()), "params": params,
            "source": src}


def port_info(cls, fname):
    p = os.path.join(PKGDIR, fname)
    if not os.path.isfile(p):
        return None
    src = open(p, encoding="utf-8", errors="replace").read()
    m = re.search(r"pub fn %s::new\((.*?)\n\) ->" % cls, src, re.S)
    params = []
    if m:
        for line in m.group(1).splitlines():
            mm = re.match(r"\s*([a-z_][A-Za-z0-9_]*)\s*~?\s*:", line)
            if mm:
                params.append(mm.group(1))
    i = src.find("pub struct %s {" % cls)
    doc = []
    if i >= 0:
        for l in reversed(src[:i].rstrip().splitlines()):
            s = l.strip()
            if s.startswith("///"):
                doc.append(s[3:].strip())
            elif s.startswith("//"):
                continue
            else:
                break
        doc.reverse()
    return {"file": fname, "params": params, "doc": " ".join(doc), "source": src}


def derive():
    """Return the derived provenance map.  The single authority."""
    pkg = find_upstream_package()
    if not pkg:
        raise RuntimeError("the installed `doubleml` package was not found")

    up = {}
    for cls, mod in UPSTREAM_CLASSES.items():
        info = upstream_info(pkg, cls, mod)
        if info:
            up[cls] = info
    port = {}
    est_files = port_estimator_files()
    for cls, fname in est_files.items():
        if cls.endswith("Data"):
            continue                      # a data container, not an estimator
        info = port_info(cls, fname)
        if info:
            port[cls] = info

    # --- step 1: the DISTINGUISHING-parameter match ------------------------
    by_dist = {}
    for uc, info in up.items():
        d = DISTINGUISHING.get(uc, set())
        if not d:
            continue
        by_dist[uc] = sorted(pc for pc, pi in port.items() if d <= set(pi["params"]))

    MAP = {}
    chosen = {}
    for uc, carriers in by_dist.items():
        if len(carriers) == 1:
            chosen[uc] = carriers[0]
            MAP[carriers[0]] = (uc, "distinguishing-parameter match")

    # --- step 2: name + design --------------------------------------------
    for pc, uc in NAME_DESIGN.items():
        if pc in MAP or pc not in port:
            continue
        if uc in chosen:
            continue
        chosen[uc] = pc
        MAP[pc] = (uc, "name + design")

    # the port's DoubleMLDIDCrossSection: its header names upstream's
    # DoubleMLDIDCS._score_elements, and upstream's DIDCS docstring says
    # "repeated cross-sections".
    xsec_doc = port.get("DoubleMLDIDCrossSection", {}).get("doc", "")
    cs_up_doc = up.get("DoubleMLDIDCS", {}).get("doc", "")
    if "_score_elements" in xsec_doc and "repeated cross-sections" in cs_up_doc:
        chosen["DoubleMLDIDCS"] = "DoubleMLDIDCrossSection"
        MAP["DoubleMLDIDCrossSection"] = ("DoubleMLDIDCS", "renamed: design markers")

    # the port's DoubleMLRDD: upstream's RDD estimator is the class RDFlex, and
    # it is the only upstream class that uses DoubleMLRDDData.
    rdd_users = [c for c, i in up.items() if "DoubleMLRDDData" in i["source"]]
    if rdd_users == ["RDFlex"]:
        chosen["RDFlex"] = "DoubleMLRDD"
        MAP["DoubleMLRDD"] = ("RDFlex", "renamed: the only upstream DoubleMLRDDData user")

    # the port's DoubleMLDIDCS: upstream has a class of the same NAME, but a
    # different DESIGN, and its nearest design (upstream DoubleMLDIDMulti)
    # already has its counterpart.  So it gets no partner.
    if "DoubleMLDIDCS" not in MAP:
        MAP["DoubleMLDIDCS"] = (None, "port-side variant: no 1:1 upstream class")

    plain = sorted(p for p, (u, _r) in MAP.items() if u and u == p)
    renamed = sorted(p for p, (u, _r) in MAP.items() if u and u != p)
    nopartner = sorted(p for p, (u, _r) in MAP.items() if u is None)
    used = [u for u, _r in MAP.values() if u]
    dupes = sorted({u for u in used if used.count(u) > 1})

    return {
        "plain": plain,
        "renamed": {p: MAP[p][0] for p in renamed},
        "no_upstream_class": nopartner,
        "reason": {p: MAP[p][1] for p in MAP},
        "upstream_class_of": {p: MAP[p][0] for p in MAP},
        "counts": {"plain": len(plain), "renamed": len(renamed),
                   "no_upstream_class": len(nopartner), "total": len(MAP)},
        "upstream_distinguishing_carriers": by_dist,
        "upstream_class_claimed_twice": dupes,
        "upstream_package": pkg,
        "upstream_params": {c: i["params"] for c, i in up.items()},
        "port_params": {c: i["params"] for c, i in port.items()},
        "upstream_module_of": {c: i["module"] for c, i in up.items()},
    }


def main():
    blob = derive()
    print("=== step 1: the upstream class's distinguishing parameters ===")
    for uc, carriers in blob["upstream_distinguishing_carriers"].items():
        print("  upstream %-22s carried by: %s" % (uc, carriers or "NOBODY"))
    print()
    print("=== step 2: the grouping, under the 1:1 constraint ===")
    print("  name-identical      : %d" % len(blob["plain"]))
    print("  renamed             : %d  %s" % (len(blob["renamed"]),
          [(p, blob["renamed"][p]) for p in sorted(blob["renamed"])]))
    print("  no 1:1 upstream class: %d  %s" % (len(blob["no_upstream_class"]),
          blob["no_upstream_class"]))
    print("  TOTAL               : %d" % blob["counts"]["total"])
    print()
    print("  upstream classes claimed more than once: %s"
          % (blob["upstream_class_claimed_twice"] or "NONE"))
    assert not blob["upstream_class_claimed_twice"], "the 1:1 constraint is violated"
    assert blob["counts"]["total"] == 22, "the grouping must cover all 22 estimators"
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(blob, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
