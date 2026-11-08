"""The tree's "MoonBit has no file I/O" claim must quote THIS compiler.

THE CLAIM
=========
`examples/parity/pyexample_data.mbt` and `pyexample_did.py` both say, in
their own words, that MoonBit has no file I/O, and both SUPPORT that with a
quoted compiler message:

    `@std/env`, `@std/fs`, `@std/io` and `@std/process` all fail to resolve
    (`Cannot find import '@std/env'`)

That quote was TRUE when it was written and it is FALSE now, and the way it
went false is the interesting part.  The compiler did not stop rejecting
those packages; it stopped calling the failure that way.  When the standard
library moved into `moonbitlang/core/*` packages, the `@std` prefix stopped
being a package name at all, and the diagnostic became:

    Error: [4037]
       2 |   let _ = @std.env::get("PATH")
         |           ----+----
         |                +---- Cannot use `@std`: package std is not imported.

and the builtin is still unbound:

    Error: [4021]
         |           ----+----
         |                +---- The value identifier read_file is unbound.

So the SUBSTANCE of the claim still holds -- the four packages do not
resolve, `read_file` does not exist, and the installed core ships no `fs`
and no `io` module -- but the QUOTED TEXT belonged to a compiler that no
longer ships.  A claim that quotes a dead message is a stale claim, and the
house rule about stale content says exactly that.

WHY THIS IS A CHECK AND NOT A NOTE
==================================
The house already had a probe for this claim -- `_verify/_probe_fs_claim_1640.py`
-- but a probe is not a gate: it MEASURES and leaves the verdict to whoever
reads its output, and the tree's own text was never compared with what the
probe found.  So the two could disagree forever, and they did: the probe
found "Error: [4037]" while the tree still quoted a message from a
compiler two channel builds old.

This check closes that gap by comparing the tree's words with the compiler's
output, on the toolchain that is installed NOW.  When the next compiler
changes the diagnostic, this goes RED and the tree's words have to follow --
which is the whole point.

THE PROBE RUNS AS A PACKAGE
===========================
A probe file dropped loose in `_verify/` answers "no work to do" and checks
nothing -- it is not in a package.  So the probes are generated into a
package, in a temp directory OUTSIDE the workspace, with no dependencies at
all: `moon check --target native` then reports the diagnostic under test
instead of a network error.
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(tempfile.gettempdir(), "moonbit_doubleml_fileio_claim")

# The two live claims.  Both are in the tree, both are read by a reader, and
# both quote the compiler.
CLAIMS = [
    os.path.join("examples", "parity", "pyexample_data.mbt"),
    "pyexample_did.py",
]

# The four packages whose absence is the claim, and the builtin that is not
# there either.
PROBES = {
    "probe_env.mbt": 'fn main {\n  let _ = @std.env::get("PATH")\n  println("env")\n}\n',
    "probe_fs.mbt": 'fn main {\n  let _ = @std.fs::read_file("x")\n  println("fs")\n}\n',
    "probe_io.mbt": 'fn main {\n  let _ = @std.io::println("io")\n}\n',
    "probe_process.mbt": 'fn main {\n  let _ = @std.process::get_argv()\n}\n',
    "probe_readfile.mbt": 'fn main {\n  let _ = read_file("x")\n}\n',
}

fails = []
N = 0


def check(label, cond, detail=""):
    global N
    N += 1
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


def read(rel):
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", "replace")


def normalize(text):
    """Whitespace-insensitive, and indifferent to how a comment wraps.

    The quote is wrapped across lines in the tree, and in a `.mbt` comment
    the wrap puts the file's own `//` marker INSIDE the message.  A reader
    sees the message; a naive comparison sees the marker.  So the leading
    comment markers are stripped before the whitespace is collapsed --
    otherwise the rule would be about the WRAPPING rather than about the
    message, and a re-wrap would turn it red for no reason.
    """
    kept = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("//"):
            s = s[2:]
        elif s.startswith("*"):
            s = s[1:]
        kept.append(s)
    return re.sub(r"\s+", " ", " ".join(kept)).strip()


# ---------------------------------------------------------------- the rules --
def quotes_the_message(tree_text, compiler_message):
    """The tree must quote the compiler's message, whitespace-insensitively."""
    if not compiler_message:
        return False
    return normalize(compiler_message) in normalize(tree_text)


def quotes_the_code(tree_text, code):
    """The tree must name the error code the compiler reports."""
    return re.search(r"error\s+%s\b" % code, tree_text) is not None


def retires_the_old_quote(tree_text, retired):
    """The dead message must be gone from the tree."""
    return normalize(retired) not in normalize(tree_text)


# --------------------------------------------------------------- the probes --
def build_package():
    shutil.rmtree(PKG, ignore_errors=True)
    os.makedirs(PKG)
    with io.open(os.path.join(PKG, "moon.mod"), "w", encoding="utf-8",
                 newline="\n") as fh:
        fh.write('name = "t/fileio-claim"\n\nversion = "0.0.1"\n')
    with io.open(os.path.join(PKG, "moon.pkg"), "w", encoding="utf-8",
                 newline="\n") as fh:
        fh.write('pkgtype(kind: "executable")\n\nsupported_targets = "native"\n')


def run_probe(name, body):
    with io.open(os.path.join(PKG, name), "w", encoding="utf-8",
                 newline="\n") as fh:
        fh.write(body)
    shutil.rmtree(os.path.join(PKG, "_build"), ignore_errors=True)
    p = subprocess.run(["moon", "check", "--target", "native"], cwd=PKG,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=900)
    shutil.rmtree(os.path.join(PKG, "_build"), ignore_errors=True)
    os.remove(os.path.join(PKG, name))
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def first_code(output):
    m = re.search(r"Error: \[(\d+)\]", output)
    return m.group(1) if m else ""


