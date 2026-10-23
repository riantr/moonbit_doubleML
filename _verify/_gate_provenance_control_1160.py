"""Positive control: does _gate_provenance_1160.py actually FAIL when the
README is wrong? A gate that passes on a correct file and also passes on a
broken one is worthless.

Mutate one row's marker in a COPY of the README, point the gate at the copy,
and require a non-zero exit. Two mutations, covering both directions:
  A  claim `no upstream counterpart` for a class that IS upstream
  B  claim plain *(upstream)* for the one that has none

Nothing on disk is modified; the copy lives in a temp dir and is deleted.
"""
import os, re, shutil, subprocess, sys, tempfile
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
DOC = os.path.join(ROOT, "doc", "004_estimators", "readme.mbt.md")
GATE = os.path.join(ROOT, "_verify", "_gate_provenance_1160.py")

tmp = tempfile.mkdtemp(prefix="prov_gate_")
shutil.copytree(os.path.join(ROOT, "moonbit_doubleML"), os.path.join(tmp, "moonbit_doubleML"),
                ignore=shutil.ignore_patterns("_build", "_verify", "target", ".git"))
shutil.copytree(os.path.join(ROOT, "doc"), os.path.join(tmp, "doc"))
shutil.copy2(os.path.join(ROOT, "_verify", "doubleml-0.11.4.tar.gz"),
             os.path.join(tmp, "doubleml-0.11.4.tar.gz"))
bad_readme = os.path.join(tmp, "README.mbt.md")
bad_doc = os.path.join(tmp, "doc", "004_estimators", "readme.mbt.md")
gate_copy = os.path.join(tmp, "gate.py")
shutil.copy2(GATE, gate_copy)   # the gate locates its inputs relative to its own path

original = open(README, encoding="utf-8").read()
original_doc = open(DOC, encoding="utf-8").read()

# (label, target file, text to append)
MUTATIONS = [
    # --- table-row markers -------------------------------------------------
    ("A: table claims a real upstream class has no counterpart", "R",
     "\n| `DoubleMLPLR` | x | y *(no upstream counterpart)* |\n"),
    ("B: table claims the counterless one is plain upstream", "R",
     "\n| `DoubleMLDIDCrossSection` | x | y *(upstream)* |\n"),
    # --- prose assertions (the ones this audit itself introduced) ------------
    ("C: README 'Every one of the 22 has a counterpart'", "R",
     "\nEvery one of the 22 has a counterpart in doubleml 0.11.4.\n"),
    ("D: README 'all 22 models in upstream'", "R",
     "\ncovering all 22 models in upstream.\n"),
    ("E: README 'no textual occurrence anywhere in the sdist'", "R",
     "\nand no textual occurrence anywhere in the sdist.\n"),
    ("F: doc 'All 22 have an upstream counterpart'", "D",
     "\nAll 22 have an upstream doubleml.DoubleML* counterpart.\n"),
    ("G: README '19 upstream models'", "R",
     "\nAll 19 upstream models are faithfully re-implemented.\n"),
]

ok = True
try:
    for label, target, injected in MUTATIONS:
        # restore pristine copies, then inject into exactly one file
        open(bad_readme, "w", encoding="utf-8").write(original)
        open(bad_doc, "w", encoding="utf-8").write(original_doc)
        path = bad_readme if target == "R" else bad_doc
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(injected)
        r = subprocess.run([sys.executable, gate_copy], capture_output=True, text=True)
        detected = r.returncode != 0
        ok &= detected
        print(f"  {'DETECTED' if detected else 'MISSED  '}  {label}  (exit={r.returncode})")
        if not detected:
            print("      gate passed on a deliberately broken file")
    # restore pristine copies for the final unmutated run
    open(bad_readme, "w", encoding="utf-8").write(original)
    open(bad_doc, "w", encoding="utf-8").write(original_doc)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# and the unmutated README must still pass
r = subprocess.run([sys.executable, GATE], capture_output=True, text=True)
print(f"  {'PASS    ' if r.returncode == 0 else 'BROKEN  '}  unmutated README (exit={r.returncode})")
ok &= r.returncode == 0

print()
print("GATE DISCRIMINATES" if ok else "GATE DOES NOT DISCRIMINATE")
sys.exit(0 if ok else 1)