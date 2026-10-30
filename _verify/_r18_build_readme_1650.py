"""Round 18: build the user-facing README and the companion ENGINEERING.md.

The README that ships is the page a reader lands on.  It was 2290 lines, of
which roughly 1200 were an internal investigation narrative -- a history of
defects found and fixed in past releases, the CI harness's internals, and the
archaeology behind the upstream naming map.  None of that is something a user
of the library needs in order to use it.

So the document is split in two:

  README.mbt.md    the LIBRARY document -- what it is, how to install it, how
                   to call it, where its sharp edges are, what it does not
                   claim.  Shaped like the reference package page.
  ENGINEERING.md   the PROJECT document -- the README as it stood at
                   v0.164.11, in full, with a banner that says what it is.

THE LINE BETWEEN THEM
---------------------
A fact is in the README when a person who has run `moon add
riantr/moonbit_doubleML` and is writing code against the library would need it
to use the library correctly or to trust its output.  A fact is in
ENGINEERING.md when it describes this repository -- its CI, its QA registry, its
release history -- rather than the library.

42 verifiers pin 397 distinct strings in the README.  Every one of them is a
fact the project has established, so this rewrite KEEPS every user-facing one
IN the README, verbatim, and moves the project-facing ones to ENGINEERING.md
together with the checks that assert them.  Nothing is deleted: the ledger is
the whole previous README, word for word, and the new README is a condensation
of it.

THE SOURCE
----------
The pre-rewrite README is read from the released tag, not from a working-copy
backup, so this builder is re-runnable from any checkout:

    git cat-file blob v0.164.11:README.mbt.md

LF-only, no BOM, in and out.  The shipped copy
`moonbit_doubleML/README.mbt.md` is written byte-identically.

THE VERSION
-----------
The version comes from `moonbit_doubleML/moon.mod`, so this builder and the
bump script cannot disagree: the bump script changes `moon.mod` and then
calls this builder, and the README's version sites follow.

NOTE FOR A LATER ROUND
----------------------
This builder is PINNED to the v0.164.11 source.  Re-running it rebuilds the
README from that release, so it would revert any README edit made after
round 18.  A later round that edits the README must either update SRC_TAG
and the block ranges, or stop using this builder and edit the README
directly.  The round-18 verifier's pinned-literal census would catch such a
reversion, but the fix belongs to the round that caused it.

ROUND 20 ADDED A PATCH STEP, AND THAT IS THE MECHANISM
------------------------------------------------------
Round 20 found a gap in the API reference and fixed it here rather than in
README.mbt.md, because a direct edit would be reverted by the next bump.
The fix is a (old, new) pair applied to the assembled text, so the README is
still generated from one source and the fix travels with it.  A later round
that edits the README should add its own pair to PATCHES, not edit
README.mbt.md.

ROUND 21 ADDED A SECOND PAIR
----------------------------
Same mechanism, for a different kind of defect: two measured figures that the
measurements do not support.  The pair lives in PATCHES below, next to a
comment that carries the measurement it was derived from.  Two things follow
for whoever comes next:

  * The pair is applied to the ASSEMBLED text, so it must match exactly once.
    The builder aborts if it matches any other number of times -- that is the
    check that stops a patch from silently doing nothing.
  * A patch that changes a NUMBER is only as good as the measurement behind
    it.  The measurement is a tracked record
    (`_verify/_hazard_margins_1650.json`) and a tracked verifier
    (`_verify/_verify_hazard_margins_1650.py`) that checks the README against
    it.  A patched number with no witness is a new unverified claim.
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

# ------------------------------------------------------------------- the source
SRC_TAG = "v0.164.11"
BACKUP = "_r18_readme_before_1650.md"


def load_source():
    """The pre-rewrite README, from the released tag or the local backup."""
    try:
        out = subprocess.run(["git", "cat-file", "blob", "%s:README.mbt.md" % SRC_TAG],
                             cwd=ROOT, capture_output=True, text=True,
                             encoding="utf-8", errors="replace")
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout, "git %s:README.mbt.md" % SRC_TAG
    except OSError:
        pass
    if os.path.exists(BACKUP):
        return io.open(BACKUP, encoding="utf-8", newline="").read(), BACKUP
    raise SystemExit("no source: neither %s:README.mbt.md nor %s"
                     % (SRC_TAG, BACKUP))


SRC, SRC_FROM = load_source()
L = SRC.split("\n")


def blk(a, b):
    """Old-README lines a..b inclusive, verbatim."""
    return "\n".join(L[a - 1:b])


def ver():
    m = re.search(r'^version\s*=\s*"([^"]+)"',
                  io.open("moonbit_doubleML/moon.mod", encoding="utf-8").read(),
                  re.M)
    return m.group(1)


V = ver()


# ------------------------------------------------------------------- the pins
def dep_pin(pkg):
    """The version a package is pinned at in the library's own manifest.

    DERIVED, never typed in.  A pin the README hard-codes is a number that
    rots the moment the registry publishes the next version -- and the tree's
    own dep-pin check then fails on a document that was CORRECT when it was
    written.  Reading the pin from the manifest makes that class of staleness
    impossible: the README cannot name a pin the tree does not declare.
    """
    raw = io.open("moonbit_doubleML/moon.mod", encoding="utf-8").read()
    live = "\n".join(re.sub(r"//.*$", "", ln) for ln in raw.split("\n"))
    m = re.search(r'"%s@([^"]+)"' % re.escape(pkg), live)
    if not m:
        raise SystemExit("the manifest does not pin %s" % pkg)
    return m.group(1)


def dep_warn():
    """The `dependencies` check's WARN, as the QA harness words it.

    The harness is the authority.  This reproduces its rule -- the same three
    steps as `c_deps` in `.github/scripts/qa_loop/checks.py` -- so the README
    quotes the warning a reader will actually meet.
    `_verify/_verify_test_verification_1650.py` compares the quoted text
    against the LIVE harness output, so the two implementations cannot drift
    apart unnoticed.
    """
    raw = io.open("moonbit_doubleML/moon.mod", encoding="utf-8").read()
    live = "\n".join(re.sub(r"//.*$", "", ln) for ln in raw.split("\n"))
    imp = re.search(r"import\s*\{(.*?)\}", live, re.S)
    deps = re.findall(r'"([^"]+)"', imp.group(1)) if imp else []
    srcs = ""
    for b, d, fs in os.walk("moonbit_doubleML"):
        d[:] = [x for x in d if x not in ("_build", "_verify", "target", ".git")]
        for f in sorted(fs):
            if f.endswith(".mbt"):
                try:
                    srcs += io.open(os.path.join(b, f), encoding="utf-8",
                                    errors="replace").read()
                except OSError:
                    pass
    unused = [d for d in deps
              if d.split("@")[0].rsplit("/", 1)[-1] not in srcs]
    unofficial = [d for d in deps
                  if not d.startswith(("moonbitlang/", "riantr/"))]
    notes = []
    if unofficial:
        notes.append("non-conforming: %s" % unofficial)
    if unused:
        notes.append("declared but unreferenced by library code: %s" % unused)
    return "%d declared; %s" % (len(deps), "; ".join(notes))


def dep_warn_block():
    """The WARN, wrapped the way the README prints it."""
    w = dep_warn()
    w = w.replace("non-conforming: [", "non-conforming:\n[", 1)
    w = w.replace("unreferenced by library code: [",
                  "unreferenced by library code:\n[", 1)
    return w


ASYNC = dep_pin("moonbitlang/async")

# The toolchain this release was VERIFIED on -- and, since round 71, the floor
# a consumer needs.
#
# ONE place, on purpose.  A toolchain move is a move in FOUR places otherwise:
# the bare-`moon test` sentence, the Status table's Toolchain row, the parity
# line, and the Installation section's requirement.  Four literals are four
# chances to move one and forget three, and the one that is forgotten is the
# one a reader would have tripped over.
TOOLCHAIN = "0.1.20261028"

# --------------------------------------------------------------- the test counts
#
# The test totals are the most prominent numbers the README states, and until
# round 72 they were LITERALS inherited from the v0.164.11 base document.  A
# number inherited from a snapshot rots in silence: the next `.mbt` file
# carrying a `test "..."` changes the tree without changing the document.
#
# DERIVED here, by the SAME rule `_verify/_verify_testcounts_1610.py` uses --
# the same regex, the same de-duplication by name -- so the generator and the
# check that holds it cannot disagree about what "the test count" means.
def test_decls(directory):
    """the `test "..."` declarations under a directory, by name."""
    acc = set()
    for base, dirs, files in os.walk(directory):
        dirs[:] = [x for x in dirs if x not in ("_build", "_verify", "target", ".git")]
        for f in files:
            if f.endswith(".mbt"):
                src = io.open(os.path.join(base, f), encoding="utf-8",
                              errors="replace").read()
                acc.update(re.findall(r'\btest\s+"([^"]+)"', src))
    return acc


LIB_TESTS = len(test_decls("moonbit_doubleML"))
DOC_TESTS = len(test_decls("doc"))
WASMGC_TESTS = LIB_TESTS + DOC_TESTS

# --------------------------------------------------------- the vectorised surface
#
# `vectorized.mbt`'s public free functions, and the library files that route
# their residual extraction through `vector_subtract`.  The README states both,
# and until round 72 it stated FOUR helpers where the file exports SIX, and
# named two call sites where twelve library files call it.  NOTHING held the
# claim, which is exactly why it could rot: the helpers were added and the
# document was not.  Both halves are DERIVED now, and
# `_verify/_verify_vectorised_surface_1680.py` holds them.
def vectorised_surface():
    src = io.open("moonbit_doubleML/vectorized.mbt", encoding="utf-8",
                  errors="replace").read()
    fns = sorted(set(re.findall(r"pub fn (\w+)\s*\(", src)))
    callers = []
    for f in sorted(os.listdir("moonbit_doubleML")):
        if not f.endswith(".mbt") or f == "vectorized.mbt" or f.endswith("_test.mbt"):
            continue
        body = io.open(os.path.join("moonbit_doubleML", f), encoding="utf-8",
                       errors="replace").read()
        if "vector_subtract" in body:
            callers.append(f)
    return fns, callers


VEC_FNS, VEC_CALLERS = vectorised_surface()


def list_pieces(names):
    """the list, split so that the 'and' belongs to the last piece."""
    items = ["`%s`" % n for n in names]
    if len(items) == 1:
        return items
    return items[:-2] + [items[-2] + " and " + items[-1]]


def wrap_list(pieces, width):
    """the list, broken after the last piece that fits `width`.

    The list is DERIVED, so its length is not known when the sentence that
    holds it is written -- and a derived list that cannot be wrapped would
    land in the published document as one long line.  Breaking it here keeps
    the paragraph at the width the rest of the README uses.
    """
    out = []
    line = ""
    last = len(pieces) - 1
    for i, piece in enumerate(pieces):
        text = piece if i == last else piece + ","
        cand = (line + " " + text) if line else text
        if len(cand) > width and line:
            out.append(line)
            line = text
        else:
            line = cand
    if line:
        out.append(line)
    return "\n".join(out)


# ==============================================================================
# 1.  THE LEDGER -- the project document
# ==============================================================================
#
# The whole previous README, in full.  The blocks that moved into the new
# README are NOT removed from it: the ledger is the historical document, and a
# ledger that drops the parts a reader might want to check against is not a
# ledger.  The banner says so.

LEDGER_HEAD = """# ENGINEERING notes -- `moonbit_doubleML`

