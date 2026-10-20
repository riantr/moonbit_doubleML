#!/usr/bin/env python3
"""v0.154.x -- enumerate EVERY defaulted constructor parameter, not just learners.

Why this exists: the learner-default audit (`_enum_defaults_1530.py`) only ever
looked at `ml_g` / `ml_m` / `ml_l` / `ml_r`. But the objective is "the remaining
N defaults", and `propensity_clip`, `in_sample_normalization`, `score`, `n_folds`,
`n_rep`, `seed`, `cov_type` and the bootstrap knobs are defaults too -- and
several of them are places where this port has historically diverged from
upstream (e.g. `propensity_clip` defaults to 1e-6 here while upstream's
deprecated scalar `trimming_threshold` is 1e-2, per the `did_binary.mbt`
struct comment).

Output is a flat table: estimator, parameter, default literal. Grouped so the
divergences are easy to spot. Parses, does not grep: balanced-paren slicing on
each `pub fn DoubleMLXxx::new(` body, comments stripped first so a commented-out
default can never be counted.

Usage:  python _enum_all_defaults_1540.py [package_dir]
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

PKG = Path(sys.argv[1] if len(sys.argv) > 1 else "moonbit_doubleML").resolve()

NEW_RE = re.compile(r"pub fn (DoubleML[A-Za-z0-9_]+)::new\s*\(")

# `name? : Type = <value>` at parameter granularity. Optional params use `?`
# (pre-format) or `~` (post-`moon fmt` canonical form) -- accept both, because
# the formatter rewrote the whole tree in v0.153.0.
PARAM_RE = re.compile(
    r"(?m)^\s*([a-z_][a-z0-9_]*)[?~]?\s*:\s*([A-Za-z0-9_\[\]\.]+)\s*=\s*(.+?)\s*,?\s*$"
)

# Params whose default is a *construction* spanning several lines; we take the
# opening line and note that it is multi-line rather than mis-parsing.
MULTILINE_OPENERS = ("LearnerDispatch::", "PSProcessor::", "PSProcessorConfig::")


def strip_line_comments(text):
    out = []
    for line in text.splitlines():
        i = line.find("//")
        out.append(line if i == -1 else line[:i])
    return "\n".join(out)


def balanced_slice(text, start):
    depth = 0
    for k in range(start, len(text)):
        if text[k] == "(":
            depth += 1
        elif text[k] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1 : k]
    return text[start + 1 :]


def normalise(v):
    v = " ".join(v.split())
    # Flatten the multi-line LearnerDispatch constructions onto one line so
    # they are comparable as a unit.
    return v


rows = defaultdict(list)
for path in sorted(PKG.glob("*.mbt")):
    src = strip_line_comments(path.read_text(encoding="utf-8"))
    for m in NEW_RE.finditer(src):
        name = m.group(1)
        body = balanced_slice(src, m.end() - 1)
        for pm in PARAM_RE.finditer(body):
            pname, ptype, pval = pm.group(1), pm.group(2), normalise(pm.group(3))
            if pname == "self":
                continue
            rows[pname].append((name, ptype, pval, path.name))

print(f"# package: {PKG}")
print(f"# .mbt files scanned: {len(list(PKG.glob('*.mbt')))}")
print()
print(f"{'parameter':<28} {'sites':>5}  distinct defaults")
print("-" * 96)
for pname in sorted(rows, key=lambda k: (-len(rows[k]), k)):
    sites = rows[pname]
    vals = defaultdict(list)
    for est, ptype, pval, _f in sites:
        vals[pval].append(est)
    summary = " | ".join(
        f"{v} ({len(e)})" for v, e in sorted(vals.items(), key=lambda kv: -len(kv[1]))
    )
    print(f"{pname:<28} {len(sites):>5}  {summary[:120]}")

print()
print("=" * 96)
print("Per-estimator detail")
print("=" * 96)
for est in sorted({e for sites in rows.values() for e, _, _, _ in sites}):
    # The parameter NAME is the dict key; the values are (est, type, value,
    # file).  This used to read `for sites in rows.values() for e, t, v, _f`,
    # which never bound the name and raised NameError on `p` -- so the
    # per-estimator detail section crashed and the script exited non-zero.
    items = [(pname, t, v) for pname, sites in rows.items()
             for e, t, v, _f in sites if e == est]
    items.sort()
    print(f"\n{est}")
    for p, t, v in items:
        print(f"    {p:<26} : {t:<26} = {v[:70]}")

print()
total = sum(len(v) for v in rows.values())
print(f"TOTAL defaulted constructor parameters: {total}")
print(f"distinct parameter names: {len(rows)}")
