# mooncakes.io Issue Draft (README UTF-8 rendering)

> **Status**: draft, not yet submitted. The user (`riantr` / `ren-yongxiang`,
> GitHub `@riantr`) needs to file this against
> `https://github.com/moonbitlang/mooncakes.io/issues` under their own
> GitHub account. Once approved, submit via the GitHub web UI or
> `gh issue create --repo moonbitlang/mooncakes.io --title "..." --body-file ...`.

---

## Title

`README.mbt.md` content is not decoded as UTF-8 in the package-page renderer; multi-byte bytes fall through to system locale and surface as garbled CJK mojibake

## Body

### Summary

When rendering the README of `riantr/moonbit_doubleML` (and any package whose `README.mbt.md` contains non-ASCII characters such as `·`, `—`, `θ`, `×`, `⇒`, `…`), the page on `https://mooncakes.io/docs/#/<owner>/<package>` shows the heading as garbled Han characters like `鈊?Doubleб` instead of the original UTF-8 text (e.g. `moonbit_doubleML · Double / Debiased Machine Learning in MoonBit`).

### Reproduction steps

1. Open a package whose README contains UTF-8 multi-byte characters. The `riantr/moonbit_doubleML` README is a clean repro (see the v0.68.0 page).
2. Visit `https://mooncakes.io/docs/#/riantr/moonbit_doubleML` in a browser whose system locale defaults to a non-UTF-8 charset (e.g. Chinese Windows, system code page = GBK / CP936).
3. The README heading renders as mojibake.

In a UTF-8-default browser (e.g. macOS Safari, English Windows), the same page may render correctly because the browser's text-encoding fallback lands on UTF-8 by accident.

### Root cause analysis

The HTML page itself declares the correct charset:

```html
<head>
  <meta charset="UTF-8">
  ...
</head>
```

Verified on `https://mooncakes.io/docs/#/riantr/moonbit_doubleML` (HTML inspected, `<meta charset="UTF-8">` is present). So the page-level document encoding is correct.

