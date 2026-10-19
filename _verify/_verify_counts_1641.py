"""Pin the README's counts to what the tree and the tags actually say.

Round 7 found four count words that had drifted from the list they
introduce, in one class: "N things (a, b, c, ...)" where N no longer
matches the list, or the list no longer covers the set.

  1. "The five remaining `adjust_ps` call sites (six listed)" -- the true
     current set is EIGHT call sites in seven files.
  2. v0.64.0 "Adds `bootstrap()` to 8 remaining estimators (nine listed)"
     -- measured: exactly nine estimators gained `bootstrap`.
  3. v0.66.0 "Adds `sensitivity_analysis()` on 7 IRM-style estimators
     (eight listed)" -- measured: exactly eight gained it.
  4. v0.149.0 "5 gates added (`expand_v149_test.mbt`)" -- the file's gates
     are numbered 1..6, with GATE 1 and GATE 2 sharing one test function.

Every count in the same section that was CHECKED and is CORRECT is pinned
too, so the next round cannot quietly break one of them:

  v0.67.0  `confint(joint?)` gained by 9 estimators
  v0.86.0  sandwich coverage 2 -> 6 of 22; 6 new white-box tests
  v0.90.0  11 affected estimators; 13 psi-construction sites
  v0.64.0 / v0.65.0 / v0.66.0 / v0.148.0 / v0.150.0 / v0.151.0 / v0.152.0
           gate counts; 6 new wbtests in v063_wbtest.mbt
  fuzz     11 surfaces
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LIB = os.path.join(ROOT, "moonbit_doubleML")
# `git show` needs a REPO-RELATIVE path, not the absolute one used above
GITLIB = "moonbit_doubleML"
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()
flat = re.sub(r"\s+", " ", readme)

fails = []


def check(label, cond, detail=""):
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# ---------------------------------------------------------------- git helpers
def git(*args):
    r = subprocess.run(["git"] + list(args), cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


_cache = {}


def src_at(tag, f):
    key = (tag, f)
    if key not in _cache:
        rc, out = git("show", "%s:%s/%s" % (tag, GITLIB, f))
        _cache[key] = out if rc == 0 else None
    return _cache[key]


def prod_files(tag):
    key = ("files", tag)
    if key not in _cache:
        rc, out = git("ls-tree", "--name-only", tag, GITLIB + "/")
        _cache[key] = [f[len(GITLIB) + 1:] for f in out.split()
                       if f.endswith(".mbt") and not f.endswith("_test.mbt")]
    return _cache[key]


QUAL = re.compile(r"pub fn (DoubleML\w+)::(\w+)\s*\(([^)]*)\)", re.S)
CALL = re.compile(r"\.adjust_ps\(")
TEST = re.compile(r'^test\s+"', re.M)
GATE = re.compile(r"\bGATE\s+(\d+)\b")


def methods(tag, method, need_param=None):
    out = set()
    for f in prod_files(tag):
        src = src_at(tag, f)
        if not src:
            continue
        for m in QUAL.finditer(src):
            if m.group(2) != method:
                continue
            if need_param and not re.search(r"\b%s\b" % need_param, m.group(3)):
                continue
            out.add(m.group(1))
    return out


print("=== 1. the `adjust_ps` call sites ===")
sites = []
for f in sorted(os.listdir(LIB)):
    if not f.endswith(".mbt") or f.endswith("_test.mbt"):
        continue
    lines = io.open(os.path.join(LIB, f), encoding="utf-8",
                    errors="replace").read().splitlines()
    for i, line in enumerate(lines, 1):
        if not CALL.search(line):
            continue
        if line.lstrip().startswith("//"):
            continue
        buf, j, depth = line, i, line.count("(") - line.count(")")
        while depth > 0 and j < len(lines):
            j += 1
            buf += " " + lines[j - 1]
            depth = buf.count("(") - buf.count(")")
        sites.append((f, i, re.search(r"\bcv\s*=", buf) is not None))
no_cv = sorted("%s:%d" % (f, i) for f, i, c in sites if not c)
with_cv = sorted("%s:%d" % (f, i) for f, i, c in sites if c)
print("  without cv: %s" % ", ".join(no_cv))
print("  with cv   : %s" % ", ".join(with_cv))
EXPECTED_NO_CV = ["apo.mbt:320", "cvar.mbt:736", "cvar.mbt:1005",
                  "did.mbt:628", "did_cross_section.mbt:615",
                  "did_cs_binary.mbt:374", "quantile.mbt:217", "ssm.mbt:671"]
check("the derived no-cv set is the expected eight",
      set(no_cv) == set(EXPECTED_NO_CV) and len(no_cv) == 8,
      "got %s" % no_cv)
check("the README says 'eight'",
      "call sites that do not forward `cv` are **eight**" in flat)
check("the README says 'seven files'", "**eight**, in seven\n> files" in readme
      or "**eight**, in seven files" in flat)
for s in EXPECTED_NO_CV:
    check("the README names %s" % s, "`%s`" % s in readme)
check("the old 'five remaining' wording is gone",
      "five remaining `adjust_ps` call sites" not in flat)
print()

print("=== 2. v0.64.0: estimators that gained `bootstrap` ===")
a, b = methods("v0.63.0", "bootstrap"), methods("v0.64.0", "bootstrap")
gained = sorted(b - a)
print("  gained: %d -> %s" % (len(gained), ", ".join(gained)))
check("exactly nine gained it", len(gained) == 9, "got %d" % len(gained))
check("the README says 'nine remaining estimators'",
      "Adds `bootstrap()` to nine remaining estimators" in flat)
for e in ("DoubleMLSSM", "DoubleMLDID", "DoubleMLDIDBinary",
          "DoubleMLDIDCSBinary", "DoubleMLLPQ", "DoubleMLPQ",
          "DoubleMLQTE", "DoubleMLDIDCS", "DoubleMLBLP"):
    check("the README's list names %s" % e.replace("DoubleML", ""), e in flat)
print()

print("=== 3. v0.66.0: estimators that gained `sensitivity_analysis` ===")
a, b = methods("v0.65.0", "sensitivity_analysis"), methods("v0.66.0", "sensitivity_analysis")
gained = sorted(b - a)
print("  gained: %d -> %s" % (len(gained), ", ".join(gained)))
check("exactly eight gained it", len(gained) == 8, "got %d" % len(gained))
check("the README says 'eight IRM-style estimators'",
      "Adds `sensitivity_analysis()` on eight IRM-style estimators" in flat)
print()

print("=== 4. v0.149.0: the gates in expand_v149_test.mbt ===")
src = src_at("v0.149.0", "expand_v149_test.mbt") or ""
gates = sorted(set(int(g) for g in GATE.findall(src)))
tests = len(TEST.findall(src))
print("  GATE labels: %s   test functions: %d" % (gates, tests))
check("the file has GATE 1..6", gates == [1, 2, 3, 4, 5, 6], "got %s" % gates)
check("the README says 'six gates added'",
      "six gates added (`expand_v149_test.mbt`" in flat)
check("the README notes that GATE 1 and GATE 2 share a test function",
      "GATE 1 and GATE 2 share one test" in flat)
print()

print("=== the counts that are CORRECT stay correct ===")
a, b = methods("v0.66.0", "confint", "joint"), methods("v0.67.0", "confint", "joint")
check("v0.67.0: exactly nine gained a `joint` param",
      len(b - a) == 9, "got %d" % len(b - a))
check("the README still says 9 single-theta estimators",
      "`confint(joint?)` API parity to 9 single-theta estimators" in flat)

sa = methods("v0.85.0", "sandwich_se")
sb = methods("v0.86.0", "sandwich_se")
check("v0.86.0: sandwich coverage went 2 -> 6",
      len(sa) == 2 and len(sb) == 6, "got %d -> %d" % (len(sa), len(sb)))
check("the README still says 'coverage 2 -> 6 of 22'",
      "coverage 2 -> 6 of 22" in flat)

for f, tag, prev, claim, kind in (
        ("expand_v152_test.mbt", "v0.152.0", "v0.151.0", 4, "gates"),
        ("expand_v151_test.mbt", "v0.151.0", "v0.150.0", 8, "gates"),
        ("expand_v150_test.mbt", "v0.150.0", "v0.149.0", 5, "gates"),
        ("expand_v148_test.mbt", "v0.148.0", "v0.147.0", 5, "gates")):
    s = src_at(tag, f) or ""
    # a `GATE n` that names ANOTHER file is a cross-reference, not a local
    # gate -- and the file can be named on a PRECEDING line:
    #     /// and were never available for `==` (the same reason
    #     /// `expand_v146_test.mbt`
    #     /// GATE 5 uses a tolerance).
    local = set()
    lines = s.splitlines()
    for m in re.finditer(r"\bGATE\s+(\d+)\b", s):
        line_no = s.count("\n", 0, m.start())
        window = "\n".join(lines[max(0, line_no - 4):line_no + 1])
        others = re.findall(r"(expand_v\d+_test\.mbt|v\d+_wbtest\.mbt)", window)
        if others and all(o != f for o in others):
            continue
        local.add(int(m.group(1)))
    check("%s has %d local gates" % (f, claim), len(local) == claim,
          "got %s" % sorted(local))

wb = src_at("v0.63.0", "v063_wbtest.mbt") or ""
check("v063_wbtest.mbt has 6 tests", len(TEST.findall(wb)) == 6,
      "got %d" % len(TEST.findall(wb)))

fuzz = io.open(os.path.join(ROOT, "examples", "fuzz", "main.mbt"),
               encoding="utf-8", errors="replace").read()
n_surf = len([l for l in fuzz.splitlines() if re.match(r"^//\s+\d+\.", l)])
check("the fuzz harness has 11 surfaces", n_surf == 11, "got %d" % n_surf)
check("the README still says 11 surfaces", "across 11 surfaces" in flat)

# the simulator-bug list: "Eight simulator bugs it has caught" + N bullets
rlines = readme.splitlines()
lead = next((i for i, l in enumerate(rlines)
             if "simulator bugs it has caught" in l), None)
n_bul = 0
if lead is not None:
    for l in rlines[lead + 1:]:
        s = l.strip()
        if s.startswith("Not simulated:"):
            break
        if s.startswith("- "):
            n_bul += 1
check("the simulator-bug list has 8 bullets", n_bul == 8, "got %d" % n_bul)
check("the README says 'Eight simulator bugs'",
      "Eight simulator bugs it has caught" in flat)
check("the old 'Nine simulator bugs' wording is gone",
      "Nine simulator bugs it has caught" not in flat)

print()
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
