"""Shared parser for `examples/parity`.

Ten of the twenty-four `validate_*_with_python.py` scripts previously could not
run MoonBit at all -- no `subprocess`, no `os.system` -- so they computed a
Python-only reference, printed a trailing `PASS`, and CI grepped for it. No
change to the port could turn them red.

`examples/parity/main.mbt` emits what those ten need, in a deliberately trivial
format:

    section <name>
    val <label> <double>
    data <name> <n> <double> ...
    end

This module runs that emitter once and hands the caller its section. Two rules
it enforces, because both have bitten this repo before:

1. **A missing section raises.** If the emitter stops emitting `rdd`, the RDD
   validator must fail, not quietly compare nothing and print PASS.
2. **A missing value raises.** Same reason, one level down.

A helper that returns an empty dict on failure is how ten checks end up unable
to fail.
"""
from __future__ import annotations

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
EXAMPLE = "examples/parity"

_CACHE: dict | None = None


class ParityError(RuntimeError):
    pass


def run_parity(example: str = EXAMPLE, timeout: int = 1800) -> str:
    """Run the emitter and return its raw stdout. Raises on a non-zero exit."""
    result = subprocess.run(
        ["moon", "run", example, "--target", "native"],
        cwd=ROOT, capture_output=True, text=True, timeout=timeout,
        encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        err = (result.stderr or result.stdout or "").strip()
        raise ParityError(
            "`moon run %s` exited %d.\n%s" % (example, result.returncode, err[-800:]))
    return result.stdout


def parse(out: str) -> dict:
    """-> {section_name: {"val": {...}, "data": {...}, "err": [...]}}"""
    sections: dict = {}
    cur = None
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "section":
            cur = parts[1]
            sections[cur] = {"val": {}, "data": {}, "err": []}
        elif parts[0] == "end":
            cur = None
        elif cur is None:
            continue
        elif parts[0] == "val" and len(parts) >= 3:
            sections[cur]["val"][parts[1]] = float(parts[2])
        elif parts[0] == "data" and len(parts) >= 3:
            n = int(parts[2])
            sections[cur]["data"][parts[1]] = [float(t) for t in parts[3:3 + n]]
        elif parts[0] == "err":
            sections[cur]["err"].append(" ".join(parts[1:]))
    return sections


def section(name: str, example: str = EXAMPLE, cached: bool = True) -> dict:
    """One section, or raise. `cached` reuses this process's single run."""
    global _CACHE
    if cached and _CACHE is None:
        _CACHE = parse(run_parity(example))
    if cached and _CACHE is not None:
        all_sections = _CACHE
    else:
        all_sections = parse(run_parity(example))
    if name not in all_sections:
        raise ParityError(
            "examples/parity did not emit a `%s` section (it emitted: %s). "
            "A validator that cannot find its data must fail, not pass "
            "vacuously." % (name, ", ".join(sorted(all_sections)) or "nothing"))
    return all_sections[name]


def val(sec: dict, label: str) -> float:
    if label not in sec["val"]:
        raise ParityError(
            "section has no value %r (it has: %s)"
            % (label, ", ".join(sorted(sec["val"])) or "nothing"))
    return sec["val"][label]


def data(sec: dict, name: str) -> list:
    if name not in sec["data"]:
        raise ParityError(
            "section has no data %r (it has: %s)"
            % (name, ", ".join(sorted(sec["data"])) or "nothing"))
    return sec["data"][name]


def report(title: str, rows: list, ok: bool) -> int:
    """Print the per-row evidence and the trailing verdict line CI greps for.

    `rows` is [(label, moonbit_repr, python_repr, passed_bool)].
    """
    print("=" * 74)
    print(title)
    print("=" * 74)
    bad = []
    for label, mb, py, good in rows:
        mark = "MATCH " if good else "DIFFER"
        if not good:
            bad.append(label)
        print("  %-6s %-22s moonbit=%-24s python=%s"
              % (mark, label, mb, py))
    print()
    print("checked %d item(s) against the MoonBit build" % len(rows))
    if bad:
        print("items that disagree: %s" % ", ".join(bad))
    verdict = "PASS" if ok and not bad else "FAIL"
    print("%s: %s" % (title, verdict))
    return 0 if verdict == "PASS" else 1