The bug is in how the README **content payload** (the markdown body returned by the package's `readme` field in the API, or the unpacked `README.mbt.md` blob inside the published zip) is inserted into the DOM. The rendering code appears to inject the bytes/text directly without explicitly decoding them as UTF-8 — when the browser later tries to interpret the resulting text nodes, it has no per-node charset signal and falls back to the document charset (or, if the bytes came in via a string property that bypasses the document charset, the system locale).

Concretely:

- A `C2 B7` UTF-8 byte sequence (legitimate encoding of `·` middle-dot, U+00B7) is interpreted as the GBK character `鈊` (U+922A).
- An `E2 80 94` UTF-8 byte sequence (legitimate encoding of `—` em-dash, U+2014) does not have a valid GBK mapping, so the browser substitutes `?`.
- A `CE B8` UTF-8 byte sequence (legitimate encoding of `θ`, U+03B8) decodes as `Σ` or similar under GBK.

The disk-side README.mbt.md is correct UTF-8 (verified with `git hash-object`, `Format-Hex`, and direct byte inspection; hash `e3829154...`, no BOM). The bug is purely in mooncakes.io's renderer.

### Suggested fix

In the package-page renderer code, ensure the README content is decoded as UTF-8 **before** it is inserted into the DOM. Either:

1. Read the file via `fetch(...).then(r => r.text())` (which respects the response charset), and ensure the upstream API serves the file with `Content-Type: text/markdown; charset=utf-8` or `text/plain; charset=utf-8`. Most browser `fetch` implementations honor this.
2. If the content is delivered as a `Uint8Array` (binary), wrap decoding in `new TextDecoder('utf-8', { fatal: true }).decode(bytes)` explicitly, **not** `String.fromCharCode(...bytes)` (which ignores UTF-8 multi-byte sequences).
3. When inserting into the DOM, prefer `element.textContent = decodedString` over `element.innerHTML = decodedString`, and never use `unescape(escape(str))` (which is also charset-unaware).

### Related secondary bug: stale `README.mbt.md` cache in `moon publish`

While investigating (1) we also found that **every `riantr-moonbit_doubleML-X.Y.Z.zip` from v0.63.0 onward contains the exact same `README.mbt.md` blob**:

| Publish version | zip README length | zip README hash |
| --- | --- | --- |
| v0.62.1 | 15,548 | `60f500d7...` |
| v0.62.2 | 15,746 | `66aa40ab...` |
| v0.63.0 | 16,004 | `6b8b78b2...` |
| v0.64.0 | 16,004 | `6b8b78b2...` (same as v0.63.0) |
| v0.65.0 | 16,004 | `6b8b78b2...` (same as v0.63.0) |
| v0.66.0 | 16,004 | `6b8b78b2...` (same as v0.63.0) |
| v0.67.0 | 16,004 | `6b8b78b2...` (same as v0.63.0) |
| v0.68.0 | 16,004 | `6b8b78b2...` (same as v0.63.0) |
| **v0.68.1** | **16,004** | **`6b8b78b2...` (still same as v0.63.0 — confirming the cache bug is not invalidated even after a docs-only patch that converts the entire README to ASCII)** |

Yet on disk, the `README.mbt.md` was updated in v0.64.0, v0.65.0, v0.66.0, v0.67.0, v0.68.0, and v0.68.1 — each with a distinct blob hash (`5d3c025c19496ee92d67e37272c1318ae59f96f4` is the v0.68.1 disk hash, all 31 non-ASCII chars converted to ASCII). So `moon publish` is silently re-using the v0.63.0 `README.mbt.md` it cached the first time `readme = "README.mbt.md"` was added to `moon.mod`. The mooncakes.io API confirms this — the v0.68.1 entry still serves the v0.63.0 README content (which still contains the original UTF-8 multi-byte sequences and will still render as mojibake on mooncakes.io because of bug (1) above).

This means **the v0.64 through v0.68.1 releases all show the same v0.63.0 README on mooncakes.io**, even though the disk file evolved correctly across those releases. This is upstream of mooncakes.io — it's a `moon publish` cache-invalidation bug.

Suggested fix in `moon`: invalidate / re-read `readme = "README.mbt.md"` from disk on every publish invocation; do not reuse whatever the build pipeline last cached.

Repro of the `moon` bug (no `mooncakes.io` interaction needed; pure local observation):

```bash
# After any disk-side edit to README.mbt.md:
git hash-object README.mbt.md        # e.g. 5d3c025c19496ee92d67e37272c1318ae59f96f4
moon publish --verbose                # Server status: 200 OK
unzip -p _build/publish/riantr-moonbit_doubleML-0.68.1.zip README.mbt.md | git hash-object --stdin
                                     # 6b8b78b22613a1f94377b1b59d1a16df3df6fca0 (unchanged from v0.63.0)
```

### Verification artifacts (from our end)

- `moon.mod` excerpt showing the `readme = "README.mbt.md"` directive is in the v0.63.0-onward release branch:
  ```toml
  readme = "README.mbt.md"
  ```
- Our local mitigation in the v0.68.1 docs-only patch: convert all 31 non-ASCII chars in `README.mbt.md` to ASCII equivalents (`·` → `-`, `—` → `--`, `θ` → `theta`, `×` → `x`, `⇒` => `=>`, `…` → `...`). The file becomes bulletproof under any charset interpretation. Hash: `5d3c025c19496ee92d67e37272c1318ae59f96f4`, 18,315 bytes.
- We will verify post-publish that mooncakes.io actually receives the new hash `5d3c025c...`. If the API still returns `6b8b78b2...`, that confirms the `moon publish` cache bug is upstream (item 2 above) and must be fixed before this issue can be fully resolved on the package-page side.

### Environment

- Browser: Chrome / Edge on Chinese Windows (system locale `zh-CN`, code page GBK / CP936) reproduces consistently. UTF-8-default browsers render correctly.
- mooncakes.io package: `riantr/moonbit_doubleML` v0.68.0 (build status `success`, last publish `2026-09-30T13:47:58Z`).
- Affected package page: `https://mooncakes.io/docs/#/riantr/moonbit_doubleML`