#!/usr/bin/env python3
"""v0.153.0 -- are the remaining `ignore(ml_g)` / `ignore(ml_m)` lines vestigial?

Context: `did_cs.mbt` carried a vestigial `ignore(ml_g)` that claimed a dropped
parameter when `ml_g` was in fact used four times later in the same function.
Fixed in v0.153.0. Five more such pairs turned up in the same audit
(apo.mbt, did.mbt, did_binary.mbt, iivm.mbt, ssm.mbt).

`ignore(x)` is a no-op, so nothing can BREAK from these. The risk is purely
that they assert a drop that does not happen -- which is what made the did_cs
one produce a phantom audit finding.

Method: for each `fn` whose body contains `ignore(ml_<slot>)`, count further
occurrences of that identifier AFTER the ignore line, inside the same function.
Zero uses = the claim is true and the line is honest (or at least accurate);
>0 = the line misdescribes the code.

Usage:  python _ignore_audit_1530.py [package_dir]
"""
import re
import sys
from pathlib import Path

PKG = Path(sys.argv[1] if len(sys.argv) > 1 else "moonbit_doubleML").resolve()

# Must match METHODS too (`pub fn DoubleMLAPO::fit(`), not just top-level
# `fn helper(`. The first version used `^fn ` and found nothing at all --
# a silent zero that reads exactly like "no defects".
FN_RE = re.compile(r"^(?:pub )?fn ([A-Za-z0-9_:]+)\s*\(", re.M)
IGNORE_RE = re.compile(r"^\s*ignore\(ml_([gmlr])\)\s*$", re.M)


def strip_comments(text):
    out = []
    for line in text.splitlines():
        i = line.find("//")
        out.append(line if i == -1 else line[:i])
    return "\n".join(out)


def balanced_end(text, open_idx):
    depth = 0
    for k in range(open_idx, len(text)):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return len(text) - 1


rows = []
for path in sorted(PKG.glob("*.mbt")):
    src = strip_comments(path.read_text(encoding="utf-8"))
    for fm in FN_RE.finditer(src):
        op = src.find("{", fm.end() - 1)
        if op == -1:
            continue
        close = balanced_end(src, op)
        body = src[op:close]
        for im in IGNORE_RE.finditer(body):
            slot = im.group(1)
            after = body[im.end():]
            # Word-boundary count of the identifier after the ignore line.
            uses = len(re.findall(r"\bml_" + slot + r"\b", after))
            # A `~label` forwarding reference still counts; a re-declaration
            # would not. Report the raw count and let the caller judge.
            name = fm.group(1)
            line_no = src[: op + im.start()].count("\n") + 1
            rows.append((path.name, line_no, name, f"ml_{slot}", uses))

print(f"{'file':<24} {'line':>5}  {'function':<34} {'slot':<6} {'later uses':>10}  verdict")
print("-" * 104)
honest = misleading = 0
for fname, line_no, name, slot, uses in rows:
    verdict = "HONEST (unused)" if uses == 0 else f"MISLEADING ({uses} uses)"
    if uses == 0:
        honest += 1
    else:
        misleading += 1
    print(f"{fname:<24} {line_no:>5}  {name:<34} {slot:<6} {uses:>10}  {verdict}")

print("-" * 104)
print(f"total ignore(ml_*) lines: {len(rows)}")
print(f"  honest (parameter truly unused): {honest}")
print(f"  misleading (parameter IS used later): {misleading}")
if misleading:
    print("\nA 'misleading' line is not a bug -- `ignore` is a no-op -- but it")
    print("asserts a drop that does not happen, which is how the did_cs.mbt one")
    print("produced a phantom audit finding.")
