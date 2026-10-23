"""Cut the 0.163.1 release: version, README sync, CHANGELOG promotion.

Order matters and follows the repo's release policy: local CI is already
green on 6a8b7bb, THEN every version reference in the README is synced, and
only then is the tag cut. The registry reads the README as it is at the tag,
so a tag cut before this would publish a README that disagrees with the
code.

The two test counts in the README were already stale -- it claimed
1116/1116/1116 and 1122 while the measured counts are 1117/1117/1117 and
1123. Those are corrected from a fresh `moon test` run, not from memory.

Encodings are explicit and verified after the write, because this tree mixes
them: README.mbt.md and moon.mod are LF-only with no BOM, while CHANGELOG.md
has a CRLF header and an LF body.
"""

import io
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLD_V, NEW_V = "0.163.0", "0.163.1"

README = os.path.join(REPO, "README.mbt.md")
MOD = os.path.join(REPO, "moonbit_doubleML", "moon.mod")
CHANGELOG = os.path.join(REPO, "CHANGELOG.md")

# --- README: exact, single-occurrence anchors -----------------------------
R_VERSION = "| `moon.mod` version | **%s** |" % OLD_V
R_VERSION_NEW = "| `moon.mod` version | **%s** |" % NEW_V

R_TESTS = "| Tests (native / wasm / js) | **1116 / 1116 / 1116** |"
R_TESTS_NEW = "| Tests (native / wasm / js) | **1117 / 1117 / 1117** |"

R_WASM = "| Tests (wasm-gc) | **1122 / 1122** (lib + 6 doc tutorials) |"
R_WASM_NEW = "| Tests (wasm-gc) | **1123 / 1123** (lib + 6 doc tutorials) |"

R_TAG = "python .github/scripts/ci_local.py run --all --release-tag v%s" % OLD_V
R_TAG_NEW = "python .github/scripts/ci_local.py run --all --release-tag v%s" % NEW_V

# New subsection, appended to the LPLR convergence discussion. Placed on the
# unique tail of that paragraph so the anchor cannot drift.
R_ANCHOR = ("one is about the sensitivity API surface, the other about an "
            "estimate.")
R_BLOCK = """

**Known divergence, reported and NOT gated: the small-n regime.** At n = 500
the port and upstream agree to ~0.007. That is one design point, and it is
the one this estimator was never wrong at. On identical rows and the
identical outer partition, below it:

| n | port | upstream | port `se` | upstream `se` |
|---|---|---|---|---|
| 60 | `-0.049` | `3.53962` | `0.762` | `20.199` |
| 100 | `14.431` (warns) | `-0.558127` | `751657` | `0.832026` |
| 160 | `0.580578` | `0.749398` | `0.777` | `0.588` |

91 of 200 small-n designs still warn where upstream warns zero times. This is
**reported by `pyexample_lplr.py` section 5 on every run and asserted by
nothing**, on purpose: a gate that is red forever gets ignored, which is
worse than no gate. The cause is pinned to the Newton step. The port damps
it (`lplr.mbt`, clamped to 0.25) and upstream does not -- scipy's Newton is
a bare `p = p0 - fval/fder`. Removing the damping is the faithful port and
does close the gap (11.4 -> 3.59 at n=60, 13.8 -> 0.086 at n=100), but it
reaches `se = NaN` by trial 2 of `examples/fuzz`, aborts on
`var_est.mbt:79`, and needs four gates conditioned on solver convergence --
while upstream is 0/300 non-finite on the same DGP. Two candidate causes
were implemented and measured: the `d_tilde` nuisance (falsified, trial 0 vs
trial 2) and the `a_hat` double cross-fit (falsified, gaps 4.6x and 5.1x
worse). Every other element is verified equivalent term by term. The
residual is recorded in `_verify/LPLR_GATE_BLINDNESS_1680.md` sections
13-16 rather than papered over with a guard whose justification would be a
guess."""


def read(p):
    with io.open(p, encoding="utf-8", newline="") as f:
        return f.read()


def write(p, t, eol="\n"):
    with io.open(p, "w", encoding="utf-8", newline=eol) as f:
        f.write(t)


def main():
    # ---- moon.mod --------------------------------------------------------
    m = read(MOD)
    old_line = 'version = "%s"' % OLD_V
    if m.count(old_line) != 1:
        raise SystemExit("moon.mod version anchor matched %d" % m.count(old_line))
    m = m.replace(old_line, 'version = "%s"' % NEW_V)
    write(MOD, m)

    # ---- README.mbt.md (LF only) ----------------------------------------
    r = read(README)
    if "\r" in r:
        raise SystemExit("README is not LF-only")
    for label, old, new in (
        ("version", R_VERSION, R_VERSION_NEW),
        ("tests", R_TESTS, R_TESTS_NEW),
        ("wasm-gc", R_WASM, R_WASM_NEW),
        ("release-tag", R_TAG, R_TAG_NEW),
    ):
        n = r.count(old)
        if n != 1:
            raise SystemExit("README %s anchor matched %d times" % (label, n))
        r = r.replace(old, new)
    if R_ANCHOR not in r:
        raise SystemExit("README anchor paragraph not found")
    if "Known divergence, reported and NOT gated" in r:
        raise SystemExit("small-n block already present")
    r = r.replace(R_ANCHOR, R_ANCHOR + R_BLOCK, 1)
    write(README, r)

    # ---- CHANGELOG.md (CRLF header, LF body -- replace heading in place) --
    c = read(CHANGELOG)
    head = "## [Unreleased]"
    if c.count(head) != 1:
        raise SystemExit("Unreleased heading matched %d" % c.count(head))
    c = c.replace(head, "## [%s]" % NEW_V, 1)
    write(CHANGELOG, c, eol="")

    # ---- verify every write ---------------------------------------------
    m2, r2, c2 = read(MOD), read(README), read(CHANGELOG)
    print("moon.mod version  :", 'version = "%s"' % NEW_V in m2)
    print("README version    :", R_VERSION_NEW in r2)
    print("README tests      :", R_TESTS_NEW in r2)
    print("README wasm-gc    :", R_WASM_NEW in r2)
    print("README release-tag:", R_TAG_NEW in r2)
    print("README small-n    :", "Known divergence, reported and NOT gated" in r2)
    print("CHANGELOG heading :", "## [%s]" % NEW_V in c2,
          "| Unreleased gone:", head not in c2)
    for name, txt in (("moon.mod", m2), ("README.mbt.md", r2)):
        print("%-14s BOM=%s CR=%s" % (name, txt.startswith("\ufeff"), "\r" in txt))
    print("CHANGELOG    BOM=%s CRLF=%d bareLF=%d"
          % (c2.startswith("\ufeff"), c2.count("\r\n"),
             c2.count("\n") - c2.count("\r\n")))
    stale = [s for s in (R_VERSION, R_TESTS, R_WASM, R_TAG) if s in r2]
    print("stale refs left in README:", stale)


if __name__ == "__main__":
    main()
