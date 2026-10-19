#!/usr/bin/env python3
"""v0.153.0 -- snapshot / compare every tracked .mbt file around `moon fmt`.

Why this exists: `moon fmt` is whole-package and, in another repo in this
workspace, it silently rewrote every `.mbt` from LF to CRLF. Here `moonbit_doubleML`
is LF-only and must stay that way, so the line-ending convention is captured
BEFORE the rewrite and compared after.

Usage:
  python _fmt_snapshot_1530.py save   <out.json>
  python _fmt_snapshot_1530.py check  <snapshot.json>
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The git root is the OUTER `DoubleMachineLearning` directory, so running
# `git ls-files` from there lists paths relative to THAT root and mixes in the
# sibling projects. Running it from `moonbit_doubleML` scopes to this subtree
# and returns paths relative to it, which is what `ROOT` already is.
REPO = ROOT


def tracked_mbt():
    # NOT `git ls-files "*.mbt"`: that pathspec matched only 7 root-level files
    # here instead of all 242, because the pattern is applied without
    # FNM_PATHNAME. List everything and filter by suffix instead.
    out = subprocess.run(
        ["git", "ls-files"],
        cwd=REPO,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=300,
    )
    paths = [
        REPO / p
        for p in out.stdout.splitlines()
        if p.strip().endswith(".mbt") and (REPO / p).exists()
    ]
    # Untracked-but-present package files (the two new gate files this round)
    # must be covered too -- they are about to be formatted.
    for p in sorted((ROOT).glob("*.mbt")):
        if p not in paths:
            paths.append(p)
    return sorted(set(paths))


def stats(p: Path):
    b = p.read_bytes()
    crlf = b.count(b"\r\n")
    lf = b.count(b"\n") - crlf
    return {
        "sha": hashlib.sha256(b).hexdigest(),
        "bytes": len(b),
        "crlf": crlf,
        "lf": lf,
        "bom": b[:3] == b"\xef\xbb\xbf",
    }


def main():
    mode = sys.argv[1]
    if mode == "save":
        snap = {str(p.relative_to(REPO)).replace("\\", "/"): stats(p)
                for p in tracked_mbt()}
        Path(sys.argv[2]).write_text(json.dumps(snap, indent=1), encoding="utf-8")
        total_crlf = sum(v["crlf"] for v in snap.values())
        total_lf = sum(v["lf"] for v in snap.values())
        print(f"snapshotted {len(snap)} .mbt files")
        print(f"  total CRLF line-ends : {total_crlf}")
        print(f"  total bare-LF line-ends: {total_lf}")
        print(f"  files with any CRLF   : {sum(1 for v in snap.values() if v['crlf'])}")
        print(f"  files with a BOM      : {sum(1 for v in snap.values() if v['bom'])}")
        return 0

    if mode == "check":
        before = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
        changed, crlf_flip, bom_now = [], [], []
        for rel, v in before.items():
            p = REPO / rel
            if not p.exists():
                changed.append((rel, "DELETED"))
                continue
            now = stats(p)
            if now["sha"] != v["sha"]:
                changed.append((rel, "changed"))
            if now["crlf"] and not v["crlf"]:
                crlf_flip.append(rel)
            if now["bom"] and not v["bom"]:
                bom_now.append(rel)
        added = []
        for p in tracked_mbt():
            rel = str(p.relative_to(REPO)).replace("\\", "/")
            if rel not in before:
                added.append(rel)

        print(f"files before          : {len(before)}")
        print(f"content changed       : {len(changed)}")
        print(f"  -> {', '.join(r for r, _ in changed) if changed else '(none)'}")
        print(f"new files (not snapsh.): {len(added)}")
        print()
        print(f"*** CRLF INTRODUCED   : {len(crlf_flip)}")
        for r in crlf_flip:
            print(f"  !! {r}")
        print(f"*** BOM INTRODUCED    : {len(bom_now)}")
        for r in bom_now:
            print(f"  !! {r}")
        after_crlf = sum(stats(p)["crlf"] for p in tracked_mbt() if p.exists())
        print(f"total CRLF line-ends now: {after_crlf}")
        return 1 if (crlf_flip or bom_now) else 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
