#!/usr/bin/env python3
"""Round 14: generate the re-audit cases for the upstream proof restrictions.

Each case is a self-contained MoonBit package (its own moon.mod + moon.pkg
with "proof-enabled": true) so that `moon prove` can reach it in today's
layout -- the v0.52.0 records cite `moon prove _prove_pilot`, which now
hard-errors with "not inside any known module".

The cases mirror the exact constructs the records name, one restriction at a
time, plus TWO control cases:

  b0_control        no restricted construct at all
  b1c_fixed_control FixedArray + C-style range -- the shape the `_prove_pilot`
                    package actually uses, so the record's claim that the
                    FixedArray workaround "works" is testable

The controls are the subjects that prove the harness discriminates: without
them, "every case failed" would be an indistinguishable answer.

Two defects in this harness were caught by the controls during development
and are worth recording, because they are the same shape as the defects
being audited in the records:
  * a header line emitted without its `//` prefix -> the case fails to
    PARSE, which is not a proof failure;
  * a case that called `require` -> unbound outside the main package, so it
    tested the wrong thing entirely.

Both are "the artefact does not contain the construct the record names".
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
BASE = os.path.join(ROOT, "_verify", "upstream_prove_1649", "cases")

PKG = 'options(\n  "proof-enabled": true,\n)\n'


def _case(*lines):
    """A case header: EVERY non-blank line must be a MoonBit `//` comment."""
    out = []
    for ln in lines:
        if ln.strip() and not ln.startswith("//"):
            ln = "// " + ln
        out.append(ln)
    return "\n".join(out) + "\n"


CASES = {}

CASES["b0_control"] = (
    _case(
        "CONTROL -- no restricted construct at all.",
        "",
        "If this case does not reach the Why3 stage with zero frontend",
        "errors, the harness cannot discriminate a proof failure from a",
        "platform failure, and every other case is void.",
    ),
    """///|
pub fn sum_to(n : Int) -> Int where {
  proof_require: n > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for i = 0; i < n; i = i + 1 {
    total = total + i
  }
  total
}
""")

CASES["b1_array_param"] = (
    _case(
        "Blocker 1 -- Array[T] in a CONTRACTED FUNCTION PARAMETER.",
        "",
        "Mirrors the shape named in UPSTREAM_ISSUE_01_array_lowering.md",
        "(`pub fn array_min(arr : Array[Double]) -> Double raise ...`) but",
        "with Int elements and an Int contract, so the only construct under",
        "test is the Array[T] lowering: no Double comparison, no raise,",
        "no foreach, no helper call.",
    ),
    """///|
pub fn array_sum(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result >= 0,
} {
  let mut total = 0
  for i = 0; i < arr.length(); i = i + 1 {
    total = total + arr[i]
  }
  total
}
""")

CASES["b1_array_field"] = (
    _case(
        "Blocker 1 -- Array[T] in a STRUCT FIELD.",
        "",
        "The other half of Blocker 1: the record says the lowering gap is",
        "'not struct-field-specific', so the field shape is tested",
        "separately from the parameter shape above.",
    ),
    """///|
pub struct Holder {
  data : Array[Int]
}

///|
pub fn holder_sum(h : Holder) -> Int where {
  proof_require: h.data.length() > 0,
  proof_ensure: result => result >= 0,
} {
  let mut total = 0
  for i = 0; i < h.data.length(); i = i + 1 {
    total = total + h.data[i]
  }
  total
}
""")

CASES["b1c_fixed_control"] = (
    _case(
        "CONTROL for Blocker 1 -- FixedArray + C-style range.",
        "",
        "This is the shape the `_prove_pilot` package actually uses, and the",
        "shape the record says the workaround 'works'.  It differs from",
        "b1_array_param in exactly two ways: FixedArray instead of Array,",
        "and the C-style range.  If this case reaches the Why3 stage with",
        "zero frontend errors, then the Array[T] cases fail because of",
        "Array[T] and not because of the harness.",
    ),
    """///|