def explanation(output, needle):
    """The diagnostic the compiler prints, out of its diagnostic box."""
    for line in output.splitlines():
        s = line.strip()
        if needle in s:
            tail = s.rsplit("╰", 1)[-1]
            tail = tail.lstrip("─━- ").strip()
            return tail
    return ""


ver = subprocess.run(["moon", "version"], cwd=ROOT, capture_output=True,
                     text=True, encoding="utf-8", errors="replace")
mv = re.search(r"moon\s+([0-9.]+)", ver.stdout or "")
TOOLCHAIN = mv.group(1) if mv else ""
print("toolchain: moon %s" % (TOOLCHAIN or "?"))
print()

print("=== the probes, on the toolchain that is installed NOW ===")
build_package()
results = {}
for name in sorted(PROBES):
    rc, out = run_probe(name, PROBES[name])
    code = first_code(out)
    if name == "probe_readfile.mbt":
        msg = explanation(out, "unbound")
    else:
        msg = explanation(out, "not imported")
    results[name] = (rc, code, msg)
    print("  %-22s exit=%-3d code=%-6s %s" % (name, rc, code or "-", msg[:70]))
shutil.rmtree(PKG, ignore_errors=True)

std_codes = set()
std_msgs = set()
for name in PROBES:
    if name == "probe_readfile.mbt":
        continue
    rc, code, msg = results[name]
    std_codes.add(code)
    std_msgs.add(msg)
RF = results["probe_readfile.mbt"]

print()
print("=== the claim's substance, measured ===")
check("every `@std/*` probe fails", all(results[n][0] != 0 for n in PROBES
                                         if n != "probe_readfile.mbt"))
check("all four `@std/*` probes report the SAME error code",
      len(std_codes) == 1 and "" not in std_codes,
      "codes=%s" % sorted(std_codes))
check("the four `@std/*` probes report the SAME diagnostic",
      len(std_msgs) == 1 and "" not in std_msgs,
      "messages=%s" % sorted(std_msgs))
check("the `read_file` probe fails", RF[0] != 0, "exit %d" % RF[0])
check("the `read_file` probe reports error 4021", RF[1] == "4021",
      "code=%s" % RF[1])
check("the `read_file` probe says the identifier is unbound",
      "unbound" in normalize(RF[2]), "message=%r" % RF[2])

STD_CODE = sorted(std_codes)[0] if std_codes and "" not in std_codes else ""
STD_MSG = sorted(std_msgs)[0] if std_msgs and "" not in std_msgs else ""

print()
print("=== the tree's words match the compiler's ===")
for rel in CLAIMS:
    text = read(rel)
    check("%s quotes the compiler's diagnostic" % os.path.basename(rel),
          quotes_the_message(text, STD_MSG),
          "the compiler says %r" % STD_MSG)
    check("%s names the compiler's error code" % os.path.basename(rel),
          quotes_the_code(text, STD_CODE),
          "the compiler says %s" % STD_CODE)
    check("%s names the toolchain it was measured on" % os.path.basename(rel),
          TOOLCHAIN in text, "no %s in the file" % TOOLCHAIN)
    check("%s no longer quotes the retired diagnostic" % os.path.basename(rel),
          retires_the_old_quote(text, "Cannot find import '@std/env'"),
          "the retired message is still there")

print()
print("=== control arms: the rules can bite ===")
# A tree that quotes the OLD message must be REJECTED by the same rule that
# accepts the current one -- otherwise the rule would be satisfied by any
# message at all.
OLD_MSG = "Cannot find import '@std/env'"
OLD_CODE = "9999"
check("C1 a claim quoting the current diagnostic is ACCEPTED",
      quotes_the_message("all fail to resolve (\"%s\")" % STD_MSG, STD_MSG))
check("C1b a claim quoting the RETIRED diagnostic is REJECTED",
      not quotes_the_message("all fail to resolve (`%s`)" % OLD_MSG, STD_MSG))
check("C2 a claim naming the current code is ACCEPTED",
      quotes_the_code("error %s" % STD_CODE, STD_CODE))
check("C2b a claim naming a DIFFERENT code is REJECTED",
      not quotes_the_code("error %s" % OLD_CODE, STD_CODE))
check("C3 a claim carrying the retired message is REJECTED",
      not retires_the_old_quote("`%s`" % OLD_MSG, OLD_MSG))
check("C3b a claim without the retired message is ACCEPTED",
      retires_the_old_quote("\"%s\"" % STD_MSG, OLD_MSG))
# The wrap must not decide the verdict: a `.mbt` comment that breaks the
# message across two lines puts the file's own `//` marker inside it.
check("C4 a claim whose quote is wrapped across two comment lines is ACCEPTED",
      quotes_the_message("// all fail to resolve -- \"Cannot use `@std`:\n"
                         "// package std is not imported.\", error 4037",
                         STD_MSG))
check("C4b the same claim with a DIFFERENT message is REJECTED",
      not quotes_the_message("// all fail to resolve -- \"Cannot use `@std`:\n"
                             "// package std is not imported.\", error 4037",
                             OLD_MSG))

print()
print("=" * 78)
# The summary's SHAPE is part of the contract: `_verify_ledger_counts_1650.py`
# reads a check's count out of one of three shapes, and a shape it cannot read
# is a count it cannot check.  "N checks, M failed" is the first of them.
print("%d checks, %d failed" % (N, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
