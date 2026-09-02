#!/usr/bin/env python3
"""v0.48.0 cascade (v2): wrap every function body that contains
check(/require( in a `try { ... } catch { PreconditionError::Violated(loc) => abort(...) }` block.

Supports multi-line fn headers (the previous version only matched
single-line headers and missed did.mbt, data.mbt, etc., which have
6-7 line headers with default-valued parameters).

Preserves the pre-v0.48.0 abort behavior at every call site.
Idempotent: a body already wrapped (first non-blank line after the
opening `{` is `try {`) is skipped.

Run from project root. Operates on `*.mbt` in cwd, skipping any file
under `_build`, `_verify`, `.archived`, or ending in `.archived`.
"""
import os
import re
import sys
from pathlib import Path

FN_START_RE = re.compile(r'^((?:pub(?:\([^)]+\))?\s+)?fn\s+[A-Za-z_]\w*(?:::\w+)?)')
CHECK_RE = re.compile(r'\b(?:check|require)\s*\(')


def find_fn_header_end(lines, start):
    """Return the index of the line that contains the opening `{` of the
    fn body, scanning forward from the line that contains `fn ...`.
    Tracks `(`/`)` balance for default-valued multi-line parameters,
    and looks for the first unbalanced `{` after the closing `)`.
    Returns None if the header is malformed.
    """
    paren_depth = 0
    seen_paren_open = False
    for i in range(start, len(lines)):
        line = lines[i]
        for ch in line:
            if ch == '(':
                paren_depth += 1
                seen_paren_open = True
            elif ch == ')':
                paren_depth -= 1
                if paren_depth == 0 and seen_paren_open:
                    # Now look for '{' on this line or subsequent lines.
                    for j in range(i, len(lines)):
                        if '{' in lines[j]:
                            return j
                    return None
    return None


def brace_body_end(lines, start):
    """Return the index of the line containing the closing `}` for the
    brace opened at line `start`. Skips braces inside line comments
    (`//`) and string literals.
    """
    depth = 0
    in_str = False
    for i in range(start, len(lines)):
        line = lines[i]
        j = 0
        while j < len(line):
            ch = line[j]
            if in_str:
                if ch == '\\' and j + 1 < len(line):
                    j += 2
                    continue
                if ch == '"':
                    in_str = False
                j += 1
                continue
            if ch == '"':
                in_str = True
            elif ch == '/' and j + 1 < len(line) and line[j + 1] == '/':
                break
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    return i
            j += 1
    raise ValueError(f"unbalanced brace from line {start + 1}")


def find_first_opening_brace_on_line(line):
    """Return the index of the first '{' in `line`, ignoring chars
    inside line comments and string literals.
    """
    in_str = False
    j = 0
    while j < len(line):
        ch = line[j]
        if in_str:
            if ch == '\\' and j + 1 < len(line):
                j += 2
                continue
            if ch == '"':
                in_str = False
            j += 1
            continue
        if ch == '"':
            in_str = True
        elif ch == '/' and j + 1 < len(line) and line[j + 1] == '/':
            return -1
        elif ch == '{':
            return j
        j += 1
    return -1


def already_wrapped(lines, body_start_line):
    """Check if the body at body_start_line is already wrapped: the
    first non-blank line after the opening `{` is `try {`.
    """
    for k in range(body_start_line + 1, min(body_start_line + 5, len(lines))):
        s = lines[k].strip()
        if s == '':
            continue
        return s == 'try {'
    return False


def indent_of(line):
    m = re.match(r'^(\s*)', line)
    return m.group(1) if m else ''


