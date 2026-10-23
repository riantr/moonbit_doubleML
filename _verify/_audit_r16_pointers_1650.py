"""Round 16, part 2: the specific pointers and snippets UPSTREAM_PROVENANCE.md cites.

Every claim in the record that names a line number or quotes code is checked
against the INSTALLED upstream package.  The record says its source of truth is
the 0.11.4 SDIST, so the sdist is compared too -- a pointer that resolves in
one and not the other is exactly the kind of rotted pointer this round is for.
"""
import io
import os
import re
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VD = os.path.join(REPO, "_verify")
PKG = r"C:\Users\31379\AppData\Local\Programs\Python\Python313\Lib\site-packages\doubleml"
TARBALL = os.path.join(VD, "doubleml-0.11.4.tar.gz")

print("=== A. does the installed package ship a tests/ directory? ===")
tdir = os.path.join(PKG, "tests")
print("  %s exists=%s" % (tdir, os.path.isdir(tdir)))
if os.path.isdir(tdir):
    names = sorted(os.listdir(tdir))[:20]
    print("  entries:", names)
print()

# --------------------------------------------------- B. the did_cs.py pointer
print("=== B. the record's pointer: 'did/did_cs.py L16' ===")
pat = re.compile(r"^class\s+DoubleMLDIDCS\b.*$")
p = os.path.join(PKG, "did", "did_cs.py")
lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
for i, l in enumerate(lines, 1):
    if pat.match(l):
        print("  installed 0.11.3  did/did_cs.py:%d  %s" % (i, l.strip()))
        for j in range(max(0, i - 4), i):
            print("        context %d: %s" % (j + 1, lines[j].rstrip()[:96]))
        break
else:
    print("  installed 0.11.3: class DoubleMLDIDCS not found")
print()

# the same in the 0.11.4 sdist
if os.path.isfile(TARBALL):
    print("  --- the 0.11.4 sdist the record names as its source of truth ---")
    with tarfile.open(TARBALL, "r:gz") as tf:
        member = None
        for m in tf.getmembers():
            if m.name.endswith("doubleml/did/did_cs.py"):
                member = m
                break
        if member is None:
            print("  did/did_cs.py NOT in the sdist")
        else:
            src = tf.extractfile(member).read().decode("utf-8", "replace")
            for i, l in enumerate(src.splitlines(), 1):
                if pat.match(l):
                    print("  sdist 0.11.4      did/did_cs.py:%d  %s" % (i, l.strip()))
                    break
            else:
                print("  sdist: class DoubleMLDIDCS not found")
print()

# ------------------------------------------- C. the LinearScoreMixin snippet
print("=== C. the record's quoted 'double_ml_score_mixins.py' snippet ===")
sm = os.path.join(PKG, "double_ml_score_mixins.py")
if os.path.isfile(sm):
    src = open(sm, encoding="utf-8", errors="replace").read()
    for fn in ("_compute_score", "_compute_score_deriv", "_est_coef"):
        m = re.search(r"def %s\(self.*?(?=\n    def |\nclass |\Z)" % fn, src, re.S)
        if not m:
            print("  %-22s NOT FOUND" % fn)
            continue
        body = m.group(0)
        lineno = src[:m.start()].count("\n") + 1
        print("  %-22s at double_ml_score_mixins.py:%d" % (fn, lineno))
        for l in body.splitlines()[:12]:
            print("        " + l.rstrip()[:96])
    print()
    print("  class LinearScoreMixin defined here: %s" % bool(re.search(r"class LinearScoreMixin", src)))
else:
    print("  double_ml_score_mixins.py not in the installed package")
print()

# ------------------------------------------------- D. the var_did hand reference
print("=== D. the record's quoted 'did/tests/_utils_did_manual.py' snippet ===")
print("  the record quotes a function from upstream's TESTS tree.")
for cand in (os.path.join(PKG, "tests", "_utils_did_manual.py"),
             os.path.join(PKG, "did", "tests", "_utils_did_manual.py")):
    print("  %-70s exists=%s" % (cand, os.path.isfile(cand)))
local = os.path.join(VD, "_utils_did_manual.py")
if os.path.isfile(local):
    src = open(local, encoding="utf-8", errors="replace").read()
    m = re.search(r"def var_did\(.*?(?=\ndef |\Z)", src, re.S)
    print("  the record's own copy in _verify/: var_did found=%s" % bool(m))
    if m:
        print("  " + "\n  ".join(m.group(0).splitlines()[:8]))
print()

# ------------------------------------------- E. the port's DIDCS design marker
print("=== E. the port's DoubleMLDIDCS: what does it actually estimate? ===")
p = os.path.join(REPO, "moonbit_doubleML", "did_cs.mbt")
src = open(p, encoding="utf-8", errors="replace").read()
# the struct's own doc comment
m = re.search(r"((?:^///.*\n)+)^struct DoubleMLDIDCS \{", src, re.M)
if m:
    print("  struct DoubleMLDIDCS doc:")
    for l in m.group(1).splitlines()[:22]:
        print("    " + l.strip()[:110])
else:
    i = src.find("struct DoubleMLDIDCS {")
    print("  (no struct doc comment) context:")
    for l in src[max(0, i - 1200):i].splitlines()[-14:]:
        print("    " + l.strip()[:110])
print()

# does the port's DIDCS mention Callaway-Sant'Anna / cell grid / staggered?
for marker in ("Callaway", "Sant'Anna", "cell", "staggered", "multi-period",
               "multi-period", "gt_combinations"):
    hits = len(re.findall(re.escape(marker), src))
    if hits:
        print("  did_cs.mbt mentions %-14s %d times" % (marker, hits))
print()

print("=== F. the port's DoubleMLDIDMulti doc ===")
p2 = os.path.join(REPO, "moonbit_doubleML", "did_multi.mbt")
s2 = open(p2, encoding="utf-8", errors="replace").read()
i = s2.find("/// Construct a `DoubleMLDIDMulti`")
if i >= 0:
    print("  " + s2[i:i + 1400].split("pub fn")[0].rstrip()[:1400])
