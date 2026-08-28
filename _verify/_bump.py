"""Bump moon.mod version with CRLF + no BOM preservation.

Usage: python _verify/_bump.py 0.36.0

Auto-detects the current version (everything before the bump was
applied) by reading `version = "X.Y.Z"` from moon.mod.
"""
import re
import sys
from pathlib import Path

target = sys.argv[1]  # e.g. "0.36.0"
p = Path("moon.mod")
b = p.read_bytes()
# Find the current version line (whatever it is, as long as it's
# in `version = "X.Y.Z"` form).
m = re.search(rb'version = "(\d+\.\d+\.\d+)"', b)
if not m:
    raise SystemExit("could not find version line in moon.mod")
old_version = m.group(1).decode()
old_marker = f'version = "{old_version}"'.encode()
new_marker = f'version = "{target}"'.encode()
new = b.replace(old_marker, new_marker, 1)
# ensure CRLF and no BOM
new = new.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
if new[:3] == b'\xef\xbb\xbf':
    new = new[3:]
p.write_bytes(new)
print(f"Bumped {old_version} -> {target}, CRLF={new.count(b'\r\n')}, BOM={new[:3] == b'\xef\xbb\xbf'}")