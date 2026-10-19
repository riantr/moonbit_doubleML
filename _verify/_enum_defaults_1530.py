#!/usr/bin/env python3
"""v0.153.0 -- authoritative enumeration of every LEARNER DEFAULT in the package.

Motivation: the active goal says "go through the remaining 11 defaults by
measurement", but that list is not recoverable from any durable artifact. This
script re-derives the candidate set from the SOURCE, so a user-supplied list can
be checked against what actually exists rather than against memory.

What counts as a "default" here: a `pub fn DoubleMLXxx::new(` parameter whose
default VALUE is a `LearnerDispatch::...()` construction. That is what a caller
who never mentions the argument actually gets.

Deliberately NOT counted (they are not caller-facing defaults):
  * `pub fn DoubleMLXxx::fit(...)` parameters defaulting to `self.ml_g` -- that
    is "reuse what the constructor stored", not a learner choice.
  * plain struct fields `ml_g : LearnerDispatch` -- no default, always supplied.

Outputs a CSV-ish table to stdout, sorted, plus a summary count.

Usage:  python _enum_defaults_1530.py [package_dir]
"""
import re
import sys
from pathlib import Path

PKG = Path(sys.argv[1] if len(sys.argv) > 1 else "moonbit_doubleML").resolve()

# `pub fn DoubleMLFoo::new(` -- capture the estimator name.
NEW_RE = re.compile(r"pub fn (DoubleML[A-Za-z0-9_]+)::new\s*\(")

# A learner parameter carrying a DEFAULT VALUE. Two shapes matter:
#   ml_m? : LearnerDispatch = LearnerDispatch::logistic_regression(\n  LogisticRegression::new(),\n ),
#   ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
# so we match the slot, then scan forward to the matching `= LearnerDispatch::`.
PARAM_RE = re.compile(
    r"\b(ml_[gmlr])\?\s*:\s*LearnerDispatch\s*=\s*LearnerDispatch::([a-z_]+)\s*\("
)

FIT_RE = re.compile(r"pub fn (DoubleML[A-Za-z0-9_]+)::fit\s*\(")


def strip_line_comments(text):
    out = []
    for line in text.splitlines():
        i = line.find("//")
        out.append(line if i == -1 else line[:i])
    return "\n".join(out)


def balanced_slice(text, start):
    """From `text[start]` == '(' return the text up to its matching ')'."""
    depth = 0
    for k in range(start, len(text)):
        c = text[k]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1 : k]
    return text[start + 1 :]


rows = []
fits = set()
files = sorted(PKG.glob("*.mbt"))

for path in files:
    raw = path.read_text(encoding="utf-8")
    src = strip_line_comments(raw)

    for m in FIT_RE.finditer(src):
        fits.add(m.group(1))

    for m in NEW_RE.finditer(src):
        name = m.group(1)
        body = balanced_slice(src, m.end() - 1)
        # line number of the `pub fn` so the report is greppable
        line_no = src[: m.start()].count("\n") + 1
        found = PARAM_RE.findall(body)
        if not found:
            rows.append((name, path.name, line_no, "", "", "NO-LEARNER-DEFAULT"))
            continue
        for slot, kind in found:
            rows.append((name, path.name, line_no, slot, kind, ""))

rows.sort(key=lambda r: (r[3], r[0]))

print(f"# package: {PKG}")
print(f"# .mbt files scanned: {len(files)}")
print()
hdr = f"{'estimator':<26} {'file':<24} {'line':>5} {'slot':<6} {'default':<22} note"
print(hdr)
print("-" * len(hdr))
for name, fname, line_no, slot, kind, note in rows:
    print(
        f"{name:<26} {fname:<24} {line_no:>5} "
        f"{(slot or '-'):<6} {(kind or note):<22} {note if note else ''}".rstrip()
    )

print()
learner_rows = [r for r in rows if r[3]]
no_default = [r for r in rows if not r[3]]
print(f"estimator ::new definitions        : {len(set(r[0] for r in rows))}")
print(f"learner default sites (ml_* slots) : {len(learner_rows)}")
print(f"estimators with NO learner default : {len(no_default)}"
      + (f" -> {[r[0] for r in no_default]}" if no_default else ""))

by_slot = {}
for _, _, _, slot, kind, _ in learner_rows:
    by_slot.setdefault(slot, {}).setdefault(kind, 0)
    by_slot[slot][kind] += 1
print()
print("defaults by slot:")
for slot in sorted(by_slot):
    kinds = by_slot[slot]
    total = sum(kinds.values())
    detail = ", ".join(f"{k}={v}" for k, v in sorted(kinds.items()))
    print(f"  {slot}: {total}  ({detail})")

# Which estimators carry each slot -- this is the cross-check surface for a
# user-supplied list, so print it explicitly rather than making them grep.
print()
print("estimators per slot:")
for slot in sorted(by_slot):
    names = sorted(r[0] for r in learner_rows if r[3] == slot)
    print(f"  {slot} ({len(names)}): {', '.join(names)}")
