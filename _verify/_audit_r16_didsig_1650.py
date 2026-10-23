"""Round 16, part 3: which port estimator IS upstream's DoubleMLDIDMulti?

The port has SIX DID estimators; upstream has FIVE DID classes:

  upstream: DoubleMLDID, DoubleMLDIDBinary, DoubleMLDIDCS,
            DoubleMLDIDCSBinary, DoubleMLDIDMulti
  port:     DoubleMLDID, DoubleMLDIDBinary, DoubleMLDIDCS,
            DoubleMLDIDCSBinary, DoubleMLDIDMulti, DoubleMLDIDCrossSection

So exactly one port DID estimator has no 1:1 upstream partner, and the two
candidates for it are the port's DoubleMLDIDCS (cell grid, per (g,t)) and
its DoubleMLDIDMulti (gt_combinations, row-major index).  Both carry
control_group + anticipation_periods, so the signature is what decides it.

DECISION CRITERION: upstream's DoubleMLDIDMulti has ONE constructor.  A
provenance map is only meaningful if the upstream class's parameter surface
matches exactly one port estimator.  So: compare the parameter sets.
"""
import ast
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = r"C:\Users\31379\AppData\Local\Programs\Python\Python313\Lib\site-packages\doubleml"
PKGDIR = os.path.join(REPO, "moonbit_doubleML")


def up_init_params(mod, cls):
    p = os.path.join(PKG, mod.replace("/", os.sep))
    tree = ast.parse(open(p, encoding="utf-8", errors="replace").read())
    for n in tree.body:
        if isinstance(n, ast.ClassDef) and n.name == cls:
            for f in n.body:
                if isinstance(f, ast.FunctionDef) and f.name == "__init__":
                    a = f.args
                    names = [x.arg for x in a.args] + [x.arg for x in a.kwonlyargs]
                    return names
    return None


def port_new_params(cls, fname):
    p = os.path.join(PKGDIR, fname)
    src = open(p, encoding="utf-8", errors="replace").read()
    m = re.search(r"pub fn %s::new\((.*?)\n\) ->" % cls, src, re.S)
    if not m:
        return None
    body = m.group(1)
    names = []
    for line in body.splitlines():
        line = line.strip()
        mm = re.match(r"([a-z_][A-Za-z0-9_]*)\s*~?\s*:", line)
        if mm:
            names.append(mm.group(1))
    return names


def setdiff(a, b):
    return sorted(set(a) - set(b))


print("=== upstream DID constructor parameter sets ===")
UP = {
    "DoubleMLDID": "did/did.py",
    "DoubleMLDIDBinary": "did/did_binary.py",
    "DoubleMLDIDCS": "did/did_cs.py",
    "DoubleMLDIDCSBinary": "did/did_cs_binary.py",
    "DoubleMLDIDMulti": "did/did_multi.py",
}
up_sets = {}
for cls, mod in UP.items():
    ps = up_init_params(mod, cls)
    up_sets[cls] = set(ps or [])
    print("  %-22s %2d params: %s" % (cls, len(ps or []), ", ".join(ps or [])))
print()

print("=== the port's DID constructor parameter sets ===")
PORT = {
    "DoubleMLDID": "did.mbt",
    "DoubleMLDIDBinary": "did_binary.mbt",
    "DoubleMLDIDCS": "did_cs.mbt",
    "DoubleMLDIDCSBinary": "did_cs_binary.mbt",
    "DoubleMLDIDMulti": "did_multi.mbt",
    "DoubleMLDIDCrossSection": "did_cross_section.mbt",
}
port_sets = {}
for cls, fname in PORT.items():
    ps = port_new_params(cls, fname)
    port_sets[cls] = set(ps or [])
    print("  %-24s %2d params: %s" % (cls, len(ps or []), ", ".join(ps or [])))
print()

print("=== DECISION: which port estimator matches upstream DoubleMLDIDMulti? ===")
target = up_sets["DoubleMLDIDMulti"]
for cls in ("DoubleMLDIDCS", "DoubleMLDIDMulti", "DoubleMLDID", "DoubleMLDIDCrossSection"):
    p = port_sets[cls]
    only_port = setdiff(sorted(p), sorted(target))
    only_up = setdiff(sorted(target), sorted(p))
    # the characteristic upstream parameters
    char = {"gt_combinations", "control_group", "anticipation_periods"}
    has_char = sorted(char & p)
    print("  port %-24s vs upstream DoubleMLDIDMulti:" % cls)
    print("      shared              : %d" % len(p & target))
    print("      only in the port    : %s" % (only_port or "-"))
    print("      only in upstream    : %s" % (only_up or "-"))
    print("      upstream's characteristic params present: %s" % (has_char or "NONE"))
print()

print("=== upstream's own characteristic parameters on DoubleMLDIDMulti ===")
for p in ("gt_combinations", "control_group", "anticipation_periods", "n_folds",
          "n_rep", "seed", "score", "in_sample_normalization", "propensity_clip",
          "ml_g", "ml_m", "learner_g", "learner_m"):
    present = p in target
    print("  %-24s %s" % (p, "yes" if present else "no"))
print()

print("=== which upstream classes have control_group / anticipation_periods? ===")
for cls, mod in UP.items():
    ps = up_sets[cls]
    print("  %-22s control_group=%-5s anticipation_periods=%-5s gt_combinations=%s"
          % (cls, "control_group" in ps, "anticipation_periods" in ps,
             "gt_combinations" in ps))
print()

print("=== upstream DoubleMLDIDMulti's own docstring, verbatim ===")
p = os.path.join(PKG, "did", "did_multi.py")
src = open(p, encoding="utf-8", errors="replace").read()
tree = ast.parse(src)
for n in tree.body:
    if isinstance(n, ast.ClassDef) and n.name == "DoubleMLDIDMulti":
        d = ast.get_docstring(n) or ""
        print("  " + " ".join(d.split())[:520])
        # its __init__ signature, verbatim
        for f in n.body:
            if isinstance(f, ast.FunctionDef) and f.name == "__init__":
                print()
                print("  __init__ params (verbatim order):")
                print("    " + ", ".join([x.arg for x in f.args.args]
                                        + [x.arg for x in f.args.kwonlyargs]))
