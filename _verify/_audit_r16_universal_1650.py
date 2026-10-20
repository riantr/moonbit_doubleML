"""Round 16, part 4: the DECISIVE test for which port estimator mirrors
upstream's DoubleMLDIDMulti.

Evidence so far:
  * upstream's DoubleMLDIDMulti is the ONLY upstream DID class with
    `gt_combinations`;
  * the port's DoubleMLDIDMulti is the ONLY port DID estimator with
    `gt_combinations`;
  * the port's DoubleMLDIDMulti doc says: `"universal"` ... "(upstream's
    `universal` is only meaningful for repeated cross sections, which this
    port does not implement)".

That last line is a quotation of upstream's KEYWORD vocabulary.  If
"universal" is a gt_combinations keyword of upstream's DoubleMLDIDMulti, then
the port's DoubleMLDIDMulti is that class -- and the port's DoubleMLDIDCS,
which has no gt_combinations at all, is NOT it.

This script settles it, and also asks whether upstream has ANY class that
computes a cell grid without gt_combinations (i.e. whether the port's
DoubleMLDIDCS design exists upstream at all).
"""
import ast
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PKG = r"C:\Users\31379\AppData\Local\Programs\Python\Python313\Lib\site-packages\doubleml"
REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"

print("=== A. 'universal' / 'standard' / 'all' as upstream keywords ===")
for cls, mod in (("DoubleMLDIDMulti", "did/did_multi.py"),
                 ("DoubleMLDIDCS", "did/did_cs.py"),
                 ("DoubleMLDID", "did/did.py"),
                 ("DoubleMLDIDBinary", "did/did_binary.py")):
    p = os.path.join(PKG, mod.replace("/", os.sep))
    src = open(p, encoding="utf-8", errors="replace").read()
    tree = ast.parse(src)
    doc = ""
    for n in tree.body:
        if isinstance(n, ast.ClassDef) and n.name == cls:
            doc = ast.get_docstring(n) or ""
            break
    print("  %-20s doc mentions:" % cls)
    for kw in ("universal", "standard", "gt_combinations", "all"):
        print("      %-16s %s" % (kw, ("YES" if kw in doc else "no")))
print()

print("=== B. where upstream uses the 'universal' keyword, in source ===")
hits = []
for root, _d, files in os.walk(PKG):
    for f in files:
        if not f.endswith(".py"):
            continue
        p = os.path.join(root, f)
        try:
            src = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "universal" in src:
            rel = os.path.relpath(p, PKG).replace("\\", "/")
            for i, l in enumerate(src.splitlines(), 1):
                if "universal" in l:
                    hits.append((rel, i, l.strip()[:120]))
for rel, i, l in hits[:24]:
    print("  %-28s :%-4d %s" % (rel, i, l))
if not hits:
    print("  'universal' appears NOWHERE in the installed upstream package")
print()

print("=== C. upstream's gt_combinations handling in did_multi.py ===")
p = os.path.join(PKG, "did", "did_multi.py")
src = open(p, encoding="utf-8", errors="replace").read()
for i, l in enumerate(src.splitlines(), 1):
    if re.search(r"gt_combinations|universal|standard|_get_ga|panel", l):
        print("  did_multi.py:%-5d %s" % (i, l.rstrip()[:120]))
print()

print("=== D. does upstream have a cell-grid estimator without gt_combinations? ===")
print("  searching every upstream .py for a class that builds a (g, t) cell grid")
found_any = False
for root, _d, files in os.walk(PKG):
    for f in files:
        if not f.endswith(".py"):
            continue
        p = os.path.join(root, f)
        try:
            src = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for i, l in enumerate(src.splitlines(), 1):
            if re.search(r"def _get_(gt|grid|cells|combinations)", l):
                print("  %-30s :%-5d %s"
                      % (os.path.relpath(p, PKG).replace("\\", "/"), i, l.strip()[:110]))
                found_any = True
if not found_any:
    print("  (no _get_gt / _get_grid / _get_cells helper in upstream)")
print()

print("=== E. the port's DoubleMLDIDCS: does it accept gt_combinations at all? ===")
psrc = open(os.path.join(REPO, "moonbit_doubleML", "did_cs.mbt"),
            encoding="utf-8", errors="replace").read()
m = re.search(r"pub fn DoubleMLDIDCS::new\((.*?)\n\) ->", psrc, re.S)
params = [x for x in re.findall(r"([a-z_][A-Za-z0-9_]*)\s*~?\s*:", m.group(1))]
print("  DoubleMLDIDCS params:", params)
print("  has gt_combinations :", "gt_combinations" in params)
msrc = open(os.path.join(REPO, "moonbit_doubleML", "did_multi.mbt"),
            encoding="utf-8", errors="replace").read()
m2 = re.search(r"pub fn DoubleMLDIDMulti::new\((.*?)\n\) ->", msrc, re.S)
params2 = [x for x in re.findall(r"([a-z_][A-Za-z0-9_]*)\s*~?\s*:", m2.group(1))]
print("  DoubleMLDIDMulti params:", params2)
print("  has gt_combinations :", "gt_combinations" in params2)
