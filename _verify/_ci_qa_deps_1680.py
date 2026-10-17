import io

PATH = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\.github\workflows\check.yml"

# Anchor: the qa-loop job's typos install block, which is the last step before
# "Update dependencies". Insert the Python-dependency install between typos and
# the MoonBit dependency update, mirroring python-cross-check's step.
ANCHOR = """      - name: Update dependencies
        run: |
          moon version --all
          moon update

      # The harness must be able to fail before its verdict is worth anything,
      # so the self-test gates this job too.
"""

STEP = """      # The nine `pyexample_*` checks in the fast scope are PORT-vs-UPSTREAM
      # gates: they import numpy, pandas, scikit-learn and doubleml from the
      # emitted rows. This job had no dependency install, so every one of them
      # died in 0.03s with `ModuleNotFoundError: No module named 'numpy'`.
      #
      # It went unseen because these checks are NEW: at 465431c -- the last CI
      # run on this repo that was green -- checks.py had ZERO `c_pyexample*`
      # functions. They arrived in d3ac364 ("gate DoubleMLLPLR on shared rows
      # and a pinned partition"), so the run that reported this failure was the
      # first CI execution these gates ever had. Locally they always passed,
      # because a developer machine already has numpy; the job that runs them
      # on CI did not.
      #
      # Same install line as `python-cross-check`, so the two jobs cannot drift
      # into disagreeing about what the port is compared against.
      - name: Install Python dependencies
        run: |
          python -m pip install --upgrade pip
          pip install doubleml numpy pandas statsmodels scikit-learn "rdrobust>=2,<3"

"""


def main():
    with io.open(PATH, encoding="utf-8", newline="") as f:
        src = f.read()
    if "\r" in src:
        raise SystemExit("check.yml is not LF-only")
    if "Install Python dependencies" in src:
        n = src.count("      - name: Install Python dependencies")
        print("install steps already present:", n)
        if n >= 2:
            print("nothing to do")
            return
    if src.count(ANCHOR) != 1:
        raise SystemExit("anchor matched %d times" % src.count(ANCHOR))
    out = src.replace(ANCHOR, STEP + ANCHOR.split("# The harness")[0]
                      + "# The harness" + ANCHOR.split("# The harness")[1])
    with io.open(PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    with io.open(PATH, encoding="utf-8", newline="") as f:
        chk = f.read()
    print("install steps now:", chk.count("- name: Install Python dependencies"))
    print("qa-loop has it   :",
          "Install Python dependencies" in chk[chk.find("  qa-loop:"):
                                               chk.find("  qa-loop:") + 2600])
    print("BOM:", chk.startswith("\ufeff"), "| CR:", "\r" in chk)


if __name__ == "__main__":
    main()
