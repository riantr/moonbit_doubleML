"""Round 17 method script: audit `_verify/LPLR_GATE_BLINDNESS_1680.md`.

This is the ONLY `_verify/` record the shipped README cites (README.mbt.md
lines 1162 and 1217), so every promise it makes is a promise the README
inherits.  Three classes of defect are checked, and each is checked by
RESOLVING it, not by matching prose:

  1. PATH PROMISES  -- every script the record names must exist AND be
     tracked in git.  "It is on my disk" is not "it is in the repository";
     a reader who clones the tag cannot open it otherwise.
  2. POINTERS       -- every `file:line` must resolve to a real file, a
     real line range, and the content there must be the thing claimed.
  3. TEST COUNTS    -- the record quotes test counts.  Those are measured,
     and they were last measured on an older tree.

Writes `_verify/_r17_lplr_audit_1650.json`.
"""
import json
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
PKG = os.path.join(ROOT, "moonbit_doubleML")
REC = os.path.join("_verify", "LPLR_GATE_BLINDNESS_1680.md")

import doubleml  # noqa: E402
UP = os.path.dirname(doubleml.__file__)
UPSTREAM_VERSION = getattr(doubleml, "__version__", "?")

# ---------------------------------------------------------------- git state
def git(*args):
    r = subprocess.run(["git"] + list(args), cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.stdout


TRACKED = set(x.strip() for x in git("ls-files").splitlines() if x.strip())

# ---------------------------------------------------------------- resolution
UPSTREAM_ALIASES = {
    "lplr.py": os.path.join("plm", "lplr.py"),
    "_estimation.py": os.path.join("utils", "_estimation.py"),
    "double_ml_score_mixins.py": "double_ml_score_mixins.py",
    "utils/_estimation.py": os.path.join("utils", "_estimation.py"),
    "utils/resampling.py": os.path.join("utils", "resampling.py"),
    "plm/lplr.py": os.path.join("plm", "lplr.py"),
}


def candidates(path):
    """Ordered candidate locations for a path as written in the record."""
    base = os.path.basename(path)
    c = []
    if path.startswith("doubleml/"):
        c.append(os.path.join(UP, path[len("doubleml/"):]))
    if path in UPSTREAM_ALIASES:
        c.append(os.path.join(UP, UPSTREAM_ALIASES[path]))
    if path == "check.yml":
        c.append(os.path.join(ROOT, ".github", "workflows", "check.yml"))
    if path.endswith(".mbt"):
        # package-relative is the house convention: the shipped package is
        # moonbit_doubleML/, and a bare `lplr.mbt` in the repo root is a
        # 0-byte stray, NOT the source the record is talking about.
        c.append(os.path.join(PKG, base))
    c.append(os.path.join(ROOT, path))
    c.append(os.path.join(PKG, path))
    c.append(os.path.join(ROOT, base))
    c.append(os.path.join(UP, path))
    c.append(os.path.join(UP, base))
    return c


def resolve(path):
    for c in candidates(path):
        if os.path.isfile(c):
            return os.path.normpath(c)
    return None


def rel(p):
    if p is None:
        return None
    if p.startswith(UP):
        return "<upstream>/" + os.path.relpath(p, UP)
    if p.startswith(ROOT):
        return os.path.relpath(p, ROOT).replace("\\", "/")
    return p


def read_lines(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read().split("\n")


# ---------------------------------------------------------------- the record
rec_text = open(os.path.join(ROOT, REC), encoding="utf-8", errors="replace").read()
rec_lines = rec_text.split("\n")

POINTER = re.compile(
    r"`?([A-Za-z0-9_./\\-]+\.(?:py|mbt|md|ps1|yml|yaml|json|txt)):(\d+)(?:-(\d+))?`?")

pointers = {}
for i, line in enumerate(rec_lines, 1):
    for m in POINTER.finditer(line):
        path, a = m.group(1), int(m.group(2))
        b = int(m.group(3)) if m.group(3) else None
        key = "%s:%s%s" % (path, a, "-%d" % b if b else "")
        pointers.setdefault(key, {"pointer": key, "path": path, "first": a,
                                  "last": b or a, "record_lines": []})
        pointers[key]["record_lines"].append(i)

for key, p in pointers.items():
    real = resolve(p["path"])
    p["resolved_to"] = rel(real)
    p["resolved_abs"] = real
    p["in_range"] = False
    p["cited_text"] = []
    if real:
        content = read_lines(real)
        p["file_lines"] = len(content)
        p["in_range"] = p["last"] <= len(content)
        if p["in_range"]:
            p["cited_text"] = [content[n - 1].strip()
                               for n in range(p["first"], p["last"] + 1)]

# ------------------------------------------------------- script path promises
# Every python file the record names, with or without the `_verify/` prefix.
SCRIPT = re.compile(r"(_verify/)?([A-Za-z0-9_]+\.py)\b")
scripts = {}
for i, line in enumerate(rec_lines, 1):
    for m in SCRIPT.finditer(line):
        prefix, name = m.group(1) or "", m.group(2)
        relpath = prefix + name
        key = relpath
        s = scripts.setdefault(key, {"cited_as": relpath, "name": name,
                                     "record_lines": []})
        s["record_lines"].append(i)

for key, s in scripts.items():
    name = s["name"]
    cands = [os.path.join("_verify", name), name,
             os.path.join("moonbit_doubleML", name)]
    found = None
    for c in cands:
        if os.path.isfile(os.path.join(ROOT, c)):
            found = c.replace("\\", "/")
            break
    s["found_at"] = found
    s["exists"] = found is not None
    s["tracked"] = bool(found) and found in TRACKED
    # a citation that omits the `_verify/` prefix for a file that lives there
    # is a promise that does not resolve as written
    s["resolves_as_cited"] = os.path.isfile(os.path.join(ROOT, key))
    s["prefix_ok"] = s["resolves_as_cited"] or (found is not None and
                                                key.startswith("_verify/"))

# ------------------------------------------------------------- test counts
COUNT = re.compile(r"\b(\d{3,4})\s*/\s*(\d{3,4})\b")
counts = []
for i, line in enumerate(rec_lines, 1):
    for m in COUNT.finditer(line):
        counts.append({"record_line": i, "pair": "%s/%s" % m.groups(),
                       "a": int(m.group(1)), "b": int(m.group(2)),
                       "context": line.strip()[:300]})

# ------------------------------------------------------------------- output
result = {
    "record": REC.replace("\\", "/"),
    "upstream_package": "doubleml %s" % UPSTREAM_VERSION,
    "upstream_path": UP,
    "record_lines": len(rec_lines),
    "pointers": sorted(pointers.values(), key=lambda p: (p["path"], p["first"])),
    "pointer_count": len(pointers),
    "pointers_unresolved": [p["pointer"] for p in pointers.values()
                            if p["resolved_to"] is None],
    "pointers_out_of_range": [p["pointer"] for p in pointers.values()
                               if p["resolved_to"] is not None and not p["in_range"]],
    "scripts": sorted(scripts.values(), key=lambda s: s["cited_as"]),
    "scripts_missing": [s["cited_as"] for s in scripts.values() if not s["exists"]],
    "scripts_untracked": [s["cited_as"] for s in scripts.values()
                          if s["exists"] and not s["tracked"]],
    "scripts_bad_prefix": [s["cited_as"] for s in scripts.values()
                           if s["exists"] and not s["prefix_ok"]],
    "test_counts": counts,
}

out = os.path.join(ROOT, "_verify", "_r17_lplr_audit_1650.json")
with open(out, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(result, fh, indent=2, ensure_ascii=False)

print("record            : %s (%d lines)" % (REC, len(rec_lines)))
print("upstream          : doubleml %s" % UPSTREAM_VERSION)
print("pointers          : %d   unresolved=%d  out-of-range=%d" % (
    len(pointers), len(result["pointers_unresolved"]),
    len(result["pointers_out_of_range"])))
for p in result["pointers_unresolved"]:
    print("   UNRESOLVED  ", p)
for p in result["pointers_out_of_range"]:
    print("   OUT OF RANGE", p)
print("scripts cited     : %d   missing=%d  untracked=%d  bad-prefix=%d" % (
    len(scripts), len(result["scripts_missing"]), len(result["scripts_untracked"]),
    len(result["scripts_bad_prefix"])))
for s in scripts.values():
    if not s["exists"] or not s["tracked"] or not s["prefix_ok"]:
        print("   %-42s exists=%-5s tracked=%-5s as_cited=%-5s  lines=%s" % (
            s["cited_as"], s["exists"], s["tracked"], s["resolves_as_cited"],
            s["record_lines"][:4]))
print("test-count claims : %d" % len(counts))
for c in counts:
    print("   L%-5d %-10s  %s" % (c["record_line"], c["pair"], c["context"][:130]))
print()
print("wrote", os.path.relpath(out, ROOT))
