#!/usr/bin/env python3
"""Hold the GENERATED documents against ESCAPE DAMAGE.

THE DEFECT CLASS
================
`_verify/_r18_build_readme_1650.py` holds the README and the ENGINEERING banner
as Python STRING LITERALS.  A hex escape inside one of them is not TEXT -- it
is a CHARACTER.  So a banner sentence that quotes the earlier toolchain's
output as

    the earlier one rendered `b'\\x45'`

has to be written in the SOURCE as `b'\\\\x45'` (two backslashes).  Written with
one, Python consumes the escape and the shipped document says

    the earlier one rendered `b'E'`

-- one character where the toolchain printed four, and a quotation of a string
the toolchain never printed.  The CHANGELOG (a plain-text file, so its
backslashes are literal), the commit message and the example's own comment all
say `b'\\x45'`, so three documents agreed and the banner did not, and nothing
had noticed: every check that read the SOURCE saw four characters there, and
the damage only exists in the OUTPUT.

WHAT THIS CHECKS
================
1.  The rule: NO string literal in the builder may contain a hex escape that
    FIRES.  An escape fires when the number of backslashes immediately before
    it is ODD -- then Python eats them and evaluates the escape.  An EVEN
    count means the backslashes are literal and the text survives.
2.  The output: the shipped `ENGINEERING.md` must be WHAT THE BUILDER
    PRODUCES -- the builder's evaluated `LEDGER_HEAD` must be in the shipped
    file, with the one placeholder the builder fills in (`__GAP_NOTE__`)
    allowed to differ, because the builder computes it from the round numbers.
3.  The plain-text reference: the CHANGELOG is a FILE, not a literal, so the
    code span it spells around the same escape is the ground truth, and the
    banner must spell it the same way.

THE CONTROL ARM
===============
`--falsify` re-introduces the historical damage -- it turns the builder's
DOUBLED backslash back into a single one, which is exactly what the defect
was -- and requires the checks to go RED on the mutated builder.  A check
that has never been shown to fail is a comment.

Run: python _verify/_verify_escape_damage_1650.py [--falsify]
"""
import ast
import io
import os
import re
import sys
import tempfile
import warnings

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILDER = os.path.join(ROOT, "_verify", "_r18_build_readme_1650.py")
LEDGER = os.path.join(ROOT, "ENGINEERING.md")
README = os.path.join(ROOT, "README.mbt.md")
PKG_README = os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")

# A hex escape, with the run of backslashes that precedes it.  Python consumes
# backslashes in PAIRS, so an ODD count fires the escape and an EVEN count
# leaves the text alone.
HEX = re.compile(r"(\\+)(?:x([0-9A-Fa-f]{2})|u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8}))")
GAP_NOTE = "__GAP_NOTE__"

BENIGN = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'"}

# The main check list.  The control arm's own runs are reported SEPARATELY and
# do not change this count, so the published count is the same whether or not
# `--falsify` was passed.
RESULTS = []


def ok(msg):
    RESULTS.append(True)
    print("  ok   %s" % msg)


def bad(msg):
    RESULTS.append(False)
    print("  FAIL %s" % msg)


