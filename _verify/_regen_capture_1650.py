#!/usr/bin/env python3
"""Regenerate `_verify/_upstream_defaults_1540.txt` from `_verify/_upstream_defaults_1540.py`.

WHY THIS EXISTS.  The record `PORT_VS_UPSTREAM_DEFAULTS_1540.md` cites the
capture as "raw upstream capture".  It was stored as **UTF-16** (so it read as
mojibake in most tools), and it was **truncated** -- it stopped before the
script's learner-defaults section, so it was not the script's output at all.
A reader who re-ran the script and diffed it against the file saw a
difference and had no way to tell which was authoritative.

This script makes the file authoritative by construction: it runs the capture
script, writes its stdout as **UTF-8 / LF**, and then asserts that the file
on disk is byte-identical to a fresh run.  A failure here is a real failure.

Run:  python _verify/_regen_capture_1650.py
Exit: 0 only if the file on disk matches a fresh run byte for byte.
"""
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "_verify" / "_upstream_defaults_1540.py"
CAPTURE = ROOT / "_verify" / "_upstream_defaults_1540.txt"

run = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, cwd=str(ROOT))
if run.returncode != 0:
    print(f"capture script FAILED (exit {run.returncode})")
    print(run.stderr.decode("utf-8", errors="replace"))
    raise SystemExit(1)

text = run.stdout.decode("utf-8", errors="strict").replace("\r\n", "\n")
CAPTURE.write_bytes(text.encode("utf-8"))

on_disk = CAPTURE.read_bytes()
again = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, cwd=str(ROOT))
fresh = again.stdout.decode("utf-8", errors="strict").replace("\r\n", "\n").encode("utf-8")

print(f"capture script : {SCRIPT.name} (exit {run.returncode})")
print(f"capture file   : {CAPTURE.relative_to(ROOT)}")
print(f"  bytes        : {len(on_disk)}")
print(f"  encoding     : utf-8, LF-only ({on_disk.count(b'\r')} CR bytes)")
print(f"  BOM          : {on_disk[:3] == b'\xef\xbb\xbf'}")
print(f"  lines        : {text.count(chr(10))}")
print(f"re-run byte-identical to the file on disk: {on_disk == fresh}")

if on_disk != fresh:
    raise SystemExit("FAIL: the capture on disk does not match a fresh run")
print("OK")