pub fn sum_fixed(arr : FixedArray[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result >= 0,
} {
  let mut total = 0
  for i = 0; i < arr.length(); i = i + 1 {
    total = total + arr[i]
  }
  total
}
""")

CASES["b2_double_cmp"] = (
    _case(
        "Blocker 2 / audit finding 2a -- Double literal and comparison.",
        "",
        "Verbatim from _verify/audit-bucket2-double/double_cmp.mbt, the file",
        "the records cite.  Tests BOTH restrictions at once: the `<` operator",
        "on a Double, and the `1.5` Double literal (finding A2, a distinct",
        "error class the original 4-blocker summary did not name).",
    ),
    """///|
pub fn double_cmp(x : Double, n : Int) -> Bool where {
  proof_require: x < 1.5,
  proof_require: n > 0,
  proof_ensure: result => result == (x < 1.5),
} {
  x < 1.5
}
""")

CASES["b3_raise_body"] = (
    _case(
        "Blocker 3 -- `raise X` in a contracted function body.",
        "",
        "Verbatim from _verify/test-bucket3-raise/raise_test.mbt -- NOT from",
        "_verify/audit_bucket3_raise/raise_test.mbt, which the records cite",
        "but which holds the Bucket 2 Double source (see the record's note).",
        "",
        "Audit finding A3 says this shape makes `moonc prove` exit with the",
        "help-text error rather than a clean diagnostic.",
    ),
    """///|
pub suberror SomeError

///|
pub fn foo(x : Int) -> Int raise SomeError where {
  proof_require: x > 0,
} {
  if x <= 0 {
    raise SomeError
  }
  x
}
""")

CASES["b4_foreach"] = (
    _case(
        "Blocker 4 -- `for x in arr` in a contracted body.",
        "",
        "Verbatim from _verify/audit_bucket4_foreach/foreach_test.mbt.  Audit",
        "finding A4 says this also exits with the help-text error.",
    ),
    """///|
pub fn sum_array(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for x in arr {
    total = total + x
  }
  total
}
""")

CASES["b4c_style_control"] = (
    _case(
        "CONTROL for Blocker 4 -- the C-style rewrite, over the SAME Array.",
        "",
        "The record claims the C-style rewrite 'compiles and proves (no",
        "errors) under `moon prove`'.  Over Array[Int] it does NOT: the",
        "C-style form still carries Blocker 1.  Keeping Array fixed and",
        "changing only the loop form is what isolates the foreach.",
    ),
    """///|
pub fn sum_array_c(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for i = 0; i < arr.length(); i = i + 1 {
    total = total + arr[i]
  }
  total
}
""")

CASES["b4r_range_foreach"] = (
    _case(
        "Blocker 4 -- `for x in 0..<n`, the single-binder Int range form.",
        "",
        "The record says the same help-text error fires for this form too,",
        "not just for `for x in arr`.  Tested separately, because the two",
        "forms are different restrictions in the proof frontend.",
    ),
    """///|
pub fn sum_range(n : Int) -> Int where {
  proof_require: n > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for x in 0..<n {
    total = total + x
  }
  total
}
""")

CASES["blkA_call_whitelist"] = (
    _case(
        "New Block A -- the proof-callable whitelist.",
        "",
        "A call to a function that is not #proof_pure / #proof_callable",
        "inside a contracted body.  The record lists the calls it blocks:",
        "seed_to_bytes, @random.Rand::chacha8, Bytes::from_array,",
        "Array::make, Array::makei, perm.swap, rng.int, the .push methods",
        "and Fold::new.  `helper` below is the minimal user-code instance of",
        "the same shape.",
    ),
    """///|
pub fn helper(x : Int) -> Int {
  x + 1
}

///|
pub fn uses_helper(x : Int) -> Int where {
  proof_require: x > 0,
  proof_ensure: result => result > 1,
} {
  helper(x)
}
""")

CASES["blkB_block_expr"] = (
    _case(
        "New Block B -- block and literal expressions in a contracted body.",
        "",
        "The v0.48.0 cascade wrap, copied from the production shape in",
        "moonbit_doubleML/plr.mbt: `try { require(...) } catch { ... abort(...) }`",
        "is the FIRST statement of every DML estimator body, so this shape is",
        "the one that blocks the whole main package.",
        "",
        "The `require` call is replaced by an inline raise: `require` lives",
        "in the main package and is unbound in a standalone case, so the",
        "first version of this case measured the wrong thing entirely.",
    ),
    """///|
pub suberror PreconditionError {
  Violated(String)
}

///|
pub fn with_try(x : Int) -> Int where {
  proof_require: x > 0,
  proof_ensure: result => result == x,
} {
  try {
    if x <= 0 {
      raise PreconditionError::Violated("x")
    }
    x
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc)
  }
}
""")


def main() -> None:
    for name, (header, body) in sorted(CASES.items()):
        d = os.path.join(BASE, name)
        os.makedirs(d, exist_ok=True)
        header = _case(*header.rstrip("\n").split("\n"))
        with open(os.path.join(d, "case.mbt"), "w", encoding="utf-8",
                  newline="\n") as f:
            f.write(header + "\n" + body)
        with open(os.path.join(d, "moon.mod"), "w", encoding="utf-8",
                  newline="\n") as f:
            f.write('name = "local/reaudit_%s"\n\nversion = "0.1.0"\n' % name)
        with open(os.path.join(d, "moon.pkg"), "w", encoding="utf-8",
                  newline="\n") as f:
            f.write(PKG)
        print("wrote", name)
    print("\n%d cases under %s" % (len(CASES), BASE))


if __name__ == "__main__":
    main()