def parse(src):
    """ast.parse without the builder's own SyntaxWarning noise."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return ast.parse(src)


def literals(src):
    """Every string literal in the source: (node, source segment, value)."""
    out = []
    for node in ast.walk(parse(src)):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            seg = ast.get_source_segment(src, node)
            if seg:
                out.append((node, seg, node.value))
    return out


def resolve(text, hex_too=False):
    """Resolve the escapes in a SOURCE fragment the way Python does.

    `hex_too` decides what happens to a hex escape: FALSE leaves it as TEXT
    (the spelling the source shows), TRUE evaluates it (the character the
    source produces).  Benign escapes (`\\n`, `\\t`, `\\r`, `\\\\`, `\\"`,
    `\\'`) are always resolved.
    """
    out = []
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "\\":
                out.append("\\")
                i += 2
                continue
            if nxt in BENIGN and nxt != "\\":
                out.append(BENIGN[nxt])
                i += 2
                continue
            m = HEX.match(text, i)
            if m and hex_too:
                hx = m.group(2) or m.group(3) or m.group(4)
                out.append(chr(int(hx, 16)))
                i = m.end()
                continue
            out.append(text[i:i + 2])
            i += 2
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def code_span(seg, pos):
    """The backtick-quoted span of the source text around `pos`.

    The sentence is `` rendered `b'\\x45'`, `` -- the code span is
    `` `b'\\x45'` `` and the comma after it is not part of what is QUOTED.
    A whitespace-delimited token would take the comma with it, and then the
    same quoted text would compare unequal in two documents that spell it
    identically.
    """
    left = seg.rfind("`", 0, pos)
    right = seg.find("`", pos)
    if left < 0 or right < 0:
        return None
    return seg[left:right + 1]


def escapes(src):
    """Every hex escape in the source: (lineno, fires, src_span, spelled,
    fired).

    `spelled` is the code span as the source SHOWS it (benign escapes
    resolved, the hex escape left as text); `fired` is the same span with the
    hex escape EVALUATED.  Neither is hard-coded -- both come from the
    builder.
    """
    out = []
    for node, seg, _value in literals(src):
        for m in HEX.finditer(seg):
            fires = len(m.group(1)) % 2 == 1
            lineno = node.lineno + seg[:m.start()].count("\n")
            span = code_span(seg, m.start())
            if span is None:
                continue
            out.append((lineno, fires, span,
                        resolve(span, hex_too=False),
                        resolve(span, hex_too=True)))
    return out


def ledger_value(src):
    """The builder's EVALUATED LEDGER_HEAD -- what the banner actually says."""
    for node in parse(src).body:
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name) and tgt.id == "LEDGER_HEAD":
                    v = node.value
                    if isinstance(v, ast.Constant) and isinstance(v.value, str):
                        return v.value
                    if isinstance(v, ast.BinOp):
                        left = v.left
                        if (isinstance(left, ast.Constant)
                                and isinstance(left.value, str)):
                            return left.value
    return None


def newest_section(changelog_text):
    """The CHANGELOG's newest section -- a plain-text file, so its backslashes
    are LITERAL.  It is the reference the generated banner is measured against."""
    m = re.search(r"(?m)^## \[", changelog_text)
    if not m:
        return ""
    n = re.search(r"(?m)^## \[", changelog_text[m.end():])
    end = (m.end() + n.start()) if n else len(changelog_text)
    return changelog_text[m.start():end]


def ledger_contains(doc, value):
    """Is the builder's evaluated LEDGER_HEAD in the shipped document?

    The builder fills ONE placeholder (`__GAP_NOTE__`) from the round numbers
    it derives, so the two sides differ there by design.  The check is
    therefore: the head of the literal is the head of the document, and the
    tail of the literal is in the document after it.
    """
    if value is None:
        return False, "the builder's LEDGER_HEAD literal is unreadable"
    if GAP_NOTE not in value:
        return doc.startswith(value), "the literal carries no gap placeholder"
    head, tail = value.split(GAP_NOTE, 1)
    if not doc.startswith(head):
        n = min(len(doc), len(head))
        i = 0
        while i < n and doc[i] == head[i]:
            i += 1
        return False, ("the document's head differs at offset %d: %r vs %r"
                       % (i, doc[i:i + 30], head[i:i + 30]))
    if doc.find(tail, len(head)) < 0:
        return False, "the literal's tail is not in the document"
    return True, ""


def run_checks(src, label, count=True):
    """The checks against a builder source.  Returns the failure list.

    `count` says whether these results join the published total; the control
    arm calls this too, and its results are reported but NOT counted.
    """
    fails = []

    def say(good, msg):
        if count:
            (ok if good else bad)(msg)
        else:
            print("  %s %s" % ("ok  " if good else "FAIL", msg))
        if not good:
            fails.append(msg)

    print("\n-- %s --" % label)
    try:
        parse(src)
        say(True, "the builder parses as Python")
    except SyntaxError as ex:
        say(False, "the builder parses as Python (%s)" % ex)
        return fails

    literal_list = literals(src)
    say(True, "the builder's string literals are enumerable (%d literal(s))"
        % len(literal_list))

    fired = [e for e in escapes(src) if e[1]]
    if fired:
        for lineno, _f, span, spelled, firedspan in fired:
            say(False, "no hex escape fires in any string literal -- line %d "
                       "spells %s but evaluates to %s"
                % (lineno, spelled, firedspan))
    else:
        say(True, "no hex escape fires in any string literal")

    val = ledger_value(src)
    doc = io.open(LEDGER, encoding="utf-8").read()
    good, why = ledger_contains(doc, val)
    say(good, "the shipped ENGINEERING.md carries the builder's evaluated "
              "LEDGER_HEAD" + ("" if good else " -- %s" % why))

    return fails


