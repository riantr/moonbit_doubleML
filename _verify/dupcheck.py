"""Duplicate code detection for MoonBit sources.

Normalizes each line (strip comments / whitespace), then uses a
sliding-window hash to find repeated blocks of >= MIN_BLOCK lines
across production .mbt files. Reports the largest non-overlapping
duplicate groups.
"""

import hashlib
import sys
from collections import defaultdict
from pathlib import Path

MIN_BLOCK = 12


def normalize(line: str) -> str:
    # Strip line comments and whitespace; drop blank lines.
    s = line.split("//")[0].strip()
    return " ".join(s.split())


def load_lines(path: Path):
    with open(path, encoding="utf-8") as f:
        raw = f.readlines()
    out = []  # (normalized, original_lineno)
    for i, ln in enumerate(raw, start=1):
        n = normalize(ln)
        if n:
            out.append((n, i))
    return out


def main() -> int:
    root = Path(__file__).parent.parent
    files = sorted(
        p
        for p in root.glob("*.mbt")
        if not p.name.endswith("_test.mbt") and not p.name.endswith(".archived")
    )
    print(f"Scanning {len(files)} production .mbt files (blocks >= {MIN_BLOCK} lines)\n")

    # Hash every window of size MIN_BLOCK across all files.
    windows = []  # (file, lineno, h)
    index = defaultdict(list)
    for p in files:
        lines = load_lines(p)
        norm = [n for n, _ in lines]
        linenos = [l for _, l in lines]
        for i in range(len(norm) - MIN_BLOCK + 1):
            block = "\n".join(norm[i : i + MIN_BLOCK])
            h = hashlib.md5(block.encode()).hexdigest()
            windows.append((p.name, linenos[i], h))
            index[h].append((p.name, linenos[i]))

    # Duplicate groups: same hash appearing in 2+ distinct locations.
    dups = {h: locs for h, locs in index.items() if len(locs) >= 2}
    if not dups:
        print("NO DUPLICATE BLOCKS FOUND")
        return 0

    # Merge overlapping windows into maximal regions per file pair.
    by_pair = defaultdict(set)
    for h, locs in dups.items():
        for a in locs:
            for b in locs:
                if a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]):
                    by_pair[(a[0], b[0])].add((a[1], b[1]))

    total_dup_lines = 0
    print("Duplicate block groups (>= {} identical normalized lines):".format(MIN_BLOCK))
    print("=" * 72)
    for (fa, fb), pairs in sorted(by_pair.items()):
        pairs = sorted(pairs)
        # Merge chains: consecutive line pairs differing by 1 extend the region.
        merged = []
        cur = None
        for la, lb in pairs:
            if cur and la == cur[0] + cur[4] and lb == cur[2] + cur[4]:
                cur = (cur[0], fa, cur[2], fb, cur[4] + 1)
            else:
                if cur:
                    merged.append(cur)
                cur = (la, fa, lb, fb, 1)
        if cur:
            merged.append(cur)

        for m in merged:
            length = m[4]
            if length < MIN_BLOCK:
                continue
            total_dup_lines += length
            print(
                f"  {fa}:{m[0]}-{m[0]+length-1}  <->  {fb}:{m[2]}-{m[2]+length-1}"
                f"   ({length} lines)"
            )
    print("=" * 72)
    print(f"Total duplicated lines in merged regions: {total_dup_lines}")
    return 0 if total_dup_lines == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