> **This is the companion to `README.mbt.md`, not a second README.** The
> README is the document a user of the library needs: what it is, how to
> install it, how to call it, and where its sharp edges are. Everything that
> is *about this project* rather than *about the library* -- the CI harness's
> internals, the QA registry, the release-by-release history of the defects
> that moved the estimator defaults, and the archaeology behind the upstream
> naming map -- lives here instead.
>
> It was split out of the README on 2026-10-21 (round 18). The README was
> 2290 lines; it is now a document a person can read end to end.
>
> **Nothing was deleted.** What follows is the README as it stood at
> `v0.164.11`, in full and word for word -- including the blocks that are now
> in the README, because a ledger that drops the parts a reader might want to
> check against is not a ledger. The new README is a condensation of it.
>
> The records that hold the *measurements* are in `_verify/` and are
> referenced from both documents.
>
> **Corrections, 2026-10-21.** This document's body is the README as it
> was published at `v0.164.11`, and a snapshot is not rewritten -- so the
> corrections live here, beside the corrected figures, and in
> `README.mbt.md`, which is the document the registry actually serves.
>
> * **Round 21.** The propensity-margin paragraph further down quotes a
>   **366x** separation for `DoubleMLIRM` and a **300x** one for
>   `DoubleMLAPO`.  Both figures were re-measured against the current tree
>   and are **367x** and **320x**.  The measurement is in
>   `_verify/_hazard_margins_1650.json`.
> * **Round 22.** The Examples section quotes **12** of the 16 CLI demos
>   printing a 95 % CI.  The count is **11**: the passage's own breakdown
>   names five demos that print none, and 16 - 5 = 11.  The 12 came from a
>   measuring regex whose last alternative matched ANY bracketed line, so
>   `examples/pava`'s `case[v0]` case label counted as an interval.  The
>   measurement is in `_verify/_cli_demo_ci_1650.json`.  Round 22 also
>   corrected thirteen passages of prose in the README -- among them a
>   paragraph that opened with half a sentence, a claim that one API shape
>   covered all 22 estimators when six constructors differ, and an estimator
>   list that summed to 21 under a headline that said 22.
> * **Round 23.** The opening sentence's "22 estimators in total" could be read
>   as UPSTREAM's count.  Upstream has **21** estimator classes -- the 19
>   name-identical ones plus `RDFlex` and `DoubleMLDIDCS` -- and the 22 is
>   this port's, which is what the next sentence's 19 + 2 + 1 says.  The
>   README now reads "with **22 estimators** in total".  The arithmetic
>   itself was never in doubt: `_verify/_verify_round16_provenance_1650.py`
>   derives the grouping from the INSTALLED upstream package.
> * **Round 24.** Two sentences used a bare count as a referent -- "the
>   largest margin of the four" and "all four earlier outcomes" -- without
>   saying which four.  They are the same four: `DoubleMLIRM`, `DoubleMLAPO`,
>   `DoubleMLAPOS` and `DoubleMLSSM`, the estimators migrated to a classifier
>   propensity by v0.138.0.  Both sentences now name them, and the set is
>   derived by `_verify/_verify_count_referents_1650.py` from the source's own
>   propensity defaults, so it cannot drift.  The QA LOOP's `gherkin` message
>   also read "29/29 mapped test names resolve", although 3 of the 29 are
>   prose citations that name no test at all; it now reports the split
>   recorded below -- 26 against real declarations, 3 prose-exempt -- so "All
>   29 resolve" means "29 of 29 under the check's own rule".
> * **Round 25.** Three NAMES in the README did not survive being used: the
>   LPLR snippet passed `alpha=1.5` to a constructor that has no `alpha`
>   (`alpha` is the DGP's), the nonlinear options were named by their
>   `LearnerDispatch` enum VARIANTS rather than by the package's constructor
>   functions, and the "21 runnable example binaries" bullet's own
>   decomposition summed to 19.  All three are fixed in the README, and the
>   LPLR snippet is fixed in the source docstring too.  The new check
>   `_verify/_verify_snippet_names_1650.py` derives every constructor's real
>   parameters from the package, so a snippet that passes a parameter that
>   does not exist is a failure, not a sentence.
> * **Round 26.** The upstream-provenance GROUPING was audited, and it was
>   right in the published README and wrong in three sibling documents.
>   `doc/001_introduction` named `DoubleMLDIDCrossSection` as "the one
>   port-only estimator"; `doc/004_estimators` stated the old grouping (20
>   name-matched, one renamed, one port-only) and called the port's
>   `DoubleMLDIDCS` "DID with repeated cross-sections" -- which is UPSTREAM's
>   `DoubleMLDIDCS`, the estimator this port calls
>   `DoubleMLDIDCrossSection`; and `skills/moonbit_doubleML.md` said "20
>   mirror upstream by name" and that `DoubleMLDIDCrossSection` "has no
>   upstream counterpart (port-only)".  All three predate
>   `_verify/UPSTREAM_PROVENANCE.md`, which was first tracked in v0.164.11,
>   so they were never reconciled with it.  The new check
>   `_verify/_verify_provenance_grouping_1650.py` derives the grouping from
>   the INSTALLED upstream package and the port's own source -- the one
>   shared name that is a coincidence is found mechanically (`DoubleMLDIDCS`:
>   upstream consumes the id-less `DoubleMLDIDData`, the port consumes the
>   id-bearing `DoubleMLDIDCSData`) -- and then checks that every document
>   which states the grouping states THAT one.
> * **Round 27.** The four TUTORIAL documents under `doc/` -- the ones a reader
>   opens AFTER the README, and which the README does not restate -- were
>   audited for the first time, and three of them carried false claims.
>   `doc/005_dgps` gave `make_irm_heterogeneous_data` the signature
>   `(n_obs, theta, seed)` when the source says `(n_obs, dim_x, seed)`, and
>   claimed every factory exposes `x_get()` / `y_get()` / `d_get()` when
>   `make_lplr_LZZ2020` returns an `LplrData` carrying `theta_get()` and
>   `data_get()` instead -- so the document's own usage example did not apply
>   to it.  `doc/003_quick_start` published three exact numbers and NOTHING
>   asserted them: the tutorial test called `ignore(fitted.coef())` and never
>   mentioned `confint()`; the test now asserts all three bit-exactly, which
>   keeps the test COUNT unchanged.  `doc/006_python_check` described ONE family
>   of Python cross-checks and claimed "No estimator ships without a Python
>   cross-check", which was true only because it counted the 9 `pyexample_*`
>   upstream gates it never mentioned -- three estimators (`DoubleMLAPO`,
>   `DoubleMLDIDMulti`, `DoubleMLQTE`) are covered ONLY by that family, and
>   three more (`DoubleMLDIDCS`, `DoubleMLDIDCrossSection`, `DoubleMLPLPR`)
>   only by the `validate_*` family.  That document's step 2 claimed every
>   `validate_*` script builds its reference "via the upstream
>   `doubleml.DoubleMLXxx`" -- true for 9 of the 24, false for the other 15 --
>   and the README said the `pyexample_*` family was the only one whose
>   reference is upstream, which 2 of the 9 wheel-importing `validate_*`
>   scripts also do (`validate_did_cs_binary_with_python.py` and
>   `validate_lplr_with_python.py`).  The new check
>   `_verify/_verify_tutorial_claims_1650.py` derives the DGP signatures, the
>   accessor sets, the 22-estimator coverage map and the 9/15 wheel split from
>   the source, and checks that a witness sits next to every published number.
> * **Round 28.** The `score` argument was audited -- where it lives, what it
>   accepts, and which estimators have one at all.  The port has **9** `score`
>   parameters at **7** estimators: `DoubleMLPLR` takes it on `fit()` (also on
>   `fit_cluster()` and `tune()`), six others take it on `new()`, and **15 of
>   the 22 take no score argument at all**.  `doc/004_estimators` said the
>   column was "the value you pass to `fit(score=...)`" -- true for exactly one
>   estimator -- and it filled the other rows with the strings `apo`, `apos`,
>   `pq`, `qte`, `lpq`, `cvar` and `policy_tree`, which are the port's
>   INTERNAL cache-kind tags (the `hash_hyperparams(...)` kind, and
>   `policy_tree` the `estimator_kind`), not score values.  The README's
>   "three vocabularies" note repeated the mistake: five of the eight strings
>   it listed as accepted by the port are ones no estimator accepts, and the
>   upstream list gave 9 of the **15** spellings upstream actually uses --
>   `ATTE`, `LATE`, `experimental`, `instrument`, `nonignorable` and
>   `IV-type` were missing.  The API reference's "constructor arguments also
>   differ" paragraph did not name the one difference that moves between
>   `new()` and `fit()`.  `skills/moonbit_doubleML.md` said `ml_m` defaults to
>   the classifier "for the six estimators whose propensity enters the score as
>   `1 / m_hat`" and then named **seven** -- the seventh, `DoubleMLLPLR`, is
>   not one of them, because its propensity enters its score as `d - m_hat` --
>   and it said all 24 `validate_*` scripts re-derive the hand-rolled
>   reference, which is true of **15**: the other nine take theirs from
>   upstream's wheel.  The new check
>   `_verify/_verify_score_argument_1650.py` derives all of it from the
>   source: the score parameters and their owners, the accepted set at each
>   site, the cache-kind tags, and both vocabularies -- the upstream one
>   measured on the vendored 0.11.4 tree AND on the installed 0.11.3, which
>   agree.
>
>   The published count was wrong once, and the error is worth recording.  The
>   first entry said the new verifier runs **127** checks.  It runs **135** checks
>   on the tree as it stands.  The 127 was a real number -- but it was the
>   number the dry-run's transcript reports, and the dry-run measures the
>   verifier on a DELIBERATELY BROKEN tree, where two of its loops are shorter
>   (one fewer score site in doc/004's table, one fewer score parameter in the
>   source), so four checks do not execute.  A number of the wrong thing is
>   still a wrong number, and the two counts sat side by side in one tracked
>   log with nothing saying which was which.  The verifier now ASSERTS its own
>   published count, and the dry-run asserts the failure count it ends at.
> * **Round 29.** The PUBLIC API DOCSTRINGS -- the `///` blocks a user reads in
>   an IDE -- were audited for numbers for the first time, and three carried
>   counts that had gone stale.  `DoubleMLLPQ::bias_corrected_coef` said it was
>   "Identical in reasoning to the **twelve** `bias_corrected_coef` methods
>   added in v0.86.0 - v0.92.0", but that range holds **thirteen** (the twelve
>   that landed at v0.91.0, plus `DoubleMLLPLR` at v0.92.0);
>   `DoubleMLPQ::bias_corrected_coef` said "**thirteen** ... v0.86.0 - v0.93.0",
>   which holds **fourteen**; and the canonical `bias_corrected_theta` docstring
>   in `sandwich.mbt` -- the one every other docstring cites as "the full
>   argument" -- said "All **twelve** `bias_corrected_coef` methods are now
>   documented no-ops" when there are **fifteen** by that name.  The pattern is
>   exact: each author counted the family as of the version BEFORE the
>   immediately preceding addition.  `DoubleMLLPLR` (v0.92.0) says twelve and
>   is RIGHT; `DoubleMLLPQ` (v0.93.0) says twelve and is wrong by one;
>   `DoubleMLPQ` (v0.94.0) says thirteen and is wrong by one; `DoubleMLQTE`
>   (v0.95.0) says fifteen and is RIGHT.  The new check
>   `_verify/_verify_docstring_counts_1650.py` derives the `bias_corrected*`
>   family from the SOURCE -- its members, each one's self-declared
>   `vX.Y.Z+:` version, and the count of members in any stated range -- and
>   asks the five docstrings that publish a count of that family whether they
>   agree.  It also gates the other package-wide counts in the public
>   docstrings, each derived rather than asserted: the 22-estimator roster, the
>   15-estimator sandwich family, upstream 0.11.4's 21 estimator classes and
>   the 17 of them whose `cf` default is `0.03`, upstream's 7
>   `_sensitivity_implemented` estimators and 12
>   `init_ps_processor` callers, the 5 `RDDKernel` variants and the 3 of them
>   that are negative outside `|u| <= h`, the policy tree's 5-slot encoding,
>   the `GainStatsResult` field count, the `DoubleMLDIDBinary` delegation
>   count, the `hash_data` row sample and the logistic defaults.
>
>   Two things about how it reads the tree are worth recording.  It reads the
>   DOCSTRING, not the file: `fit_cache.mbt` says "first 10 + last 10" in a
>   `//` code comment as well as in the `hash_data` docstring, and a
>   whole-file search is satisfied by the comment a reader never sees.  And
>   its check count is FIXED, not tree-dependent: the five publishing sites
>   are a named list and every other check is an aggregate, so a site whose
>   docstring is destroyed reports a FAILED CHECK rather than a skipped one
>   and the count cannot move.  That is the lesson from v0.164.22, where the
>   published count was the one measured on the dry-run's broken tree.
>   `_verify/_dryrun_round29_1650.py` breaks each of the fifteen claims one at
>   a time and requires the failure count to GROW at every step, and it ends
>   at **29** failures.  Two of its mechanisms are worth noting: one moves a
>   member's self-declared version and one removes a member from the SOURCE,
>   so the derived counts change and the publishers that still state them are
>   caught -- nothing in the verifier is hard-coded to "the family has fifteen
>   members".  An early draft of that driver had a mechanism that REPAIRED an
>   earlier one's failure -- moving one publisher's range moved the derived
>   count onto exactly the value the previous mechanism had broken -- so the
>   failure count went flat on a tree that was still broken.  Each mechanism
>   now has a site of its own, and the one that changes the derived family
>   SIZE runs last, because it would otherwise break the checks the other
>   mechanisms are aimed at.
> * **Round 30.** The `file:line` CITATIONS in the tracked prose -- the last
>   prose surface no earlier round had audited -- were checked for the first
>   time.  A citation is a PROMISE: the thing this sentence names is AT that
>   line.  Nothing kept that promise, because the port's `.mbt` files are
>   edited every release and a citation written for one release points at
>   whatever happened to be on that line in the next one -- and the sentence
>   still READS FINE, because the sentence is never re-read.
>
>   Measured at v0.164.23: the tracked prose carried **102** citations into
>   this repo, in **42** files, and **64 of them** did not point at a line
>   that mentions the thing the sentence names.  The four that had broken
>   worst were `did_binary.mbt:445` (cited for the four-row dummy inner
>   model; line 445 is a `catch` arm), `lplr.mbt:1630` (cited for
>   `set_sample_splitting`; line 1630 is a prediction assignment, the
>   function is at 2022), `lplr.mbt:758` (cited for the `kfold` draw; line
>   758 is a loop header, the draw is at 781) and `did_cs.mbt:1263` (cited
>   for the panic on a 3-row stub; line 1263 is an unrelated `require`, the
>   panic site is `did.mbt:276`).  All 64 are repaired, and the prose
>   carried **103** citations in **40** files that all resolved.
>
>   The new check `_verify/_verify_citations_1650.py` asks a mechanical
>   question of each of them: does the cited line MENTION the thing the
>   sentence names?  It uses the LONGEST IDENTIFIER the sentence names rather
>   than the whole quoted string, because the prose is allowed to write the
>   maths where the code writes numpy and the identifier is what both
>   spellings share.  It reads the prose in PARAGRAPHS, so a claim whose
>   quote and whose citation sit on adjacent wrapped lines still binds, and it
>   takes the anchor from the quoted token CLOSEST to the citation, with the
>   one BEFORE winning when the two sides are within eight characters.  A
>   citation with no code beside it is UNCHECKABLE and FAILS: the fix is to
>   quote the code, not to loosen the check.
>
>   Only the citations that name a file IN THIS REPO are checked.  A citation
>   that names an upstream Python file is a promise about a pinned third-party
>   package (`doubleml` 0.11.4) that this repo does not ship, and the
>   vendored upstream tree is not tracked, so a tracked verifier could not
>   check them anyway.  That count -- **266** -- was DECLARED and asserted
>   too, so the set could not move silently in either direction, and both
>   counts being declared is what kept the published check count FIXED at
>   **108**.
>
>   `_verify/_dryrun_round30_1650.py` breaks each of the eight mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **9** failures.  Two of its mechanisms are worth recording, both
>   because the first draft got them WRONG.  The mechanism that reproduces
>   the rot itself -- a source file grows a line above a cited one -- was
>   first aimed at `dgp_did_CS2021.mbt:50-51`, a RANGE citation, and it
>   contributed NOTHING: inserting a line above a two-line range leaves the
>   content inside the window, so the citation still resolved.  And the
>   mechanism that truncates a file was first aimed at `ps_processor.mbt`,
>   whose tail carries an upstream-side citation: the truncation moved the
>   upstream count from 266 to 265 as a SIDE EFFECT, and the mechanism that
>   moves that count on purpose put it back, so the failure count went flat
>   on a tree that was still broken.  That is the same trap as round 29's,
>   and the fix is the same: each mechanism has a site of its own, and the
>   one that changes the derived set SIZE runs last.
>
>   The ledger body below is a `v0.164.11` snapshot, so its own line pointers
>   name where the code was THEN; round 30 moved some of those lines again.
>   The CURRENT pointers live in the records under `_verify/`, and round 30
>   re-anchored the four of them that round 30's own repairs had moved.
>
> * **Round 31.** The **21** example manifests under `examples/` each import
>   the library BY VERSION, and every one of them named a version long gone:
>   **19** pinned `0.52.0` and **2** (`examples/bitexact/`,
>   `examples/parity/`) pinned `0.162.0`, against a package at `0.164.24` --
>   **159** and **34** releases behind respectively, counted from the
>   CHANGELOG's own version headings.  Nothing could see it: inside the
>   WORKSPACE the pin is INERT, because the workspace member wins, so every
>   example built against the current library while its manifest named an
>   ancient one.  Outside the workspace the pin decides what gets installed,
>   and the README invites the reader to copy an example out of the tree.
>   All **21** now pin the library's current version, and the manifests are
>   **bump sites**: `_verify/_bump_1636.py` re-pins them with every release,
>   so they cannot drift again.  That was not optional -- the round-9 check
>   requires every tracked file carrying a current-version literal to be a
>   site the bump script covers, so re-pinning the examples without adding
>   them there would have failed that check on the next release.
>
>   The new check `_verify/_verify_example_pins_1650.py` runs **28** checks:
>   one per manifest, the derived library version, the declared count of
>   **21** examples, a stale-literal scan over the version SITES (the set the
>   bump script owns, so "every site" is a NAMED set rather than a guess),
>   the README's own install block, and the published count itself.  The scan
>   covers the version sites only: a historical record may name an old
>   version on purpose -- `CHANGELOG.md` and the `_verify/` records are
>   exactly where an old version belongs -- while a MANIFEST is a promise
>   about what to install, and a promise of an old version is a defect.
>
>   `_verify/_dryrun_round31_1650.py` breaks each of the five mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **8** failures.  The last mechanism moves the SET SIZE -- a new
>   example manifest appears -- so it runs last, because it would otherwise
>   break the checks the other mechanisms are aimed at.
>
>   Two numbers in the tree were wrong in the same way, and both are fixed
>   here.  The api_server's `/version` handler said the package was "109
>   releases ahead"; the CHANGELOG's version headings put it at **124** --
>   the gap at the last release that still advertised `0.52.0`, and also
>   the number of releases the drift went unnoticed for.  Its closing
>   sentence said a version bump "touches FOUR places" -- it touched that
>   many when it was written, and it touches every place the version lives
>   now, so it names `_verify/_bump_1636.py` instead of counting.  The bump
>   script's own docstring said "Nine sites" and listed seven; it now lists
>   every place instead of counting them.
>
>   Not touched: the examples' OWN `version` fields.  Those are the example
>   packages' versions, they are never published, and they do not track the
>   library today (`examples/parity` says `0.1.0`), so changing them would
>   be a new convention rather than a broken promise.  Nor is
>   `examples/api_server`'s `moonbitlang/async@0.20.3` pin -- a published
>   third-party dependency, out of scope here.
>
> * **Round 32.** The README's quoted MEASUREMENTS were audited for the first
>   time as a set, and two of the ratios it states were not the numbers they
>   claimed to be.  The LPLR pitfall said the derivative was `-8.07e-05`
>   "against a score of `-0.1119`, a factor of **344** down" -- but that
>   quotient is **1387**.  The 344 is real: it is the derivative's fall from
>   `-0.0277` at `theta0 = 1.003` to `-8.07e-05` at `theta0 = 6.842`, which
>   is what the witness script prints ("derivative falls by a factor of
>   343.5") and what the record's section 27f says.  The passage attached the
>   number to the wrong pair, so a reader could not check it; it now names
>   both start values, and 344 is the quotient of the two derivatives it
>   prints.  And the hazard table's `DoubleMLIIVM` row said "`0.987` vs
>   `1.031` (16x *smaller* SE)" without printing the standard errors, so the
>   16 was a number with no arithmetic behind it in the document; the row now
>   prints them (`0.0047` vs `0.0747`), in the OLS-first order the table uses
>   everywhere else.  The v0.163.4 entry that carried the first wording is
>   corrected too.
>
>   The new check `_verify/_verify_measurements_1650.py` runs **46** checks
>   over three invariants:
>
>   * every RATIO the README states must be DERIVABLE from the numbers its
>     own passage prints -- and a table row is its own passage, so a ratio in
>     a cell is measured against that cell and not against the table.  The
>     rule is general: it is not a list of the ratios, it is the arithmetic
>     of every ratio the document states.
>   * every number in a TABLE CELL must be the correctly-ROUNDED rendering of
>     a value in the CHANGELOG entry that names that row's estimator -- the
>     witness set is derived from the entries, not listed.
>   * every SMALL-N figure must be the correctly-rounded rendering of a value
>     in the record the README cites for that passage.
>
>   The rounding is by SIGNIFICANT DIGITS, so `0.531` is accepted against a
>   measured `0.5307` and `8.07e-05` against `-8.06571e-05` -- a rendering of
>   the measured value, not a different value.  The hazard table's cells had
>   been quoted from the v0.132.0-v0.142.0 measurement rounds since they were
>   written, and this is the first check that re-derives them.
>
>   `_verify/_dryrun_round32_1650.py` breaks each of the six mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **10** failures.  The last mechanism moves the SET SIZE -- a new
>   table row appears -- so it runs last, because it would otherwise break
>   the checks the other mechanisms are aimed at.
>
>   The check's own EVIDENCE was wrong at first, and it is worth recording
>   because it is the same failure the round exists to remove.  The verifier
>   stored the dividend and the divisor in whichever order the loop reached
>   them, and printed `0.5307 / 5.2464 = 9.9` -- a false equality in the
>   very tool that checks the README's arithmetic.  The verdicts were right;
>   the evidence printed beside them was not.  The pair is now ordered, so
>   every line is true as printed (`5.2464 / 0.5307 = 9.9`), and a
>   percentage prints both the fraction and the percentage (`17 / 40 =
>   0.4250 = 42.5%`).
>
> * **Round 33.** The propensity table's four measurements had never been
>   checked, and its third column could not be read at all.
>
>   The README writes every measured value in a CODE SPAN, and the check that
>   holds a table cell to the record reads a cell's numbers out of those
>   spans.  The propensity table wrote its numbers in bold and plain instead,
>   so `-225.86`, `0.043`, `1.44` and `0.842` fell outside the rule that was
>   supposed to cover them.  They were checkable all along: the v0.131.9
>   record holds `-225.86204067169143`, `0.043343170315623715`,
>   `1.4426392091401607` and `0.8419771777915093`.  The table now writes them
>   the way the rest of the document does, and the cell set grows from 20 to
>   **27** -- every new cell witnessed by the record that measured it.
>
>   The table's third column is headed `rv`, and the README never said what
>   `rv` IS.  It is upstream's **robustness value** -- the sensitivity-
>   analysis reading of how much confounding the estimate survives, so
>   **higher is more robust**.  The direction comes from this repository's own
>   records: v0.131.7 says a `nu2` pinned at 1 "claimed a robustness value of
>   19.6, i.e. 'robust to enormous confounding', where the correct value is
>   0.84", and v0.131.5 says a DID ATT of 1.02 "scored `rv = 7.77` (visibly
>   robust) when the correct value is `1.73` (fragile)".  Two other rows
>   broke the same convention -- the QTE row's tau bounds and the DIDBinary
>   row's `~1e-4` -- and are fixed the same way.
>
>   The fourth invariant makes the convention a CHECK rather than an
>   assumption: a table's measurements must be written in code spans.  A
>   convention nobody enforces decays, and this one decayed unnoticed for
>   twenty releases.  `_verify/_verify_measurements_1650.py` now runs **70**
>   checks over four invariants.
>
>   `_verify/_dryrun_round33_1650.py` breaks each of the seven mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **9** failures.  The last mechanism moves the SET SIZE -- a
>   measurement loses its code span -- so it runs last, because it would
>   otherwise break the checks the other mechanisms are aimed at.  The sixth
>   breaks the CONVENTION without moving the cell set, so the new rule's
>   verdict is visible on its own rather than riding along with the set-size
>   check.
>
>   The v0.164.26 entry's published failure count is corrected from 9 to
>   **10**: that count is tree-dependent by design, and round 33 added a
>   check.  Each dry-run reads its count from the entry that names it, so
>   neither can be read in place of the other.
>
> * **Round 34.** The tree that is RELEASED must be the tree that was
>   TESTED, and until this round nothing checked that.
>
>   The `v0.164.27` tree carried `examples/api_server/moon.mod` pinning
>   `riantr/moonbit_doubleML@0.164.26` while the library at that tag was
>   `0.164.27` -- the exact defect round 31 was created to eliminate.  The
>   checks were not wrong: the round-31 pin verifier READ THE WORKING TREE,
>   and on disk the manifest was correct.  The COMMIT captured the INDEX,
>   and the index still held round 32's blob, because the `git add` list
>   for that release was HAND-WRITTEN and had missed the file.  The tree
>   that was tested and the tree that were released were DIFFERENT TREES.
>
>   Round 31's own staging script derives its list from `git status
>   --porcelain`, so it cannot miss a file; round 33 stopped using it.  That
>   is the regression.  The tag is not moved, and never will be: a tag is
>   never reused.  The branch is repaired, and v0.164.28 carries the
>   corrected manifest.
>
>   The new check `_verify/_verify_release_tree_1650.py` runs **36** checks
>   over the tree at a REF rather than the files on disk.  Its default is
>   HEAD -- the tree the registry was last given -- and the release
>   procedure runs it against the new commit BEFORE the tag is made.  What
>   it checks at that ref: the library's version is readable; every example
>   manifest pins THAT version; every other bump site carries that version
>   and names no other library version; the two README copies are
>   byte-identical; and the README names that version.  The site set is
>   DERIVED from the bump script's own `EDITS` table -- "every place the
>   version lives" is a NAMED set, not a guess -- and the manifests are
>   derived from the tree itself.
>
>   I3 also grew: the small-n passage's INTEGER measurements were left out
>   because a bare-integer scan also picks up file:line numbers such as
>   `149`.  The code-span convention removes the need for that exclusion --
>   a code span holding exactly one number is a measurement, so `-1381`,
>   `-648` and `172149` are figures while `double_ml_score_mixins.py:149`
>   is a citation.  All three are witnessed by the record the README cites,
>   and the figure set is now **15**.
>
>   `_verify/_dryrun_round34_1650.py` breaks each of the seven mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **7** failures.  Each mechanism COMMITS its breakage, because a
>   verifier that reads a ref cannot see an uncommitted edit.
>
> * **Round 35.** The README's API promises and its source citations were
>   both unchecked, and one of each was wrong.
>
>   The API-snippet check matched only snippets written with the
>   `@moonbit_doubleML.` prefix -- **4** of the **10** constructors the README
>   states.  The other six were written unqualified or inside a fenced block,
>   and no check could see them.  That is how
>   `DoubleMLLPLR::new(data, alpha=1.5)` -- a parameter that does not exist --
>   survived until a reader found it by hand: the check's wording said "the
>   README's API snippets" while its extraction reached 40 % of them.  The
>   check now reaches every constructor, and asserts that it reached them all.
>
>   Nothing checked the README's source citations either.  The DID paragraph
>   cited `did.mbt:708` for "the observational DID score", and line 708 is
>   `let w_d = d_i / m_i`, which lives in the `else` branch opened at
>   `did.mbt:704` -- the **experimental** score.  The observational branch is
>   `did.mbt:659-689`, and its default form computes
>   `(D - m) / (p_hat * (1 - m))`, where `1 / m` appears **nowhere**: `m` is in
>   the numerator, and for a treated row the `m` dependence cancels.  The
>   README's explanation of why the DID family's OLS default is safe was
>   describing a branch the shipped default never runs.
>
>   Two smaller drifts travel with it.  "A bare `moon test` runs every declared
>   backend" is false: measured on the toolchain this release was cut with, a
>   bare run prints `[wasm]`, `[wasm-gc]` and `[native]` and reports
>   `no test entry found` for `js` -- 1117 js tests it never runs, which reads
>   as a false green.  And the RNG keys are 32-byte ChaCha8 keys compared
>   **byte-for-byte** (`validate_bitexact_with_python.py:377`), not IEEE-754
>   doubles, so "25 of the 25 bit-exact items and 6 / 6 RNG keys are IEEE-754
>   identical" was wrong about the keys.
>
>   The two checks are `_verify/_verify_api_snippets_1680.py` (**135**
>   checks -- every constructor the README states, every named argument
>   against the source's parameters and defaults, every positional argument's
>   name against the source's name at that position, every `LearnerDispatch`
>   function it names, and the API reference's accessor promises) and
>   `_verify/_verify_citations_1650.py` (**45** checks -- C1: the cited range
>   must carry the token the sentence claims; C2: a citation that names a
>   configuration must sit in the branch that configuration selects, and a
>   doc-comment citation must NAME it).  The configurations C2 knows about are
>   DERIVED from the source's own `score == "..."` comparisons, not listed.
>
>   *That checker was replaced.*  The `file:line` checker this entry describes
>   was REWRITTEN in v0.164.33: the same file,
>   `_verify/_verify_citations_1650.py`, is now the PUBLISHER-record checker
>   described in round 39, and it makes **11** checks and asks a different
>   question.  The **45** above, and round 30's **103** citations in **40**
>   files, its **266** upstream citations and its fixed **108**, are what that
>   checker measured THEN; nothing in the tree measures them today, and a
>   reader who went looking for C1 and C2 in the file would not find them.
>
>   `_verify/_dryrun_round35_1650.py` breaks each of the seven mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **7** failures.
>
> * **Round 36.** The README's NEGATIVE claims -- the whole "Not covered, so
>   not claimed" section -- were only HALF checked, and one of them OVERSTATED
>   the limit it described.
>
>   Round 22's `_verify/_verify_test_verification_1650.py` already re-derives
>   the absence claims: that the `mutation` and `fuzz` checks run in no CI
>   workflow, that the `coverage` check is a proxy and not instrumented line
>   coverage, that the fuzz harness ignores its seed argument, that the
>   mutation battery is three mutants on one kernel, that the two declared
>   `moon.mod` dependencies are imported by nothing, and that no CI step
>   invokes a dependency-vulnerability scanner.  What it could not see was the
>   SIZE of the thing the limit was about.  It checked that the seed argument
>   is ignored, and stopped there -- so the README was free to say the
>   consequence was "a re-run of one case, not a fuzz", and the check stayed
>   green.
>
>   One invocation is **11 surfaces at 300 trials each**: the harness's own
>   banner prints "300 trials per surface", and
>   `_verify/LPLR_GATE_BLINDNESS_1680.md` records "ALL 11 SURFACES PASSED".
>   So each invocation is a real property-based run, and what the check
>   repeats is that ONE run, because the seed ARGUMENT is ignored.  The limit
>   is the missing seed sweep, not a missing fuzzer -- and "not a fuzz"
>   contradicted the README's own Examples table, which calls the same binary
>   "Random-property fuzz harness across 11 surfaces".  The QA `fuzz` check's
>   evidence carried the same overstatement; it now reports the scale it
>   measured, derived from the harness source so it cannot rot.
>
>   The new check `_verify/_verify_not_covered_1650.py` (**52** checks) closes
>   the other half.  It measures the harness's scale, requires the README to
>   name it, and fails if the README or the check's evidence calls a fuzz run
>   "one case".  It also decides "does CI run this check?" by the runner's OWN
>   selection rule -- selected AND (scope is not `full` OR `--full` was
>   passed) -- read out of the workflow YAML, where round 22's check greps
>   the workflows for the check's ID.  That grep has a hole: a workflow that
>   selects the full scope without naming any ID would run the `fuzz` check,
>   and the grep would still report "no workflow runs it".  The
>   `dependencies` check is CALLED rather than re-implemented, and the claims
>   are matched against a whitespace-normalised copy of the document, because
>   a hard-wrapped README breaks a raw substring match.
>
>   The section's lead-in repeated the heading above it word for word, and the
>   "Still" in it asserted a continuity no document supports; it is gone.
>
>   `_verify/_dryrun_round36_1650.py` breaks each of the **12** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **18** failures.
>
> * **Round 37.** The README's API PROMISES were checked against the tree
>   for the first time, and **two** of them were false; and the tracked
>   verifier contract was not SELF-CONTAINED, so a green suite was a
>   statement about one working directory rather than about the repository.
>
>   *The two document defects.*  The API reference said "every estimator's
>   `new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
>   optionals".  Measured by the parameter's TYPE -- not its name, which
>   is how `ml_pi` was missed -- the **22** estimators take **8** distinct
>   argument sets: `ml_g` / `ml_m` on **11**, `ml_l` / `ml_m` on
>   `DoubleMLPQ` and `DoubleMLQTE`, `ml_g` / `ml_m` / `ml_r` on
>   `DoubleMLIIVM`, `ml_g` / `ml_m` / `ml_pi` on `DoubleMLSSM`, `ml_g`
>   alone on `DoubleMLBLP` and `DoubleMLRDD`, `learner_l` / `learner_m`
>   on `DoubleMLPLR`, `learner` on `DoubleMLPLIV` and `DoubleMLPLPR`,
>   and NO learner at all on `DoubleMLLPQ` and `DoubleMLPolicyTree`.  The
>   same paragraph's "Default is `LearnerDispatch::linear_regression()`
>   (OLS)" is true for `ml_g` everywhere and FALSE for `ml_m` on the
>   **seven** structs migrated to a classifier -- which the README itself
>   names further down, so the page contradicted itself.  The promise is
>   now the table of argument sets, derived from the source.
>
>   The Status table's sandwich-variance row said "Introduced v0.89.0".
>   The CHANGELOG's own headings say **v0.79.0** introduced the family
>   (HC0-HC3 + cluster) on `DoubleMLIRM` and `DoubleMLPLR`, v0.86.0 and
>   v0.87.0 extended it, and v0.89.0 was ONE step of that extension
>   (10 -> 12 of 22).  The row's counts were right -- **15** scalar,
>   **4** per-cell, **3** with none of that API -- so the defect was in
>   the version literal, which rots silently because nothing else on the
>   page repeats it.  The row also said "**3** expose none", true of the
>   sandwich API and misleading about robustness: `DoubleMLBLP` and
>   `DoubleMLRDD` expose a heteroskedasticity-robust `hac_se` under their
>   own name (v0.96.0 and v0.97.0), and the README did not mention
>   `hac_se` AT ALL.  A limit that is understated is as false as one that
>   is overstated.
>
>   The API reference said "each DID variant takes its own data type".  It
>   does not: `DoubleMLDIDCS`, `DoubleMLDIDCSBinary` and `DoubleMLDIDMulti`
>   all take `DoubleMLDIDCSData`.  The sentence now names the four types
>   the DID family actually takes.
>
>   *The contract was not self-contained.*  The local suite is the tracked
>   `_verify/` contract, and it was measured in a FRESH CLONE: **3** of the
>   tracked verifiers FAILED there, and **15** of them located their tree by
>   the ABSOLUTE path of the working copy -- in a clone they read the
>   ORIGINAL tree, so they went green for the wrong reason.  Two verifiers
>   also depended on files git does not track
>   (`_verify/_probe_ops_1640.mbt`, `_verify/_qa_fast_1639.json`), and two
>   more FAILED on a clone because they check a downloaded third-party tree
>   that a clone does not have, with no notion of "the subject is not here".
>
>   The fixes: **61** tracked verifiers now derive their root from
>   `__file__`; the two upstream-dependent verifiers SKIP with a reason
>   when the vendored tree is absent (still counted, still visible); the
>   commands verifier builds the example before it checks the built path;
>   the fmt gate copies the package OUTSIDE the workspace and WARMS the
>   copy before each arm mangles it -- the copy's deleted `_build` left the
>   toolchain's format task "up to date" with its output missing, and the
>   warm-up itself runs `moon fmt`, so warming a MANGLED copy would format
>   it and the check would exit 0 for the wrong reason; the
>   upstream-records verifier resolves a cited path against the REPOSITORY
>   ROOT -- it used to resolve against the PARENT of the checkout, so its
>   green depended on the checkout's directory NAME -- treats a citation
>   to a path the repository IGNORES as the LOCAL promise it is, and skips
>   with a reason; and the two missing files are now TRACKED.  After the
>   fixes the whole tracked contract runs GREEN in a fresh clone.
>
>   The new check `_verify/_verify_contract_selfcontained_1650.py` holds
>   the contract to it: no tracked verifier may name an absolute path,
>   every tracked verifier's root must resolve to THIS repository, every
>   repository-relative file a tracked verifier READS must be a TRACKED
>   file, and a verifier over a downloaded tree must have a SKIP path.
>
>   The three checks are `_verify/_verify_api_promises_1650.py`
>   (**42** checks), the extended
>   `_verify/_verify_sandwich_coverage_1680.py` (**16** checks) and
>   `_verify/_verify_contract_selfcontained_1650.py` (**8** checks).
>   `_verify/_dryrun_round37_1650.py` breaks each of the **16**
>   mechanisms one at a time and requires the failure count to GROW at
>   every step, and it ends at **23** failures.
>
> * **Round 38.** The README named things the TREE DOES NOT HAVE -- a file
>   that never existed, a capability the package does not export, a rule its
>   own manifest breaks, a measurement stated more strongly than it was
>   measured -- and the tree's own validator count was **FORTY-TWO** releases
>   stale.
>
>   *The four document defects.*  The Project-layout block named
>   `moonbit_doubleML.mbt` -- "the main re-export file (the import surface)".
>   There is no such file: `git log --all --diff-filter=AD -- '*moonbit_doubleML.mbt'`
>   is EMPTY, so it never existed in this repository.  The layout now names
>   `moon.pkg`, the package's real interface file.
>
>   The API bullet promised "optional JSON in/out for native / wasm-gc / wasm
>   / js backends".  The library exports NO JSON API: with comments and
>   docstrings stripped, no production file in the package mentions a JSON
>   type, a `to_json` or a `from_json`.  The JSON that exists belongs to
>   `examples/api_server/`, which does its own request and response encoding.
>   The bullet now says exactly that.
>
>   The same bullet asserted the dependency rule is met -- "only
>   `moonbitlang/*` official packages" -- while `moonbit_doubleML/moon.mod`
>   declares `moonbit-community/sqlite3@0.2.3`, a non-official package that
>   nothing imports.  The README's own Dependency-rule section already said
>   "the rule is not met, by one line", so the page contradicted itself.  The
>   bullet now discloses the one declared line that does not meet the rule,
>   and keeps the claim that IS true -- the library's runtime supply chain is
>   `moonbitlang/core` only.
>
>   The hazard table's QTE row said the OLS arm was "frozen at `-1.583` for
>   tau `0.50`-`0.90`".  The release that measured it (v0.139.0) recorded FIVE
>   taus and found the freeze at THREE of them (`0.50` / `0.75` / `0.90`); at
>   `0.10` and `0.25` it was not frozen.  A hyphen reads as a continuous
>   interval the evidence does not support.  The row now names the three
>   measured taus.
>
>   *The count that rotted.*  `_verify/run_all_validators.py` said it runs
>   "all 23 validate_*.py", and the tracked capture
>   `_verify/validate_results.txt` said "Total: 23, PASS: 23".  The capture's
>   blob has not changed since **v0.68.0**, when the tree really did hold 23
>   validators; the twenty-fourth landed with **v0.163.0**, and the number
>   stayed wrong through **FORTY-TWO** releases (v0.163.0 -> v0.164.31).  A
>   claim no check re-derives is a claim that can rot unnoticed -- the same
>   disease as a layout naming a file that was never there.  The runner's
>   docstring now states the RULE (it runs every `validate_*.py` in the tree)
>   and lets the script derive the number, and the capture was regenerated by
>   re-running it: **Total: 24, PASS: 24, FAIL: 0**.
>
>   *What could not see a count.*  `_verify/_verify_count_referents_1650.py`
>   scanned for counts written as a WORD, at most twelve, beside one of
>   twelve nouns -- so it could not see "**22** estimators", the README's most
>   repeated count, nor "four data types", nor "24 Python reference scripts".
>   A registry that cannot SEE a claim cannot own it, and an unowned count
>   rots.  The scan now runs in three forms (the word form, the word form past
>   twelve, and the DIGIT form), the ARTEFACT vocabulary covers data types,
>   files, spellings, classes, packages, implementations, modes, jobs,
>   surfaces, scripts, binaries, examples, tests and arguments, and a new
>   section G derives the inventory's own counts FROM THE TREE -- the 22
>   estimator structs, the 19 files that hold one, the 220 `.mbt` files, the
>   129 blackbox, the 26 whitebox and the 24 Python reference scripts.  A
>   digit count's intervening tokens may not contain a digit, so the scan
>   cannot bridge over a comma and read "65 production, 129 blackbox test" as
>   a count of 65.
>
>   The new check `_verify/_verify_package_claims_1650.py` (**48** checks)
>   holds the README to what the package IS and PROVIDES: every file the
>   layout names must be a TRACKED file; the JSON surface is derived from the
>   package's sources with comments and docstrings stripped, because a JSON
>   mention in a COMMENT is not a JSON API; the dependency set comes from
>   `moon.mod`'s import block with comments stripped, so the manifest's
>   commented EXAMPLE (`moonbitlang/x`) is not counted as a dependency; and
>   the QTE row's taus must equal the CHANGELOG's own v0.139.0 taus, as a
>   sampled set and not as a range.
>
>   `_verify/_dryrun_round38_1650.py` breaks each of the **10** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **16** failures.  It caught three defects in its own construction:
>   the mechanisms are CUMULATIVE, so a mechanism that patches a passage an
>   earlier mechanism already rewrote must patch the text as it now stands; a
>   probe file that did not match the pattern the registry derives its count
>   from would have contributed NOTHING; and the counter counted a bare
>   `*** FAIL ***` section HEADER as a failure, which no verifier ever
>   reported -- the count has to equal the number the verifiers state in their
>   own `N checks, M failed` summaries, because that is the number the
>   CHANGELOG publishes.
>
> * **Round 39.** A SECOND USER-FACING DOCUMENT had never been audited, and
>   TWO of the README's claims had no check that could see them.
>
>   *The second document.*  `skills/moonbit_doubleML.md` is what a coding
>   agent READS before writing code against this library, so every claim in
>   it is a promise the tree has to keep -- exactly like the README's.  No
>   check read it at all, and the rot showed immediately: the skill quoted
>   the api_server's declared library pin as
>
>   > the library pin `0.52.0`
>
>   while `examples/api_server/moon.mod` declared 0.164.32.  That is the SAME
>   rot the two tutorials had -- fixed in v0.164.3, when the bump script
>   gained sites 5 and 6 for exactly this reason -- in the same shape, missed
>   for **132** releases because the file is a DOCUMENT and nothing read it.
>   The skill is now bump site **9**, and `_verify/_verify_skill_claims_1650.py`
>   (**58** checks) audits it: its pin, the **26** whitebox files and the
>   **169** test cases in them, the **21** driver binaries and the `main.mbt`
>   each one carries, the **24** cross-validators and the three repo-level
>   harnesses the glob does not pick up, the **9** scripts that take their
>   reference from the upstream wheel, the **11** learner variants by NAME,
>   the **16** estimators that expose all four accessors and the six that do
>   not, the **19** estimator files and the three that hold two structs, the
>   **17** DGP modules and the **35** files in all, and every concrete file
>   the skill names.  Every one of those numbers was RIGHT; only the pin had
>   rotted.
>
>   *A citation no check could see.*  The honesty section cited "Athey &
>   Imbens (2016, PNAS 113(27):7353-7358)".  The publisher's own deposited
>   record for the DOI gives the page range as **7353-7360**, and OpenAlex
>   agrees.  The authors, the year, the journal, the volume and the issue
>   were all right, and the SUBSTANCE the README credits is right -- only
>   the last two digits of the range were wrong.  A reader who looked the
>   paper up would have found the citation wrong and the claim right, which
>   is the worst of both.  No in-tree check can see a literature citation,
>   which is why it survived thirty-eight rounds;
>   `_verify/_verify_citations_1650.py` (**11** checks) now resolves each
>   citation against the PUBLISHER's record -- Crossref for the two journal
>   articles, arXiv for the preprint -- and compares the year, the volume,
>   the issue and the page range field by field.  When the publisher cannot
>   be reached the check SKIPS with a reason: an unreachable publisher is
>   not a wrong citation, and a contract that turns a network outage into a
>   red build teaches its reader to ignore it.
>
>   *An order that reads as a claim.*  The sandwich-variance row said
>   "`DoubleMLBLP` and `DoubleMLRDD` do expose a heteroskedasticity-robust
>   `hac_se` under their own name (v0.96.0 / v0.97.0)".  Read positionally
>   -- the way this document pairs names with versions everywhere else --
>   that asserts BLP = v0.96.0 and RDD = v0.97.0, and BOTH are false:
>   `rdd.mbt` marks its `hac_se` "v0.96.0+" and `blp_policy.mbt` marks its
>   own "v0.97.0+", and the CHANGELOG's own headings agree.  The SET of two
>   versions was right, so the defect was the ORDER -- and an order that
>   reads as a claim is a claim.
>   `_verify/_verify_sandwich_coverage_1680.py` (now **20** checks) derives
>   each `hac_se` version from the SOURCE's own doc-comment, cross-checks it
>   against the CHANGELOG's heading, and then requires the table to PAIR
>   them.
>
>   Two smaller gaps closed with them.  The README's "the library imports
>   nothing outside `moonbitlang/core`" had NO check behind it; the library's
>   sources declare no import of their own and the package's whole import
>   surface is `moon.pkg`'s `moonbitlang/core/*` block, and that is now
>   asserted.  And round 38's layout check matched only `.mbt` / `.pkg` /
>   `.mod`, so every DIRECTORY the Project-layout block names -- and
>   `moon.work`, `AGENTS.md` and `skills/moonbit_doubleML.md` -- went
>   unchecked; a path in prose is a promise whether or not it ends in an
>   extension, and all **24** of them are now checked.
>
>   `_verify/_dryrun_round39_1650.py` breaks each of the **8** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **13** failures.  It needs the network, because one of the
>   mechanisms is exercised by the citation check; the pre-flight refuses to
>   run without the publisher rather than measuring nothing.
>
>   *The toolchain moved under the release.*  The local `moon` went from
>   `0.1.20261016` to `0.1.20261023` while this release was being cut, and the
>   README's Toolchain row is checked against the INSTALLED toolchain -- so the
>   row, and every claim that names a toolchain, had to be RE-DERIVED rather
>   than re-labelled.  All four held: a bare `moon test` still prints
>   `Total tests: 0` for `wasm` and `native` and reports "no test entry
>   found" for `js`; `@std/env`, `@std/fs`, `@std/io` and `@std/process` still
>   do not resolve and the builtin `read_file` still does not exist (error
>   4021); and the operator bit-exactness table is unchanged, because
>   `_verify/_verify_op_table_1640.py` re-measures it on whatever toolchain is
>   installed NOW.  ONE claim did not survive the move: `train` was a hard
>   error on `moon 0.1.20261016` and is NOT reserved on `moon 0.1.20261023` --
>   it compiles as a local and as a field -- so the agent skill's "all are
>   reserved in current MoonBit" was corrected to say which ones are and which
>   one moved.
>
> * **Round 40.** The LEDGER nobody read.
>
>   *The last stale pin.*  `doc/moon.mod` -- the DOC PROJECT's own manifest --
>   named the library at **0.52.0**, and it was the LAST file in the tree still
>   carrying that literal.  The round-31 sweep fixed all 21 example manifests
>   and the round-39 sweep fixed the agent skill; neither of them read this
>   file, because it is a THIRD kind of file.  In-tree the pin is inert --
>   `doc` is a member of `moon.work`, so the workspace member wins and the six
>   tutorials build against the current library -- and outside the tree it is
>   the only thing that decides what gets installed.  It is now bump site **10**
>   of `_verify/_bump_1636.py`, so it moves with the release, and the
>   release-tree check holds it to the version like every other site.
>
>   *Four numbers in this banner that no check owned.*  This banner publishes
>   a count for the checks it names, and every one of those numbers is a claim
>   about the TREE -- but nothing could see them: the CHANGELOG publishes its
>   own counts and the checks that publish one assert it against their own
>   run, while the BANNER's numbers were asserted by nobody.  Four were false:
>   `_verify/_verify_measurements_1650.py` published **66** and makes **70**;
>   `_verify/_verify_release_tree_1650.py` published **34** and makes **36**;
>   `_verify/_verify_package_claims_1650.py` published **19** and makes **48**;
>   and `_verify/_verify_score_argument_1650.py` published **131** and makes
>   **135**.  The third of the four is the one worth recording: **19** was
>   never true -- that check has run more checks than it ever published, and
>   it has done so since the day it was written.
>
>   The new check `_verify/_verify_ledger_counts_1650.py` (**32** checks) owns
>   the class.  It reads the counts this banner publishes, RUNS each check it
>   names, and requires the published number to be the number that check makes
>   on this tree; and it requires the CHANGELOG's publication of the same
>   count to agree with the banner's, because the two documents are read side
>   by side and must not contradict each other.  The count is MEASURED, not
>   read: a check's count is what its checks add up to, so no literal in the
>   source can stand in for it.
>
>   *Eight sentences that were false.*  A fresh-eyes audit of the README, the
>   agent skill and the six tutorials found eight claims that were FALSE, and
>   not one of them was a number that had rotted: they were prose asserting
>   something the tree does not do, and a sentence can only be rewritten.
>   The agent skill said all 16 CLI-style demos "print true-vs-estimated
>   theta and a 95% CI" -- **14** of the 16 print a true value and **11**
>   print a CI, and the README had said so for releases.  The estimators
>   tutorial said the port has **9** `score` parameters and told the reader
>   to pass one to `fit_cluster(...)`: there are **8**, at 7 estimators, and
>   `fit_cluster` is a PRIVATE dispatch target, so a reader who followed the
>   sentence got "Type DoubleMLPLR has no method fit_cluster".  The same
>   tutorial gave `DoubleMLDIDMulti` a panel-form `DoubleMLDIDData`; it
>   takes `DoubleMLDIDCSData`.  The README pointed at "the full curl recipe"
>   in a file whose recipe is a PowerShell one, and offered a
>   `moonrun --port 4000` invocation that moonrun REJECTS and that the
>   service ignores anyway -- its listen port is hard-coded.  The estimators
>   tutorial also promised a note about upstream's `__all__` that the
>   package README does not carry.  And the DGP tutorial said the panel and
>   DID DGPs return `DoubleMLPanelData` / `DoubleMLDIDCSData` and carry
>   `t` / `g` / `id` accessors: they return `DidCsData`, `DidMultiData` and
>   `PlprData`, the panel one carries no `t` / `g` / `id` at all, and the
>   worked example it pointed at held no LPLR test.
>
>   The new check `_verify/_verify_doc_claims_1650.py` (**32** checks)
>   derives every one of those from the SOURCE: the demo split from the
>   record the measuring verifier writes, the `score` parameters from their
>   signatures with the parentheses BALANCED -- a `[^)]*` matcher cuts a
>   signature short at the first ")" and loses one of the eight -- the DGP
>   factories' return types and accessors, the api_server's port, and the
>   test names in the files the tutorials cite.
>
>   `_verify/_dryrun_round40_1650.py` breaks each of the **5** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **7** failures.  Three of the mechanisms break this banner's
>   own numbers, one breaks the pin and one breaks a tutorial's count, so
>   the classes are proved from both sides.
>
> * **Round 41.** The count that moved with the network.
>
>   *A number that was true only while a publisher answered.*  Two
>   fresh-eyes audits -- one for the numbers, one for the promises --
>   independently found the same defect.  The citation check
>   `_verify/_verify_citations_1650.py` publishes **11** checks, and it made
>   ten of them whenever arXiv was unreachable, because the skip that stood
>   in for the preprint's two checks was ONE skip.  The check that owns this
>   banner's counts compares the published number with the number the check
>   MAKES, so a publisher's rate limit turned the whole tracked contract
>   red -- and the release's own claim, "57 passed / 0 failed", was true
>   only while the network was up.  One auditor watched arXiv answer 429
>   and watched the contract fail; the other read the same thing off two
>   runs of the same script.
>
>   A skip now stands for EXACTLY the check it replaces: one per field that
>   could not be compared, and one per arXiv check.  The count is the
>   number of checks DEFINED, which is a property of the file and not of
>   the network -- the round-29 precedent, applied to the reachability of a
>   third party rather than to the shape of the tree.  Measured both ways:
>   `_verify/_verify_citations_1650.py` makes **11** checks with the
>   publishers reachable, and **11** with every request failing.
>
>   *A number this banner published that no check could see.*  Round 40's
>   entry records its four corrections in a shape with no "checks" word in
>   it -- a published count and the count the check actually makes -- so
>   the check that reads this banner's counts never saw it.  The
>   score-argument one was FALSE: `_verify/_verify_score_argument_1650.py`
>   makes **135** checks, and the banner said **131**.
>   `_verify/_verify_ledger_counts_1650.py` (**34** checks) reads that shape
>   now, and its live half is the count the check makes; the other half is
>   history, the way "v0.164.21's entry said ... runs **127**" is history in
>   the CHANGELOG.  A prose claim that no check can see is a claim that rots
>   in silence, and silence is what let this one rot.
>
>   *One checker, three counts, and a file that was rewritten.*  This banner
>   published **108** for the citation check in round 30, **45** in round
>   35 and **11** in round 39 -- and the file was REWRITTEN in v0.164.33,
>   so the rules round 35 describes (C1 and C2) are not in it any more.  A
>   reader who went looking for them would not find them.  Round 30's entry
>   now says what it measured then, and round 35's carries the note.
>
>   *The upstream roster was 17, and upstream has 21.*  Round 29's entry
>   published "upstream 0.11.4's 17 estimator classes", and the check that
>   derived it matched `^class (DoubleML\w+)\(` -- which needs BOTH the
>   prefix and the parentheses, and upstream declares `DoubleMLBLP`,
>   `DoubleMLPolicyTree` and `RDFlex` without them.  The number was wrong,
>   and it was wrong in a way that AGREED with the docstring it checked:
>   the `cf` default of `0.03` really does reach **17** classes, and that
>   is a different seventeen.  A check that agrees with a document for the
>   wrong reason is not a check.  The count is derived from the AST now --
>   upstream's class graph, walked -- and from the port's own provenance
>   record, which names the upstream classes the port ports.  The
>   `cvar.mbt` docstring says "17 of its 21 estimator classes", and
>   `_verify/_verify_docstring_counts_1650.py` (**76** checks) measures both
>   numbers and names the four upstream classes with no
>   `sensitivity_analysis` at all.  The tracked record that had published
>   the reach as **16** -- and had said "17 is not the measured number" --
>   was corrected in place, with the re-measurement that shows why.
>
>   *A workflow that described a layout the tree no longer had.*  The
>   nightly workflow said the package was "flat-layout (no moon.work)" and
>   that it checked "the package root directly rather than iterating over
>   workspace members".  The REPOSITORY root carries the workspace -- the
>   library, `doc/` and the examples -- and `moon check` resolves UP to
>   that root from any directory inside it, so the step checks every
>   member.  Measured: the same task list from the repository root and from
>   the package directory.  `_verify/_verify_layout_1680.py` owns the claim
>   now.
>
>   *Two paths in prose that pointed at nothing.*  The api_server's README
>   named two files under `.archived/` that exist in a local working tree
>   and are git-ignored, so a clone does not have them; it says so now.  And
>   `doc/moon.mod` -- the DOC PROJECT's manifest -- declared
>   `readme = "README.md"`, a file that does not exist; the doc project
>   has the landing page its manifest promises now.
>
> * **Round 42.** The promises the tree could not keep.
>
>   *A licence that granted one thing and claimed another.*  The README
>   said MIT, the manifest declared MIT, and mooncakes.io published MIT --
>   but the root `LICENSE` was the stock APACHE-2.0 text: 202 lines, with
>   its `Copyright [yyyy] [name of copyright owner]` placeholder unfilled,
>   and untouched since the initial commit.  `CHANGELOG.md`'s v0.60.0
>   entry records the intent -- the licence was rewritten to MIT and the
>   MANIFEST was fixed to match, but the licence TEXT was never rewritten.
>   So a reader who downloaded the repository was handed Apache-2.0 while
>   every document told them MIT, and 22 manifests still carried the
>   pre-v0.60.0 default.  Both LICENSE files carry MIT now, and every
>   manifest declares it.  `_verify/_verify_license_1650.py` (**11**
>   checks) owns the class, and its count is fixed against the network as
>   well as the tree.
>
>   *A version number about somebody else's repository.*  The "Used By"
>   section said pyroduct's cross-check ran against `riantr/moonbit_doubleML`
>   "v0.163.3 (its current pin)".  Pyroduct bumps its pins on its own
>   schedule: by the time this README shipped, its `moon.mod` imported
>   `0.164.34`, and the literal `0.163.3` survived only inside a comment
>   in pyroduct's own manifest.  A number this repository does not control
>   must not be published as one it does, so the literal is gone and the
>   figures -- `n = 400`, `theta = 1.5`, the two deltas -- stay.
>   `_verify/_verify_package_claims_1650.py` (**51** checks) owns it.
>
>   *A routing instruction that did not route.*  The api_server's README
>   said new routes go in the `routes` constant, but `/ping` is not in it:
>   `/ping` is answered before the body is read and before the router
>   runs, and it is one of the five endpoints the same README tabulates.
>   `_verify/_verify_doc_claims_1650.py` (**43** checks) owns that, and
>   with it the introduction's example size -- the fenced block's own
>   height, which is 35 lines and not the 30 the text used to say -- and
>   the source comment's own wasm recipe, which named the wrong build
>   directory, dropped the release profile and passed a `--port` flag the
>   service does not read.
>
>   *A verification claim that failed on a clone.*  The README published
>   "all four mutations killed".  The mutation battery matches LITERAL
>   newlines in `examples/bitexact/main.mbt`, so in a CRLF working tree two
>   of its four mutations matched nothing: the battery skipped them and
>   exited 1.  The release machine carried a local `core.autocrlf=false`,
>   which is not part of the tracked tree, so only the machine that cut the
>   release ever saw the claim hold.  The repository now pins its own line
>   endings in a root `.gitattributes`, and the battery matches whichever
>   endings the file has.  Measured: four of four killed in an LF tree and
>   four of four killed in a CRLF clone.  `_verify/_verify_layout_1680.py`
>   owns the file.
>
>   *A class of pointers that no check owned.*  The `file:line` checker was
>   rewritten in v0.164.33 into the publisher-record checker and nothing
>   took its place, so the in-repo pointers in the README, the skill, the
>   tutorials, the api_server README and the CI comments were owned by
>   nothing at all.  `_verify/_verify_file_line_refs_1650.py` (**60**
>   checks) owns them now: every pointer's file must exist and be
>   tracked, its line must be inside the file, and the block it sits in
>   must name something the target file carries.
>
>   *And the count that moved with the HOST.*  The first run of that check
>   made 116 checks in the working tree and 60 in a fresh clone, and the
>   fresh clone was right.  The root `README.md` is a SYMLINK to
>   `README.mbt.md`: a checkout that can materialise a symlink reads the
>   same document twice, and a Windows clone -- where git writes the link
>   target as a one-line stub -- reads it once.  A check that counted a
>   document by PATH would make its own count depend on the host.  The
>   document set is deduped by CONTENT now, and the check makes the same
>   number of checks in both environments.
>
>   *The ledger that reads this banner grew by two checks*, because the
>   contract has two more members: `_verify/_verify_ledger_counts_1650.py`
>   (**38** checks) now.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round42_1650.py` breaks ONE promise -- the licence text,
>   a manifest's licence, a pointer to a file that is not there, a pointer
>   past the end of its file, the routing instruction's exception, the
>   introduction's example size, the "Used By" section's pin, the
>   repository's own line endings -- and the failure count must GROW at
>   every step.  The run ends at **16** failures.

>
> * **Round 43.** The licence the tree did not close, and the code that did
>   not compile.
>
>   *A licence that granted one thing and claimed another -- again.*  Round 42
>   rewrote TWO of the seventeen LICENSE files, and the v0.164.36 entry
>   announced the class closed: "Both LICENSE files now carry MIT".  The tree
>   has SEVENTEEN tracked LICENSE files, and FIFTEEN of them still carried the
>   stock Apache-2.0 text -- each one beside a `moon.mod` that declared
>   `license = "MIT"`.  Six package directories shipped no LICENSE at all.
>   The check that owned the class read two files, so it could not fail on the
>   other fifteen: it was written to match the fix that had been made, not to
>   match the class of defect.  Every licence file in the tree is
>   byte-identical to the root MIT text now, and every package directory that
>   has a manifest is covered by one.  `_verify/_verify_license_files_1650.py`
>   (**6** checks) owns the class, and its count is fixed against the tree.
>
>   *Two code blocks the reader could not compile.*  The published README is a
>   document a reader COPIES from, and two of its fenced `moonbit` blocks did
>   not compile.  The first assigned to `ml_m`, which is not a variable -- it
>   is an optional NAMED PARAMETER of eight estimators' constructors -- so the
>   line does not compile at all, and it was written in the LIBRARY's
>   namespace rather than the reader's.  The second passed the Quick Start's
>   `DoubleMLData` to `DoubleMLLPLR::new`, which takes a `DoubleMLBinaryData`
>   -- LPLR's outcome is BINARY:
>
> >     Expr Type Mismatch
> >     has type : @riantr/moonbit_doubleML.DoubleMLData
> >     wanted   : @riantr/moonbit_doubleML.DoubleMLBinaryData
>
>   The README's own verifier could not see either: it checks the NAMES of a
>   call's arguments, and a type mismatch is not a name.  Both blocks are
>   rewritten into the reader's namespace, and
>   `_verify/_verify_readme_snippets_1650.py` (**7** checks) COMPILES them --
>   EACH in its own probe, against the LOCAL library, with a preamble that
>   supplies the context the fragments assume.  One probe with every block in
>   it proves only that AT LEAST ONE block compiles: the compiler stops at
>   the first error, so a broken block hides the ones after it.  CI runs it.
>
>   *A rule with a false positive.*  The API-snippets check compares a named
>   argument's value with the source's DEFAULT, because the README's
>   convention is that a constructor call it states shows the defaults.  Round
>   43's "pass a classifier explicitly" snippet deliberately passes a
>   NON-default learner, which the rule flagged.  The rule now applies to
>   LITERALS only: an expression is a choice, not a stated default.
>   `_verify/_verify_api_snippets_1680.py` published **135** and makes
>   **139**.
>
>   *Two documents that disagreed.*  `AGENTS.md` said the api_server's
>   `main_test.mbt` "is currently empty"; the api_server's own README said
>   there is **no** `main_test.mbt`, and the file does not exist.  And the
>   agent skill's anti-pattern list said `train` was "reserved in current
>   MoonBit" -- in the same paragraph that said it was not.
>
>   *The ledger that reads this banner grew by six checks*, because this
>   banner now publishes a count for three more checks than it did -- and the
>   ledger makes one check in each of its two live sections for every check
>   the banner names, so a new name costs two.
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) now.
>
>   *A sweep of the tree's own dry-runs.*  SIXTEEN of the THIRTY had stopped
>   biting, and the causes were three classes, all of them mechanical: a
>   mechanism's ANCHOR had moved, a CLASS had moved to a different verifier,
>   and a PUBLISHED COUNT had gone stale.  Three drivers read the FIRST
>   published count in the whole CHANGELOG instead of their own, so each
>   compared its measurement against a number that belonged to somebody
>   else's dry-run; every driver now reads the count from the BULLET that
>   names it, and one entry can carry several drivers' counts.
>
>   `_verify/_verify_dryrun_teeth_1650.py` (**13** checks) owns the class now.
>   It SIMULATES every driver's mechanisms in source order -- they are
>   CUMULATIVE, so a mechanism may patch the text an earlier mechanism
>   produced -- and it holds every anchor live in the tree, every patched
>   file tracked, every verifier a driver names still in the tree, every
>   driver's counter able to SEE its verifiers' failure markers, and the
>   CHANGELOG's published count and this banner's to agree.
>
>   *And it holds the OWNER and the CHECKER to the same number.*  The
>   sentence that carries a published count is hard-WRAPPED, so a reader that
>   matches it with literal spaces reads an OLDER entry's number instead: four
>   drivers were comparing themselves against somebody else's count, one read
>   nothing at all, and the checker here reported that six drivers published
>   no count -- two readers, each certain, both wrong, and nothing comparing
>   them.  Every driver now reads its own number out of a
>   whitespace-collapsed bullet, every driver that reads the banner finds a
>   count there, and this checker runs the driver's own lookup and requires
>   the two to agree.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round43_1650.py` breaks ONE promise -- a licence text, a
>   missing licence, the README's `ml_m` block, the README's LPLR block, a new
>   block that does not compile, and the probe's resolution of the library --
>   and the failure count must GROW at every step.  The run ends at **8**
>   failures.
>
> * **Round 44.** The service that died on a bad request, and the documents
>   that promised something else.
>
>   *A malformed IRM request killed the whole service.*  `POST /fit/irm` with a
>   treatment vector that is not binary -- or is binary but leaves one arm
>   empty in a fold -- made the library ABORT (`require(train_d0.length() > 0)`,
>   `irm.mbt:378`).  A MoonBit panic is not catchable: `require` and `abort`
>   are panics rather than errors, so the `try/catch` around the handler could
>   not hold it and the PROCESS EXITED.  `/healthz` then refused connections,
>   so one bad request took the service down for every other caller.
>   `examples/api_server/main.mbt` now PRE-VALIDATES the split with the
>   library's own public `kfold` and `Fold::train_indices`, and answers **400**
>   instead of dying.  The api_server's QA check now asserts four cases: a
>   valid fit, a non-binary treatment, a fold without both groups, and a live
>   `/healthz` after each rejection.
>
>   *A dependency two versions behind.*  The api_server example pinned
>   `moonbitlang/async@0.20.3` while this README's own dependency rule says to
>   pin the latest published version (`0.22.5`) -- and the example is the only
>   thing in the tree that imports it at all.  It is on `0.22.5` now, and the
>   dependency table's note says what is actually true: the line is dead IN THE
>   LIBRARY, and the example imports the same package at the same pin.
>
>   *Five documents that promised something the tree does not do.*  The DID
>   bias was rendered as "~0.001" where the measured figure is `0.00050` -- a
>   2x overstatement of a number the same paragraph prints correctly two lines
>   later.  The layout block named `example/consumer_demo`, which is the
>   example's PACKAGE name, where a repository PATH was meant
>   (`examples/consumer_demo`).  A bare `moon test` does not run "three of the
>   four declared backends": it runs the suite on ONE of them (`wasm-gc`),
>   reports `Total tests: 0` for `wasm` and `native`, and never reports `js` at
>   all -- while `moon test --target js` runs 1117 of them.  The installation
>   guide told an installed CONSUMER to run the test suite and quoted the
>   repository's 1117, and a consumer that installs the package runs no tests
>   at all.  And the introduction's blanket rule -- "`ml_m` defaults to the
>   logistic classifier wherever the propensity enters the score as
>   `1 / m_hat`" -- is false for `DoubleMLIIVM`, which carries `1/m` and
>   `1/(1-m)` and still defaults `ml_m` to OLS.
>
>   *A finding that was wrong twice.*  Two independent audits reported that
>   `doc/006_python_check` mis-split the Python cross-check coverage, and BOTH were wrong.
>   A MUTATION settles a coverage claim: `DoubleMLQTE::fit` was broken, and the
>   validate family stayed GREEN -- so it does not gate the QTE estimator, and
>   the guide's **16** / **3** / **3** split is correct.  What the validate
>   script's own LABEL overstates is its coverage, not the guide's arithmetic.
>   `_verify/_verify_tutorial_claims_1650.py` already derives that map from
>   what each script CONSTRUCTS.
>
>   *One published count moved.*  The rule about `ml_m`'s default now has an
>   owner for the TUTORIAL as well as for the skill, and that owner derived
>   the tutorial's sentence from the SOURCE: the blanket rule the
>   introduction stated is false for `DoubleMLIIVM`, whose `ml_m` models the
>   INSTRUMENT's propensity and still defaults to OLS.
>   `_verify/_verify_score_argument_1650.py` published **135** and makes
>   **140**.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round44_1650.py` breaks ONE promise -- the layout's
>   path, the dependency table's note, the service sentence, the bare-`moon
>   test` sentence, doc/001's `ml_m` rule and doc/002's consumer count --
>   and the failure count must GROW at every step.  The run ends at **9**
>   failures.
>
>   *The ledger is unchanged.*  This round publishes no new count, so
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) stays.
>
> * **Round 45.**  The service that died on ANOTHER bad request.
>
>   The v0.164.38 release added a pre-validation to `POST /fit/irm`, and its
>   CHANGELOG entry said the service "answers **400** instead of dying".  It
>   did -- for the two cases it enumerated.  For a third it still DIED, and
>   the panic was in the NEW validator: `require_irm_split` calls the
>   library's own `kfold`, and `kfold` aborts on `require(n_folds <= n_obs)`
>   (`kfold.mbt:442`) -- a PANIC, not a catchable error, so the process
>   exits and every later caller is refused.
>
>   MEASURED, not inferred: `POST /fit/irm` with one row and `n_folds = 2`
>   printed `precondition failed at kfold.mbt:442:5-442:30` and
>   `PanicError`; the client saw the connection reset, and `/healthz` then
>   answered "connection refused" instead of `{"status":"ok"}`.  `/fit/plr`
>   died the same way -- it calls the library too -- and so did `n_folds = 1`
>   and `n_rep = 0`, because the library `require`s `n_folds >= 2`,
>   `n_folds <= n_obs` and `n_rep >= 1` (`plr.mbt:106-108`,
>   `irm.mbt:121-123`).
>
>   The service now checks the SAME conditions first, in
>   `require_crossfit_params`, and `parse_fit_request` calls it -- so BOTH
>   fit handlers are covered, and no endpoint can reach a `require` with a
>   value the library will reject.  All five cases answer **400** and the
>   service stays up.  The api_server's QA check asserts them: the two from
>   v0.164.38, plus `n_folds > n_obs` on BOTH endpoints, `n_folds < 2` and
>   `n_rep < 1`, and a live `/healthz` after each rejection.
>
>   *Three code blocks that do not compile as printed.*  Every fenced
>   `moonbit` block in this README is a FRAGMENT -- `let data =
>   @moonbit_doubleML.DoubleMLData::new(x, y, d)` -- and MoonBit rejects a
>   module-scope `let` bound to a call ("Cannot infer the type of variable
>   data", Error 4074).  Measured: at module scope the fragment is
>   REJECTED; inside a function body the same fragment compiles.  So the
>   snippets were right and their PLACEMENT was not said out loud, and a
>   reader who pasted the Quick Start at the top of a file got a type error
>   that looked like a library bug.  Each block now carries a one-line
>   marker saying it belongs inside a function.
>
>   *Two published counts moved.*  `_verify/_verify_readme_snippets_1650.py`
>   published **7** and makes **10**: it now compiles each block TWICE --
>   once inside a function body, once at module scope -- and REQUIRES the
>   marker on any block that does not compile at module scope, so the promise
>   has an owner and the owner is the compiler.  Its count was also
>   ENVIRONMENT-DEPENDENT: 7 with the toolchain on PATH and 5 without it,
>   because one skip stood for three per-block compiles; there is now one
>   skip per compile per block, so the count is a property of the file.
>   `_verify/_verify_measurements_1650.py` published **70** and makes **79**:
>   it now owns the two n = 500 gaps BY TIER and the 16-cell swap's counts,
>   which its own I3 cannot see -- the gaps sit in the DON'T list, which is
>   ONE paragraph, so a marker that finds the LPLR item also finds the RDD
>   item (witnessed by a different gate), and the swap's counts are integers,
>   which are counts and stay out of the figure set.
>
>   *A finding that was wrong TWICE.*  Two fresh-eyes audits reported that
>   `doc/006_python_check` mis-split the Python cross-check coverage -- that
>   `DoubleMLQTE` is gated by both families, and that the guide's **16** /
>   **3** / **3** split is wrong.  BOTH were wrong, and the same mutation
>   settled it again: `DoubleMLQTE::fit` was broken, and the validate
>   family stayed GREEN while the pyexample family went RED.  The validate
>   script prints "quantile / LPQ / QTE parity: PASS", but its QTE row is a
>   DERIVED IDENTITY (`qte == pq - med_c`), not the estimator -- so its
>   LABEL overstates what it gates, and the guide's arithmetic is correct.
>   A script's printed label is not evidence of what it gates.
>
>   *Three numbers a reader could not check.*  "At `n = 500` the port and
>   upstream agree to ~0.007" named only the smaller of the two gated gaps
>   -- `0.007307` on the `nuisance_space` tier and `0.010609` on the
>   `instrument` tier -- and both are now named.  "all 8 of 8 swap cells"
>   is the port-`beta` half of a SIXTEEN-cell swap, and now says so.  And
>   the example table's "4 cohorts x 4 periods" is the DGP, while the
>   example prints `n_groups = 3`, because cohort 0 is never treated; the
>   row now says both.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round45_1650.py` breaks ONE promise -- a code block's
>   marker, the n = 500 gaps, the swap's total, the example table's
>   treatment-group count -- and the failure count must GROW at every step.
>   The run ends at **8** failures.
>
>   *The ledger is unchanged.*  This round publishes no new count, so
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) stays.
>
> * **Round 46.**  The names that were not files.
>
>   A fresh-eyes audit read every promise the README makes and checked it
>   against the tree.  One was broken; three were imprecise.
>
>   *Seven script names that are not files.*  The upstream-owned paragraph
>   named the two scripts that GATE the port against upstream with their full
>   filename, and then named the seven that import the wheel for CONTEXT with
>   the bare stem -- `validate_apos`, `validate_cluster_iv`,
>   `validate_cluster_plr`, `validate_iivm`, `validate_irm`, `validate_pliv`,
>   `validate_plpr` -- while the files on disk are
>   `validate_apos_with_python.py` and so on.  All seven bare names were
>   verified ABSENT from the tree; all seven suffixed forms are PRESENT and
>   tracked.  A reader who copied the name got "No such file or directory",
>   and the same sentence, two lines earlier, wrote the full name.
>
>   *The backend command.*  The opening summary and the Features list said
>   the four backends were green "under `moon test --deny-warn`".  A bare
>   `moon test` runs the suite on ONE backend -- the document says so itself,
>   95 lines later in the Quick Start, where it explains that on this
>   toolchain a bare `moon test` reports `Total tests: 0` for `wasm` and
>   `native` and never reports `js`.  The three places that make the
>   four-backend claim now spell the per-backend command out.
>
>   *The census phrase.*  "22 estimators (`DoubleML*` structs)" is true of the
>   estimators and loose as a phrase: a reader who greps `struct DoubleML`
>   finds **34** structs in **20** files -- the 22 estimators plus 12 `*Data`
>   types -- and concludes the document is wrong.  Measured: 22 estimator
>   structs, in 19 production files, 16 holding one and 3 holding two.  The
>   sentence now uses the precise spelling the Status table already used.
>
>   *The registry that owns the claim.*
>   `_verify/_verify_count_referents_1650.py` keys on the PHRASE, so a
>   re-worded count is a new phrase -- and a phrase the registry does not
>   know is a claim nobody re-derives.  Its key was REPLACED, not kept: a
>   registered key that is absent from the README is itself a failing claim.
>
>   *The dry-run that has to keep biting.*
>   `_verify/_dryrun_round38_1650.py` mutates the census phrase to prove the
>   count is owned.  A driver that patches a phrase the document no longer
>   carries writes nothing and silently stops proving anything, so it now
>   mutates the phrase the reader NOW sees.
>
>   *A tree under test that was two releases at once.*  The round-44 driver
>   checks out HEAD and copies in the files it exercises, so the tree it
>   breaks carried this round's CHECKS and the last round's DOCUMENTS -- and
>   the baseline went red for a reason that had nothing to do with the
>   promise being broken.  Round 24's driver copies the documents its checks
>   read, and round 35 says why: "the CHANGELOG that publishes the failure
>   count has to be IN the tree under test, or the published-count check is
>   vacuous".  The round-44 and round-45 drivers now do the same.
>
>   *A second audit, and what it found.*  A fresh-eyes audit measured every
>   number in the published README against the tree and mutation-tested the
>   checks that guard them: **92** quantitative claims, **0** false, **3**
>   misleading -- and the three misleading ones are the four-backend command
>   and the census phrase, fixed above.  No number in the document is wrong.
>
>   *Three numbers that were true, and unwatched.*  The same audit found
>   numbers that are true today but that nothing in the tree would catch if
>   they rotted, because the check beside them derives a DIFFERENT figure and
>   the two were never tied together.  The Status table's own "**22**" and its
>   own "**220** / **65** / **129** / **26**" were two of them: the census
>   verifier derived 22 and 220 from the source and compared them with the
>   body sentence, and nobody compared them with the table's row.  The
>   "16 are CLI-style numeric demos" was the third -- a floating number, and
>   changing it to 15 left every check green.  All three are derived now, and
>   each was proven to bite by mutating the README and watching the check go
>   red.
>
>   *Still unwatched, and named here so they are not forgotten.*  The audit
>   found seven more: the sandwich-variance split, the 9 / 2 / 7 split of the
>   Python cross-checks, the bit-exact item and RNG-key counts, the
>   `examples/main` run census, the transcendental bit-pattern counts -- which
>   no probe derives, because the fixture deliberately emits no transcendental
>   -- and the pyroduct figures, which belong to a consumer repository that is
>   not in this tree.  They are true as measured; they are the next round's
>   work.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round46_1650.py` breaks ONE promise -- the seven script
>   names, the Status table's estimator count, its .mbt census, the CLI-style
>   demo count -- and the failure count must GROW at every step.  The run ends
>   at **4** failures.
>
>   *Checked and left alone.*  The README attributes the upstream score
>   vocabulary to `doubleml-for-py` **0.11.4** while the provenance labels are
>   measured against the installed **0.11.3**.  The 0.11.4 wheel was fetched
>   from PyPI and carries exactly the same 15 spellings and the same 21
>   estimator classes, so the attribution is right; the installed wheel is the
>   provenance anchor, and the string is pinned by a dry-run that fails if it
>   moves.
>
>   *The ledger is unchanged.*  This round publishes no new count, so
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) stays.
>
> * **Round 47.**  Four of the seven, and three that never were unwatched.
>
>   The round-46 entry above named seven numbers as "still unwatched".  This
>   round checked that list against the tree, and the list was wrong three
>   times out of seven.
>
>   *Three of them were already watched.*  The sandwich-variance split is
>   derived by `_verify/_verify_sandwich_coverage_1680.py`, which reads the
>   estimator set out of the source and ties the Status table's own
>   "**15 / 22**", "**4**", "**3**" and "**19 / 22**" to it.  The 9 / 2 / 7
>   split is derived by `_verify/_verify_tutorial_claims_1650.py`, and the
>   `examples/main` census by `_verify/_verify_layout_1680.py`: 18 banners,
>   12 distinct estimators.  The round-46 entry listed all three as
>   unwatched.
>
>   *The four that were unwatched, and what now watches them.*
>
>   *The bit-exact scope.*  "25 of the 25 bit-exact items" and "the 6 / 6 RNG
>   keys" were PRESENT-CHECKED: the strings were in the document, which says
>   nothing about whether they are true.  The new check
>   `_verify/_verify_bitexact_scope_1650.py` (**40** checks) derives the item
>   count from the validator's own `reference()` -- the number of `out[...]`
>   assignments IS the number of items it compares -- and the key count from
>   the fixture's seed list, and then RUNS the validator and compares the run
>   with both.  A document that says 26, a validator that drops an item and a
>   fixture that emits 5 seeds are three different failures, and the check
>   catches all three.
>
>   *The transcendental bit patterns.*  `sqrt 6/6`, `cos 6/6`, `sin 6/6` and
>   `ln 5/6` lived in two docstrings and nowhere else, because
>   `examples/bitexact` deliberately emits NO transcendental -- it must not:
>   `ln` differs from CPython by one ULP, and a fixture that emitted one
>   could not be a gate that passes.  So the probe is separate: a throwaway
>   program that prints the four functions of six arguments, so their
>   IEEE-754 bit patterns can be compared with CPython's.  The check measures
>   them and ties the README's table rows, the validator's docstring and the
>   fixture's docstring to the same measurement.  The invariants are the
>   STANDARD's, not the toolchain's: `sqrt` must agree everywhere, because
>   IEEE-754 requires it, and `ln` must disagree somewhere, because libm is
>   not correctly rounded.
>
>   *The two numbers the upstream paragraph published.*  The paragraph says
>   "**9** of its 24 scripts import the upstream `doubleml` wheel, and **2**
>   of those gate the port against upstream ... The other **7** import the
>   wheel for context".  The 9 and the 24 were derived; the 2 and the 7 were
>   not tied to anything -- the paragraph could have said "**3** of those
>   gate" and every check would still have been green.  The gating SET is now
>   derived: the upstream NAMES come from the AST (a name bound from a call
>   into the wheel), and a wheel importer gates iff some line outside a print
>   call mentions one of them together with a port token.  The old rule was a
>   line PATTERN, and it missed the shape `validate_lplr` uses, where the
>   comparison is on the line AFTER the difference.  The derivation finds
>   exactly `validate_did_cs_binary_with_python.py` and
>   `validate_lplr_with_python.py`, and the README's own **2** and **7** are
>   tied to it.
>
>   *The examples/main row's NAMES.*  The row said "`DoubleMLPLR` + 11 others
>   (IRM / PLIV / IIVM / ...)" and its COUNT was checked; its NAMES were not.
>   The row could have dropped RDD and named PLQ instead, and every check
>   would have stayed green.  The names are now read out of the row and
>   compared with the set the driver actually runs.
>
>   *The pyroduct figures, and what cannot be derived.*  The "Used By"
>   section quotes a downstream consumer's own numbers.  They are true, and
>   they are not derivable from here: the code that produces them is in
>   another repository, the published pyroduct package ships no sources, and
>   its published README does not carry the figures.  So the section now says
>   whose measurement they are and that this repository does not re-measure
>   them, and the check that owns it --
>   `_verify/_verify_package_claims_1650.py` (**53** checks) -- says so too.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round47_1650.py` breaks ONE promise -- the bit-exact item
>   count, the RNG key count, the `ln` row's count, the upstream paragraph's
>   two numbers, the examples/main row's NAMES, the pyroduct attribution --
>   and the failure count must GROW at every step.  The run ends at
>   **11** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**46** checks) is the new number.
>
> * **Round 48.**  The shape filter, and three sentences that claimed more
>   than the tree supports.
>
>   The user named `bobzhang/toml@0.4.3` -- 841 lines / 24 504 chars -- as
>   the shape to work from: a package README that states the CURRENT truth
>   and the boundaries, and carries no release-by-release archaeology, no
>   duplicated restatements and no internal call-site census.  Twelve
>   passages of that kind came out of this README.  Nothing MEASURED went
>   with them: every figure a verifier pins is still published, and the
>   checks that pinned one were RE-TARGETED rather than deleted -- a check
>   that followed a sentence must follow the FACT, not the wording.
>
>   *Three prose claims that were watched, and still wrong.*  A fresh-eyes
>   prose audit read the sentences and asked one question of each: does it
>   claim more than the tree supports?  Three did, and all three were
>   WATCHED claims -- the numbers in them were right, the SCOPE around them
>   was not.  A verifier that pins a string says the string SURVIVES; it
>   does not say the string is true.
>
>   *The Attribution promised a comparison that does not exist.*  "all three
>   ship upstream, and are compared against it" -- but
>   `validate_plpr_with_python.py` compares UPSTREAM's theta against the
>   HAND-ROLLED one and never against the port's, on a different dataset
>   (numpy's `default_rng` against the port's `chacha8_rng`), and
>   `pyexample_suite.py` contains no `plpr` at all.  PLPR has no upstream
>   gate; `DoubleMLLPLR` and `DoubleMLDIDCSBinary` have one.
>
>   *The small-n caution said both sides fail.*  "Both this port and
>   upstream fail there, in opposite directions" is false on the gate's own
>   output: the direction REVERSES with n (at n = 60 the port is well-behaved
>   and upstream is not; at n = 100 it is exactly reversed; at n = 160
>   neither fails).  The upstream half of the claim survives -- upstream
>   really is ill-posed there.
>
>   *The upstream gates do not all run upstream's own code.*  Eight of the
>   nine `pyexample_*` scripts import the `doubleml` wheel; `pyexample_rdd.py`
>   imports `rdrobust`, a different package.  The paragraph now names both.
>
>   *The new check.*  `_verify/_verify_prose_scope_1650.py` (**42** checks)
>   derives the upstream-gated estimator SET from the scripts themselves, the
>   small-n DIRECTION from the gate's own three measured rows, and the
>   reference package of each gate from the scripts' imports -- and ties the
>   README's three sentences to all three.  A sentence can be fixed by
>   another sentence; a sentence tied to a MEASUREMENT cannot.
>
>   *A dry-run that could only be run ONCE.*  Three of the tracked drivers
>   -- `_dryrun_round35`, `_dryrun_round46` and `_dryrun_round47` -- aborted
>   with "nothing to commit" when the sweep ran AFTER the release commit:
>   their copy-in was already in the clone, because the clone is cut at HEAD
>   and the commit carries it.  Eleven of the drivers already tolerated that;
>   these three did not, and this round's fourth inherited the gap by copying
>   one of them.  A check that can only be run once cannot be re-checked.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round48_1650.py` breaks ONE promise -- the Attribution's
>   comparison claim, the small-n caution, the upstream-gate reference, the
>   migration paragraph's set, the estimator table -- and the failure count
>   must GROW at every step.  The run ends at **20** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**48** checks) is the new number.
>
> * **Round 49.**  The nine sentences the README's neighbours were still
>   getting wrong -- and three more found while fixing them.
>
>   Round 48 shipped the README.  A fresh-eyes audit then read the SIX
>   TUTORIALS, the skill and the example README -- the documents the README
>   points its readers at -- and asked the same question of every sentence:
>   does it claim more than the tree supports?  Nine did, and the two worst
>   were real API-surface defects that no CI gate can catch, because one
>   lived inside a `moonbit nocheck` fence and the other was prose about the
>   dependency rule.
>
>   *"Every estimator follows" the constructor snippet.*  Six of the 22 do
>   not accept those arguments: `DoubleMLPQ`, `DoubleMLQTE` and
>   `DoubleMLLPQ` have no `n_rep`, and `DoubleMLBLP`, `DoubleMLPolicyTree`
>   and `DoubleMLRDD` take no `n_folds`, no `n_rep` and no `seed`.  The
>   sentence said "Every", and the sentence about `score` said it was "the
>   one that does not follow" -- so the document had one exception where it
>   had seven.
>
>   *The dependency rule was broken by the package it is about.*  The skill
>   allowed only `moonbitlang/*` and `riantr/*`, and the library's OWN
>   `moon.mod` declares `moonbit-community/sqlite3@0.2.3`, which is
>   neither.  No `.mbt` in the library imports it -- 0 references -- so it is
>   a dead entry, and the rule now says so instead of pretending otherwise.
>
>   *Upstream's factories were in the wrong place.*  Only 3 of the 18 live
>   under `doubleml/did/datasets/`; the other 15 are spread over three more
>   packages, only 8 of the 18 upstream names end in `_data`, and SIX are
>   renamed here -- including `make_pliv_data`, which upstream keeps
>   PRIVATE as `_make_pliv_data` and this port publishes.
>
>   *Three provenance headers named upstream factories that do not exist.*
>   `make_dgp_irm_data_discrete_treatments`, `make_pliv_data` and
>   `simple_rdd_dgp` -- none of them is an upstream name.  The port's own
>   record of upstream was wrong in three places, and doc/005 was right only
>   because it had been written from the upstream package rather than from
>   the headers.
>
>   *The rest.*  doc/006_python_check's transcript was not a prefix of what the loop
>   prints (it dropped the glob's SECOND file with no elision marker, and
>   put the verdict on the banner's line); the same document handed the
>   reader the loop CI's own comment identifies as the defect it was
>   rewritten to remove; doc/002 listed `scipy` as a direct dependency and
>   `rdrobust` with no constraint, while CI installs it pinned `>=2,<3` ON
>   PURPOSE; doc/004 put `DoubleMLQTE` with the scalar-quantile estimators
>   when it takes `quantiles`, an `Array[Double]`; "35 files in all" counted
>   a file its own description excluded; and doc/003 called a cross-section
>   a panel.
>
>   *The new check.*  `_verify/_verify_doc_scope_1650.py` (**133** checks)
>   ties each of the nine to a MEASUREMENT rather than to a string: the
>   constructor census is brace-matched out of the library's sources, the
>   dependency exception is parsed out of every tracked `moon.mod` (with the
>   COMMENTS stripped first -- a commented-out `import { ... }` in the
>   header of `moon.mod` is the easiest way to parse the wrong block), the
>   upstream census comes from a TRACKED manifest, and the transcript is
>   rebuilt from the glob order and each script's own trailing statement.
>
>   *The upstream manifest.*  Upstream publishes a WHEEL, and its 0.11.4
>   sdist is a local cache that is not tracked -- so a contract run in a
>   fresh clone cannot see it.  `_verify/_dgp_upstream_manifest_1690.txt`
>   is the tracked snapshot, carrying the sdist's sha256, and the port's
>   provenance headers must agree with it.  That agreement is the check that
>   found the three bad headers.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round49_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 5 -> 10 -> 17 -> 21 -> 24 -> 26 ->
>   28 -> 30 -> 33.  The run ends at **38** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**50** checks) is the new number.
>
> * **Round 50.**  Seven citations of upstream that named things upstream does
>   not have.
>
>   The README's own provenance table was already right.  The drift was in the
>   place the port records upstream FOR ITSELF -- the comments, the
>   provenance headers, the ledger.  Every `doubleml.*` path in those is a
>   claim that the path resolves, so all of them were resolved against
>   upstream 0.11.4 by the real import mechanics, not by matching file
>   names.  Seven did not resolve.
>
>   *Three were names upstream does not have.*  `LPQScore` (upstream's LPQ
>   class is `DoubleMLLPQ`), `DoubleMLRDD` (upstream's RDD class is `RDFlex`
>   -- `DoubleMLRDD` is THIS repository's name for its own estimator, which
>   is what made the wrong citation read as right), and
>   `_compute_sensitivity_elements` (there is no such function; the
>   base-class hook is
>   `doubleml.double_ml.DoubleML._sensitivity_element_est`).
>
>   *Two were shadowed by a re-export.*  A package's namespace is what its
>   `__init__.py` binds, and `from .mod import name` binds `name` there and
>   SHADOWS the submodule of the same name.  So
>   `doubleml.utils.gain_statistics` IS the function, and the citation that
>   appended `.gain_statistics` to it asked a function for an attribute it
>   does not have; the same held for `doubleml.plm.datasets._make_pliv_data`.
>
>   *Two were simply the wrong path.*  `DoubleML` is not exported at the
>   package's top level -- the class lives in `doubleml/double_ml.py` -- and
>   `_aggregate_coefs_and_ses` is in `doubleml/utils/_estimation.py`, not
>   `doubleml/utils/`.
>
>   *Two of the seven were claims about upstream that were wrong in
>   substance, not just in spelling.*  The RDD comment said that dropping
>   the kernel weights for a non-OLS learner "is the upstream convention":
>   upstream's `RDFlex` REQUIRES a learner that supports `sample_weights` and
>   always applies the kernel weights, so that is this port's own
>   restriction.  And the LPQ comment said upstream's `comp_prob` is
>   `E[D | Z=1] - E[D | Z=0]`: upstream estimates that difference doubly
>   robustly from the cross-fitted nuisance predictions.  The part the
>   port's own fix rests on -- that upstream computes it ONCE, on the full
>   sample -- was true, and is now said accurately.
>
>   *The CHANGELOG held five more broken citations*: three copies of the
>   claims above, in the v0.62.0, v0.23.0 and v0.19.0 entries, and two in the
>   v0.49.0 entry, where `DoubleMLDIDCSBinary` was named at the package's top
>   level rather than in `doubleml/did/`.  They are corrected in place, the way
>   the ledger's own history records: the round-33 entry corrected an earlier
>   published count for the same reason.
>
>   *The new check.*  `_verify/_verify_upstream_refs_1650.py` (**36** checks)
>   ties every citation to the TRACKED manifest of what resolves, and -- when
>   the upstream sdist is present -- to the artefact itself: the file is
>   there, and the name is on the recorded line.  The sdist is a local cache
>   and is not tracked, so in a FRESH CLONE that part is a SKIP, not a
>   failure.
>
>   *The upstream manifest.*  `_verify/_symbol_upstream_manifest_1690.txt`
>   records every cited path with the upstream file and line where the name
>   is bound or defined, and carries the sdist's sha256.  Two independent
>   derivations agree on all of them: the sdist model and a real import.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round50_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 2 -> 4 -> 5 -> 6 -> 7 -> 8.  The run
>   ends at **9** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**52** checks) is the new number.
>
> * **Round 51.**  A published count that two documents disagreed about.
>
>   The `ml_m` slot -- the propensity nuisance learner -- is the one constructor
>   argument whose default CHANGED the estimators' answers.  Seven of the
>   estimators that carry it now default to a classifier and eight to a
>   regressor.  The README said seven and named all seven.  `TUNE_DESIGN.md`
>   said SIX -- twice -- and this CHANGELOG had already corrected a "6 / 6"
>   claim to "**7 logistic / 8 linear**" in an earlier round.  Nothing watched
>   that document's number, so the two disagreed silently: a root-level design
>   record that no verifier audits, carrying a count the README contradicted.
>
>   *The count was never derived from the package.*  It was carried by hand
>   from one document to the next, and the only copy of it that no check owned
>   was the one in the document nobody audited.  So the new check reads the
>   split out of the SOURCE -- `LearnerDispatch::is_classifier` is the
>   package's own decision procedure, and the `ml_m` defaults are read from the
>   `DoubleMLXxx::new` signatures -- and holds every LIVE document that states
>   it against that derivation.  The CHANGELOG and the ENGINEERING body are
>   historical and are left alone: they record what was true when they were
>   written.
>
>   *The new check.*  `_verify/_verify_mlm_defaults_1650.py` (**20** checks)
>   measures the split and audits the documents that publish it.  No number is
>   hard-coded in it: the set may legitimately grow, and a migration that
>   changes the source without changing the documents is exactly what it is
>   for.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round51_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 4 -> 5 -> 6 -> 7 -> 10 -> 13 -> 14.
>   The run ends at **14** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**54** checks) is the new number.
>
> * **Round 52.**  Ten reproduction commands that named scripts nobody could
>   run.
>
>   A path in prose is a promise: it must exist, and it must be TRACKED.  Ten
>   `python <script>.py` commands in tracked Markdown named scripts that are
>   not in the repository -- and not one of the nine was EVER committed, because
>   no commit in this repository's history adds a file by any of those names,
>   so a reader could never have run one of them.  Every one of them sat in a
>   document that no verifier opened.
>
>   Three of those documents did not merely go stale; they contradicted the
>   CHANGELOG.  `CLUSTER_UPSTREAM_PARITY_1680.md` carries a section that says
>   the dead commands "pointed at nothing", that "a reproduction command that
>   cannot be run is worse than none, because it reads as evidence", and that
>   they were "Replaced with the two scripts that do exist" -- and then lists
>   three, and leaves the original block untouched.  So the CHANGELOG
>   published "the block now cites the three scripts that do" while the block
>   cited none of them.
>
>   `PQ_QTE_GATE_DESIGN_1680.md` still said "gate not yet built" after
>   `pyexample_pq.py` had landed, and `RDD_PARITY_1680.md` said of a docstring
>   "Not yet corrected ... Logged, not fixed" -- in the SAME commit that
>   corrected it, whose own message says "Also corrects a docstring stating
>   an identity its own test cannot see".  That note also quoted a test name
>   that does not exist: the test is
>   `v116_tau_bc_equals_the_collapsed_form_only_when_b_equals_h`, and the
>   note said `..._when_b_equals_h`.
>
>   *The new check.*  `_verify/_verify_repro_paths_1650.py` (**28** checks)
>   holds every live document's reproduction commands, status lines and counts
>   against the tree, and reads the root `README.md` symlink from the INDEX
>   rather than from the working tree -- this host materialises it as a
>   hardlink and a fresh clone writes a 13-byte stub, so a check that read
>   the file would publish a count that differs between clones.  A document
>   may keep its original text; it says so in its own words, and the check
>   says so in its detail line rather than passing silently.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round52_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 8 -> 9.
>   The run ends at **9** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**56** checks) is the new number.
>
> * **Round 53.**  Paths named in prose, and the promise they make.
>
>   Round 52 held that a *reproduction command* is a promise.  This round holds
>   that a path named in PROSE is the same kind of promise: a document that
>   says its evidence was captured under a named file tells the reader that
>   the file exists and is worth opening.  A census of every tracked Markdown
>   document found **34** such promises in LIVE documents that no reader could
>   keep -- seven named scripts that were NEVER committed, four named files
>   that were tracked until 0.12.0's scratch-hygiene release untracked them,
>   nine named a script that had been RENAMED (to
>   `validate_with_python.py.archived_2026_09_25`, the name it has today), and
>   two named a CI workflow that had been RENAMED to
>   `.github/workflows/check.yml`.
>
>   *The new check.*  `_verify/_verify_path_promises_1650.py` (**296** checks) holds every path named in prose in every live document against the
>   tree, and reads the root `README.md` symlink from the INDEX rather than
>   from the working tree -- this host materialises it as a hardlink and a
>   fresh clone writes a 13-byte stub, so a check that read the file would
>   publish a count that differs between clones.  A document may keep its
>   original text; it says so in its own words, and the check says so in its
>   detail line rather than passing silently.
>
>   *A check that grew.*  `_verify/_verify_repro_paths_1650.py` published
>   **28** and makes **30**: the repair record this round tracks carries two
>   more reproduction commands, and a command is a check.
>
>   *A rule the two verifiers share.*  A path that is POSSESSIVELY
>   attributed to another repository is a reference to that repository's
>   file, not a promise about a file here.  The skill-claims verifier
>   already drew that line -- the skill names one of another package's own
>   files, and that file is supposed to be ABSENT from this tree -- and
>   this check draws it too, because two verifiers that disagree about the
>   same file are worse than one that is wrong.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round53_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8.
>   The run ends at **8** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**58** checks) is the new number.
>
> * **Round 54.**  Numbers in prose are promises too -- and nothing held them.
>
>   Round 53 held that a path named in prose is a promise.  This round holds
>   that a NUMBER in prose is the same kind of promise.  The documents that
>   describe the tree as it stands -- `README.mbt.md` and
>   `skills/moonbit_doubleML.md` -- state dozens of counts: 22 estimators in 19
>   source files, 220 `.mbt` files, 24 Python validators, 21 example binaries,
>   15 of 22 estimators with a scalar sandwich SE, 11 `LearnerDispatch`
>   variants, 26 whitebox files holding 169 test cases, 7 of 22 estimators
>   taking a `score` argument.
>
>   Every one of them was MEASURED true -- and none of them was held by
>   anything.  The next `.mbt` file would have falsified "220" silently, and
>   the README would have gone on claiming it.  A number nobody checks is a
>   number that is already on its way to being wrong.
>
>   *The new check.*  `_verify/_verify_number_promises_1650.py` (**51** checks)
>   measures each quantity from the tree and checks EVERY place the two
>   documents state it -- a number that appears in six sentences is six
>   promises, not one.  The claim is PARSED out of the document, never
>   hand-copied: a check that compares the tree against a number typed into
>   the verifier is not a check of the document at all.
>
>   *Counts are not enough.*  One mechanism swaps an estimator name in the
>   sandwich-variance row and leaves the count alone.  A check that compares
>   only counts cannot see it, so the contract checks the NAMES too.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **296** and makes **298**: this round's banner names two more paths, and a
>   path named in prose is a check.
>
>   *A hole the dry-run found.*  The first draft of the check matched
>   "**22** estimators" and not "**22 estimators**" -- the bold around the
>   whole phrase rather than around the number -- so the README's most
>   prominent estimator claims were invisible to it.  The dry-run caught it:
>   the mechanism that changed the number did not move the failure count, and
>   a mechanism that moves nothing is not being measured.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round54_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10.
>   The run ends at **10** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**60** checks) is the new number.
>
> * **Round 55.**  A citation names a PLACE -- and the place has to be inside
>   the file.
>
>   Round 53 held that a path named in prose is a promise.  Round 54 held that a
>   number in prose is a promise.  This round holds that a CITATION -- a path
>   with a LINE RANGE, `ssm.mbt:73-74` -- is the same kind of promise with a
>   third half: the place it names must be INSIDE the file.
>
>   The scanner could not see that form at all.  Its path token accepts no
>   colon, so a citation was not a path to it -- and the live documents hold
>   **474** citations, every one of them invisible.  A citation is what a
>   reader follows, and nothing was watching where it pointed.
>
>   **Not retained in this repository**: `cmd/`, `_build/`,
>   `__generated_driver_for_blackbox_test.mbt` -- the paths this entry names
>   are the ones the documents describe and this repository does not keep.
>
>   *The scope device, widened by two DERIVED signals.*  Round 53 scoped a
>   promise by "a directory the repository has NOW".  Two places this
>   repository wrote to fell outside that: `cmd/`, the package's entry-point
>   tree -- a deleted tracked path says the directory was here once -- and
>   `_build/`, which the repository's own `.gitignore` names, so the toolchain
>   writes HERE.  Neither signal is a list this project keeps: one comes out of
>   the git history, one out of the tracked `.gitignore`.
>
>   *What it measured.*  **31** promises in **18** live documents that no reader
>   could keep: twenty-seven paths under the `cmd/` tree, and four citations --
>   `cmd/main/main.mbt`, `cmd/apos/main.mbt`,
>   `_build/_verify_TODO3_snapshot.mbt`, and the `moon test` driver
>   `__generated_driver_for_blackbox_test.mbt`.
>
>   *The third way to discharge a promise, in a form a scanner can read.*
>   Round 53's rule: point at the file that exists; TRACK the file; or say in
>   the house's own words that it is not there.  The third way now has a form:
>   a line that opens with the words **Not retained in this repository**, and
>   then names the paths the document does not keep.  The words are the
>   DOCUMENT'S, never a list this project keeps.  Eighteen documents say it
>   once, in their own words, and every mention of the path in that document
>   is discharged by it.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **298** and makes **443**: a citation is a check, and so is every distinct
>   path it names.
>
>   *A driver that grew with it.*  `_verify/_dryrun_round53_1650.py` now ends
>   at **9** failures: its "a historical document is live again" mechanism
>   trips one more check, because `cmd/main/main.mbt` is a promise now that
>   `cmd/` is in scope.  A published count is a promise too, and the round
>   that makes it false republishes it -- which is what this entry is.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round55_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 3 -> 4 -> 6 -> 9 -> 10 -> 11.
>   The run ends at **11** failures.
>
>   *The ledger does not move.*  This round publishes no count for a NEW
>   check, so `_verify/_verify_ledger_counts_1650.py` (**60** checks) is still
>   the number.
>
> * **Round 56.**  The tutorial pages' numbers -- and the probe that found
>   nobody was holding them.
>
>   Round 53 held that a path named in prose is a promise.  Round 54 held that
>   a number in prose is a promise.  This round holds that the TUTORIAL pages
>   under `doc/` -- and the api_server README -- make numbers too, and that
>   their numbers had NO holder at all.
>
>   The instrument was a MUTATION PROBE.  It changed one number in one page,
>   ran every tracked verifier that reads that page, and asked which ones
>   failed.  **26** claims had no holder: nothing in this repository would
>   have failed if `doc/001_introduction` had said "17 regressors", or
>   `doc/004_estimators` "default `[0.7]`", or the api_server README "the
>   body cap is 32 MiB".
>
>   *The new check.*  `_verify/_verify_doc_numbers_1650.py` (**52** checks)
>   measures each quantity from the tree -- the estimator census, the
>   `LearnerDispatch` enum, the DGP factories and the accessors of the types
>   they RETURN, the Python script families, the constructor defaults, the
>   propensity-learner defaults, the CI workflow, the api_server's own source
>   -- and checks every place the pages state it.  The claim is PARSED out of
>   the document, never hand-copied, and a number that appears in two
>   sentences is two promises, not one.
>
>   *What it found.*  Nothing FALSE: every one of the **26** claims was true
>   of the tree when it was measured.  That is not a defence of them.  A
>   promise nobody watches rots in silence, and the next `.mbt` file would
>   have falsified "17 `dgp_*.mbt` modules" without a single red line.
>
>   *Two claims that were the SAME number in two sentences.*  The
>   `doc/006_python_check` page says "**9** of the 24 import the upstream
>   `doubleml` wheel" and, eight lines earlier, "upstream's wheel in **9**".
>   One was held and one was not: a quantity is a promise per SENTENCE, not
>   per quantity.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **443** and makes **446**: a path named in prose is a check, and this
>   round's banner names three more of them.
>
>   *A check that was measuring the wrong tree.*  The round-9 verifier's
>   version-literal scan WALKED THE FILESYSTEM.  A scratch clone of the tree
>   sitting at the repository root carries every version literal in it, so the
>   check reported a dozen version sites that no reader could open and no
>   bump script could reach.  The scan is now scoped to the TRACKED tree --
>   the repository, not the checkout -- which is what the check always meant.
>   `_verify/_verify_round9_docs_1644.py` (**65** checks) is the number it
>   makes now, in the house's own summary shape.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round56_1650.py` breaks ONE promise -- one number in one
>   page -- and the failure count must GROW at every step: 0 -> 1 -> 2 -> 3 ->
>   4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11 -> 12 -> 13 -> 14 -> 16 -> 17 ->
>   18 -> 19 -> 20 -> 21 -> 22 -> 23 -> 24 -> 25 -> 27 -> 28 -> 29.  The run
>   ends at **29** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**64** checks) is the new number.
>
> * **Round 57.**  AGENTS.md -- the document an agent opens first, and the
>   one nobody was holding.
>
>   Rounds 48-56 audited the README, the six tutorials, the skill and the
>   example README.  `AGENTS.md` is the only live document at the repository
>   ROOT that none of them touched -- and it is the FIRST thing an agent
>   opens.  A MUTATION PROBE on it -- change one claim, run every verifier
>   that reads the document, ask which ones fail -- says that THREE of the
>   eleven claims it probed were held by anybody and EIGHT were held by
>   NOBODY.  The library's location, the tutorial range, the dependency
>   rule, the async version, the commit citation, the public API calls and
>   the "no test file" claim could all have been wrong, and no red line
>   would have appeared.
>
>   *The probe had to be fixed twice before it measured anything true.*  The
>   first pass took the readers to be "the verifiers whose SOURCE names the
>   document" -- an UNDER-approximation: the path-promises verifier reads
>   every tracked markdown file, so it holds AGENTS.md's path promises
>   without the string "AGENTS.md" ever appearing in its source.  The reader
>   set is now MEASURED at runtime, with an audit hook that logs every file
>   a verifier opens: SEVEN verifiers open AGENTS.md.  The second pass wrote
>   the mutation into the clone's working tree, and the path-promises
>   verifier reads documents from the INDEX -- on purpose, so its check
>   count is the same in every clone -- so it could not see a mutation that
>   was never COMMITTED.  Each mutation is committed now, and the probe
>   says EIGHT were held by nobody before this round and NONE after it.
>
>   *Three claims were FALSE of the tree.*
>
>     * the DEPENDENCY RULE.  "Only official (`moonbitlang/*`) packages are
>       allowed.  Non-official packages may only be `riantr/*`" -- while the
>       library's own `moonbit_doubleML/moon.mod` declares
>       `moonbit-community/sqlite3@0.2.3`, which is neither.  Round 49 gave
>       `skills/moonbit_doubleML.md` exactly this correction, naming the one
>       declared line that does not meet the rule; AGENTS.md was never given
>       the same edit, so two documents described two different rules.
>     * the INTERFACE FILE.  "each package has a generated interface file
>       `.mbti`" -- the toolchain writes `pkg.generated.mbti`, the tracked
>       `.gitignore` ignores it, and NO tracked file ends in `.mbti` at all.
>       "Check the diffs of `.mbti` file" asked for a diff that `git diff`
>       can never produce.
>     * the PACKAGE LAYOUT.  "each directory contains a `moon.pkg` file" --
>       `doc/` is a MODULE of six packages and has no `moon.pkg` of its own,
>       and `_verify/` holds MoonBit source that belongs to no package.
>
>   *The new check.*  `_verify/_verify_agents_claims_1650.py` (**66** checks)
>   derives every claim from the tree -- the workspace census from
>   `moon.work`, the dependency carve-out from every tracked `moon.mod`'s
>   import block with the comments stripped, the package census from the
>   tracked tree, the interface file's name from the tracked `.gitignore`,
>   and the commit citation from the git object database -- and checks every
>   place AGENTS.md states it.
>
>   *A claim about the TREE is broken by changing the TREE.*  The last
>   mechanism of the dry-run commits a `deprecated.mbt` into the scratch
>   clone, because the verifier's scope is the TRACKED tree: a file that
>   exists only in a working copy is not a claim about the repository.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **446** and makes **450**: a path named in prose is a check, and this
>   round names four more of them.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round57_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 2 -> 4 -> 6 -> 7 -> 9 -> 10 -> 12 ->
>   16 -> 17 -> 19 -> 20 -> 21 -> 22 -> 23 -> 25 -> 26 -> 28 -> 29 -> 31 ->
>   32 -> 33 -> 35.  The run ends at **35** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**66** checks) is the new number.

> * **Round 58.**  The SECONDARY documents -- the four that rounds 48-57 never
>   audited.
>
>   Rounds 48-57 audited the README, `AGENTS.md`, the six tutorials, the skill
>   and the example README.  Four LIVE documents were left: `.githooks/README.md`,
>   `doc/README.mbt.md`, `doc/menu.json` and
>   `_verify/upstream_prove_1649/README.md`.  The same MUTATION PROBE says they
>   were in the state `AGENTS.md` was in: of the **24** claims the BASELINE
>   probe could put to the test, **18** were held by NOBODY -- the hook's
>   command, the member count, the tutorial table, the tutorial target, the
>   menu, the toolchain the proof re-audit was measured on and the per-case
>   error counts could all have been wrong, and no red line would have
>   appeared.  After this round, **25** claims probed and **NONE** held by
>   nobody.
>
>   *The reader set is MEASURED at RUNTIME*, with an audit hook that logs
>   every file a verifier opens: **5** verifiers open `.githooks/README.md`,
>   **6** open `doc/README.mbt.md`, **1** opens `doc/menu.json` and **4** open
>   the proof re-audit README.  The six claims that DID have a holder were
>   held by `_verify/_verify_round11_handoffs_1646.py` (the hook's tracked
>   mode), `_verify/_verify_path_promises_1650.py` (two paths) and
>   `_verify/_verify_round14_upstream_1649.py` (the two per-case error counts)
>   -- and one of round 11's two did not hold a claim at all: it PINNED the
>   falsehood, so correcting the document would have failed the check.
>
>   *Eight claims were FALSE of the tree.*
>
>     * the TASK COUNT.  "measured: `moon: ran 54 tasks`" -- the number is not
>       holdable at all: it changes with the build state and with the toolchain,
>       and `moon check` prints "no work to do" instead of a count on a warm
>       tree.  It was REPLACED by the member count, which `moon.work` derives.
>     * "It is the same command `publish.yml` runs before it publishes."  It is
>       not: `publish.yml` runs `moon check --target "$target" --deny-warn`.
>     * "`moon check` does **not** check `_test.mbt` files -- only `moon test`
>       compiles them."  FALSE: `moon check`'s OWN PLAN type-checks the
>       `_test.mbt` files and the `readme.mbt.md` doctests.  `moon check`
>       type-checks them; only `moon test` RUNS them.
>     * "the QA LOOP -- those live in `.github/workflows/`".  The QA LOOP's own
>       scripts live in `.github/scripts/qa_loop/`.
>     * "See the README's 'What CI actually gates' table."  There is no such
>       table in the README -- it is a section of `ENGINEERING.md`.
>     * "the current toolchain" (six times) and "the current proof frontend":
>       a 2026-10-20 audit cannot describe the toolchain in use today.  The
>       document now says **the audited toolchain**, and names the versions it
>       was measured on.
>     * "the controls are classified `PLATFORM_ERROR` rather than `PROVED` in
>       `out/b0_control.log`".  The log holds the RAW EVIDENCE; the label is
>       `run_reaudit.py`'s.
>     * "The toolchain has moved five patch releases since."  Reworded so the
>       gap is between the versions the document itself names -- `v0.10.11` and
>       the audited `v0.10.16` -- which keeps it true forever.
>
>   *A check that HELD THE FALSEHOOD.*  `_verify/_verify_round11_handoffs_1646.py`
>   REQUIRED the sentence "does **not** check `_test.mbt` files" to be in the
>   hook README -- it asserted the error, not the truth.  It now requires the
>   corrected sentence, and its own count is unchanged at **45**.
>
>   *The new check.*  `_verify/_verify_secondary_docs_1650.py` (**151** checks)
>   derives every claim from the tree -- the member count from `moon.work`,
>   the hook's mode from `git ls-files -s`, the cross-check count from the
>   tracked `validate_*_with_python.py` glob, the doc-package census from the
>   tracked tree, the `_test.mbt` question from `moon check --dry-run`'s own
>   plan, the per-case error counts from the tracked `out/*.log` files, and the
>   patch-release gap from the two versions the document names.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round58_1650.py` breaks ONE promise, and the failure count
>   must GROW at every step.  The run ends at **28** failures.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **450** and makes **459**: a path named in prose is a check, and this round
>   names nine more of them.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**68** checks) is the new number.

> * **Round 59.**  The README's SHAPE -- measured against the two references.
>
>   Rounds 48-58 audited the TEXT of every live document.  This round audited
>   the SHAPE: what a reader is GIVEN, and in what order.  The two reference
>   packages the user named -- `Ridge-Lab/capnp@0.1.0` and `gaato/discord@0.10.0`
>   -- were measured feature by feature against this README, and FOUR gaps came
>   out of the comparison.
>
>   *The README carried NO IMAGE at all.*  Both references open with a CI
>   badge; this one had none, and nothing would have said so, because the
>   README is GENERATED -- a generator change can lose a section without any
>   red line.  It now opens with a badge on `.github/workflows/check.yml`: the
>   workflow named "CI", which runs on every push to `main` and `master` and on
>   every pull request.
>
>   *The status was 590 lines down.*  discord opens its prose with a
>   one-paragraph STATUS; this README's status sat under "Development status",
>   past the Features list, the estimator table, the API reference, the
>   propensity section and the pitfalls.  There is now one under the opening
>   paragraph, and every element of it is DERIVED from `moonbit_doubleML/moon.mod`:
>   MIT is the manifest's `license`, the four backends are its
>   `supported_targets`, and the estimator count is measured.  NO version
>   literal goes in it: a version in a new place is a new bump site, and a
>   bump site the bump script does not know about is a stale number waiting to
>   happen.
>
>   *A shape element that was REFUSED.*  capnp states a MINIMUM toolchain --
>   the lowest MoonBit it supports.  Nothing in this tree establishes a floor:
>   `moonbit_doubleML/moon.mod` declares no toolchain constraint, and the
>   workflows install the LATEST `moon` rather than pinning one.  So no floor
>   is published.  What the README says instead -- the toolchain it was
>   VERIFIED on -- is what is held.
>
>   *The shape was not HELD.*  Nothing failed if the next bump dropped the
>   badge, because the README is GENERATED -- a generator change can lose a
>   section without a red line.  `_verify/_verify_readme_shape_1650.py`
>   (**29** checks) holds the shape now: the badge must name a
>   TRACKED workflow, point at
>   this project's own repository, carry that workflow's own name, and belong
>   to a workflow that runs on a push to the release branch; the opening must
>   keep the reference's ORDER -- title, badge, paragraph, status -- and the
>   status paragraph must name the manifest's licence, the manifest's backends
>   and the measured estimator count, must point at a section that exists,
>   must say what is not claimed, and must carry no version literal.  The
>   shape the references SHARE is held too: a console block with a command and
>   its output, the install command, `moon update`, a MoonBit import block, a
>   "not covered" section, a licence section, an attribution section, a table
>   row naming every declared backend, the toolchain statement and the
>   test-count row.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round59_1650.py` breaks ONE promise, and the failure count
>   must GROW at every step.  The run ends at **28** failures.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **459** and makes **461**: a path named in prose is a check, and this
>   round names 2 more of them.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**70** checks) is the new number.

> * **Round 70.**  The dependency pin moved, and the TOOLCHAIN moved with it.
>
>   The tree's own dep-pin check turned RED: the registry published
>   `moonbitlang/async@0.22.6` and the pin was one version behind.  Nothing
>   was wrong with the DOCUMENTS -- the TREE was behind, and the check said so
>   before anything was published.
>
>   *The move was not a number edit.*  0.22.6 imports
>   `moonbitlang/core/async`, a subpackage that only the core shipped with
>   `moon 0.1.20261028` carries.  On `moon 0.1.20261023` the build plan could
>   not even be SOLVED -- "Cannot find import 'moonbitlang/core/async' in
>   moonbitlang/async@0.22.6" -- and the library stopped building altogether.
>   So the toolchain moved with the dependency, which is what the workflows
>   do anyway: they install the LATEST `moon`.
>
>   *Every claim that NAMED the toolchain was re-derived, not re-labelled.*
>   The four per-target counts are still **1117 / 1123 / 1117 / 1117**; a bare
>   `moon test` still reports `Total tests: 0` for `wasm` and `native` and
>   "no test entry found" for `js`; `@std/env`, `@std/fs`, `@std/io` and
>   `@std/process` still do not resolve; `read_file` is still error **4021**;
>   and `train` is still not reserved.  All five hold, so only the LABELS
>   moved -- in the README, in `AGENTS.md`, in the tutorials, in the skill, in
>   the bitexact harness, and in the two workflows that justify
>   `--allow-inert`.
>
>   *The pin is now DERIVED.*  The README named it in four places, and every
>   one of them was a literal in the builder -- so the class of staleness was
>   "the registry publishes a version and the document keeps naming the old
>   one".  The builder now reads the pin from `moonbit_doubleML/moon.mod` and
>   the quoted `dependencies` WARN from the harness's own rule, so the README
>   CANNOT name a pin the tree does not declare.
>
>   *The check that would have caught it.*  The dependency RULE's own example
>   named a pin, and NOTHING held it to the tree: the manifest could move and
>   the rule could keep quoting the old version, and no check would have said
>   so.  `_verify/_verify_dep_pins_1680.py` now asserts that a version a
>   document names must be a version the tree declares -- the class it was
>   already meant to own -- and the rule's example is in it.
>
>   *The recorded evidence was stale too.*  `_verify/_qa_fast_1639.json` was
>   added in v0.164.31 and had never been refreshed; its `dependencies`
>   evidence still named `0.22.5`, and the check that compares the README's
>   quote against it caught exactly that.  It is refreshed now, from a REAL
>   run of the harness on the new toolchain: the same tally (**19** PASS,
>   **10** SKIP, **2** WARN), and the artifact records the toolchain that
>   measured it.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round70_1650.py` breaks ONE promise -- the rule's
>   example, the table's row, the service sentence -- and the failure count
>   must GROW at every step.  The run ends at **5** failures.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **461** and makes **463**: a path named in prose is a check, and this
>   round names 2 more of them.
>
>   *The ledger holds.*  This round publishes no count for a NEW check -- it
>   extends one that already had one -- so
>   `_verify/_verify_ledger_counts_1650.py` (**70** checks) is unchanged.

> * **Round 71.**  The README states the FLOOR a reader must meet.
>
>   Round 59 REFUSED to publish a minimum toolchain, and the refusal was
>   right at the time: nothing in this tree established one.  The tree pinned
>   `moonbitlang/async@0.22.5`, whose published source does not touch the
>   core at all, so ANY `moon` could build this package.  Round 70 moved the
>   pin to `0.22.6` -- and THAT is what established the floor, because
>   0.22.6 is the first published version whose source imports a subpackage
>   the core has to provide.
>
>   *The floor is measured, not asserted.*  Every published version from
>   0.10.0 to 0.22.5 has ZERO files importing `moonbitlang/core/async`;
>   0.22.6 has six.  The core that ships with `moon 0.1.20261028` carries the
>   subpackage; the core of `moon 0.1.20261023` does not.  And a CONSUMER
>   proves it end to end: the published package builds on the new core, and
>   on the old one it fails to solve with "Cannot find import
>   `moonbitlang/core/async` in `moonbitlang/async@0.22.6`" -- the same
>   consumer, the same package, two cores, so the failure IS the floor.
>
>   *Dead is not the same as harmless.*  The "Not covered" section called
>   both declared dependencies dead, and a reader could reasonably take that
>   to mean they cost nothing.  One of them does: the dead pin is what sets
>   the floor.  The other one does not -- `sqlite3`'s published source
>   imports five core subpackages, and the older core carries every one of
>   them.
>
>   *The check that holds it.*  `_verify/_verify_toolchain_floor_1680.py`
>   runs **21** checks: the pin is read out of `moon.mod`, the published
>   source of that pin is read out of the toolchain's own downloaded copy,
>   the installed core is asked whether it carries the subpackage, and the
>   Installation section and the Status table are asked whether they name
>   the same toolchain.  A floor NEWER than the toolchain the release was
>   verified on would be a release that cannot build on the floor it
>   publishes -- and that is a check too.
>
>   *The dependency RULE is not the only place a version appears.*  The
>   Installation section names the pin the floor is built on, so
>   `_verify/_verify_dep_pins_1680.py` now holds that site as well: a
>   version a document names must be a version the tree declares.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round71_1650.py` breaks ONE promise -- the pin, the
>   toolchain agreement, the floor's direction, the cost of the dead pin,
>   the installation guide, and the core the measurement reads.  The run
>   ends at **10** failures, and the capture is published.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **461** and makes **465**: a path named in prose is a check, and
>   this round names 2 more of them.
>
>   *The ledger moved.*  This round publishes a count for a NEW check, so
>   `_verify/_verify_ledger_counts_1650.py` (**72** checks) is the new number.

> * **Round 72.**  Three passages that had gone out of date -- and the two
>   references have moved since round 59 measured them.
>
>   *Two INDEPENDENT audits, and both said PASS.*  A fresh-eyes read of the
>   published README -- one hunting stale claims, one hunting the
>   verification claims -- found no false claim and no stale number in the
>   measured surface: the 22 estimators in 19 files, the 220 `.mbt` files,
>   the 1117 tests, the 24 validators, the 9 upstream gates, the 15/4/3
>   sandwich split, the 7 score takers and the 8 argument sets all match the
>   tree.  What they found was three passages that had gone QUIETLY out of
>   date -- and every one of them was a promise nothing held.
>
>   *The vectorised inventory.*  The README listed the public free functions
>   `vectorized.mbt` exports: FOUR of them.  The file exports SIX --
>   `vector_multiply` and `vector_divide` (v0.82.0+) were missing.  It named
>   the IRM and PLR paths as the callers of `vector_subtract`; TWELVE library
>   files call it.  The helpers were added and the document was not, and
>   NOTHING held the claim, which is exactly why it could rot.
>
>   *The Development section pointed at a frozen snapshot.*  It said the test
>   suite, the Python cross-checks, the QA harness and the reproducibility
>   commands "are all documented in `ENGINEERING.md`".  They are -- but
>   `ENGINEERING.md`'s BODY is this README as it stood at `v0.164.11`, word
>   for word, so a reader sent there for the CURRENT commands was sent to a
>   snapshot.  The live ones are in `.github/workflows/check.yml` and
>   `.github/scripts/qa_loop/`, and the section says so now.
>
>   *And fixing that broke a driver that was anchored to the old
>   sentence.*  `_verify/_dryrun_round23_1650.py` proves the README's
>   SHAPE by breaking it in six places, and one of the six -- the
>   relative markdown link -- was anchored to the LITERAL sentence
>   "documented in `ENGINEERING.md`, together with".  Rewriting that
>   sentence killed the anchor: the driver stopped on its THIRD
>   mechanism, so the last three never ran and it published a failure
>   count it had not measured.  The holder was already in the tree --
>   `_verify/_verify_dryrun_teeth_1650.py` asks whether every anchor in
>   every tracked driver is still live, and it is what caught this --
>   which is what that verifier exists for.  The anchor is a REGEX now:
>   it names the PROMISE (the README names the companion document in a
>   code span, and the registry serves exactly one file, so that name
>   must not become a relative link) and not the wording the promise
>   happens to be wearing this release.
>
>   *The opening paragraph lost a caveat that had ALREADY been corrected
>   once.*  Round 22 corrected "a claim that one API shape covered all 22
>   estimators when six constructors differ" -- and round 48's condensation
>   dropped the caveat from the opening paragraph AGAIN, while keeping it in
>   the Features list eleven lines further down.  A correction that has to be
>   made twice needs a holder, not another round's memory.
>
>   *The counts are derived now.*  The test totals were LITERALS inherited
>   from the v0.164.11 base document the generator starts from.  They are
>   derived from the tree now -- by the same rule
>   `_verify/_verify_testcounts_1610.py` uses, so the generator and the check
>   that holds it cannot disagree -- and every claim SHAPE is derived, the
>   ones present and the ones a later round adds.  A shape that DISAPPEARS
>   is an abort: a claim that silently stopped being made is a claim nobody
>   is watching any more.
>
>   *The references have moved, and the badge row with them.*  capnp is at
>   0.3.0 and discord at 0.13.0; both named versions are still there.  The
>   deferred plan was to give this README discord@0.10.0's six-badge
>   opening.  Measured: discord REMOVED four of its six badges between 0.10.0
>   and 0.13.0, and capnp carries exactly ONE badge -- the CI one -- at both
>   versions, which is what this README carries.  A badge row is decoration
>   that one of the references has since deleted, so the plan is DROPPED on
>   the references' own evidence.
>
>   *The dependency pin moved, and the toolchain floor did NOT.*  The registry
>   published `moonbitlang/async@0.22.7` on 2026-10-30 and the tree's own
>   dep-pin check turned RED: the pin has to be the published latest, and it
>   was one version behind.  Nothing was wrong with the DOCUMENTS -- the TREE
>   was behind, and the check said so before anything was published.  The pin
>   moved in both manifests with `moon add --upgrade`, and the README followed
>   without a hand-edited version, because every place it names the pin is
>   DERIVED from the manifest.  The floor did NOT move: the published source
>   of 0.22.7 imports the same three core subpackages 0.22.6 does -- `async`,
>   `debug` and `set` -- and the toolchain's bundled core carries all three,
>   so the Installation section's minimum `moon` is unchanged and the whole
>   gate was re-run on the new dependency before anything was published.
>
>   *And four other live documents named the old pin, and NOTHING held
>   them.*  `AGENTS.md`, the introduction, the installation guide and the agent
>   skill carry the pin in prose, and no check read those sites.  Round 70
>   moved the pin by hand in those files, and for one release they were a
>   version AHEAD of the tree -- v0.164.54 named `moonbitlang/async@0.22.6`
>   while the tree still pinned 0.22.5.  A literal with no holder is a literal
>   that rots, and the registry publishes a new version every day.  Their
>   literals move with the tree's now, and
>   `_verify/_verify_dep_pins_1680.py` holds them: every live document that
>   names a third-party pin must name a version the tree declares, with the
>   two historical documents exempt.  The check was proved to BITE -- a
>   document put back on the old pin turns it red.
>
>   *Three published counts moved with it.*  The new check holds the README's
>   own pin sites as well, and three dry-run drivers break exactly those sites
>   -- the dependency table's note, the rule's example and the Installation
>   requirement.  Their published failure counts moved with the check -- 8 ->
>   9, 4 -> 5 and 9 -> 10 -- and they are re-published with the MEASURED
>   values, not with the numbers an earlier round measured.  The rule was not
>   weakened to keep the old numbers: a check scoped to dodge a published
>   count is a check that stops holding the thing it was written for.
>
>   *The checks that hold them.*  `_verify/_verify_vectorised_surface_1680.py`
>   runs **12** checks: the exported names come out of `vectorized.mbt`, the
>   caller set out of the library's own sources, and the README's paragraph
>   is asked whether it names every one of them, names none that the file
>   does not export, and states the measured count.
>   `_verify/_verify_readme_caveats_1680.py` runs **18** checks: the opening
>   paragraph's caveat, the Features list's, the API reference's own
>   constructor table, and the Development section's pointer at the live gate
>   sources.  Both were proved to BITE -- the old text fails them -- before
>   either was published.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round72_1650.py` breaks ONE promise -- drop a helper,
>   name one that does not exist, understate the caller count, call
>   `matrix_predict` an element-wise wrapper, drop the API-shape caveat, and
>   put the stale pointer back.  The run ends at **14** failures, and the
>   capture is published.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **465** and makes **470**: a path named in prose is a check, and this
>   round names 3 more of them -- the two places the current gate
>   commands live, and the driver that proves the README's shape.
>
>   *The ledger moved.*  This round publishes a count for TWO new checks, so
>   `_verify/_verify_ledger_counts_1650.py` (**76** checks) is the new
>   number.
>
>
>
>
>
"""

ledger = LEDGER_HEAD + "## The README as it stood at v0.164.11\n\n" \
    + SRC.split("\n", 1)[1].lstrip("\n")

# ==============================================================================
# 2.  THE README -- the library document
# ==============================================================================

PITCH = blk(1, 28)

# The pitch's second sentence names the two renamed estimators.  "renamed" has
# to be in it: the provenance table and the pitch must use the same word for the
# same thing, and a verifier checks the count and the word together.  The
# rewrap keeps "**no 1:1 upstream class**" on one line for the same reason --
# a line break inside a bold phrase breaks every regex that looks for it.
PITCH = PITCH.replace(
    "**2** are upstream estimators under\na different name -- `DoubleMLRDD` is "
    "upstream's RDD estimator (upstream\ncalls it `RDFlex`) and "
    "`DoubleMLDIDCrossSection` is upstream's\n`DoubleMLDIDCS`; and **1**, "
    "`DoubleMLDIDCS`, has **no 1:1 upstream\nclass** -- it is this port's "
    "variant of upstream's multi-period\n`DoubleMLDIDMulti`, which upstream "
    "keeps in a single class that this\nport splits in two. Those provenance "
    "labels are re-measured against the\n**installed** `doubleml` 0.11.3 "
    "package, not asserted -- see the\nestimator table below and "
    "`_verify/UPSTREAM_PROVENANCE.md`.",
    "**2** are renamed -- `DoubleMLRDD` is upstream's RDD estimator (upstream\n"
    "calls it `RDFlex`) and `DoubleMLDIDCrossSection` is upstream's\n"
    "`DoubleMLDIDCS`; and **1**, `DoubleMLDIDCS`, has **no 1:1 upstream class**\n"
    "-- it is this port's variant of upstream's multi-period `DoubleMLDIDMulti`,\n"
    "which upstream keeps in a single class that this port splits in two. Those\n"
    "provenance labels are re-measured against the **installed** `doubleml`\n"
    "0.11.3 package, not asserted -- see the estimator table below and\n"
    "`_verify/UPSTREAM_PROVENANCE.md`.")

FEATURES = """## Features

- ✅ **22 estimators** in 19 source files -- PLR, IRM, PLIV, IIVM, the DID
  family (5), SSM, APO, APOS, PQ, QTE, LPQ, LPLR, CVAR, RDD, BLP, PLPR and
  PolicyTree. The table is below.
- ✅ **One API shape** -- `DoubleMLXxx::new(...).fit()`. Two different sets of
  six differ -- six in their accessors, six in their constructors -- and both
  are named in **API reference** rather than left to be discovered.
- ✅ **Cross-fitting infrastructure** -- `kfold`, repeated cross-fitting,
  stratified K-fold, a `chacha8_rng(seed)` PRNG, and Kahan summation.
- ✅ **Robust variance and inference** -- heteroskedasticity-consistent (HC)
  standard errors, cluster-robust variance, multiplier bootstrap confidence
  intervals, joint CIs, and Romano-Wolf multiple-testing adjustment.
- ✅ **Propensity-score processing** -- `PSProcessorConfig`: clipping,
  isotonic calibration, CV calibration, all reachable from an estimator.
- ✅ **Four backends** -- `native`, `wasm`, `wasm-gc`, `js` -- all green under
  `moon test --deny-warn`.
- ✅ **24 / 24 Python reference scripts PASS** -- 25 of the 25 bit-exact items
  and 6 / 6 RNG keys are IEEE-754 identical to CPython.
- ✅ **No runtime third-party dependency** -- the library imports nothing
  outside `moonbitlang/core`.
- ✅ **21 runnable example binaries**, an HTTP service, and a property-based
  fuzz harness.

"""

# ROUND 71: THE INSTALLATION SECTION STATES THE FLOOR.
#
# `capnp@0.1.0` says which MoonBit it needs ("需要 MoonBit 0.10.14 或更新
# 版本").  Round 59 REFUSED to publish a floor, because nothing in this tree
# established one -- and at that time nothing did: the pin was
# `moonbitlang/async@0.22.5`, whose published source does not touch the core
# at all, so any `moon` could build it.
#
# Round 70 moved the pin to 0.22.6, and THAT is what established the floor.
# The published source of 0.22.6 imports `moonbitlang/core/async` (six
# files); every earlier published version -- 0.10.0 through 0.22.5 -- does
# not.  A core that carries the subpackage arrived with `moon 0.1.20261028`
# (core 0.10.18); the core of `moon 0.1.20261023` does not have it, and a
# CONSUMER on that toolchain cannot resolve the dependency at all.
#
# So the floor is a FACT about the published package, not a preference, and
# it is stated where a reader meets it: immediately before the `moon add`
# they are about to run.  The pin is DERIVED (see `ASYNC`), so this sentence
# cannot name a version the tree does not declare; the toolchain is DERIVED
# (see `TOOLCHAIN`), so a toolchain move is one edit and not four.
INSTALL = ("""## Installation

**Requires `moon __TOOLCHAIN__` or newer.** The package declares
`moonbitlang/async@__ASYNC_PIN__`, and that published version imports
`moonbitlang/core/async` -- a subpackage of the MoonBit core that older
cores do not carry. On an older `moon` the dependency cannot be resolved at
all: the build fails with "Cannot find import `moonbitlang/core/async` in
`moonbitlang/async@__ASYNC_PIN__`". The core that ships with
`moon __TOOLCHAIN__` provides it, and this release's tests, cross-checks and
bit-exactness gate were run on that toolchain.

```bash
moon add riantr/moonbit_doubleML
```

Then reference it from `moon.mod`:

```moonbit nocheck
///|
import {
  "riantr/moonbit_doubleML@%(v)s",
}
```

""").replace("__TOOLCHAIN__", TOOLCHAIN).replace("__ASYNC_PIN__", ASYNC)

# The upstream-correspondence note.  The full derivation is in ENGINEERING.md.
#
# ROUND 22: the note used to open with "**AMENDED 2026-10-20 (round 16).**".
# That is the project's own review vocabulary: "round 16" means nothing to a
# reader who has only the published page, and "AMENDED" promises a previous
# version they never saw.  The substance -- which names do not map 1:1, and
# where the derivation is -- is kept; the internal marker is not.  The naming
# map is already in the estimator table above, so what is left here is a
# pointer rather than a second copy of it.
#
# The paths are CODE SPANS, not links, and that is deliberate: the README
# that ships is the only file the registry publishes, so a relative link to a
# file in the repository is a link to nowhere on the published page.  The
# old README used code spans for the same reason.
AMENDED = """> **How the names map.** `DoubleMLDIDCS` has **no 1:1 upstream class**
> -- it is this port's variant of upstream's `DoubleMLDIDMulti` -- and the
> two *renamed* pairs are `DoubleMLRDD` (upstream `RDFlex`) and
> `DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`). The derivation, and
> the parameter that distinguishes them, are in
> `_verify/UPSTREAM_PROVENANCE.md` and in `ENGINEERING.md`.

"""

# The RDD arm, verbatim, cut at the sentence boundary.  The next sentence in
# the old README ("The standing rule is the same one below") pointed at text
# that stayed in the ledger, so the pointer would dangle here.
RDD_ARM = blk(1369, 1378)
RDD_ARM = RDD_ARM[:RDD_ARM.index("than asserted.") + len("than asserted.")]

# The pitfalls, in the reference page's DO / DON'T shape.  The LPLR regime and
# the RDD arm are the old README's own paragraphs, kept verbatim -- they are
# the two places where the port's answer can be wrong in a way a user has to
# know about before trusting it.
PITFALLS = """## Common pitfalls and best practices

### ⚠️ Partially logistic regression: the small-n regime

This port damps LPLR's Newton step so the answer stays finite; upstream does
not. What follows is why that is a fragility the two implementations SHARE, and
not a defect this port introduced.

%(lplr)s

### ✅ DO

1. **Pass a classifier for `ml_m` wherever the propensity carries
   identification.** The estimators that need one default to
   `logistic_regression`; the ones that do not are named in **Propensity
   processing** above, with the measurement behind each. `ml_g` deliberately
   stays OLS -- it models `E[y | x]`, not `P(y = 1 | x]`.
   `LearnerDispatch::is_classifier()` reports which constructors qualify.
2. **Read the warnings.** `DoubleMLLPLR::fit()` can return a degenerate
   standard error, and it says so rather than returning a confident wrong
   number:

   ```moonbit
   let model = DoubleMLLPLR::new(data, alpha=1.5).fit()
   for w in model.warnings() { println(w) }
   ```

3. **Treat `n < 200` as ill-posed for partially logistic regression.** Both
   this port and upstream fail there, in opposite directions, and the port
   damps its Newton step to keep the answer finite.

### ❌ DON'T

1. **Don't read a small-n LPLR standard error as an estimate.** At `n = 500`
   the port and upstream agree to ~0.007. Below that the gate is a *report*,
   not a guarantee.
2. **Don't assume every `adjust_ps` call forwards `cv`.** The `adjust_ps`
   call sites that do not forward `cv` are **eight**, in seven files:
   `apo.mbt:320`, `cvar.mbt:736`, `cvar.mbt:1005`, `did.mbt:628`,
   `did_cross_section.mbt:615`, `did_cs_binary.mbt:374`, `quantile.mbt:217`
   and `ssm.mbt:671`. The only two that do are IRM's and IIVM's -- `cv=` is
   passed at `irm.mbt:430` and `iivm.mbt:525`.
3. %(rdd)s
"""

readme = []
A = readme.append

A(PITCH.rstrip() + "\n")
A(FEATURES)
A(blk(51, 77).rstrip() + "\n")
A(INSTALL % {"v": V})
A("## Quick Start\n\n" + blk(1492, 1518).rstrip() + "\n\n"
  + blk(1522, 1532).rstrip() + "\n")
A("## The 22 estimators\n\n" + blk(1611, 1623).rstrip() + "\n\n"
  + blk(1624, 1647).rstrip() + "\n\n" + blk(1649, 1658).rstrip() + "\n\n"
  + AMENDED)
A("## API reference\n\n" + blk(79, 97).rstrip() + "\n\n"
  + blk(1426, 1449).rstrip() + "\n")
A("## Propensity processing\n\n" + blk(116, 228).rstrip() + "\n")
A("## Cross-fitting\n\n" + blk(99, 114).rstrip() + "\n")
A("## Examples\n\n" + blk(1536, 1608).rstrip() + "\n")
A((PITFALLS
    .replace("%(lplr)s", blk(1134, 1162).rstrip())
    .replace("%(rdd)s", RDD_ARM.replace("\n", "\n   ").rstrip())))
A("## Development status\n\n" + blk(32, 47).rstrip() + "\n")
A("### Validated against upstream, not only against ourselves\n\n"
  + blk(1349, 1367).rstrip() + "\n")
A("### Numerical parity with CPython\n\n" + blk(1958, 1977).rstrip() + "\n")
A("### Not covered, so not claimed\n\n" + blk(2024, 2038).rstrip() + "\n")
A("### Honest policy trees (v0.98.0)\n\n" + blk(1753, 1782).rstrip() + "\n")
A("## Project layout\n\n" + blk(1786, 1814).rstrip() + "\n")
A("## Dependency rule\n\n" + blk(1818, 1836).rstrip() + "\n")
A("## Attribution\n\n" + blk(2244, 2274).rstrip() + "\n")
A("## Used By\n\n" + blk(2278, 2290).rstrip() + "\n")
A("""## Development

`ENGINEERING.md` is the companion, and it is worth saying what it is: its
header is the correction ledger for every round to date, and its body is this
README as it stood at `__SRCTAG__`, word for word. The CURRENT gate commands
are not in that snapshot -- they are in `.github/workflows/check.yml` (what CI
runs) and `.github/scripts/qa_loop/` (the QA harness the CI job invokes).
Both files are in the repository; the registry publishes this one.

```console
$ moon test --target native --deny-warn
Total tests: 1117, passed: 1117, failed: 0.
```

## License

MIT. The upstream package, `DoubleML/doubleml-for-py`, is BSD 3-Clause; this
port is MIT-licensed and credits it (see **Attribution** above).
""".replace("__SRCTAG__", SRC_TAG))

text = "\n".join(readme)
while "\n\n\n" in text:
    text = text.replace("\n\n\n", "\n\n")

# The version sites the old README carried are rewritten to the version in
# `moon.mod`.  The old README's own version is derived from its source, not
# typed in: the builder must not know the version it is building.
_m = re.search(r"\*\*(\d+\.\d+\.\d+)\*\*", SRC)
OLD_V = _m.group(1) if _m else ""
if OLD_V and OLD_V != V:
    text = text.replace("| `moon.mod` version | **%s** |" % OLD_V,
                        "| `moon.mod` version | **%s** |" % V)
    text = text.replace("(moon.mod v%s," % OLD_V, "(moon.mod v%s," % V)

# ==============================================================================
# 3.  THE ROUND-20 PATCH
# ==============================================================================
#
# The API reference promised that the differences between the estimators were
# "listed here rather than discovered later", and then listed only the
# ACCESSOR differences.  The CONSTRUCTOR differences are a different six --
# `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ` take `n_folds` and `seed` but
# no `n_rep`, and `DoubleMLBLP`, `DoubleMLRDD`, `DoubleMLPolicyTree` take
# none of the three -- and the two sets overlap in only three estimators.  A
# reader of `DoubleMLPQ` or `DoubleMLRDD` found nothing in the table, which
# is exactly the "discovered later" the sentence promised to prevent.
#
# The README is GENERATED, so the fix has to live here: an edit made to
# README.mbt.md directly would be reverted by the next bump.
#
# `_verify/_verify_ctor_options_1650.py` derives the groups from the
# constructors' signatures and checks the README against them.

OLD_API = """**One API shape, with the differences named** -- every estimator is built
`DoubleMLXxx::new(...).fit()`, with `n_folds` / `n_rep` / `seed` among the
labelled options. The *shape* is uniform; the signature and the accessor set
are not, and the six exceptions are listed here rather than discovered later:

| estimator | instead of | because |
|---|---|---|
| `DoubleMLAPOS` | `coef` / `se` -> `coefs` / `ses` | one estimate per treatment level |
| `DoubleMLQTE` | `coef` / `se` -> `coefs` / `ses` | one estimate per quantile |
| `DoubleMLDIDCS` | `coef` / `se` -> `coef_at` / `se_at` | one ATT per (group, period) |
| `DoubleMLDIDMulti` | `coef` / `se` -> `coef_at_idx` / `se_at_idx` | the same cells, by row-major index |
| `DoubleMLBLP` | `confint` -> `confint_joint` | the interval is for a contrast of the IV coefficient vector |
| `DoubleMLPolicyTree` | no scalar coefficient at all | `leaf_influence`, `leaf_se`, `policy_value`, `policy_value_se` |

The other 16 expose `.coef()` / `.se()` / `.confint()` / `.bootstrap()`.
Constructor arguments differ for the same reason: `DoubleMLDIDBinary` needs
`g_value` / `t_value_pre` / `t_value_eval`, `DoubleMLAPOS` needs
`treatment_levels`, `DoubleMLPolicyTree` needs `features` / `orth_signal` /
`depth` / `honest`, and each DID variant takes its own data type."""

NEW_API = """**One API shape, with the differences named** -- every estimator is built
`DoubleMLXxx::new(...).fit()`. The *shape* is uniform; the signature and the
accessor set are not, and **both** sets of differences are listed here rather
than discovered later. They are two different sets of six, and they overlap in
only three estimators.

**The accessor differences:**

| estimator | instead of | because |
|---|---|---|
| `DoubleMLAPOS` | `coef` / `se` -> `coefs` / `ses` | one estimate per treatment level |
| `DoubleMLQTE` | `coef` / `se` -> `coefs` / `ses` | one estimate per quantile |
| `DoubleMLDIDCS` | `coef` / `se` -> `coef_at` / `se_at` | one ATT per (group, period) |
| `DoubleMLDIDMulti` | `coef` / `se` -> `coef_at_idx` / `se_at_idx` | the same cells, by row-major index |
| `DoubleMLBLP` | `confint` -> `confint_joint` | the interval is for a contrast of the IV coefficient vector |
| `DoubleMLPolicyTree` | no scalar coefficient at all | `leaf_influence`, `leaf_se`, `policy_value`, `policy_value_se` |

The other 16 expose `.coef()` / `.se()` / `.confint()` / `.bootstrap()`.

**The constructor differences** -- which estimators take `n_folds` / `n_rep` /
`seed`. This is a different partition from the accessor table above, so the
two groups of "the other 16" are not the same sixteen:

| estimators | `n_folds` | `n_rep` | `seed` |
|---|---|---|---|
| the other 16 | yes | yes | yes |
| `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ` | yes | **no** | yes |
| `DoubleMLBLP`, `DoubleMLRDD`, `DoubleMLPolicyTree` | no | no | no |

The quantile estimators cross-fit once -- `solve_pq` has no repetition loop,
so there is no `n_rep` to set. The last three take no cross-fitting option
at all: `DoubleMLBLP` is given a basis and an orth signal, `DoubleMLRDD`
fits locally around a cutoff, and `DoubleMLPolicyTree` splits the sample
once for its honest split (its own `split_seed`).

Constructor arguments also differ in ways a table cannot show:
`DoubleMLDIDBinary` needs `g_value` / `t_value_pre` / `t_value_eval`,
`DoubleMLAPOS` needs `treatment_levels`, `DoubleMLPolicyTree` needs
`features` / `orth_signal` / `depth` / `honest`, and each DID variant takes
its own data type."""

PATCHES = [(OLD_API, NEW_API)]

# ==============================================================================
# 3b.  THE ROUND-21 PATCH -- two measured figures that were never right
# ==============================================================================
#
# The propensity-margin paragraph quoted three figures that the measurements do
# not support.  Round 21 re-ran both arms of both fixtures against the CURRENT
# tree and got:
#
#   DoubleMLIRM   worst default |bias| 0.19827515142504515
#                 best OLS      |bias| 72.7973000454581
#                 separation 367.15x
#   DoubleMLAPO   worst default |bias| 0.5306843118134537
#                 best OLS      |bias|  5.246423466298134
#                 worst default SE   0.2695805382351013
#                 best OLS      SE   86.2780366255941
#                 SE separation 320.03x
#
# So "recovers within 0.198" was false (the bias is 0.19828), "misses by at
# least 72.8" was false (the smallest miss is 72.7973), and "366x" and "300x"
# were both mis-ratios.  The 366x was a slip that had been copied through the
# v0.132.0 CHANGELOG entry, the v0.132.0 gate's comment, the v0.134.0 gate's
# comment, the README and the ledger.
#
# The figures are now stated as the MEASURED worst / smallest, at enough
# precision that the separation is DERIVABLE from the two numbers the reader
# can see: 72.797 / 0.1983 = 367.06 -> "367x", and 86.28 / 0.270 = 319.56 ->
# "320x".  A reader who divides gets the figure the document states.
#
# `_verify/_verify_hazard_margins_1650.py` checks every number in this
# paragraph against `_verify/_hazard_margins_1650.json`, so the paragraph and
# the measurement cannot drift apart.

OLD_MARGINS = """across three seeds: default recovers within `0.198`, an OLS propensity misses
by at least `72.8` -- a 366x separation on the coefficient. `DoubleMLAPO`
(true `E[Y | D=1] = 1.2`): default within `0.531`, OLS misses by as little as
`5.246` -- only ~10x. APO's standard error is the honest discriminator
(`0.270` vs `86.28`, a 300x separation), because the mechanism is that an"""

NEW_MARGINS = """across three seeds: the default's worst bias is `0.1983`, the OLS arm's
smallest bias is `72.797` -- a 367x separation on the coefficient.
`DoubleMLAPO` (true `E[Y | D=1] = 1.2`): the default's worst bias is `0.5307`,
the OLS arm's smallest bias is `5.2464` -- only ~10x. APO's standard error is
the honest discriminator (`0.270` vs `86.28`, a 320x separation), because the
mechanism is that an"""

PATCHES.append((OLD_MARGINS, NEW_MARGINS))

# ==============================================================================
# 3b.  THE ROUND-23 PATCH -- whose 22 estimators?
# ==============================================================================
#
# The opening sentence is:
#
#   "A pure-MoonBit port of the `doubleml-for-py` Python package -- the Python
#    ecosystem's most mature Double / Debiased Machine Learning implementation
#    -- 22 estimators in total."
#
# The subject of that sentence is the PORT, so "22 estimators in total"
# predicates the port -- and the next sentence ("**19** match a class of the
# same name in upstream; **2** are renamed; and **1** has no 1:1 upstream
# class") sums to 22, which is the port's count.  Upstream has **21**
# estimator classes: the 19 name-identical ones plus `RDFlex` and
# `DoubleMLDIDCS`.  The arithmetic is right.
#
# But the appositive in the middle names the UPSTREAM package, and a reader
# who takes "22 estimators in total" to belong to it is told upstream has 22
# when it has 21.  The fix is one word and it makes the count parallel with
# the 19 / 2 / 1 that follow, which are all bold for exactly this reason.
#
# `_verify/_verify_round16_provenance_1650.py` already derives the grouping
# from the INSTALLED upstream package -- 21 upstream classes plus the one
# port estimator with no 1:1 class -- so the arithmetic this sentence
# describes is machine-checked; what was left was only the reading.

OLD_TWENTY_TWO = """package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- 22 estimators in total. **19** match a
class of the same name in upstream; **2** are renamed -- `DoubleMLRDD` is upstream's RDD estimator (upstream"""

NEW_TWENTY_TWO = """package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- with **22 estimators** in total. **19** match a
class of the same name in upstream; **2** are renamed -- `DoubleMLRDD` is upstream's RDD estimator (upstream"""

PATCHES.append((OLD_TWENTY_TWO, NEW_TWENTY_TWO))

# ==============================================================================
# 3c.  THE ROUND-22 PATCHES -- a line-by-line read of the published text
# ==============================================================================
#
# Round 22 read the built README line by line, the way a reader would, and
# checked every claim it makes against the tree.  Twelve passages were wrong,
# ambiguous or stale.  Each is corrected here, in the generator, for the
# reason round 21 used: README.mbt.md is BUILT, so an edit made to it
# directly is reverted by the next bump.
#
# Four of the twelve are factual and are recorded in the CHANGELOG as
# corrections; the rest are prose.  The comments below say what each one was
# and how it was checked, so a later reader can re-derive the correction
# instead of taking it on trust.
#
# P1. THE API CLAIM CONTRADICTED THE API REFERENCE.
# The pitch promised "a unified `DoubleMLXxx::new(data, n_folds, n_rep,
# seed).fit()` API across all 22 estimators", and the Features list said
# "One API shape ... Six estimators differ in their accessors".  But the
# API reference (added in round 20) lists TWO different sets of six -- the
# accessor six and the CONSTRUCTOR six -- and they overlap in only three
# estimators.  A reader who believed the pitch would write
# `DoubleMLBLP::new(data, n_folds, n_rep, seed)`, which does not compile.
# The six that differ in their constructor are named in the API reference.
OLD_API_SHAPE = """inside the MoonBit ecosystem. Delivers a unified
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` API across all
22 estimators, robust variance estimation, propensity-score
processing, multiple-testing correction, and a reproducible validation
pipeline (24 / 24 Python reference scripts PASS) -- on `native`,"""

NEW_API_SHAPE = """inside the MoonBit ecosystem. Delivers one
`DoubleMLXxx::new(...).fit()` API across all 22 estimators -- the shape
is the same, but six take a different constructor, and those six are
named in **API reference** -- with robust variance estimation,
propensity-score processing, multiple-testing correction, and a
reproducible validation pipeline (24 / 24 Python reference scripts PASS)
-- on `native`,"""

# P2. THE FEATURES LIST DID NOT ADD UP TO ITS OWN HEADLINE.
# "PLR, IRM, PLIV, IIVM, the DID family (5), SSM, ..." sums to 21, under a
# headline that says 22.  The estimator table has SIX DID-family estimators
# -- DID, DIDBinary, DIDCS, DIDCSBinary, DIDMulti, DIDCrossSection -- so
# "the DID family (6)" is the count that makes the list sum to 22.
OLD_DID_COUNT = """- ✅ **22 estimators** in 19 source files -- PLR, IRM, PLIV, IIVM, the DID
  family (5), SSM, APO, APOS, PQ, QTE, LPQ, LPLR, CVAR, RDD, BLP, PLPR and
  PolicyTree. The table is below."""

NEW_DID_COUNT = """- ✅ **22 estimators** in 19 source files -- PLR, IRM, PLIV, IIVM, the DID
  family (6), SSM, APO, APOS, PQ, QTE, LPQ, LPLR, CVAR, RDD, BLP, PLPR and
  PolicyTree. The table is below."""

# P3. THE EXAMPLE COUNT DOUBLE-COUNTED TWO OF ITS OWN ITEMS.
# "21 runnable example binaries, an HTTP service, and a property-based fuzz
# harness" reads as 23, because `examples/api_server/` and `examples/fuzz/`
# are two OF the 21.  The Project layout section names them, and the
# Examples section counts them separately, so the two figures were already
# in the same document.
OLD_EXAMPLE_COUNT = """- ✅ **21 runnable example binaries**, an HTTP service, and a property-based
  fuzz harness."""

NEW_EXAMPLE_COUNT = """- ✅ **21 runnable example binaries** -- 16 CLI demos, an HTTP service, a
  consumer demo and a property-based fuzz harness."""

# P4. TWO PASSAGES DESCRIBED WHAT THE README USED TO SAY.
# "were for several releases described here as MoonBit-specific extras" and
# "were previously marked *(extra)*, which was wrong" are the document
# talking about its own history.  A reader who has only the published page
# has no "several releases" to compare against; the facts survive in the
# CHANGELOG and in the ledger, which is where a reader should look for them.
OLD_WAS_EXTRA = """`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` were for
several releases described here as MoonBit-specific extras; all three
ship upstream and the table marks them *(upstream)*."""

NEW_WAS_EXTRA = """`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` all ship
upstream, and the table marks them *(upstream)*."""

OLD_PREVIOUSLY_EXTRA = """partner by name coincidence. Three rows -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR` -- were previously marked *(extra)*,
which was wrong: all three ship upstream, so they had a reference
implementation all along."""

NEW_PREVIOUSLY_EXTRA = """partner by name coincidence. Three rows -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR` -- ship upstream, so each has a reference
implementation."""

# P5. THE "NUMERICAL PARITY" SECTION OPENED WITH A SENTENCE FRAGMENT.
# The block this section is built from starts at old-README line 1958, which
# is the SECOND half of a sentence: "patterns instead, against
# `examples/bitexact/`."  The subject -- and the tier statement that goes
# with it -- were at 1955-1957 and were dropped by the condensation.  A
# reader met a heading and then half a sentence.
OLD_BITEXACT_FRAGMENT = """patterns instead, against `examples/bitexact/`. Measured scope, not assumed --"""

NEW_BITEXACT_FRAGMENT = """**Bit-exact parity is a second, stronger tier.** A tolerance cannot tell "the
port is arithmetically identical to the reference" apart from "the port lands
within 1e-4 of it". `validate_bitexact_with_python.py` compares IEEE-754 bit
patterns instead, against `examples/bitexact/`. Measured scope, not assumed --"""

# P6. "THE FOUR TREE/LOGISTIC LEARNERS" WAS THREE.
# The README's own learner table marks exactly three learners as
# classification -- `LogisticRegression`, `RFClassifier`, `GBClassifier` --
# and `learner.mbt:200-202` (`is_classifier()`) returns true for exactly
# those three.  `RFLearner` and `GBLearner` are regression learners: they
# predict a mean, not a probability, so they cannot be among "the four".
OLD_FOUR_LEARNERS = """learner surface. This package ships eleven. The four tree/logistic
learners' `predict` returns `P(y = 1 | x)` for classification, never a
hard label, because DML's AIPW correction divides by the fitted
propensity."""

NEW_FOUR_LEARNERS = """learner surface. This package ships eleven. The three classification
learners' `predict` returns `P(y = 1 | x)`, never a hard label, because
DML's AIPW correction divides by the fitted propensity."""

# P7. "12 OF THE 16 PRINT A 95 % CI" WAS NEVER TRUE.
# The README's OWN breakdown beside the figure names FIVE demos that print
# no CI -- pava, splitting, apos, cluster, ssm -- and 16 - 5 = 11, not 12.
# The 12 came from the measuring script's CI regex, whose last alternative
# was `\[.*\]`: ANY line with a bracket pair counts as an interval, and
# `examples/pava` prints `case[v0] n=4 pava = 0.625 ...`.  pava prints no
# interval at all.  Re-measured with a definition that has to be satisfied by
# an actual interval -- a confidence level, a named interval, or both
# endpoints -- the count is 11, and the 11 are apo, cvar, datasets,
# did_binary, did_cross_section, did_cs, did_cs_binary, did_multi, lplr,
# main and plpr.  `_verify/_verify_cli_demo_ci_1650.py` re-derives it.
OLD_CI_COUNT = """demos that print an estimate; measured per driver, **14** of the 16 print a
true value and **12** of the 16 print a 95 % CI -- `examples/pava` and"""

NEW_CI_COUNT = """demos that print an estimate; measured per driver, **14** of the 16 print a
true value and **11** of the 16 print a 95 % CI -- `examples/pava` and"""

# P8. "AGENTS.md <- this file" COULD BE READ AS THE README.
# Every other line in that tree names its own file, so "this file" is
# ambiguous in the one place where the reader has an antecedent in mind --
# the document they are reading.
OLD_AGENTS_LINE = """AGENTS.md                <- this file (per moonbit agent convention)"""

NEW_AGENTS_LINE = """AGENTS.md                <- agent guide for coding agents (MoonBit convention)"""

# P9. A HEADING SKIPPED A LEVEL.
# `## Attribution` was followed by `#### Differences from upstream`, so the
# subsection was two levels down with nothing at the level in between.
OLD_ATTRIB_HEADING = """#### Differences from upstream `doubleml-for-py`"""

NEW_ATTRIB_HEADING = """### Differences from upstream `doubleml-for-py`"""

# P10. "ONE SCRIPT PER UPSTREAM CLASS" WAS NOT TRUE OF ITS OWN TABLE.
# `pyexample_pq.py` drives three upstream classes and `pyexample_suite.py`
# drives a family.
OLD_ONE_SCRIPT = """implementation" but "does the port agree with upstream". Measured designs, one
script per upstream class:"""

NEW_ONE_SCRIPT = """implementation" but "does the port agree with upstream". Measured designs, one
script per upstream class or family:"""

# P11. A VERSION PROMISE THAT WAS 80 RELEASES STALE.
# "a v0.82+ release can swap the bodies" read as a release still to come.
# The API has been fixed since v0.82; the package is at v0.164.x.
OLD_V082 = """today -- the public API is fixed so a v0.82+ release can swap
the bodies to a SIMD-vectorised backend (or external call to
a BLAS-style library) without breaking callers."""

NEW_V082 = """today -- the public API has been fixed since v0.82, so a future
release can swap the bodies to a SIMD-vectorised backend (or external
call to a BLAS-style library) without breaking callers."""

# ==============================================================================
# 3d.  THE ROUND-24 PATCHES -- two counts whose set a reader could not resolve
# ==============================================================================
#
# Two sentences used a bare count as a referent: "the largest margin of the
# four" and "all four earlier outcomes".  Both fours are the SAME four --
# DoubleMLIRM, DoubleMLAPO, DoubleMLAPOS and DoubleMLSSM -- but neither
# sentence said so, and the section offers two different candidate fours a
# few paragraphs apart.
#
# Where the referents came from, and why they are the same set:
#
#   * The SSM sentence was written in v0.138.0, the release that migrated
#     SSM's propensity default.  At that revision the paragraph above it
#     opened "The four migrations do NOT have the same margin" and the
#     paragraph before that listed exactly four migrations -- IRM (v0.132.0),
#     APO (v0.134.0), APOS (v0.135.0), SSM (v0.138.0).  A later condensation
#     dropped the count from "The four migrations" ("The migrations do NOT
#     all have the same margin") and left "the four" with no antecedent.
#   * The classifier sentence was written one release earlier, in v0.137.0,
#     when the four hazardous verdicts were exactly those same four; the
#     fifth, DoubleMLIIVM, is the case that refutes the classifier.
#
# Both sets are DERIVED, not asserted: `_verify/_verify_count_referents_1650.py`
# derives the four from the source (the estimators whose propensity default
# is a classifier) crossed with the README's own migration releases, and
# checks that each of these two sentences names all four.  The classifier
# sentence's own wording changed with it: "all four earlier outcomes" is now
# "the four hazardous verdicts of v0.132.0-v0.138.0", because "earlier
# outcomes" pointed at nothing and the release range is what separates these
# four from the two that turned out hazardous later (PQ and QTE, v0.139.0).

OLD_SSM_MARGIN = """`DoubleMLSSM` has the largest margin of the four, because its score carries
**two** reciprocals, one per direction (`ssm.mbt:73-74`): the treatment
propensity `m` and the selection propensity `pi`, so an unbounded regressor
breaks both denominators independently. On a saturated fixture with true
`theta = 1.0`, the OLS arm returns `242.116` with SE `185.45` where the
classifier returns `1.177` with SE `0.0982` -- roughly **200x** on the point
estimate and **1900x** on the standard error. Across three seeds the OLS
coefficient also **changes sign** (`+242`, `+106`, `-452`); the classifier's
spread over the same three seeds is `0.761`."""

NEW_SSM_MARGIN = """`DoubleMLSSM` has the largest margin of the four migrations of
v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and
`DoubleMLSSM` -- because its score carries **two** reciprocals, one per
direction (`ssm.mbt:73-74`): the treatment propensity `m` and the selection
propensity `pi`, so an unbounded regressor breaks both denominators
independently. On a saturated fixture with true `theta = 1.0`, the OLS arm
returns `242.116` with SE `185.45` where the classifier returns `1.177` with
SE `0.0982` -- roughly **200x** on the point estimate and **1900x** on the
standard error. Across three seeds the OLS coefficient also **changes sign**
(`+242`, `+106`, `-452`); the classifier's spread over the same three seeds
is `0.761`."""

OLD_CLASSIFIER = """A static classifier (read the score: does it carry `1/m`? is it doubly robust?)
was used to prioritise the probes, and it reproduces all four earlier outcomes
-- but `DoubleMLIIVM` **refuted** it, carrying `1/m` and `1/(1-m)` on every row
and still measuring harmless. A reciprocal in the score is not sufficient for
the hazard; the classifier is a way to decide what to measure first, nothing
more."""

NEW_CLASSIFIER = """A static classifier (read the score: does it carry `1/m`? is it doubly robust?)
was used to prioritise the probes, and it reproduces the four hazardous
verdicts of v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`,
`DoubleMLAPOS` and `DoubleMLSSM` -- but `DoubleMLIIVM` **refuted** it,
carrying `1/m` and `1/(1-m)` on every row and still measuring harmless. A
reciprocal in the score is not sufficient for the hazard; the classifier is a
way to decide what to measure first, nothing more."""

# ==============================================================================
# 3e.  THE ROUND-25 PATCHES -- three names that did not survive being used
# ==============================================================================
#
# Round 25 read the published README line by line once more and found three
# places where the text names something the package does not have.
#
# P12. THE LPLR SNIPPET PASSED A PARAMETER THAT DOES NOT EXIST.
# "DoubleMLLPLR::new(data, alpha=1.5)" -- `DoubleMLLPLR::new` takes `data`,
# `score`, `n_folds`, `n_folds_inner`, `n_rep`, `seed`, `ml_g` and `ml_m`
# (`lplr.mbt:352-363`).  There is no `alpha`, on the constructor or on `fit`:
# `alpha` is the DGP's (`dgp_lplr.mbt:37`), not the estimator's.  The README
# offers the snippet as copy-pasteable, in a plain `moonbit` fence, so a
# reader who copies it gets a compile error.  The same wrong line sits in the
# source docstring at `lplr.mbt:449`; that one is fixed in the source, here.
#
# P13. THE NONLINEAR OPTIONS WERE NAMED BY THEIR ENUM VARIANTS.
# `LearnerDispatch::RandomForestClassifier` and
# `LearnerDispatch::GradientBoostingClassifier` are VARIANTS of the enum
# (`learner.mbt:165,169`); the package's own constructors are the functions
# `LearnerDispatch::random_forest_classifier` and
# `LearnerDispatch::gradient_boosting_classifier` (`learner.mbt:268,279`).
# Every other `LearnerDispatch::` name in the README is a function, so this
# was the one place a reader could copy a name that is not callable the way
# the rest of the document says it is.
#
# P14. A FIGURE AND ITS OWN DECOMPOSITION DID NOT AGREE.
# "**21 runnable example binaries** -- 16 CLI demos, an HTTP service, a
# consumer demo and a property-based fuzz harness" sums to 19.  The two
# missing ones are `examples/bitexact/` and `examples/parity/`, which the
# README's own Examples section calls "kept as runnable binaries".  Round 22
# rewrote this bullet from a form with no decomposition at all into one that
# has one, and the decomposition it wrote was short by two.

OLD_LPLR_SNIPPET = """   ```moonbit
   let model = DoubleMLLPLR::new(data, alpha=1.5).fit()
   for w in model.warnings() { println(w) }
   ```"""

NEW_LPLR_SNIPPET = """   ```moonbit
   let model = DoubleMLLPLR::new(data).fit()
   for w in model.warnings() { println(w) }
   ```"""

OLD_NONLINEAR = """`LearnerDispatch::RandomForestClassifier` and
`LearnerDispatch::GradientBoostingClassifier` are the nonlinear options."""

NEW_NONLINEAR = """`LearnerDispatch::random_forest_classifier(RFClassifier::new(...))` and
`LearnerDispatch::gradient_boosting_classifier(GBClassifier::new(...))` are
the nonlinear options."""

OLD_EXAMPLES_BULLET = """- ✅ **21 runnable example binaries** -- 16 CLI demos, an HTTP service, a
  consumer demo and a property-based fuzz harness."""

NEW_EXAMPLES_BULLET = """- ✅ **21 runnable example binaries** -- 16 CLI demos, plus
  `examples/api_server/` (the HTTP service), `examples/consumer_demo/`,
  `examples/fuzz/`, and the two fixtures `examples/bitexact/` and
  `examples/parity/`."""

# ==============================================================================
# 3g.  THE ROUND-27 PATCH -- the `validate_*` family is not exclusively ours
# ==============================================================================
#
# The paragraph said: "Every script above compares the port against a second
# implementation written in this repository, which can only catch a disagreement
# someone already thought to look for."  The first half is true of all 24.  The
# second half is not: 9 of the 24 import the upstream `doubleml` wheel, and 2 of
# those 9 GATE THE PORT AGAINST UPSTREAM rather than only against a hand-rolled
# reference --
#
#   * validate_did_cs_binary_with_python.py: `if up is not None and
#     abs(mb["coef"] - up["coef"]) > MODEL_TOL: ok = False`
#   * validate_lplr_with_python.py: `band_ok = d_up < band and d_hr < band`,
#     where `d_up = abs(mb_theta - th_up)` and `th_up` is upstream's theta.
#
# So the `pyexample_*` family was not the only one able to catch a shared
# misreading of the model, and the README said it was.  The other 7 wheel
# importers use upstream for context (upstream's numbers are printed) and, in
# three of them, for separately gated rows of upstream's own quantities.
#
# Measured by _verify/_verify_tutorial_claims_1650.py, which derives the 9/15
# split from the scripts themselves (the upstream wheel is imported in code,
# not mentioned in prose) and checks both named gates still compare the port
# against upstream.

# The anchor runs to the end of the paragraph, so the new text can end with a
# clean paragraph break and the table's own intro can start on a fresh line.
# It matches the text as round 25's P10 left it ("class or family:").

OLD_UPSTREAM_OWNED = """**Nine gates whose reference is UPSTREAM, not ours** -- the `pyexample_*`
family. Every script above compares the port against a second implementation
written in this repository, which can only catch a disagreement someone already
thought to look for. The `pyexample_*` scripts instead run upstream's own code
on the port's rows and compare that: not "does the port agree with our second
implementation" but "does the port agree with upstream". Measured designs, one
script per upstream class or family:"""

NEW_UPSTREAM_OWNED = """**Nine gates whose reference is UPSTREAM, not ours** -- the `pyexample_*`
family. Every script above compares the port against a second implementation
written in this repository, which on its own can only catch a disagreement
someone already thought to look for. The `pyexample_*` scripts instead run
upstream's own code on the port's rows and compare that: not "does the port
agree with our second implementation" but "does the port agree with upstream".

The `validate_*` family is not exclusively ours, though: **9** of its 24
scripts import the upstream `doubleml` wheel, and **2** of those gate the port
against upstream rather than only against a hand-rolled reference --
`validate_did_cs_binary_with_python.py` (the port's ATT against upstream's)
and `validate_lplr_with_python.py` (the port's coefficient against upstream's
*and* the hand-rolled one, together). The other **7** import the wheel for
context (`validate_apos`, `validate_cluster_iv`, `validate_cluster_plr`,
`validate_iivm`, `validate_irm`, `validate_pliv`, `validate_plpr`); upstream's
numbers are printed there, and in some of them upstream's own quantities are
separately gated rows.

Measured designs, one script per upstream class or family:"""

# ==============================================================================
# 3f.  THE ROUND-28 PATCHES -- the score vocabulary, and WHERE the score
#      argument lives
# ==============================================================================
# Two defects, both measured against the source (the tracked verifier is
# `_verify/_verify_score_argument_1650.py`):
#
#   * The note listed five strings as score values the port accepts --
#     `apo`, `pq`, `lpq`, `cvar` and `policy_tree`.  The port accepts
#     NONE of them: they are the internal cache-kind tags passed to
#     `hash_hyperparams(...)` (and, for `policy_tree`, the
#     `estimator_kind`).  A reader following the note wrote
#     `DoubleMLAPO::new(data).fit(score="apo")`, which does not compile.
#   * The port's own list was 8 wide but only 3 of its 8 were real, and
#     upstream's was 9 of the 15 it actually uses (ATTE, LATE,
#     experimental, instrument, nonignorable and IV-type were missing).
#
# The port's real accepted union is 8 spellings, spread over only 7 of
# the 22 estimators: `DoubleMLPLR` takes the argument on `fit()`, six
# others on `new()`, and 15 estimators take no score argument at all.
#
# THREE SUBSTRINGS ARE PINNED by other verifiers and survive unchanged:
#   "three vocabularies are in play"
#   "upstream `doubleml-for-py` 0.11.4 uses `APO`, `ATE`, `PQ`, `LPQ`"
#   "`doc/004_estimators` tutorial lists the port's own strings"
# The upstream list therefore still opens with APO, ATE, PQ, LPQ.

OLD_SCORE_NOTE = """The **Score** column is a prose label for the estimand family, not a
machine string, and three vocabularies are in play: the port accepts
its own lower-case spellings (`partialling-out`, `apo`, `pq`, `lpq`,
`cvar`, `policy_tree`, `nuisance_space`, `observational`); upstream
`doubleml-for-py` 0.11.4 uses `APO`, `ATE`, `PQ`, `LPQ`, `CVaR`,
`nuisance_space`, `partialling out`, `observational` and
`missing-at-random`, and takes **no score argument at all** for
`RDFlex`, `DoubleMLBLP` or `DoubleMLPolicyTree`. The
`doc/004_estimators` tutorial lists the port's own strings, one row
per estimator."""

NEW_SCORE_NOTE = """The **Score** column is a prose label for the estimand family, not a
machine string, and three vocabularies are in play. The port accepts
**8** spellings -- `partialling-out`, `partialling out`, `iv-type`,
`IV-type`, `observational`, `experimental`, `nuisance_space` and
`instrument` -- and only **7 of the 22 estimators take a `score`
argument at all**: `DoubleMLPLR` on `fit()`, six others on `new()`.
The upstream vocabulary is a different set of **15** spellings, and
upstream `doubleml-for-py` 0.11.4 uses `APO`, `ATE`, `PQ`, `LPQ`,
`CVaR`, `LATE`, `ATTE`, `IV-type`, `experimental`, `instrument`,
`missing-at-random`, `nonignorable`, `nuisance_space`, `observational`
and `partialling out`; it takes **no score argument at all** for
`RDFlex`, `DoubleMLBLP` or `DoubleMLPolicyTree`. The
`doc/004_estimators` tutorial lists the port's own strings, one row
per estimator."""

# The API reference promises "One API shape, with the differences named",
# and this paragraph is where the constructor differences are named.  The
# score argument is a constructor difference in 6 of the 22 estimators --
# it goes on `new()`, not on `fit()` -- and it was not named.

OLD_CTOR_DIFFS = """Constructor arguments also differ in ways a table cannot show:
`DoubleMLDIDBinary` needs `g_value` / `t_value_pre` / `t_value_eval`,
`DoubleMLAPOS` needs `treatment_levels`, `DoubleMLPolicyTree` needs
`features` / `orth_signal` / `depth` / `honest`, and each DID variant takes
its own data type."""

NEW_CTOR_DIFFS = """Constructor arguments also differ in ways a table cannot show:
`DoubleMLDIDBinary` needs `g_value` / `t_value_pre` / `t_value_eval`,
`DoubleMLAPOS` needs `treatment_levels`, `DoubleMLPolicyTree` needs
`features` / `orth_signal` / `depth` / `honest`, and each DID variant takes
its own data type. The `score` argument is the one that moves between
`new()` and `fit()`: `DoubleMLPLR` takes it on `fit()`, and
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCrossSection`,
`DoubleMLDIDCSBinary`, `DoubleMLLPLR` and `DoubleMLPLPR` take it on
`new()`."""

for _old, _new in ((OLD_API_SHAPE, NEW_API_SHAPE),
                    (OLD_DID_COUNT, NEW_DID_COUNT),
                    (OLD_EXAMPLE_COUNT, NEW_EXAMPLE_COUNT),
                    (OLD_WAS_EXTRA, NEW_WAS_EXTRA),
                    (OLD_PREVIOUSLY_EXTRA, NEW_PREVIOUSLY_EXTRA),
                    (OLD_BITEXACT_FRAGMENT, NEW_BITEXACT_FRAGMENT),
                    (OLD_FOUR_LEARNERS, NEW_FOUR_LEARNERS),
                    (OLD_CI_COUNT, NEW_CI_COUNT),
                    (OLD_AGENTS_LINE, NEW_AGENTS_LINE),
                    (OLD_ATTRIB_HEADING, NEW_ATTRIB_HEADING),
                    (OLD_ONE_SCRIPT, NEW_ONE_SCRIPT),
                    (OLD_V082, NEW_V082),
                    (OLD_SSM_MARGIN, NEW_SSM_MARGIN),
                    (OLD_CLASSIFIER, NEW_CLASSIFIER),
                    (OLD_LPLR_SNIPPET, NEW_LPLR_SNIPPET),
                    (OLD_NONLINEAR, NEW_NONLINEAR),
                    (OLD_EXAMPLES_BULLET, NEW_EXAMPLES_BULLET),
                    (OLD_UPSTREAM_OWNED, NEW_UPSTREAM_OWNED),
                    (OLD_SCORE_NOTE, NEW_SCORE_NOTE),
                    (OLD_CTOR_DIFFS, NEW_CTOR_DIFFS)):
    PATCHES.append((_old, _new))

# ==============================================================================
# 3g.  THE ROUND-31 PATCH -- what a copied example actually installs
# ==============================================================================
#
# The Examples section invites the reader to copy an example out of the tree.
# What that copy installs is decided by the example's own `moon.mod` pin, and
# round 31 found all 21 of them naming a library from long ago -- a version
# the example was never written against.
#
# The pin is now the version this document describes, and
# `_verify/_verify_example_pins_1650.py` checks every manifest against the
# library's own `moon.mod`, so the sentence below is not a claim anyone has
# to take on trust: it is what the check enforces.
#
# The sentence carries NO version number on purpose.  A number here would be a
# literal that goes stale at the next release; the check is what pins it.

OLD_EXAMPLE_PINS = "their numbers are inspectable without a Python reference.\n"

NEW_EXAMPLE_PINS = """their numbers are inspectable without a Python reference.

Every example's `moon.mod` pins the library at the release this document
describes, so an example copied out of the tree and resolved there with
`moon update` installs the same library these numbers came from.
"""

PATCHES.append((OLD_EXAMPLE_PINS, NEW_EXAMPLE_PINS))

# ==============================================================================
# 3h.  THE ROUND-32 PATCHES -- two ratios a reader cannot divide out
# ==============================================================================
#
# The README states ratios: a separation, a factor, a percentage.  Round 32
# added the rule that EVERY stated ratio must be derivable from the numbers
# its own passage prints -- the reader divides and gets the same number --
# and two ratios failed it.
#
# THE 344.  The LPLR pitfall said the derivative was `-8.07e-05` "against a
# score of `-0.1119`, a factor of **344** down".  That quotient is **1387**.
# The 344 is real, but it is the DERIVATIVE's fall from `-0.0277` at
# `theta0 = 1.003` to `-8.07e-05` at `theta0 = 6.842` -- which is what the
# witness script prints ("derivative falls by a factor of 343.5") and what
# `_verify/LPLR_GATE_BLINDNESS_1680.md` section 27f says.  The passage
# attached the number to the wrong pair, so nobody could check it.  It now
# names both start values, and 344 is the quotient of the two derivatives the
# passage prints.
#
# THE 16x.  The hazard table's `DoubleMLIIVM` row said "`0.987` vs `1.031`
# (16x *smaller* SE)" without printing the standard errors, so the 16 was a
# number with no arithmetic behind it in the document.  The v0.137.0 record
# holds them (`0.0047` vs `0.0747`), so the row now prints them, in the same
# OLS-first order the table uses everywhere else.

OLD_LPLR_FACTOR = """flat past `theta ≈ 3.5`: at `theta0 = 6.842` the derivative is `-8.07e-05`
against a score of `-0.1119`, a factor of **344** down, so the first step
`theta - score/deriv` overshoots to about `-1381` and overflows. That is the
`e+70` / `e+122` / `NaN` mechanism, and the basin edge is draw-specific."""

NEW_LPLR_FACTOR = """flat past `theta ≈ 3.5`: at `theta0 = 6.842` the score is `-0.1119` but the
derivative is `-8.07e-05` -- down a factor of **344** from the `-0.0277` it
was at upstream's start value `theta0 = 1.003` -- so the first step
`theta - score/deriv` overshoots to about `-1381` and overflows. That is the
`e+70` / `e+122` / `NaN` mechanism, and the basin edge is draw-specific."""

OLD_IIVM_ROW = ("| `DoubleMLIIVM` | not demonstrated | `0.987` vs `1.031` "
                "(16x *smaller* SE) |")

NEW_IIVM_ROW = ("| `DoubleMLIIVM` | not demonstrated | `0.987` vs `1.031`; "
                "SE `0.0047` vs `0.0747` (16x *smaller*) |")

PATCHES.append((OLD_LPLR_FACTOR, NEW_LPLR_FACTOR))
PATCHES.append((OLD_IIVM_ROW, NEW_IIVM_ROW))

# ---------------------------------------------------------------------------
# Round 33: the propensity table -- four measurements nobody was checking,
# and a column nobody could read.
#
# The table's third column is headed `rv`, and the README never says what `rv`
# is.  Upstream's `sensitivity_params` carries `theta`, `se`, `ci`, `rv` and
# `rva`; `rv` is the ROBUSTNESS VALUE, the sensitivity-analysis reading of how
# much confounding the estimate survives.  The direction is fixed by this
# repo's own records: v0.131.7 says a `nu2` pinned at 1 "claimed a robustness
# value of 19.6, i.e. 'robust to enormous confounding', where the correct
# value is 0.84", and v0.131.5 says a DID ATT of 1.02 "scored `rv = 7.77`
# (visibly robust) when the correct value is `1.73` (fragile)".  So HIGHER is
# MORE ROBUST.
#
# The same table also broke the document's own convention: every measured
# value elsewhere in the README is written in a CODE SPAN, and the table's
# cells were bold and plain instead.  That is not only a style point -- the
# verifier's I2 collects a table cell's numbers from the code spans, so those
# four measurements (`-225.86`, `0.043`, `1.44`, `0.842`) were NEVER checked.
# The v0.131.9 record holds all four (`-225.86204067169143`,
# `0.043343170315623715`, `1.4426392091401607`, `0.8419771777915093`), so they
# were checkable all along.
#
# The two other rows that broke the convention are fixed the same way: the
# QTE row's tau bounds and the DIDBinary row's `~1e-4`.

OLD_PROP_TABLE = """| `linear_regression` | **-225.86** | 0.043 |
| `logistic_regression` | **1.44** | 0.842 |"""

NEW_PROP_TABLE = """| `linear_regression` | **`-225.86`** | `0.043` |
| `logistic_regression` | **`1.44`** | `0.842` |

`coef` is the estimated effect; `rv` is upstream's **robustness value** -- the
sensitivity-analysis reading of how much confounding the estimate survives, so
**higher is more robust**. The OLS propensity lands at `0.043`; the classifier
reaches `0.842`."""

OLD_QTE_TAU = ("| `DoubleMLQTE` | **hazardous -- fixed in v0.139.0** | frozen at "
               "`-1.583` for tau 0.50-0.90 |")

NEW_QTE_TAU = ("| `DoubleMLQTE` | **hazardous -- fixed in v0.139.0** | frozen at "
               "`-1.583` for tau `0.50`-`0.90` |")

OLD_DIDBIN = ("| `DoubleMLDIDBinary` | **not demonstrated** | 4 designs, "
              "~14 configs, ~1e-4 |")

NEW_DIDBIN = ("| `DoubleMLDIDBinary` | **not demonstrated** | 4 designs, "
              "~14 configs, ~`1e-4` |")

PATCHES.append((OLD_PROP_TABLE, NEW_PROP_TABLE))
PATCHES.append((OLD_QTE_TAU, NEW_QTE_TAU))
PATCHES.append((OLD_DIDBIN, NEW_DIDBIN))


# ==============================================================================
# 4.  THE ROUND-35 PATCH -- a citation that named the WRONG BRANCH
# ==============================================================================
#
# The DID paragraph cited `did.mbt:708` for "the observational DID score".
# Line 708 is `let w_d = d_i / m_i`, and it lives in the `else` branch opened at
# did.mbt:704 -- the EXPERIMENTAL score.  The observational branch is
# did.mbt:659-689, and its default form (in_sample_normalization = false,
# did.mbt:678-688) computes, at did.mbt:685-687:
#
#     let denom = p_hat * one_minus_m
#     psi_b[i] = (d[i] - m_i) / denom * resid_d0[i]
#
# The source's own doc comment (did.mbt:97) states the weight as
# `(D - m) / (p_hat * (1 - m))`: `m` is in the NUMERATOR and `1 / m` appears
# nowhere.  For a TREATED row the `m` dependence cancels -- (1 - m) / (1 - m) --
# so `m` reaches the control rows only.  `score` defaults to "observational"
# (did_binary.mbt:367), so this is the branch the shipped default runs.
#
# Three smaller drifts travel with it:
#
#   * "A bare `moon test` runs every declared backend" is false.  Measured on
#     moon 0.1.20261023, a bare run prints [wasm], [wasm-gc] and [native] --
#     but only [wasm-gc] carries the suite, and [js] is never reported at
#     all, though `moon test --target js` runs 1117 tests.
#   * The RNG keys are 32-byte ChaCha8 keys compared BYTE-FOR-BYTE
#     (validate_bitexact_with_python.py:377), not IEEE-754 doubles.
#   * `DoubleMLPolicyTree::new`'s first parameter is `features`
#     (blp_policy.mbt:1583), not `x`.

OLD_DID_SCORE = """BETTER of the pair. The reason is structural. In the observational DID score
(`did.mbt:708`) `w_d = d_i / m_i`, so `1 / m` enters **only for treated
rows** (controls get `w_d = 0`), and the score is **doubly robust** -- a
correct `g` carries identification, leaving `m` second-order. IRM and APO need
`m` for the estimand itself, which is why they showed a ~200-point error and
DID shows ~0.001. The sharpest DID case: at n=200 the CLASSIFIER default is
worse on both bias (0.0776 vs 0.00050) and SE."""

NEW_DID_SCORE = """BETTER of the pair. The reason is structural. In the observational DID score
(`did.mbt:97`) the residual weight is `(D - m) / (p_hat * (1 - m))`, so the
score never divides by `m`: for a **treated** row the `m` dependence cancels,
and `m` reaches the control rows only. The score is **doubly robust** -- a
correct `g` carries identification, leaving `m` second-order. IRM and APO need
`m` for the estimand itself, which is why they showed a ~200-point error and
DID shows ~0.0005. The sharpest DID case: at n=200 the CLASSIFIER default is
worse on both bias (0.0776 vs 0.00050) and SE."""

OLD_DID_ROW = ("| `DoubleMLDID`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, "
               "`DoubleMLDIDCrossSection`, `DoubleMLDIDMulti` | not demonstrated | "
               "doubly robust -- `1/m` enters treated rows only |")

NEW_DID_ROW = ("| `DoubleMLDID`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, "
               "`DoubleMLDIDCrossSection`, `DoubleMLDIDMulti` | not demonstrated | "
               "doubly robust -- `m` cancels for treated rows |")

OLD_BARE_TEST = """per-target numbers are in the Status table. A bare `moon test` runs every
declared backend, and on `moon 0.1.20261016` it prints `Total tests: 0` for
the backends other than the preferred one, so the per-target counts here
come from explicit `--target` runs."""

NEW_BARE_TEST = """per-target numbers are in the Status table. A bare `moon test` runs the suite
on only one of the four declared backends -- on `moon __TOOLCHAIN__` it reports
`Total tests: 0` for `wasm` and `native`, runs the suite on `wasm-gc` (1123
tests), and never reports `js` -- so the per-target counts here come from
explicit `--target` runs.""".replace("__TOOLCHAIN__", TOOLCHAIN)

OLD_RNG_ITEMS = """- ✅ **24 / 24 Python reference scripts PASS** -- 25 of the 25 bit-exact items
  and 6 / 6 RNG keys are IEEE-754 identical to CPython."""

NEW_RNG_ITEMS = """- ✅ **24 / 24 Python reference scripts PASS** -- 25 of the 25 bit-exact items
  are IEEE-754 identical to CPython, and the 6 / 6 RNG keys are byte-identical."""

OLD_RNG_CELL = ("| Python cross-checks | **24 / 24 PASS** "
                "(`validate_*_with_python.py`); 25 of the 25 bit-exact items "
                "and 6 / 6 RNG keys are IEEE-754 identical to CPython |")

NEW_RNG_CELL = ("| Python cross-checks | **24 / 24 PASS** "
                "(`validate_*_with_python.py`); 25 of the 25 bit-exact items "
                "are IEEE-754 identical to CPython, and the 6 / 6 RNG keys are "
                "byte-identical |")

OLD_POLICY_CTOR = """`DoubleMLPolicyTree::new(x, orth_signal, depth = 1, honest = false,
split_seed = 2024, min_leaf_n = 5)` splits the sample when `honest` is on:"""

NEW_POLICY_CTOR = """`DoubleMLPolicyTree::new(features, orth_signal, depth = 1, honest = false,
split_seed = 2024, min_leaf_n = 5)` splits the sample when `honest` is on:"""

PATCHES.append((OLD_DID_SCORE, NEW_DID_SCORE))
PATCHES.append((OLD_DID_ROW, NEW_DID_ROW))
PATCHES.append((OLD_BARE_TEST, NEW_BARE_TEST))
PATCHES.append((OLD_RNG_ITEMS, NEW_RNG_ITEMS))
PATCHES.append((OLD_RNG_CELL, NEW_RNG_CELL))
PATCHES.append((OLD_POLICY_CTOR, NEW_POLICY_CTOR))


# ==============================================================================
# 5.  THE ROUND-36 PATCH -- a limit that OVERSTATED the truth
# ==============================================================================
#
# "### Not covered, so not claimed" is the only part of the document that
# makes NEGATIVE claims: "no CI workflow runs it", "its seed argument is
# ignored", "nothing imports them".  Until this round NOTHING checked any of
# them -- the section was trusted, and the whole point of a section about what
# is NOT covered is that it must not be trusted.
#
# Read against the tree, the claims hold.  But one of them OVERSTATED the
# limit, and an overstated limit is as false as an understated one:
#
#   "...so the fuzz check replays one fixed seed (20260824) three times
#    rather than sweeping seeds: it is a re-run of one case, not a fuzz"
#
# One invocation is not one case.  `examples/fuzz/main.mbt` drives 11 surfaces
# (`[1/11]` .. `[11/11]`) at `let trials = 300`; the harness's own banner
# prints "300 trials per surface, fixed seed 20260824", and
# `_verify/LPLR_GATE_BLINDNESS_1680.md` records "ALL 11 SURFACES PASSED".  Each
# invocation is a real property-based run over thousands of randomised cases.
# What the check repeats is that ONE RUN, three times, because the seed
# ARGUMENT is ignored.  "Not a fuzz" also contradicted the README's own
# Examples table, which calls the same binary "Random-property fuzz harness
# across 11 surfaces".
#
# The correction states the limit exactly -- the run is not SEED-SWEEPABLE --
# and states the scale, so a reader can see how much one run covers.  A limit
# that is written down is a limit; a limit that is exaggerated is a lie.
#
# The second edit is a redundancy.  The section's first line repeated the
# heading above it word for word ("Still not covered, so not claimed."), and
# the "Still" asserted a continuity with a previous state that nothing in the
# document supports.  The heading carries the same fact, so the lead-in goes.

OLD_NOT_COVERED = """**Still not covered, so not claimed.** The `coverage` check is a
test-reachability proxy, not instrumented line coverage. There is no
dependency-vulnerability scan -- `moon update` resolves versions, it is not an
audit. `mutation` kills three mutants on one kernel, not a whole-codebase
surviving-mutant ledger, and no CI workflow runs it. `examples/fuzz/` has no
crash-regression corpus, and its seed argument is **ignored** -- `fn main`
takes no parameters -- so the fuzz check replays one fixed seed (20260824)
three times rather than sweeping seeds: it is a re-run of one case, not a
fuzz, and no CI workflow runs it either. And the two declared `moon.mod`
dependencies -- `moonbit-community/sqlite3@0.2.3`
and `moonbitlang/async@0.22.5` -- are dead: nothing imports them, and
`dependencies` already WARNs about exactly that (`2 declared; non-conforming:
['moonbit-community/sqlite3@0.2.3']; declared but unreferenced by library code:
['moonbit-community/sqlite3@0.2.3', 'moonbitlang/async@0.22.5']`) rather than
passing quietly. Removing them is an open call, not an oversight."""

NEW_NOT_COVERED = """The `coverage` check is a
test-reachability proxy, not instrumented line coverage. There is no
dependency-vulnerability scan -- `moon update` resolves versions, it is not an
audit. `mutation` kills three mutants on one kernel, not a whole-codebase
surviving-mutant ledger, and no CI workflow runs it. `examples/fuzz/` has no
crash-regression corpus, and its seed argument is **ignored** -- `fn main`
takes no parameters -- so the fuzz check replays one fixed master seed
(20260824) three times rather than sweeping seeds. Each invocation is a real
property-based run -- 11 surfaces, 300 trials per surface -- so the check
repeats that one run, and no CI workflow runs it either. And the two
declared `moon.mod` dependencies -- `moonbit-community/sqlite3@0.2.3`
and `moonbitlang/async@__ASYNC_PIN__` -- are dead: nothing imports them, and
`dependencies` already WARNs about exactly that (`__DEP_WARN__`) rather than
passing quietly. Removing them is an open call, not an oversight. Dead is not
the same as harmless, though: the published source of
`moonbitlang/async@__ASYNC_PIN__` imports `moonbitlang/core/async`, a core
subpackage that older cores do not carry, so the dead pin is what sets the
**toolchain floor** -- see **Installation**. The `sqlite3` pin is not what
forces it: its published source imports no `moonbitlang/core/async`.""".replace(
    "__ASYNC_PIN__", ASYNC).replace("__DEP_WARN__", dep_warn_block())

PATCHES.append((OLD_NOT_COVERED, NEW_NOT_COVERED))

# ==============================================================================
# 6.  THE ROUND-37 PATCHES -- three promises the source does not keep
# ==============================================================================
#
# Round 36 checked the document's NEGATIVE claims.  Round 37 checks its
# POSITIVE ones: the sentences that promise an API shape.  Three did not
# survive the measurement.
#
# (a) THE UNIVERSAL LEARNER PROMISE.
#
#     "**Learner injection via `LearnerDispatch`** -- every estimator's
#      `new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
#      optionals."
#
# Measured by the parameter's TYPE (`LearnerDispatch`), not by its name,
# the 22 estimators take 8 distinct argument sets:
#
#     ml_g / ml_m                       11   APO APOS CVAR DID DIDBinary
#                                                DIDCS DIDCSBinary
#                                                DIDCrossSection DIDMulti
#                                                IRM LPLR
#     ml_l / ml_m                        2   PQ QTE
#     ml_g / ml_m / ml_r                 1   IIVM
#     ml_g / ml_m / ml_pi                1   SSM
#     ml_g                               2   BLP RDD
#     learner_l / learner_m              1   PLR
#     learner                            2   PLIV PLPR
#     (none)                             2   LPQ PolicyTree
#
# Two estimators take NO learner at all, one takes a single `learner`, and
# `ml_pi` is a fifth argument name the sentence did not mention.  The
# same paragraph's "Default is `LearnerDispatch::linear_regression()` (OLS)"
# is true for `ml_g` everywhere and false for `ml_m` on the SEVEN structs
# migrated to a classifier -- which the README itself names further down.
#
# The replacement is the table above, plus the sentence about the default.
# The table is what a reader needs (which argument do I pass for MY
# estimator?) and it is derived from the source by the check.
#
# (b) THE STALE VERSION LITERAL IN THE STATUS TABLE.
#
#     "Introduced v0.89.0"
#
# The CHANGELOG's own headings say v0.79.0 introduced the sandwich family
# (HC0-HC3 + cluster) on `DoubleMLIRM` and `DoubleMLPLR`; v0.86.0 and
# v0.87.0 extended it; v0.89.0 was ONE step of that extension (10 -> 12 of
# 22).  The row's counts were right -- 15 scalar, 4 per-cell, 3 with none
# of that API -- so the defect was in the version, which is the kind of
# literal that rots silently because nothing else on the page repeats it.
#
# The row also said "**3** expose none", which is true of the sandwich API
# and misleading about robustness: `DoubleMLBLP` and `DoubleMLRDD` expose a
# heteroskedasticity-robust `hac_se` under their own name (v0.96.0 and
# v0.97.0), and the README did not mention `hac_se` AT ALL.  A limit that
# is understated is as false as one that is overstated.
#
# (c) THE DID DATA TYPES.
#
#     "and each DID variant takes its own data type."
#
# It does not.  `DoubleMLDIDCS`, `DoubleMLDIDCSBinary` and `DoubleMLDIDMulti`
# all take `DoubleMLDIDCSData`.  The sentence now names the four types the
# DID family actually takes.

OLD_37_LEARNER = """**Learner injection via `LearnerDispatch`** -- every estimator's
`new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
optionals. Default is `LearnerDispatch::linear_regression()` (OLS).
Built-in learners:"""

NEW_37_LEARNER = """**Learner injection via `LearnerDispatch`** -- the learner arguments are
`LearnerDispatch` optionals, and **the set differs by estimator**, so there is
no single argument to pass:

| learner arguments | estimators |
|---|---|
| `ml_g` / `ml_m` | `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection`, `DoubleMLDIDMulti`, `DoubleMLIRM`, `DoubleMLLPLR` |
| `ml_l` / `ml_m` | `DoubleMLPQ`, `DoubleMLQTE` |
| `ml_g` / `ml_m` / `ml_r` | `DoubleMLIIVM` |
| `ml_g` / `ml_m` / `ml_pi` | `DoubleMLSSM` |
| `ml_g` | `DoubleMLBLP`, `DoubleMLRDD` |
| `learner_l` / `learner_m` | `DoubleMLPLR` |
| `learner` | `DoubleMLPLIV`, `DoubleMLPLPR` |
| none | `DoubleMLLPQ`, `DoubleMLPolicyTree` |

That is **8** argument sets over the **22** estimators. `ml_r` is
`DoubleMLIIVM`'s instrument propensity (at `fit()` it reuses the
constructor's choice) and `ml_pi` is `DoubleMLSSM`'s selection propensity
(at `fit()` it reuses the `ml_m` choice). The constructor default is
`LearnerDispatch::linear_regression()` (OLS) -- except `ml_m` on the seven
structs migrated to a classifier, named below.
Built-in learners:"""

OLD_37_SANDWICH = """| Sandwich-variance coverage | **15 / 22** expose the scalar `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`; **4** more (`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`) expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose none (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`). Introduced v0.89.0 |"""

NEW_37_SANDWICH = """| Sandwich-variance coverage | **15 / 22** expose the scalar `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`; **4** more (`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`) expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose none of that API (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`) -- but `DoubleMLBLP` and `DoubleMLRDD` do expose a heteroskedasticity-robust `hac_se` under their own name (v0.96.0 / v0.97.0); `DoubleMLPolicyTree` exposes no robust SE at all. Introduced v0.79.0 (on `DoubleMLIRM` and `DoubleMLPLR`), extended to **19 / 22** by v0.100.0 |"""

OLD_37_DID = """Constructor arguments also differ in ways a table cannot show:
`DoubleMLDIDBinary` needs `g_value` / `t_value_pre` / `t_value_eval`,
`DoubleMLAPOS` needs `treatment_levels`, `DoubleMLPolicyTree` needs
`features` / `orth_signal` / `depth` / `honest`, and each DID variant takes
its own data type."""

NEW_37_DID = """Constructor arguments also differ in ways a table cannot show:
`DoubleMLDIDBinary` needs `g_value` / `t_value_pre` / `t_value_eval`,
`DoubleMLAPOS` needs `treatment_levels`, `DoubleMLPolicyTree` needs
`features` / `orth_signal` / `depth` / `honest`, and the DID variants take
four data types, not one each: `DoubleMLDIDData` for `DoubleMLDID`,
`DoubleMLDIDBinaryData` for `DoubleMLDIDBinary`, `DoubleMLDIDCSData` for
`DoubleMLDIDCS`, `DoubleMLDIDCSBinary` AND `DoubleMLDIDMulti`, and
`DoubleMLDIDCrossSectionData` for `DoubleMLDIDCrossSection`."""

PATCHES.append((OLD_37_LEARNER, NEW_37_LEARNER))
PATCHES.append((OLD_37_SANDWICH, NEW_37_SANDWICH))
PATCHES.append((OLD_37_DID, NEW_37_DID))

# ==============================================================================
# 7.  THE ROUND-38 PATCHES -- four promises the tree does not keep
# ==============================================================================
#
# Round 37 gave the API's POSITIVE promises a check.  Round 38 checks the
# promises the README makes about the PACKAGE and about the measurements it
# quotes: a file it names, a capability it exports, a range it did not
# measure, a rule its own manifest breaks.
#
# (a) THE LAYOUT NAMES A FILE THAT DOES NOT EXIST.
#     "moonbit_doubleML.mbt <- main re-export file (the import surface)".
#     There is no such file: `git log --all --diff-filter=AD -- '*moonbit_doubleML.mbt'`
#     is EMPTY, so it never existed in this repository.  The package's import
#     surface is the `pub` declarations across the 19 estimator files, and
#     the package's own `moon.pkg` names its imports and its targets.
#
# (b) THE LIBRARY IS CLAIMED TO HAVE JSON IN/OUT.  It has none: the only
#     `json` in the package's sources is inside COMMENTS (golden-file names,
#     a doc line about CLI/JSON input), and `pkg.generated.mbti` exports no
#     JSON type.  The JSON that exists belongs to `examples/api_server/`,
#     which does its own request/response encoding.  The bullet was
#     advertising a capability the port does not have.
#
# (c) A MEASURED FREEZE WAS STATED AS A RANGE.  The v0.139.0 release measured
#     FIVE taus and found the OLS arm frozen at three of them
#     (`tau = 0.50 / 0.75 / 0.90`); at `0.10` and `0.25` it was NOT frozen.
#     "for tau 0.50-0.90" reads as a continuous interval the evidence does
#     not support -- and the same release's own lesson is about reading a
#     sample as more than it is ("The miss came from sampling two taus and
#     reading 'they differ' as 'no freeze'").
#
# (d) A RULE IS ASSERTED AS MET WHILE THE MANIFEST BREAKS IT.  The bullet
#     said "only `moonbitlang/*` official packages", and `moon.mod` declares
#     `moonbit-community/sqlite3@0.2.3`.  The document's own Dependency-rule
#     section says "the rule is not met, by one line" -- so the bullet and
#     the section contradicted each other.

OLD_38_LAYOUT = ("  moonbit_doubleML.mbt   <- main re-export file (the import surface)")
NEW_38_LAYOUT = ("  moon.pkg              <- the package's imports and supported targets")

OLD_38_JSON = ("- `DoubleMLData` / `DoubleMLXxx::new().fit()` as the canonical\n"
               "  MoonBit-idiomatic API, with optional JSON in/out for native /\n"
               "  wasm-gc / wasm / js backends (Serverless / Wasm / edge\n"
               "  deployments).")
NEW_38_JSON = ("- `DoubleMLData` / `DoubleMLXxx::new().fit()` as the canonical\n"
               "  MoonBit-idiomatic API, on native / wasm-gc / wasm / js backends\n"
               "  (Serverless / Wasm / edge deployments). The library exports\n"
               "  **no** JSON in/out -- the JSON surface is `examples/api_server/`'s\n"
               "  own request/response encoding.")

OLD_38_DEPRULE = ("- Strict dependency rule (see above): only `moonbitlang/*` official\n"
                  "  packages. Minimal supply-chain surface.")
NEW_38_DEPRULE = ("- Strict dependency rule (see above): only `moonbitlang/*` official\n"
                  "  packages -- **one declared line does not meet it today**\n"
                  "  (`moonbit-community/sqlite3`, which nothing imports). The\n"
                  "  library's runtime supply chain is still `moonbitlang/core`\n"
                  "  only.")

OLD_38_QTE = ("| `DoubleMLQTE` | **hazardous -- fixed in v0.139.0** | frozen at "
              "`-1.583` for tau `0.50`-`0.90` |")
NEW_38_QTE = ("| `DoubleMLQTE` | **hazardous -- fixed in v0.139.0** | OLS arm frozen at "
              "`-1.583` at the three measured taus `0.50` / `0.75` / `0.90` |")

PATCHES.append((OLD_38_LAYOUT, NEW_38_LAYOUT))
PATCHES.append((OLD_38_JSON, NEW_38_JSON))
PATCHES.append((OLD_38_DEPRULE, NEW_38_DEPRULE))
PATCHES.append((OLD_38_QTE, NEW_38_QTE))


# ==============================================================================
# 8.  THE ROUND-39 PATCHES -- a citation and a pairing
# ==============================================================================
#
# (e) A LITERATURE CITATION WITH THE WRONG PAGE RANGE.  The honesty section
#     cited "Athey & Imbens (2016, PNAS 113(27):7353-7358)".  The publisher's
#     own deposited record for the DOI (10.1073/pnas.1510489113) gives the
#     page range as 7353-7360, and OpenAlex agrees.  The authors, the year,
#     the journal, the volume and the issue were all right, and the
#     SUBSTANCE the README credits is right -- only the last two digits of
#     the range were wrong.  No in-tree check can catch a literature
#     citation, which is why it survived thirty-eight rounds.
#
# (f) A PARENTHETICAL PAIRING THAT DOES NOT PAIR.  The sandwich-variance row
#     said "`DoubleMLBLP` and `DoubleMLRDD` do expose a heteroskedasticity-
#     robust `hac_se` under their own name (v0.96.0 / v0.97.0)".  Read
#     positionally -- the way the document pairs names with versions
#     everywhere else -- that asserts BLP = v0.96.0 and RDD = v0.97.0, and
#     BOTH are false: `rdd.mbt` marks its `hac_se` "v0.96.0+" and
#     `blp_policy.mbt` marks its own "v0.97.0+", and the CHANGELOG's
#     headings agree ("[0.96.0] -- DoubleMLRDD gets its own hac_se",
#     "[0.97.0] -- DoubleMLBLP gets its own hac_se").  The SET of two
#     versions was right, so the defect was the ORDER -- and an order that
#     reads as a claim is a claim.
#
OLD_39_PNAS = "113(27):7353-7358"
NEW_39_PNAS = "113(27):7353-7360"

OLD_39_HACSE = ("`DoubleMLBLP` and `DoubleMLRDD` do expose a "
                "heteroskedasticity-robust `hac_se` under their own name "
                "(v0.96.0 / v0.97.0)")
NEW_39_HACSE = ("`DoubleMLRDD` (v0.96.0) and `DoubleMLBLP` (v0.97.0) do expose "
                "a heteroskedasticity-robust `hac_se` under their own name")

PATCHES.append((OLD_39_PNAS, NEW_39_PNAS))
PATCHES.append((OLD_39_HACSE, NEW_39_HACSE))


# ==============================================================================
# 9.  THE ROUND-39 TOOLCHAIN PATCHES -- the toolchain moved under the release
# ==============================================================================
#
# (g) THE TOOLCHAIN MOVED.  The local `moon` went from 0.1.20261016 to
#     0.1.20261023 while this release was being cut, and the README's
#     Toolchain row is CHECKED against the installed toolchain -- so the row
#     has to name the one in use, and every claim that names a toolchain has
#     to be RE-DERIVED on it, not re-labelled.  All four were (the
#     measurements are in the ENGINEERING banner): the bare `moon test`
#     behaviour, the absence of file I/O, the operator bit-exactness table,
#     and the reserved-keyword set.  Three held and one did not: `train` is
#     no longer reserved, which the agent skill now says.
OLD_39_TOOLCHAIN_ROW = (
    "| Toolchain | `moon 0.1.20261016` -- the version every number in this "
    "table was measured on; a bare `moon` from `cli.moonbitlang.com` may be "
    "newer |")
NEW_39_TOOLCHAIN_ROW = (
    "| Toolchain | `moon __TOOLCHAIN__` -- the version this release's tests, "
    "cross-checks and bit-exactness gate were run on, and the version every "
    "number in this table was re-verified on; a bare `moon` from "
    "`cli.moonbitlang.com` may be newer |").replace("__TOOLCHAIN__", TOOLCHAIN)

# (h) THE SAME MOVE, IN THE PARITY SECTION.  The operator bit-exactness
#     table is re-measured by `_verify/_verify_op_table_1640.py` on whatever
#     toolchain is installed NOW, and it gives the same numbers -- so the
#     pair it names is the pair the measurement was last taken on.
OLD_39_PARITY = "re-measured on `moon 0.1.20261016` vs CPython 3.13.14"
NEW_39_PARITY = ("re-measured on `moon __TOOLCHAIN__` vs CPython 3.13.14"
                 ).replace("__TOOLCHAIN__", TOOLCHAIN)

PATCHES.append((OLD_39_TOOLCHAIN_ROW, NEW_39_TOOLCHAIN_ROW))
PATCHES.append((OLD_39_PARITY, NEW_39_PARITY))


# ==============================================================================
# 10.  THE ROUND-40 PATCHES -- the api_server's wasm invocation
# ==============================================================================
#
# (i) THE `moonrun` LINE WAS WRONG TWICE OVER.  It read
#
#     The same `api_server.wasm` also runs under `moonrun --port 4000`
#     (see `examples/api_server/README.md` for the full curl recipe).
#
# and BOTH halves were false.  `moonrun` takes a PATH and then the program's
# arguments, so `--port 4000` before the path is an unknown flag and the
# command is rejected outright.  And the flag would have done nothing anyway:
# `examples/api_server/main.mbt` hard-codes `DEFAULT_PORT = 4000` and never
# parses an argument, so the service binds 4000 whatever it is told.
#
# The cross-reference was false too: `examples/api_server/README.md` has no
# curl recipe -- its recipe is the PowerShell one -- and it points the other
# way, at the root README's curl block.  A path in prose is a promise: the
# pointer has to name something that is there.
OLD_40_API_RUN = (
    "The same `api_server.wasm` also runs under `moonrun --port 4000`\n"
    "(see `examples/api_server/README.md` for the full curl recipe).")
NEW_40_API_RUN = (
    "The same `api_server.wasm` also runs under `moonrun <path-to-the-wasm>`.\n"
    "The listen port is hard-coded to `4000` in `main.mbt`, so the service\n"
    "ignores any argument it is given (see `examples/api_server/README.md`\n"
    "for the full PowerShell smoke recipe).")

PATCHES.append((OLD_40_API_RUN, NEW_40_API_RUN))


# ==============================================================================
# 11.  THE ROUND-42 PATCH -- the "Used By" pin that had already gone stale
# ==============================================================================
#
# The section said:
#
#     `dmlref` package cross-checks its own from-scratch DoubleML
#     PLR against `riantr/moonbit_doubleML` v0.163.3 (its current pin):
#
# and "its current pin" was a PROMISE ABOUT ANOTHER REPOSITORY -- a number
# this repository cannot keep true, because `riantr/pyroduct` bumps its
# import pins on its own schedule.
#
# MEASURED on 2026-10-24: pyroduct's `moon.mod` imported
# `riantr/moonbit_doubleML@0.164.34`, and the literal `0.163.3` survived
# only inside a COMMENT in pyroduct's own manifest.  This package's
# 0.164.35 was published at 2026-10-24T06:58:49Z -- 2 h 13 min AFTER
# pyroduct had moved off 0.163.3 -- so the word "current" was already false
# when it shipped.
#
# A number this repository does not control must not be published as one
# it does.  The fix DROPS the version literal and keeps the substance: the
# cross-check, its nuisance, its size, its true parameter and its two
# deltas.  None of those is a promise about somebody else's release
# schedule.  The figures were re-checked against pyroduct's
# `dmlref/compare.mbt` and they hold.
OLD_42_USED_BY = (
    "  `dmlref` package cross-checks its own from-scratch DoubleML\n"
    "  PLR against `riantr/moonbit_doubleML` v0.163.3 (its current pin):\n"
    "  same nuisance (OLS), `n = 400`, true `theta = 1.5`, `theta` delta\n"
    "  `0.017` (1.667 vs 1.685) and `se` delta `0.001` (0.153 vs 0.152).")
NEW_42_USED_BY = (
    "  `dmlref` package cross-checks its own from-scratch DoubleML\n"
    "  PLR against `riantr/moonbit_doubleML`: same nuisance (OLS),\n"
    "  `n = 400`, true `theta = 1.5`, `theta` delta `0.017` (1.667 vs\n"
    "  1.685) and `se` delta `0.001` (0.153 vs 0.152).")

PATCHES.append((OLD_42_USED_BY, NEW_42_USED_BY))


# ==============================================================================
# 12.  THE ROUND-43 PATCHES -- two code blocks the compiler rejected
# ==============================================================================
#
# The README is a document a reader COPIES from.  Two of its fenced `moonbit`
# blocks did not compile, and nothing in the tree owned them:
#
#     ```moonbit
#     ml_m = LearnerDispatch::logistic_regression(LogisticRegression::new())
#     ```
#
# `ml_m` is not a variable -- it is an optional NAMED PARAMETER of eight
# estimators' constructors.  As a statement the line is a compile error
# ("The value identifier ml_m is unbound"), and it does not even show the
# reader how the learner reaches the estimator.  It is also written in the
# LIBRARY's own namespace, not the reader's: a reader who pastes it into
# their project gets "unbound identifier DoubleMLLPLR" for the second block
# and "unbound identifier LearnerDispatch" for this one.
#
#     ```moonbit
#     let model = DoubleMLLPLR::new(data).fit()
#     for w in model.warnings() { println(w) }
#     ```
#
# `DoubleMLLPLR::new` takes a `DoubleMLBinaryData` -- LPLR's outcome is
# BINARY -- while `data` in the README is the `DoubleMLData` the Quick Start
# builds.  The compiler says so:
#
#     Expr Type Mismatch
#     has type : @riantr/moonbit_doubleML.DoubleMLData
#     wanted   : @riantr/moonbit_doubleML.DoubleMLBinaryData
#
# The round-35 verifier that owns the README's API snippets checks the
# NAMES of a call's arguments and their defaults.  It cannot see a type
# mismatch, and it cannot see that a statement is not a statement at all.
# The gap is closed by `_verify/_verify_readme_snippets_1650.py`, which
# compiles the published README's own blocks.
#
# Both blocks are rewritten into the reader's namespace, and the LPLR one
# builds the binary data its constructor requires.  The `ml_m` one shows the
# learner where it belongs -- as the named argument it is.
OLD_43_ML_M = """`DoubleMLDIDMulti`, `DoubleMLIIVM`. Until each is
migrated, pass a classifier explicitly:

```moonbit
ml_m = LearnerDispatch::logistic_regression(LogisticRegression::new())
```"""

NEW_43_ML_M = """`DoubleMLDIDMulti`, `DoubleMLIIVM`. Until each is
migrated, pass a classifier explicitly -- `ml_m` is a named argument on the
constructor, so the learner goes where the estimator is built:

```moonbit
let fitted_cvar = @moonbit_doubleML.DoubleMLCVAR::new(
  data,
  ml_m=@moonbit_doubleML.LearnerDispatch::logistic_regression(
    @moonbit_doubleML.LogisticRegression::new(),
  ),
).fit()
```"""

OLD_43_LPLR_PROSE = """2. **Read the warnings.** `DoubleMLLPLR::fit()` can return a degenerate
   standard error, and it says so rather than returning a confident wrong
   number:"""

NEW_43_LPLR_PROSE = """2. **Read the warnings.** `DoubleMLLPLR::fit()` can return a degenerate
   standard error, and it says so rather than returning a confident wrong
   number. LPLR's outcome is BINARY, so it takes a `DoubleMLBinaryData`
   rather than the `DoubleMLData` the other estimators take --
   `DoubleMLBinaryData::new` aborts on any outcome that is not 0 or 1:"""

OLD_43_LPLR = """   ```moonbit
   let model = DoubleMLLPLR::new(data).fit()
   for w in model.warnings() { println(w) }
   ```"""

NEW_43_LPLR = """   ```moonbit
   let data = @moonbit_doubleML.DoubleMLBinaryData::new(x, y, d)
   let model = @moonbit_doubleML.DoubleMLLPLR::new(data).fit()
   for w in model.warnings() { println(w) }
   ```"""

PATCHES.append((OLD_43_ML_M, NEW_43_ML_M))
PATCHES.append((OLD_43_LPLR_PROSE, NEW_43_LPLR_PROSE))
PATCHES.append((OLD_43_LPLR, NEW_43_LPLR))


# ==============================================================================
# 13.  THE ROUND-45 PATCHES -- three code blocks, one number, two references
# ==============================================================================
#
# (a) THREE CODE BLOCKS THAT DO NOT COMPILE AS PRINTED.
#
# Every fenced `moonbit` block in this README is a FRAGMENT: it is written as
# `let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)`, and MoonBit
# rejects a module-scope `let` bound to a call result:
#
#     Error: [4074]
#        let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
#            ---   Cannot infer the type of variable data
#
# Measured, in a probe against this tree:
#
#     module scope, the fragment as published   -> Error 4074 (rejected)
#     inside a function body, the same fragment  -> exit 0  (accepted)
#
# So the snippets are right and their PLACEMENT was not said out loud: a
# reader who pastes the Quick Start at the top of a file gets a type error
# that looks like a library bug.  Each block now carries a one-line marker
# saying where it belongs.  The marker is a comment, so it changes nothing
# about the code.
#
# `_verify/_verify_readme_snippets_1650.py` compiles each block TWICE -- once
# inside a function body, once at module scope -- and REQUIRES the marker on
# any block that does not compile at module scope.  So the promise has an
# owner, and the owner is the compiler.
#
# The marker is one line, and it says what the reader needs to know:
# "inside a function body -- MoonBit rejects a module-scope `let` bound to a
# call".
OLD_45_QUICKSTART_MARK = """```moonbit nocheck
let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]"""

NEW_45_QUICKSTART_MARK = """```moonbit nocheck
// inside a function body -- MoonBit rejects a module-scope `let` bound to a call
let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]"""

OLD_45_CVAR_MARK = """```moonbit
let fitted_cvar = @moonbit_doubleML.DoubleMLCVAR::new("""

NEW_45_CVAR_MARK = """```moonbit
// inside a function body -- MoonBit rejects a module-scope `let` bound to a call
let fitted_cvar = @moonbit_doubleML.DoubleMLCVAR::new("""

OLD_45_LPLR_MARK = """   ```moonbit
   let data = @moonbit_doubleML.DoubleMLBinaryData::new(x, y, d)"""

NEW_45_LPLR_MARK = """   ```moonbit
   // inside a function body -- MoonBit rejects a module-scope `let` bound to a call
   let data = @moonbit_doubleML.DoubleMLBinaryData::new(x, y, d)"""

#
# (b) A NUMBER THAT NAMED ONLY THE SMALLER OF TWO GAPS.
#
# "At `n = 500` the port and upstream agree to ~0.007" is true of the
# `nuisance_space` tier and wrong about the `instrument` tier, whose gated gap
# is 0.010609 -- ~45% larger.  The gate's own record prints both
# (`_verify/LPLR_GATE_BLINDNESS_1680.md`: "the gap is 0.007307 / 0.010609"),
# and a reader who quotes the smaller one quotes the flattering half.
OLD_45_LPLR_007 = """1. **Don't read a small-n LPLR standard error as an estimate.** At `n = 500`
   the port and upstream agree to ~0.007. Below that the gate is a *report*,
   not a guarantee."""

NEW_45_LPLR_007 = """1. **Don't read a small-n LPLR standard error as an estimate.** At `n = 500`
   the port and upstream agree to `0.007307` on the `nuisance_space` tier and
   to `0.010609` on the `instrument` tier. Below that the gate is a *report*,
   not a guarantee."""

#
# (c) A COUNT THAT READS AS A DIFFERENT COUNT OUT OF CONTEXT.
#
# "all 8 of 8 swap cells" is the PORT-BETA half of a SIXTEEN-cell swap: the
# gate's record says "all 8 cells with `b` from upstream converge, all 8 with
# `b` from the port diverge" (`_verify/LPLR_GATE_BLINDNESS_1680.md` section
# 27c).  Written bare, "8 of 8 swap cells" reads as "the swap had 8 cells".
OLD_45_SWAP = """`t`/`m`/`a` values are harmless; `beta` alone reproduces the divergence, all 8
of 8 swap cells. And inside `beta`, it is not `r_hat = t - beta * a` that hurts"""

NEW_45_SWAP = """`t`/`m`/`a` values are harmless; `beta` alone reproduces the divergence -- in
all 8 of the 8 cells of the 16-cell swap that take `beta` from the port. And
inside `beta`, it is not `r_hat = t - beta * a` that hurts"""

#
# (d) A DGP COUNT A READER CANNOT MATCH AGAINST THE OUTPUT.
#
# The table said "Staggered CS-DID, 4 cohorts x 4 periods".  That is the DGP,
# and it is true -- but the example prints `n_groups = 3`, because cohort 0 is
# the never-treated cohort (`d[row] = if cohort > 0 && k >= cohort`), and the
# estimator does not count it as a treatment group.  A reader who diffs the
# README against the output sees 4 against 3 with nothing to explain it.
OLD_45_DIDCS = """| `examples/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts x 4 periods | 1.0 |"""

NEW_45_DIDCS = """| `examples/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts x 4 periods -- 3 treatment groups (cohort 0 is never treated) | 1.0 |"""

PATCHES.append((OLD_45_QUICKSTART_MARK, NEW_45_QUICKSTART_MARK))
PATCHES.append((OLD_45_CVAR_MARK, NEW_45_CVAR_MARK))
PATCHES.append((OLD_45_LPLR_MARK, NEW_45_LPLR_MARK))
PATCHES.append((OLD_45_LPLR_007, NEW_45_LPLR_007))
PATCHES.append((OLD_45_SWAP, NEW_45_SWAP))
PATCHES.append((OLD_45_DIDCS, NEW_45_DIDCS))


# ==============================================================================
# 13.  THE ROUND-44 PATCHES -- four promises the documents did not keep
# ==============================================================================
#
# Three fresh-eyes audits ran against this README.  Five of the six findings
# were real and are corrected here; the sixth (doc/006's coverage split) was
# DISPROVEN by a mutation test and changes nothing.
#
# (a) A MEASUREMENT RENDERED TWO TIMES TOO LARGE.
#     The DID paragraph says "IRM and APO need `m` for the estimand itself,
#     which is why they showed a ~200-point error and DID shows ~0.001."  The
#     same paragraph prints the figure it means one line later -- "at n=200 the
#     CLASSIFIER default is worse on both bias (0.0776 vs 0.00050) and SE" --
#     and the CHANGELOG's own measurement table carries the same row
#     (`| n=200, p=12, slope 4 | **0.0776** | **0.00050** |`).  So the prose
#     overstated the DID bias by 2x while printing it correctly two lines
#     later.  "~0.0005" is the measured figure.
#
# (b) A PACKAGE NAME PRINTED WHERE A REPOSITORY PATH WAS MEANT.
#     The layout block says
#
#         consumer_demo/         <- library-user pattern (`example/consumer_demo`)
#
#     `example/consumer_demo` is the example's PACKAGE NAME (it is what
#     `examples/consumer_demo/moon.mod` declares).  The repository PATH is
#     `examples/consumer_demo`, and that directory is tracked.  A path in
#     prose is a promise: it has to exist, and it has to be tracked.
#
# (c) A SENTENCE THAT SAID "THREE OF THE FOUR" BACKENDS RUN.
#     Measured on moon 0.1.20261023, a bare `moon test` prints
#
#         Total tests: 0, passed: 0, failed: 0. [wasm]
#         Total tests: 1123, passed: 1123, failed: 0. [wasm-gc]
#         Total tests: 0, passed: 0, failed: 0. [native]
#
#     and NOTHING for js.  So the suite runs on ONE of the four declared
#     backends, not three: wasm and native report 0 tests and js is never
#     reported at all -- while `moon test --target js` runs 1117 of them.
#     The phrase "four declared backends" is kept: `_verify_count_referents`
#     pins it, and it is the right number (the package's own
#     `supported_targets`).
#
# (d) THE EXAMPLE'S ASYNC PIN WAS TWO VERSIONS BEHIND.
#     The api_server example pinned `moonbitlang/async@0.20.3` while this
#     README's own dependency rule says to pin the latest published version
#     (`0.22.5`), and the example is the only thing in the tree that imports
#     it at all.  The pin moves to 0.22.5, the sentence that quotes it moves
#     with it, and the dependency table's note is rewritten -- because the
#     OLD note ("`examples/api_server/` uses the same package, but at its own
#     pin ... so this line matches no import") was a statement about a
#     DIFFERENCE that no longer exists.

# (a) and (c) are corrected in the NEW_ values of the patches that already
#     carried those paragraphs -- `NEW_DID_SCORE` and `NEW_BARE_TEST`.  A
#     second patch pair for either would match ZERO times by the time the loop
#     reached it, and the loop aborts on a match count other than one.

OLD_44_CONSUMER = ("  consumer_demo/         <- library-user pattern "
                   "(`example/consumer_demo`)")
NEW_44_CONSUMER = ("  consumer_demo/         <- library-user pattern "
                   "(`examples/consumer_demo`)")

OLD_44_ASYNC_PILLAR = ("The service is built directly on `moonbitlang/async@0.20.3` --\n"
                       "no third-party HTTP framework is pulled in.")
NEW_44_ASYNC_PILLAR = ("The service is built directly on `moonbitlang/async@%s` --\n"
                       "no third-party HTTP framework is pulled in." % ASYNC)

OLD_44_ASYNC_ROW = ("| `moonbitlang/async@0.22.5` | no | referenced by nothing: "
                    "`examples/api_server/` uses the same package, but at its own "
                    "pin -- `moonbitlang/async@0.20.3` -- so this line matches no "
                    "import |")
NEW_44_ASYNC_ROW = ("| `moonbitlang/async@%s` | no | referenced by nothing in "
                    "the library: `examples/api_server/` imports the same package "
                    "at the same pin (`moonbitlang/async@%s`), but no `.mbt` "
                    "under `moonbit_doubleML/` imports it |" % (ASYNC, ASYNC))

PATCHES.append((OLD_44_CONSUMER, NEW_44_CONSUMER))
PATCHES.append((OLD_44_ASYNC_PILLAR, NEW_44_ASYNC_PILLAR))
PATCHES.append((OLD_44_ASYNC_ROW, NEW_44_ASYNC_ROW))


# ==============================================================================
# 14.  THE ROUND-46 PATCHES -- one broken promise and three imprecisions
# ==============================================================================
#
# (a) SEVEN SCRIPT NAMES THAT ARE NOT FILES.
#     The upstream-owned paragraph names the two scripts that GATE the port
#     against upstream with their full filename -- and the seven that import
#     the wheel for CONTEXT with the bare stem.  The same sentence, two lines
#     earlier, writes the full name; every other occurrence in the document
#     carries the suffix too.  A backticked token reads as a filename, and
#     `validate_apos` does not exist on disk: the file is
#     `validate_apos_with_python.py`.  A reader who copies the name gets
#     "No such file or directory".
#
# (b) THE BACKEND COMMAND, IN THE TWO SUMMARIES.
#     A bare `moon test` runs the suite on ONE backend -- the document says so
#     95 lines later, in the Quick Start.  The two summaries that a reader
#     meets FIRST said only "under `moon test --deny-warn`", which is the
#     command that runs one backend.  Spelling the `--target` out costs a
#     word and removes the trap.
#
# (c) "22 estimators (`DoubleML*` structs)".
#     True for the ESTIMATORS, and loose as a phrase: a reader who greps
#     `struct DoubleML` finds 34 structs in 20 files -- the 22 estimators plus
#     12 `*Data` types -- and concludes the document is wrong.  The Status
#     table already uses the precise spelling ("22 `DoubleML*` estimator
#     structs"); this sentence now uses it too.
#
# (d) THE SAME BACKEND TRAP, IN THE STATUS TABLE.
#     "| Backends | ... all pass `moon test --deny-warn` |" makes the same
#     four-backend claim as the two summaries, with the same single-backend
#     command.  Three places made the claim; one of them said it correctly.
#
# The OLD texts are the text as the rounds up to 45 left it, so each pair
# matches exactly once.

OLD_46_SCRIPTS = """context (`validate_apos`, `validate_cluster_iv`, `validate_cluster_plr`,
`validate_iivm`, `validate_irm`, `validate_pliv`, `validate_plpr`); upstream's"""

NEW_46_SCRIPTS = """context (`validate_apos_with_python.py`, `validate_cluster_iv_with_python.py`,
`validate_cluster_plr_with_python.py`, `validate_iivm_with_python.py`,
`validate_irm_with_python.py`, `validate_pliv_with_python.py`,
`validate_plpr_with_python.py`); upstream's"""

OLD_46_INTRO_BACKENDS = """reproducible validation pipeline (24 / 24 Python reference scripts PASS)
-- on `native`,
`wasm`, `wasm-gc`, and `js` backends under `moon test --deny-warn`."""

NEW_46_INTRO_BACKENDS = """reproducible validation pipeline (24 / 24 Python reference scripts PASS)
-- on `native`,
`wasm`, `wasm-gc`, and `js` backends under
`moon test --target <backend> --deny-warn`."""

OLD_46_FEATURE_BACKENDS = """- ✅ **Four backends** -- `native`, `wasm`, `wasm-gc`, `js` -- all green under
  `moon test --deny-warn`."""

NEW_46_FEATURE_BACKENDS = """- ✅ **Four backends** -- `native`, `wasm`, `wasm-gc`, `js` -- all green under
  `moon test --target <backend> --deny-warn`."""

OLD_46_CENSUS = """22 estimators (`DoubleML*` structs) in 19 production files -- 16 with
one struct each, and three holding two"""

NEW_46_CENSUS = """22 `DoubleML*` estimator structs in 19 production files -- 16 with
one struct each, and three holding two"""

# (d) THE SAME BACKEND TRAP, IN THE STATUS TABLE.
#     The table row makes the same four-backend claim as the two summaries,
#     with the same single-backend command.  It is not in the generator's own
#     text -- it arrives from the v0.164.11 base -- so the patch has to reach
#     the ASSEMBLED document, which is what the patch loop edits.
OLD_46_STATUS_BACKENDS = """| Backends | `native`, `wasm`, `wasm-gc`, `js` -- all pass `moon test --deny-warn` |"""

NEW_46_STATUS_BACKENDS = """| Backends | `native`, `wasm`, `wasm-gc`, `js` -- all pass `moon test --target <backend> --deny-warn` |"""

PATCHES.append((OLD_46_SCRIPTS, NEW_46_SCRIPTS))
PATCHES.append((OLD_46_INTRO_BACKENDS, NEW_46_INTRO_BACKENDS))
PATCHES.append((OLD_46_FEATURE_BACKENDS, NEW_46_FEATURE_BACKENDS))
PATCHES.append((OLD_46_CENSUS, NEW_46_CENSUS))
PATCHES.append((OLD_46_STATUS_BACKENDS, NEW_46_STATUS_BACKENDS))


# ==============================================================================
# 15.  THE ROUND-47 PATCHES -- whose measurement the figures are
# ==============================================================================
#
# The "Used By" section quotes a DOWNSTREAM consumer's own numbers:
#
#     `n = 400`, true `theta = 1.5`, `theta` delta `0.017` (1.667 vs 1.685)
#     and `se` delta `0.001` (0.153 vs 0.152)
#
# They are TRUE -- pyroduct's `dmlref` report says exactly this -- and they
# are not derivable from here.  The code that produces them is in another
# repository; the published pyroduct package ships no sources (its
# `source_files` list is empty), and its published README does not carry the
# figures either.  So no probe in this tree can re-derive them, and a reader
# who skims the section could take them for this repository's measurements.
#
# The fix is NOT a version literal: a literal about another repository's pin
# rots on that repository's schedule, which is exactly why round 42 dropped
# one.  The fix is ATTRIBUTION -- the section says whose measurement the
# figures are, and says that this repository does not re-measure them.
OLD_47_USED_BY = (
    "  `dmlref` package cross-checks its own from-scratch DoubleML\n"
    "  PLR against `riantr/moonbit_doubleML`: same nuisance (OLS),\n"
    "  `n = 400`, true `theta = 1.5`, `theta` delta `0.017` (1.667 vs\n"
    "  1.685) and `se` delta `0.001` (0.153 vs 0.152).")

NEW_47_USED_BY = (
    "  `dmlref` package cross-checks its own from-scratch DoubleML\n"
    "  PLR against `riantr/moonbit_doubleML`: same nuisance (OLS),\n"
    "  `n = 400`, true `theta = 1.5`, `theta` delta `0.017` (1.667 vs\n"
    "  1.685) and `se` delta `0.001` (0.153 vs 0.152). **Those figures are\n"
    "  pyroduct's own measurement, in pyroduct's `dmlref` report; this\n"
    "  repository does not re-measure them, because the code that produces\n"
    "  them is not in this tree.**")

PATCHES.append((OLD_47_USED_BY, NEW_47_USED_BY))


# ==============================================================================
# 16.  THE ROUND-48 PATCHES -- the shape filter, and three prose defects
# ==============================================================================
#
# The reference package the user named (`bobzhang/toml@0.4.3`, 841 lines /
# 24 504 chars) states the CURRENT truth and the boundaries.  It carries no
# release-by-release archaeology, no duplicated restatements and no internal
# call-site census.  These patches remove the same KIND of content from this
# README -- and nothing else: every measured claim a verifier pins stays.
#
# (a) THE SHAPE FILTER -- seven duplications and four prose blocks:
#     the preamble's restatement of the 19 / 2 / 1 upstream map; the
#     audience paragraph's second half (it repeats the Features bullets);
#     the Features list's re-listing of the 22 estimator NAMES (the table
#     two paragraphs down lists them all); the "How the names map"
#     blockquote (it repeats the table's last column and Attribution); the
#     estimator table's preamble (the same 19 / 2 / 1 map a third time);
#     the migration VERSION list; the per-release verdict history; the
#     "a future release can swap the bodies" speculation; the Examples
#     section's directory-by-directory description; and the dependency
#     table's note, which repeated its own cell.
#
# (b) DEFECT 1 -- THE ATTRIBUTION PROMISED A COMPARISON THAT DOES NOT EXIST.
#     "all three ship upstream, and are compared against it" is false for
#     `DoubleMLPLPR`: `validate_plpr_with_python.py` compares UPSTREAM's
#     theta against the HAND-ROLLED one and never against the port's, and
#     the two sides are fitted on DIFFERENT rows (numpy's `default_rng`
#     against the port's `chacha8_rng`); `pyexample_suite.py` contains no
#     `plpr` at all.  The other two ARE compared against upstream.
#
# (c) DEFECT 2 -- THE SMALL-n CAUTION SAID BOTH SIDES FAIL.
#     "Both this port and upstream fail there, in opposite directions" is
#     false on the gate's own output: the direction REVERSES with n (at
#     n = 60 the port is well-behaved and upstream is not; at n = 100 it is
#     exactly reversed; at n = 160 neither fails).  The upstream half of the
#     claim survives -- upstream really is ill-posed there.
#
# (d) DEFECT 3 -- "RUN UPSTREAM'S OWN CODE" IS FALSE FOR ONE OF THE NINE.
#     `pyexample_rdd.py` references `rdrobust`, a different package from
#     `doubleml-for-py`.
#
# The OLD texts are the text as the rounds up to 47 left it, so each pair
# matches exactly once.

OLD_48_D1_PREAMBLE_TRIO = '`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` all ship\nupstream, and the table marks them *(upstream)*.\n'
NEW_48_D1_PREAMBLE_TRIO = ''
PATCHES.append((OLD_48_D1_PREAMBLE_TRIO, NEW_48_D1_PREAMBLE_TRIO))

OLD_48_D2_AUDIENCE_TAIL = 'inside the MoonBit ecosystem. Delivers one\n`DoubleMLXxx::new(...).fit()` API across all 22 estimators -- the shape\nis the same, but six take a different constructor, and those six are\nnamed in **API reference** -- with robust variance estimation,\npropensity-score processing, multiple-testing correction, and a\nreproducible validation pipeline (24 / 24 Python reference scripts PASS)\n-- on `native`,\n`wasm`, `wasm-gc`, and `js` backends under\n`moon test --target <backend> --deny-warn`.\n'
NEW_48_D2_AUDIENCE_TAIL = 'inside the MoonBit ecosystem. Delivers one\n`DoubleMLXxx::new(...).fit()` API across all 22 estimators, with robust\nvariance estimation and a reproducible validation pipeline\n(24 / 24 Python reference scripts PASS).\n'
PATCHES.append((OLD_48_D2_AUDIENCE_TAIL, NEW_48_D2_AUDIENCE_TAIL))

OLD_48_D3_FEATURES_NAMES = '**Pure-MoonBit, all-4-backends port of `doubleml-for-py`** -- 22 `DoubleML*`\nestimators (`DoubleMLPLR`, `DoubleMLIRM`, `DoubleMLPLIV`, `DoubleMLIIVM`,\n`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`,\n`DoubleMLDIDCSBinary`, `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`,\n`DoubleMLSSM`, `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLPQ`,\n`DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLLPLR`, `DoubleMLCVAR`,\n`DoubleMLRDD`, `DoubleMLBLP`, `DoubleMLPLPR`, `DoubleMLPolicyTree`)\nin 19 source files. **19** are marked *(upstream)* and mirror a\nname-identical `doubleml-for-py` class; **2** are marked\n*(upstream, renamed)* -- `DoubleMLRDD` (upstream `RDFlex`) and\n`DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`); and **1**,\n`DoubleMLDIDCS`, is marked *(upstream design, no 1:1 class)*.\n'
NEW_48_D3_FEATURES_NAMES = '**Pure-MoonBit, all-4-backends port of `doubleml-for-py`** -- 22 `DoubleML*`\nestimators in 19 source files. **19** are marked *(upstream)* and mirror a\nname-identical `doubleml-for-py` class; **2** are marked\n*(upstream, renamed)* -- `DoubleMLRDD` (upstream `RDFlex`) and\n`DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`); and **1**,\n`DoubleMLDIDCS`, is marked *(upstream design, no 1:1 class)*.\n'
PATCHES.append((OLD_48_D3_FEATURES_NAMES, NEW_48_D3_FEATURES_NAMES))

OLD_48_D4_NAMES_MAP = "> **How the names map.** `DoubleMLDIDCS` has **no 1:1 upstream class**\n> -- it is this port's variant of upstream's `DoubleMLDIDMulti` -- and the\n> two *renamed* pairs are `DoubleMLRDD` (upstream `RDFlex`) and\n> `DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`). The derivation, and\n> the parameter that distinguishes them, are in\n> `_verify/UPSTREAM_PROVENANCE.md` and in `ENGINEERING.md`.\n"
NEW_48_D4_NAMES_MAP = "> **How the names map.** The estimator table's last column is the map;\n> the derivation is in `_verify/UPSTREAM_PROVENANCE.md` and in\n> `ENGINEERING.md`.\n"
PATCHES.append((OLD_48_D4_NAMES_MAP, NEW_48_D4_NAMES_MAP))

OLD_48_D5_TABLE_PREAMBLE = "`DoubleMLXxx::new(...).fit()` interface. 19 are marked *(upstream)*\nagainst a name-identical `doubleml-for-py` class; two are marked\n*(upstream, renamed)* -- `DoubleMLRDD` (upstream `RDFlex`) and\n`DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`); and one,\n`DoubleMLDIDCS`, is marked *(upstream design, no 1:1 class)* -- the\nport's variant of upstream's `DoubleMLDIDMulti`:\n"
NEW_48_D5_TABLE_PREAMBLE = "`DoubleMLXxx::new(...).fit()` interface. The last column marks each\nrow's upstream counterpart:\n"
PATCHES.append((OLD_48_D5_TABLE_PREAMBLE, NEW_48_D5_TABLE_PREAMBLE))

OLD_48_D6_MIGRATION_VERSIONS = 'everywhere. **`DoubleMLIRM` was migrated in v0.132.0**,\n**`DoubleMLAPO` in v0.134.0**, **`DoubleMLAPOS` in v0.135.0**,\n**`DoubleMLSSM` in v0.138.0**, **`DoubleMLPQ` / `DoubleMLQTE` in\nv0.139.0** and **`DoubleMLLPLR` in v0.163.3**:\ntheir `ml_m` default is now\n'
NEW_48_D6_MIGRATION_VERSIONS = 'everywhere. **Seven** estimators now default to a classifier --\n`DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLSSM`,\n`DoubleMLPQ`, `DoubleMLQTE` and `DoubleMLLPLR` --\ntheir `ml_m` default is now\n'
PATCHES.append((OLD_48_D6_MIGRATION_VERSIONS, NEW_48_D6_MIGRATION_VERSIONS))

OLD_48_D7_VERDICT_HISTORY = 'Every row above is a **measured verdict**, and each was settled in the release\nthat decided it: `DoubleMLIRM` (v0.132.0), `DoubleMLAPO` (v0.134.0),\n`DoubleMLAPOS` (v0.135.0) and `DoubleMLDIDBinary` (v0.136.0) first, the rest\nin v0.137.0. `DoubleMLQTE` is the one row whose verdict is later than its\nmeasurement: v0.137.0 recorded it as *not demonstrated* (`0.162` vs `0.249`),\nand the freeze was only found in v0.139.0. **Six rows turned out hazardous**:\n'
NEW_48_D7_VERDICT_HISTORY = 'Every row above is a **measured verdict**. **Six rows turned out hazardous**:\n'
PATCHES.append((OLD_48_D7_VERDICT_HISTORY, NEW_48_D7_VERDICT_HISTORY))

OLD_48_D8_FUTURE_SWAP = 'subtract. The helpers are pure element-wise loop wrappers\ntoday -- the public API has been fixed since v0.82, so a future\nrelease can swap the bodies to a SIMD-vectorised backend (or external\ncall to a BLAS-style library) without breaking callers.\n'
NEW_48_D8_FUTURE_SWAP = 'subtract. The helpers are pure element-wise loop wrappers today.\n'
PATCHES.append((OLD_48_D8_FUTURE_SWAP, NEW_48_D8_FUTURE_SWAP))

OLD_48_D10_EXAMPLES_PROSE = '21 `examples/<bin>/` directories in `moon.work`. 16 are CLI-style numeric\ndemos that print an estimate; measured per driver, **14** of the 16 print a\ntrue value and **11** of the 16 print a 95 % CI -- `examples/pava` and\n`examples/splitting` print neither, and `examples/apos`, `examples/cluster`\nand `examples/ssm` print a true value but no CI. `examples/api_server/`\nis an HTTP service; `examples/consumer_demo/` is the library-user pattern\nthat mirrors what an external `moon add riantr/moonbit_doubleML` consumer\nwould write; `examples/fuzz/` is the property-based fuzz harness; and\n`examples/bitexact/` and `examples/parity/` are the MoonBit fixtures the\nbit-exact and LPLR parity validators drive, kept as runnable binaries so\ntheir numbers are inspectable without a Python reference.\n'
NEW_48_D10_EXAMPLES_PROSE = '21 `examples/<bin>/` directories in `moon.work`. 16 are CLI-style numeric\ndemos that print an estimate; measured per driver, **14** of the 16 print a\ntrue value and **11** of the 16 print a 95 % CI -- `examples/pava` and\n`examples/splitting` print neither, and `examples/apos`, `examples/cluster`\nand `examples/ssm` print a true value but no CI. `examples/api_server/` is\nan HTTP service; `examples/consumer_demo/` is the library-user pattern that\nmirrors what an external `moon add riantr/moonbit_doubleML` consumer would\nwrite; `examples/fuzz/` is the property-based fuzz harness; and\n`examples/bitexact/` and `examples/parity/` are the MoonBit fixtures the\nbit-exact and LPLR parity validators drive.\n'
PATCHES.append((OLD_48_D10_EXAMPLES_PROSE, NEW_48_D10_EXAMPLES_PROSE))

OLD_48_F2_DO3_SMALLN = '3. **Treat `n < 200` as ill-posed for partially logistic regression.** Both\n   this port and upstream fail there, in opposite directions, and the port\n   damps its Newton step to keep the answer finite.\n'
NEW_48_F2_DO3_SMALLN = '3. **Treat `n < 200` as ill-posed for partially logistic regression.** Upstream\n   genuinely is ill-posed there -- non-finite standard errors and root\n   warnings -- while this port damps its Newton step to keep the answer\n   finite. Which side breaks depends on n, so neither one is a safe\n   reference for the other at that size.\n'
PATCHES.append((OLD_48_F2_DO3_SMALLN, NEW_48_F2_DO3_SMALLN))

OLD_48_F3_UPSTREAM_REFERENCE = 'someone already thought to look for. The `pyexample_*` scripts instead run\nupstream\'s own code on the port\'s rows and compare that: not "does the port\nagree with our second implementation" but "does the port agree with upstream".\n'
NEW_48_F3_UPSTREAM_REFERENCE = 'someone already thought to look for. The `pyexample_*` scripts instead run a\nreference implementation on the port\'s rows and compare that: not "does the\nport agree with our second implementation" but "does the port agree with\nupstream". The reference is upstream\'s own `doubleml` classes in eight of\nthem, and `rdrobust` for the RDD arm -- `doubleml-for-py` and `rdrobust` are\ndifferent packages.\n'
PATCHES.append((OLD_48_F3_UPSTREAM_REFERENCE, NEW_48_F3_UPSTREAM_REFERENCE))

OLD_48_F1_ATTRIBUTION_COMPARISON = '`DoubleMLLPLR` and `DoubleMLDIDCSBinary` are **not** MoonBit-only -- all\nthree ship upstream, and are compared against it. The last candidate\n'
NEW_48_F1_ATTRIBUTION_COMPARISON = "`DoubleMLLPLR` and `DoubleMLDIDCSBinary` are **not** MoonBit-only -- all\nthree ship upstream. `DoubleMLLPLR` and `DoubleMLDIDCSBinary` are compared\nagainst upstream's own classes; `DoubleMLPLPR`'s upstream fit is compared\nagainst a hand-rolled reference on a different dataset from the port's, so\nPLPR has no upstream gate. The last candidate\n"
PATCHES.append((OLD_48_F1_ATTRIBUTION_COMPARISON, NEW_48_F1_ATTRIBUTION_COMPARISON))


# ==============================================================================
# 17.  THE ROUND-59 PATCHES -- the shape, measured against the two references
# ==============================================================================
#
# The reference packages the user named (`Ridge-Lab/capnp@0.1.0` and
# `gaato/discord@0.10.0`) both OPEN with a CI badge, and discord opens its
# prose with a one-paragraph STATUS.  This README had NEITHER: measured against
# the two of them, it carried NO image at all, and its status sat 590 lines
# down, under "Development status".
#
# Two changes, and every element of both is a claim the tree can hold:
#
# (a) THE CI BADGE.  It names `.github/workflows/check.yml` -- the workflow
#     named "CI", which runs on every push to `main` and `master` and on every
#     pull request.  A badge URL is a URL, not a path, so the path-promises
#     verifier does not see it: `_verify/_verify_readme_shape_1650.py` holds it
#     instead.
#
# (b) THE STATUS LINE.  Every element is DERIVED from the manifest: MIT is
#     `moon.mod`'s `license`, the four backends are its `supported_targets`,
#     and the estimator count is measured.  NO version literal goes in here on
#     purpose -- a version in a new place is a new bump site, and a bump site
#     the bump script does not know about is a stale number waiting to happen.
#
# The reference's THIRD shape element -- a MINIMUM toolchain ("需要 MoonBit
# 0.10.14 或更新版本") -- is deliberately NOT copied.  Nothing in this tree
# establishes a floor: `moon.mod` declares no toolchain constraint, and the
# workflows install the latest `moon` rather than pinning one.  The README
# already says what IS true, in the Status table: the release is verified on a
# named version, and a bare `moon` may be newer.  A floor nobody measured is
# exactly the kind of claim this repository refuses to publish.

OLD_59_A_TITLE = ("# moonbit_doubleML - Double / Debiased Machine Learning in MoonBit\n"
                   "\n"
                   "A pure-MoonBit port of the\n")
NEW_59_A_TITLE = ("# moonbit_doubleML - Double / Debiased Machine Learning in MoonBit\n"
                  "\n"
                  "[![CI](https://github.com/riantr/moonbit_doubleML/actions/workflows/"
                  "check.yml/badge.svg)]"
                  "(https://github.com/riantr/moonbit_doubleML/actions/workflows/check.yml)\n"
                  "\n"
                  "A pure-MoonBit port of the\n")
PATCHES.append((OLD_59_A_TITLE, NEW_59_A_TITLE))

OLD_59_B_FEATURES = "(24 / 24 Python reference scripts PASS).\n\n## Features\n"
NEW_59_B_FEATURES = ("(24 / 24 Python reference scripts PASS).\n"
                     "\n"
                     "> **Status**: MIT, pure MoonBit, on `native`, `wasm`, `wasm-gc` and `js`,\n"
                     "> with 22 estimators. **Development status** below states what is\n"
                     "> verified against upstream and what is **not** claimed.\n"
                     "\n"
                     "## Features\n")
PATCHES.append((OLD_59_B_FEATURES, NEW_59_B_FEATURES))


# ==============================================================================
# 18.  THE ROUND-70 PATCHES -- the pin, and the rule that names it
# ==============================================================================
#
# The registry published `moonbitlang/async@0.22.6`, and the tree's own
# dep-pin check turned RED: the pin had to be the published latest, and it
# was one version behind.
#
# Moving it is not a number edit.  0.22.6 imports `moonbitlang/core/async`,
# a subpackage that only the core shipped with moon 0.1.20261028 carries --
# on moon 0.1.20261023 the build plan cannot even be SOLVED ("Cannot find
# import 'moonbitlang/core/async' in moonbitlang/async@0.22.6").  So the
# toolchain moved with the dependency, and every claim that NAMED the
# toolchain was re-derived on it rather than re-labelled (the four per-target
# counts are still 1117 / 1123 / 1117 / 1117; a bare `moon test` still
# reports 0 for `wasm` and `native` and "no test entry found" for `js`;
# `@std/env`, `@std/fs`, `@std/io` and `@std/process` still do not resolve;
# `read_file` is still error 4021; `train` is still not reserved).
#
# The dependency rule's OWN example names the pin, and that line comes
# straight from the pristine v0.164.11 README -- no earlier patch touched it,
# so it was the last place still saying 0.22.5.  It is a PATCH, because the
# README is GENERATED: an edit to the built file is lost by the next bump.
#
# The pin itself is DERIVED from `moonbit_doubleML/moon.mod` (see `ASYNC`
# above), so the README cannot name a pin the tree does not declare -- which
# is the whole class of staleness this patch closes.

OLD_70_ASYNC_RULE = ("- Pin to the latest published version (e.g. "
                      "`moonbitlang/async@0.22.5`).")
NEW_70_ASYNC_RULE = ("- Pin to the latest published version (e.g. "
                      "`moonbitlang/async@%s`)." % ASYNC)

PATCHES.append((OLD_70_ASYNC_RULE, NEW_70_ASYNC_RULE))


# ==============================================================================
# 19.  THE ROUND-72 PATCHES -- the claims that rotted because nobody held them
# ==============================================================================
#
# Two INDEPENDENT fresh-eyes audits read the published README line by line in
# round 72.  Both returned PASS: no false claim, and every measured count --
# the 22 estimators in 19 files, the 220 `.mbt` files, the 1117 tests, the 24
# validators, the 9 upstream gates, the 15/4/3 sandwich split, the 7 score
# takers, the 8 argument sets -- matched the tree.
#
# What they did find were three passages that had gone out of date.  All three
# are corrected here, in the GENERATOR, for the reason round 21 used:
# README.mbt.md is BUILT, so an edit made to it is reverted by the next bump.
#
# F2. THE VECTORISED INVENTORY WAS TWO HELPERS AND TEN CALL SITES OUT OF DATE.
# The README listed `matrix_predict`, `vector_subtract`, `vector_add` and
# `vector_scale`; the file also exports `vector_multiply` and `vector_divide`
# (both v0.82.0+).  It named the IRM and PLR paths as the callers of
# `vector_subtract`; TWELVE library files call it.  Nothing held the claim,
# which is why it could rot: the helpers were added and the document was not.
# Both halves are DERIVED now (VEC_FNS, VEC_CALLERS), and
# `_verify/_verify_vectorised_surface_1680.py` holds them.
#
# F3. THE OPENING PARAGRAPH LOST ITS CAVEAT.
# Round 22 corrected "a claim that one API shape covered all 22 estimators when
# six constructors differ" -- and round 48's condensation dropped the caveat
# from the opening paragraph again, while keeping it in the Features list
# eleven lines further down.  The qualifier is restored, in the wording round
# 48 removed.
#
# (F1, the Development section's description of `ENGINEERING.md`, is not a
# patch: that section is built by an `A(...)` block above, so it is edited
# where it is written.)

OLD_72_VECTORISED = """**Vectorised cross-fit helpers (v0.81.0+)** -- `vectorized.mbt`
exposes `matrix_predict` (Kahan-compensated `X @ weights + bias`),
`vector_subtract`, `vector_add`, and `vector_scale` as public
free functions. `DoubleMLIRM::fit` / `fit_cluster` /
`sensitivity_analysis` and the matching `DoubleMLPLR` paths now
route the per-observation residual extraction through
`vector_subtract` instead of an inlined per-iteration load /
subtract. The helpers are pure element-wise loop wrappers today."""

NEW_72_VECTORISED = """**Vectorised cross-fit helpers (v0.81.0+)** -- `vectorized.mbt`
exposes `matrix_predict` (Kahan-compensated `X @ weights + bias`),
%s as public
free functions. `DoubleMLIRM::fit` / `fit_cluster` /
`sensitivity_analysis` and the matching `DoubleMLPLR` paths route
the per-observation residual extraction through `vector_subtract`
instead of an inlined per-iteration load / subtract, and %d of the
library's own files call it today. The `vector_*` helpers are pure
element-wise loop wrappers today; `matrix_predict` is a
Kahan-compensated matrix-vector product.""" % (
    wrap_list(list_pieces([f for f in VEC_FNS if f != "matrix_predict"]), 66),
    len(VEC_CALLERS))

OLD_72_OPENING = """inside the MoonBit ecosystem. Delivers one
`DoubleMLXxx::new(...).fit()` API across all 22 estimators, with robust
variance estimation and a reproducible validation pipeline
(24 / 24 Python reference scripts PASS)."""

NEW_72_OPENING = """inside the MoonBit ecosystem. Delivers one
`DoubleMLXxx::new(...).fit()` API shape across all 22 estimators -- six take a
different constructor, and those six are named in **API reference** -- with
robust variance estimation and a reproducible validation pipeline
(24 / 24 Python reference scripts PASS)."""

PATCHES.append((OLD_72_VECTORISED, NEW_72_VECTORISED))
PATCHES.append((OLD_72_OPENING, NEW_72_OPENING))


for _old, _new in PATCHES:
    _n = text.count(_old)
    if _n != 1:
        print("!! a README patch matched %d times (expected 1) -- ABORT" % _n)
        sys.exit(1)
    text = text.replace(_old, _new)
    print("   patched the API reference: %d -> %d chars" % (len(_old), len(_new)))

# ==============================================================================
# 4a.  THE TEST COUNTS -- derived, not inherited
# ==============================================================================
#
# The test totals are the most prominent numbers the README states, and until
# round 72 they were LITERALS inherited from the v0.164.11 base document.  A
# number inherited from a snapshot rots in silence: the next `.mbt` file
# carrying a `test "..."` changes the tree without changing the document.
#
# Each claim is matched by its SHAPE -- the shape IS the promise -- so every
# place the document states it is derived: the ones present and the ones a
# later round adds.  A shape that DISAPPEARS is an abort, because a claim
# that silently stopped being made is a claim nobody is watching any more.
#
# (The round-59 lesson: a mechanism that patches a FIXED number of sites goes
# flat when the document gains one.  Here the sites are counted at RUN TIME,
# and EVERY site of a shape is derived -- not a fixed number of them.)
def derive(text, pattern, replacement, what):
    new_text, n = re.subn(pattern, replacement, text)
    if n == 0:
        print("!! the README no longer states %s -- ABORT" % what)
        sys.exit(1)
    print("   derived %-36s in %d place(s)" % (what, n))
    return new_text


text = derive(
    text,
    r"Total tests: \d+, passed: \d+, failed: 0\.",
    lambda m: "Total tests: %d, passed: %d, failed: 0." % (LIB_TESTS, LIB_TESTS),
    "the test transcript")
text = derive(
    text,
    r"(\| Tests \(native / wasm / js\) \| \*\*)\d+ / \d+ / \d+(\*\* \|)",
    lambda m: m.group(1) + "%d / %d / %d" % (LIB_TESTS, LIB_TESTS, LIB_TESTS)
    + m.group(2),
    "the native / wasm / js row")
text = derive(
    text,
    r"(\| Tests \(wasm-gc\) \| \*\*)\d+ / \d+(\*\* \(lib \+ )\d+( doc tutorials\))",
    lambda m: m.group(1) + "%d / %d" % (WASMGC_TESTS, WASMGC_TESTS)
    + m.group(2) + str(DOC_TESTS) + m.group(3),
    "the wasm-gc row")
text = derive(
    text,
    r"where the suite is \*\*\d+\*\* -- \d+ plus \d+ doc tutorials",
    lambda m: "where the suite is **%d** -- %d plus %d doc tutorials"
    % (WASMGC_TESTS, LIB_TESTS, DOC_TESTS),
    "the preferred-target sentence")
text = derive(
    text,
    r"runs the suite on `wasm-gc` \(\d+",
    lambda m: "runs the suite on `wasm-gc` (%d" % WASMGC_TESTS,
    "the bare-run sentence")

# ==============================================================================
# 4.  WRITE
# ==============================================================================
io.open("ENGINEERING.md", "w", encoding="utf-8", newline="\n").write(ledger)
io.open("README.mbt.md", "w", encoding="utf-8", newline="\n").write(text)
# the shipped copy must stay byte-identical to the edited one
shutil.copyfile("README.mbt.md", os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md"))

for name, body in (("README.mbt.md", text), ("ENGINEERING.md", ledger)):
    b = body.encode("utf-8")
    print("%-18s %7d bytes  %5d lines  CR=%d  BOM=%s"
          % (name, len(b), body.count("\n"), b.count(b"\r"),
             b.startswith(b"\xef\xbb\xbf")))
print("source: %s" % SRC_FROM)