def falsify(src):
    """Re-introduce the historical damage.

    The damage was a DOUBLED backslash that Python ate.  Undoing that -- one
    backslash -- is the mutation, and it must be a REAL change to the file.
    """
    m = re.search(r"\\\\(?:x[0-9A-Fa-f]{2}|u[0-9A-Fa-f]{4})", src)
    if not m:
        return None, "the builder holds no doubled hex escape to undo"
    mutated = src[:m.start()] + m.group(0)[1:] + src[m.end():]
    if mutated == src:
        return None, "the mutation did not change the file"
    return mutated, None


def main(argv):
    src = io.open(BUILDER, encoding="utf-8").read()

    run_checks(src, "the shipped tree")

    a = io.open(README, "rb").read()
    b = io.open(PKG_README, "rb").read()
    if a == b:
        ok("the shipped README.mbt.md and the package copy are byte-identical")
    else:
        bad("the shipped README.mbt.md and the package copy are byte-identical")

    val = ledger_value(src) or ""
    sec = newest_section(io.open(CHANGELOG, encoding="utf-8").read())
    # ONE aggregate check per document, not one per escape: the count a
    # verifier publishes must not move with the number of escapes the builder
    # happens to contain.  The escapes are still listed, so a failure says
    # WHICH one.
    exc = escapes(src)
    bad_chlog = [e for e in exc if e[3] not in sec]
    if not exc:
        ok("the CHANGELOG's newest section spells every code span the way "
           "the source does (there are none)")
    elif bad_chlog:
        bad("the CHANGELOG's newest section spells every code span the way "
            "the source does -- %d of %d differ: %s"
            % (len(bad_chlog), len(exc),
               "; ".join("line %d spells %s" % (e[0], e[3]) for e in bad_chlog)))
    else:
        ok("the CHANGELOG's newest section spells every code span the way "
           "the source does (%d span(s))" % len(exc))

    # An escape that FIRES has a "fired form" -- the character it evaluates
    # to -- and the banner must not carry that.  An escape that does NOT fire
    # (the backslashes are literal) has no fired form to exclude.
    bad_banner = []
    for lineno, fires, _span, spelled, firedspan in exc:
        if spelled not in val:
            bad_banner.append("line %d: the banner does not spell %s"
                              % (lineno, spelled))
        elif fires and firedspan in val:
            bad_banner.append("line %d: the banner spells the fired form %s"
                              % (lineno, firedspan))
    if not exc:
        ok("the banner's evaluated text spells every code span the way the "
           "source does (there are none)")
    elif bad_banner:
        bad("the banner's evaluated text spells every code span the way the "
            "source does -- %s" % "; ".join(bad_banner))
    else:
        ok("the banner's evaluated text spells every code span the way the "
           "source does (%d span(s))" % len(exc))

    # ---- the control arm ------------------------------------------------
    # TWO counted checks, always: the arm must be BUILDABLE, and the mutated
    # builder must be REJECTED.  When the arm cannot be built the second check
    # fails with the reason -- a skipped check is a count that moves, and a
    # count that moves is a count that can be published wrong.
    print("\n-- the control arm --")
    mutated, err = falsify(src)
    if mutated is None:
        bad("the control arm could be built (%s)" % err)
        bad("the mutated builder is REJECTED -- the arm could not be built, so "
            "nothing was tested")
    else:
        ok("the control arm could be built (it mutates the builder, %d -> %d "
           "bytes)" % (len(src), len(mutated)))
        tmp = os.path.join(tempfile.gettempdir(), "_r88_builder_mutated.py")
        try:
            io.open(tmp, "w", encoding="utf-8", newline="").write(mutated)
            mfails = run_checks(mutated, "the MUTATED builder", count=False)
            if mfails:
                ok("the mutated builder is REJECTED (%d check(s) went red)"
                   % len(mfails))
            else:
                bad("the mutated builder is REJECTED -- it passed every check")
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)

    n = len(RESULTS)
    nf = sum(1 for r in RESULTS if not r)
    print("\n" + "=" * 70)
    print("checks run: %d, checks failed: %d" % (n, nf))
    print("VERDICT: %s" % ("PASS" if nf == 0 else "FAIL"))
    return 1 if nf else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
