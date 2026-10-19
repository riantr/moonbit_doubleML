#!/usr/bin/env python3
"""v0.132.0 -- empirical blast-radius census for the `ml_m` default flip.

Stage 2a classified the 89 IRM test bodies STATICALLY and produced
"hours-to-days". The actual `DoubleMLIRM` migration needed THREE test edits.
This script explains the gap by measuring, per estimator, how many
construction sites depend on the DEFAULT `ml_m` at all.

The static classification could not see this, because a site is only
*dependent* if the learner actually reaches the propensity slot. Three
things make a site immune:

  1. `ml_m` is passed explicitly to `DoubleMLIRM::new(...)`.
  2. `ml_m` is passed to the `.fit(...)` override that follows.
  3. Neither -- the site genuinely uses the default (these are the ones
     that change behaviour).

This is a LINE-BLOCK scan: a `DoubleMLIRM::new(` call spans many lines, so
`ml_m=` on line +4 is still part of that call. A line-based grep misses
those, which is very likely what inflated the stage-2a estimate.

Usage:  python _census_mlm_1320.py [package_dir]
"""
import re
import sys
from pathlib import Path

# Estimators whose `ml_m` feeds a PROPENSITY (needs a classifier) rather
# than an outcome nuisance. cvar/quantile's `ml_m` is stored but (per their
# own comments) not yet consumed, so a flip there is inert -- reported
# separately rather than folded into the actionable count.
PROPENSITY = ["DoubleMLIRM", "DoubleMLAPO", "DoubleMLDID", "DoubleMLDIDBinary",
              "DoubleMLDIDCSBinary", "DoubleMLPLR"]
STORED_ONLY = ["DoubleMLCVaR", "DoubleMLQuantile"]

CALL_RE = re.compile(r"\b(DoubleML[A-Za-z]+)\s*::\s*new\s*\(")


def block_of(text, start_idx):
    """Return the balanced-paren source of a call beginning at start_idx."""
    depth = 0
    for i in range(start_idx, len(text)):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start_idx:i + 1]
    return text[start_idx:]


def scan(pkg: Path):
    rows = []
    for f in sorted(pkg.glob("*.mbt")):
        text = f.read_text(encoding="utf-8")
        for m in CALL_RE.finditer(text):
            est = m.group(1)
            if est not in PROPENSITY and est not in STORED_ONLY:
                continue
            body = block_of(text, m.end() - 1)
            line = text[:m.start()].count("\n") + 1
            explicit_new = re.search(r"\bml_m\s*[=:]\s*LearnerDispatch", body) is not None
            rows.append({
                "file": f.name,
                "line": line,
                "est": est,
                "explicit_new": explicit_new,
                "body": body,
            })
    return rows


def main():
    pkg = Path(sys.argv[1] if len(sys.argv) > 1 else "moonbit_doubleML").resolve()
    rows = scan(pkg)

    print("=" * 72)
    print("ml_m DEFAULT-DEPENDENCY CENSUS  (v0.132.0)")
    print("=" * 72)

    # `.fit(ml_m=...)` overrides belong to the call that PRECEDES them,
    # so pair each site with the text that follows it up to the next
    # constructor of the same estimator.
    by_file = {}
    for r in rows:
        by_file.setdefault(r["file"], []).append(r)

    total_default = 0
    per_est = {}
    for est in PROPENSITY:
        hits = [r for r in rows if r["est"] == est]
        dep = [r for r in hits if not r["explicit_new"]]
        per_est[est] = (len(hits), len(dep))
        total_default += len(dep)
        print(f"  {est:<22} sites={len(hits):>3}   no-ml_m-in-new={len(dep):>3}")

    print("-" * 72)
    print(f"  {'TOTAL (propensity)':<22} sites={sum(v[0] for v in per_est.values()):>3}"
          f"   no-ml_m-in-new={total_default:>3}")

    stored = [r for r in rows if r["est"] in STORED_ONLY]
    if stored:
        print(f"  stored-but-unconsumed: {len(stored)} sites across "
              f"{len(set(r['file'] for r in stored))} files (flip is inert there)")

    print()
    print("Sites that genuinely take the DEFAULT ml_m (behaviour changes):")
    for r in rows:
        if r["est"] in PROPENSITY and not r["explicit_new"]:
            print(f"  {r['file']}:{r['line']}  {r['est']}")

    print()
    print("NOTE: a 'no-ml_m-in-new' site may still be overridden by a following")
    print("      .fit(ml_m=...), which this scan does NOT attribute. Those are")
    print("      counted as default-dependent here = a conservative OVER-count.")


if __name__ == "__main__":
    main()