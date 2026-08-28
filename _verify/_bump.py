"""Bump moon.mod version with CRLF + no BOM preservation."""
import sys
from pathlib import Path
target = sys.argv[1]  # e.g. "0.35.0"
p = Path("moon.mod")
b = p.read_bytes()
old_marker = b'version = "0.34.0"'
new_marker = f'version = "{target}"'.encode()
new = b.replace(old_marker, new_marker, 1)
# ensure CRLF and no BOM
new = new.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
if new[:3] == b'\xef\xbb\xbf':
    new = new[3:]
p.write_bytes(new)
print(f"Wrote {p}, CRLF={new.count(b'\r\n')}, BOM={new[:3] == b'\xef\xbb\xbf'}")