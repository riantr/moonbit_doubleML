"""QA loop driver.

    python .github/scripts/qa_loop/run.py [--iterations N] [--full]
                                          [--only id,id] [--json out.json]
                                          [--allow-inert]

Runs the registered checks in order, one pass per iteration, and prints a
per-iteration table plus an aggregate. Exit code:

    0  no FAIL (and no INERT, unless --allow-inert)
    1  at least one FAIL, or any INERT without --allow-inert

INERT is treated as failure by default: a gate that cannot fail is not a
passing gate, and this repo has shipped a green format check that could not
turn red.

--allow-inert downgrades INERT to a loud non-fatal warning. It exists for CI,
where `moon fmt --check` is INERT on this toolchain for a reason unrelated to
the code under test -- gating on it would fail every run forever and train
everyone to ignore a red build. The verdict is still printed either way.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import checks as C  # noqa: E402

C_FAIL, C_INERT = C.FAIL, C.INERT


def one_pass(selected, full, aggregate_from=None):
    out = []
    for c in selected:
        t0 = time.perf_counter()
        try:
            if c["id"] == "quality_metrics":
                r = c["fn"](prior=aggregate_from or [])
            elif c["scope"] == "full" and not full:
                r = C.R(c["id"], c["title"], C.SKIP,
                        "scope=full; pass --full to run")
            else:
                r = c["fn"]()
        except Exception as e:                      # noqa: BLE001
            r = C.R(c["id"], c["title"], C.FAIL,
                    f"check raised {type(e).__name__}: {e}")
        if r.seconds == 0.0:
            r.seconds = time.perf_counter() - t0
        out.append(r)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="moonbit_doubleML QA loop")
    ap.add_argument("--iterations", type=int, default=1)
    ap.add_argument("--full", action="store_true",
                    help="also run slow checks (full test suites, api, fuzz, mutation)")
    ap.add_argument("--only", default="", help="comma-separated check ids")
    ap.add_argument("--json", default="", help="write the report here")
    ap.add_argument("--allow-inert", action="store_true",
                    help="report INERT but do not exit non-zero for it (used by "
                         "CI, where a permanently-INERT gate would otherwise fail "
                         "every run for reasons unrelated to the code)")
    args = ap.parse_args(argv)

    selected = C.CHECKS
    if args.only:
        want = {x.strip() for x in args.only.split(",") if x.strip()}
        selected = [c for c in C.CHECKS if c["id"] in want]
        if not selected:
            print("no check matched --only", file=sys.stderr)
            return 1

    tool = C.moon_version()
    print("=" * 100)
    print(f"QA LOOP  |  {os.path.relpath(C.ROOT, os.path.dirname(C.ROOT))}  |  {tool}")
    print(f"checks={len(selected)}  iterations={args.iterations}  "
          f"mode={'full' if args.full else 'fast'}")
    print("=" * 100)

    all_runs = []
    for it in range(1, args.iterations + 1):
        print(f"\n--- iteration {it}/{args.iterations} " + "-" * 76)
        prev = all_runs[-1] if all_runs else None
        rs = one_pass(selected, args.full,
                      aggregate_from=[r.verdict for r in prev] if prev else None)
        for r in rs:
            print(f"  {r.verdict:<6} {r.id:<20} {r.seconds:7.2f}s  {r.evidence}")
        all_runs.append(rs)
        if args.iterations > 1 and prev is not None:
            flips = [(a.id, a.verdict, b.verdict)
                     for a, b in zip(prev, rs) if a.verdict != b.verdict]
            print("  verdict flips vs previous iteration: "
                  + (", ".join(f"{i}:{a}->{b}" for i, a, b in flips) if flips else "none"))

    last = all_runs[-1]
    tally = {}
    for r in last:
        tally[r.verdict] = tally.get(r.verdict, 0) + 1
    print("\n" + "=" * 100)
    print("AGGREGATE (final iteration): "
          + "  ".join(f"{k}={v}" for k, v in sorted(tally.items())))
    unstable = []
    if args.iterations > 1:
        for i, c in enumerate(selected):
            vs = {r[i].verdict for r in all_runs}
            if len(vs) > 1:
                unstable.append(f"{c['id']}:{sorted(vs)}")
        print("non-deterministic across iterations: "
              + (", ".join(unstable) if unstable else "none"))
    gaps = [r.id for r in last if r.verdict == C.SKIP]
    inert = [r.id for r in last if r.verdict == C_INERT]
    failed = [r.id for r in last if r.verdict == C_FAIL]
    if gaps:
        print(f"not covered ({len(gaps)}): {', '.join(gaps)}")
    if inert:
        print(f"INERT ({len(inert)}) -- cannot fail, counted as failure: {', '.join(inert)}")
    if failed:
        print(f"FAILED ({len(failed)}): {', '.join(failed)}")
    print("=" * 100)

    if args.json:
        payload = {
            "tool": tool, "mode": "full" if args.full else "fast",
            "iterations": args.iterations,
            "allow_inert": args.allow_inert,
            "runs": [[{"id": r.id, "verdict": r.verdict, "seconds": round(r.seconds, 2),
                       "evidence": r.evidence} for r in run] for run in all_runs],
            "tally": tally,
        }
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, ensure_ascii=False)
        print(f"report -> {args.json}")

    if args.allow_inert and inert:
        # Loud on purpose: this is the one place a real defect is deliberately
        # not blocking, so it must be impossible to miss in the log.
        print()
        print("::warning::%d check(s) are INERT and were NOT treated as "
              "failures because --allow-inert was passed: %s" % (len(inert), ", ".join(inert)))
        print("::warning::An INERT check cannot fail, so it protects nothing. "
              "Either fix the gate or stop treating it as coverage.")
    if failed:
        print()
        print("::error::QA loop FAILED: %s" % ", ".join(failed))

    return 1 if (failed or (inert and not args.allow_inert)) else 0


if __name__ == "__main__":
    sys.exit(main())
