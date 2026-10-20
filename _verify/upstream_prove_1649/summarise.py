#!/usr/bin/env python3
"""Summarise the re-audit logs: per case, which stage it reached and which
`Error: [NNNN]` diagnostics the proof frontend produced.

The distinction that matters on native Windows:
  * the proof FRONTEND runs before Why3, and emits `Error: [4207]` for a
    contract it cannot lower -- these are real and platform-independent;
  * the WHY3 stage needs to create an output directory, which fails on
    native Windows under the `\\\\?` extended-length path prefix.

A case that reports 4207 errors and never reaches the Why3 stage is a real
rejection.  A case that reports NO 4207 errors and then dies in the Why3
stage is a platform failure, not a proof outcome.  The control case is what
tells the two apart.
"""
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")

ERR_RE = re.compile(r"Error: \[(\d+)\]")
BOX = re.compile(r"\u2591|\u2588|\u2592|\u2593|\u2500|\u2502|\u256d|\u2570|\u256e|\u2514")

PLATFORM_MARKERS = ("Unix.Unix_error", "anomaly:")


def parse(name):
    p = os.path.join(OUT, name + ".log")
    if not os.path.exists(p):
        return None
    text = open(p, encoding="utf-8", errors="replace").read()
    codes = ERR_RE.findall(text)
    platform = any(m in text for m in PLATFORM_MARKERS)
    # Pull the diagnostic message lines: they are the ASCII ones that follow
    # a box-drawing location block.
    msgs = []
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if "Error: [" in ln:
            for j in range(i + 1, min(i + 8, len(lines))):
                cand = lines[j]
                if not cand.strip():
                    continue
                if BOX.search(cand):
                    continue
                cand = cand.strip()
                if cand.startswith("\u2588") or cand.startswith("\u2592"):
                    continue
                msgs.append(cand)
                break
    return {"codes": codes, "platform": platform, "msgs": msgs,
            "text": text}


def main():
    cases = sorted(f[:-4] for f in os.listdir(OUT) if f.endswith(".log"))
    print("%-22s %-14s %-9s %s" % ("case", "stage", "n_err", "diagnostics"))
    print("-" * 100)
    for c in cases:
        r = parse(c)
        if r is None:
            continue
        n4207 = sum(1 for x in r["codes"] if x == "4207")
        other = [x for x in r["codes"] if x != "4207"]
        if r["platform"]:
            stage = "why3-stage"
        elif n4207:
            stage = "frontend"
        else:
            stage = "other"
        seen = []
        for m in r["msgs"]:
            if m not in seen:
                seen.append(m)
        print("%-22s %-14s %-9s %s" % (
            c, stage, len(r["codes"]),
            ("; ".join(seen)[:70] if seen else "")))
        if other:
            print("%-22s %-14s %-9s other error codes: %s"
                  % ("", "", "", sorted(set(other))))
    print()
    print("legend: 'frontend' = the proof frontend rejected the contract and")
    print("        the Why3 stage was never reached -> a real rejection.")
    print("        'why3-stage' = no frontend rejection; the run died in the")
    print("        Why3 harness -> a platform failure, not a proof outcome.")


if __name__ == "__main__":
    main()
