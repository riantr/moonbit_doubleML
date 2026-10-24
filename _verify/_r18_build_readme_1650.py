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
>   ends at **9** failures.  The last mechanism moves the SET SIZE -- a new
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
>   ends at **8** failures.
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
>   ends at **14** failures.  It caught three defects in its own construction:
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

INSTALL = """## Installation

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

"""

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

The test suite, the Python cross-checks, the QA harness and the
reproducibility commands are all documented in `ENGINEERING.md`, together with
the history of the defects that moved the estimator defaults and the
derivation of the upstream naming map. Both files are in the repository; the
registry publishes this one.

```console
$ moon test --target native --deny-warn
Total tests: 1117, passed: 1117, failed: 0.
```

## License

MIT. The upstream package, `DoubleML/doubleml-for-py`, is BSD 3-Clause; this
port is MIT-licensed and credits it (see **Attribution** above).
""")

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
#     moon 0.1.20261023, a bare run prints [wasm], [wasm-gc] and [native] and
#     reports "no test entry found" for `js` -- 1117 js tests it never runs.
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
DID shows ~0.001. The sharpest DID case: at n=200 the CLASSIFIER default is
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

NEW_BARE_TEST = """per-target numbers are in the Status table. A bare `moon test` runs only
three of the four declared backends -- on `moon 0.1.20261023` it prints
`Total tests: 0` for `wasm` and `native` and reports `no test entry found`
for `js`, which it never runs -- so the per-target counts here come from
explicit `--target` runs."""

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
and `moonbitlang/async@0.22.5` -- are dead: nothing imports them, and
`dependencies` already WARNs about exactly that (`2 declared; non-conforming:
['moonbit-community/sqlite3@0.2.3']; declared but unreferenced by library code:
['moonbit-community/sqlite3@0.2.3', 'moonbitlang/async@0.22.5']`) rather than
passing quietly. Removing them is an open call, not an oversight."""

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
    "| Toolchain | `moon 0.1.20261023` -- the version this release's tests, "
    "cross-checks and bit-exactness gate were run on, and the version every "
    "number in this table was re-verified on; a bare `moon` from "
    "`cli.moonbitlang.com` may be newer |")

# (h) THE SAME MOVE, IN THE PARITY SECTION.  The operator bit-exactness
#     table is re-measured by `_verify/_verify_op_table_1640.py` on whatever
#     toolchain is installed NOW, and it gives the same numbers -- so the
#     pair it names is the pair the measurement was last taken on.
OLD_39_PARITY = "re-measured on `moon 0.1.20261016` vs CPython 3.13.14"
NEW_39_PARITY = "re-measured on `moon 0.1.20261023` vs CPython 3.13.14"

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


for _old, _new in PATCHES:
    _n = text.count(_old)
    if _n != 1:
        print("!! a README patch matched %d times (expected 1) -- ABORT" % _n)
        sys.exit(1)
    text = text.replace(_old, _new)
    print("   patched the API reference: %d -> %d chars" % (len(_old), len(_new)))

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