def process_file(path: Path) -> bool:
    src = path.read_text(encoding='utf-8')
    lines = src.split('\n')

    # Collect fn header starts in document order; then re-scan in
    # reverse for application. We need body_start_line and body_end_line
    # for each fn that has check/require in body and is not yet wrapped.
    fns = []
    for i, line in enumerate(lines):
        m = FN_START_RE.match(line)
        if not m:
            continue
        # Skip lambda-style `let fn_name = ...` (rare; treat as fn-def anyway)
        body_open_line = find_fn_header_end(lines, i)
        if body_open_line is None:
            continue
        try:
            body_end_line = brace_body_end(lines, body_open_line)
        except ValueError:
            continue
        body_text = '\n'.join(lines[body_open_line + 1:body_end_line])
        if not CHECK_RE.search(body_text):
            continue
        if already_wrapped(lines, body_open_line):
            continue
        fns.append((body_open_line, body_end_line))
    if not fns:
        return False

    # Apply wraps in reverse so earlier indices stay valid.
    for body_open_line, body_end_line in reversed(fns):
        # body_open_line is the line with the opening `{`.
        open_line = lines[body_open_line]
        open_brace_idx = find_first_opening_brace_on_line(open_line)
        if open_brace_idx < 0:
            continue
        # Determine indentation of the header line by looking at the
        # first non-empty line going up from body_open_line. Actually
        # we want the indent of the fn header (line above body_open_line
        # is the header continuation; find the line with `fn`).
        # Simpler: indent of the catch block should match the indent
        # of `pub fn` / `fn` keyword. Find the line above that has
        # the smallest indent (the fn header).
        header_indent = indent_of(lines[body_open_line])
        for j in range(body_open_line - 1, max(body_open_line - 20, -1), -1):
            jt = lines[j].strip()
            if not jt or jt.startswith('///') or jt.startswith('//'):
                continue
            if 'fn ' in lines[j]:
                header_indent = indent_of(lines[j])
                break

        # Split the open_line at the first '{': everything before '{'
        # stays on the open_line (this is the fn signature), and we
        # open `try {` immediately after.
        before_brace = open_line[:open_brace_idx + 1]  # includes '{'
        after_brace = open_line[open_brace_idx + 1:]
        # Build new structure:
        #   before_brace
        #   try {
        #   <existing body, including after_brace on the same line as new body>
        #   } catch {
        #     PreconditionError::Violated(loc) => abort(...)
        #   }
        #   (body_end_line is the line that contains the closing '}' of
        #    the function; we prepend `} catch { ... }` before it.)

        body_indent = header_indent + '  '
        try_line = body_indent + 'try {'
        catch_block = [
            body_indent + '} catch {',
            body_indent + '  PreconditionError::Violated(loc) => abort("precondition failed at " + loc.to_string())',
            body_indent + '}',
        ]

        # The line that contained the opening '{' becomes the signature
        # line (drop after_brace; it gets moved into the body with
        # +1 indent if non-empty). If after_brace is just whitespace,
        # the body effectively starts on the next line.
        new_open_line = before_brace.rstrip()
        if after_brace.strip():
            # Move after_brace to a new line with body_indent
            body_first = body_indent + after_brace.strip()
            new_body_section = [try_line, body_first]
        else:
            new_body_section = [try_line]

        new_lines = (
            lines[:body_open_line]
            + [new_open_line]
            + new_body_section
            + lines[body_open_line + 1:body_end_line]
            + catch_block
            + lines[body_end_line:]
        )
        lines = new_lines

    new_src = '\n'.join(lines)
    if new_src != src:
        path.write_text(new_src, encoding='utf-8')
        return True
    return False


def main():
    root = Path('.')
    targets = []
    for p in root.glob('*.mbt'):
        if '.archived' in p.name:
            continue
        if 'archived' in p.name:
            continue
        targets.append(p)
    targets.sort()
    changed = []
    for p in targets:
        if process_file(p):
            changed.append(str(p))
    if changed:
        print(f"WRAPPED {len(changed)} files:")
        for c in changed:
            print(f"  {c}")
    else:
        print("No files needed wrapping (already done or no check/require sites).")


if __name__ == '__main__':
    main()
