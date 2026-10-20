"""Round 16, part 5: which upstream source does EACH port DID estimator cite?

The port's own comments are the authority on what it transcribes.  For each
of the three contested estimators, list the upstream FILES its source cites
(did_cs.py, did_multi.py, did.py, ...), with line numbers.

The point: a port estimator that transcribes upstream's did_cs.py:NNN line
for line has a DIFFERENT provenance claim from one that transcribes
did_multi.py:NNN.  If BOTH cite did_cs.py, then the NAME crossing is real and
the label must say so.
"""
import os
import re
import sys
from collections import defaultdict

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
PKGDIR = os.path.join(REPO, "moonbit_doubleML")

FILES = {
    "DoubleMLDID": "did.mbt",
    "DoubleMLDIDBinary": "did_binary.mbt",
    "DoubleMLDIDCS": "did_cs.mbt",
    "DoubleMLDIDCSBinary": "did_cs_binary.mbt",
    "DoubleMLDIDMulti": "did_multi.mbt",
    "DoubleMLDIDCrossSection": "did_cross_section.mbt",
}

# an upstream citation looks like  did_cs.py:123  /  did_multi.py:45-67
CIT = re.compile(r"\b(did_cs(?:_binary)?\.py|did_multi\.py|did\.py|"
                 r"double_ml_[a-z_]+\.py|_utils_did[a-z_]*\.py|dgp_did[a-z0-9_]*\.py|"
                 r"doubleml/did/[a-z_]+\.py)\s*:\s*(\d+)(?:\s*-\s*(\d+))?")

print("=== upstream citations, per port DID estimator ===")
for cls, fname in FILES.items():
    p = os.path.join(PKGDIR, fname)
    src = open(p, encoding="utf-8", errors="replace").read()
    hits = defaultdict(list)
    for m in CIT.finditer(src):
        f = m.group(1)
        if f.startswith("doubleml/"):
            f = f.split("/")[-1]
        hits[f].append(int(m.group(2)))
    print()
    print("  %-24s (%s)" % (cls, fname))
    if not hits:
        print("      (no upstream file:line citations)")
    for f in sorted(hits, key=lambda k: -len(hits[k])):
        lines = sorted(set(hits[f]))
        shown = ", ".join(str(x) for x in lines[:12]) + (" ..." if len(lines) > 12 else "")
        print("      %-28s %2d citations  lines: %s" % (f, len(hits[f]), shown))
    # which upstream CLASS do the cited files belong to?
    print("      -> upstream class implied: %s"
          % ", ".join(sorted({"DoubleMLDIDCS" if f.startswith("did_cs.py")
                              else "DoubleMLDIDCSBinary" if f.startswith("did_cs_binary.py")
                              else "DoubleMLDIDMulti" if f.startswith("did_multi.py")
                              else "DoubleMLDID" if f.startswith("did.py")
                              else "(test util)" if f.startswith("_utils")
                              else "(dgp)" if f.startswith("dgp")
                              else f for f in hits})))
print()

print("=== does any port file cite BOTH did_cs.py and did_multi.py? ===")
for cls, fname in FILES.items():
    src = open(os.path.join(PKGDIR, fname), encoding="utf-8", errors="replace").read()
    cs = len(re.findall(r"did_cs\.py\s*:", src))
    mu = len(re.findall(r"did_multi\.py\s*:", src))
    print("  %-24s did_cs.py:%-4d did_multi.py:%-4d  %s"
          % (cls, cs, mu, "BOTH" if cs and mu else ""))
print()

print("=== the two port estimators' own one-line descriptions ===")
for cls, fname in (("DoubleMLDIDCS", "did_cs.mbt"),
                   ("DoubleMLDIDMulti", "did_multi.mbt"),
                   ("DoubleMLDIDCrossSection", "did_cross_section.mbt")):
    src = open(os.path.join(PKGDIR, fname), encoding="utf-8", errors="replace").read()
    i = src.find("pub struct %s {" % cls)
    # the doc comment immediately above
    head = src[:i].rstrip().splitlines()
    doc = []
    for l in reversed(head):
        s = l.strip()
        if s.startswith("///"):
            doc.append(s)
        elif s.startswith("//"):
            continue
        else:
            break
    doc.reverse()
    print()
    print("  %s:" % cls)
    for l in doc[:14]:
        print("    " + l[:118])
