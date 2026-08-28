#!/usr/bin/env python3
"""White-box mutation testing orchestrator for dml-moonbit.

For each mutation:
  1. Backup the prod file -> _verify/mut-bak-<file>
  2. Apply mutation (string-replace, deterministic)
  3. Run `moon test --target native -p <pkg> -f <test_filter>` and
     record exit code
  4. Restore from backup
  5. Print PASS / FAIL / SURVIVED summary

Mutation is "caught" if test exit code != 0 (test failed -> tests would
catch the regression). "Survived" means test still passed -> coverage gap.
"""
import os, re, subprocess, sys, shutil, json, time
from pathlib import Path

REPO = Path(r"D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit")
VERIFY = REPO / "_verify"

# Mutation definitions:
#   file: relative to REPO
#   search: exact source line (no trailing whitespace, no line-number prefix)
#   replace: replacement source
#   description: human-readable
#   test_filter: substring matched against moon test names (-f flag)
#   expect_killed: True if we EXPECT a test to fail (most are killed)
MUTATIONS = [
    # ----- var_est_cluster (plpr.mbt, lines 225-289) -----
    {
        "id": "M01-vec-drop-w-in-gamma",
        "file": "plpr.mbt",
        "search": "        gamma = gamma + w * s * s",
        "replace": "        gamma = gamma + s * s",
        "description": "drop per-fold weight w in gamma accumulator",
        "test_filter": "plpr_*",
        "expect_killed": True,
    },
    {
        "id": "M02-vec-drop-w-in-jhat",
        "file": "plpr.mbt",
        "search": "        j_hat = j_hat + w * sd",
        "replace": "        j_hat = j_hat + sd",
        "description": "drop per-fold weight w in j_hat accumulator",
        "test_filter": "plpr_*",
        "expect_killed": True,
    },
    {
        "id": "M03-vec-j-floor-relaxed",
        "file": "plpr.mbt",
        "search": "  if j.abs() < 1.0e-6 {",
        "replace": "  if j.abs() < 1.0e-2 {",
        "description": "relax |J|<1e-6 abort floor to 1e-2 (catches fewer pathological splits)",
        "test_filter": "*var_est_cluster*",
        "expect_killed": False,  # framework limitation: panic_ tests skip on native
    },
    {
        "id": "M04-vec-j-floor-removed",
        "file": "plpr.mbt",
        "search": "  if j.abs() < 1.0e-6 {",
        "replace": "  if false {",
        "description": "remove J-floor abort entirely",
        "test_filter": "*var_est_cluster*",
        "expect_killed": True,  # v0.35.0: catchable via plpr_var_est_cluster_raises_j_too_small_on_zero_j
    },
    {
        "id": "M05-vec-drop-one-j",
        "file": "plpr.mbt",
        "search": "  (g / (n_units.to_double() * j * j)).sqrt()",
        "replace": "  (g / (n_units.to_double() * j)).sqrt()",
        "description": "divide by j once instead of j*j (off-by-one in exponent)",
        "test_filter": "plpr_*",
        "expect_killed": True,
    },
    {
        "id": "M06-vec-npc-ignored",
        "file": "plpr.mbt",
        "search": "  let npc = n_folds_per_cluster.to_double()",
        "replace": "  let npc = 1.0",
        "description": "ignore n_folds_per_cluster (npc=1 collapses CRSE to biased estimator)",
        "test_filter": "plpr_*",
        "expect_killed": True,
    },
    # ----- est_coef_cluster (plpr.mbt, lines 185-208) -----
    {
        "id": "M07-ecc-drop-w",
        "file": "plpr.mbt",
        "search": "    let w = 1.0 / fold_n_units[f].to_double()",
        "replace": "    let w = 1.0",
        "description": "drop per-fold weight in est_coef_cluster (w=1)",
        "test_filter": "plpr_*",
        "expect_killed": True,
    },
    {
        "id": "M08-ecc-sign-flip",
        "file": "plpr.mbt",
        "search": "  -sb / sa",
        "replace": "  sb / sa",
        "description": "sign flip in cluster coef (-sb -> sb)",
        "test_filter": "plpr_*",
        "expect_killed": True,
    },
]

def run(cmd, timeout=180):
    proc = subprocess.run(
        cmd, cwd=REPO, capture_output=True, timeout=timeout,
        shell=False,
    )
    out = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
    err = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""
    return proc.returncode, out, err

def run_ps(cmd_str, timeout=180):
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd_str],
        cwd=REPO, capture_output=True, text=True, timeout=timeout,
    )
    return proc.returncode, proc.stdout, proc.stderr

def apply_mutation(m):
    fp = REPO / m["file"]
    bak = VERIFY / f"mut-bak-{m['file']}"
    if bak.exists():
        print(f"[SKIP] backup already exists for {m['file']}; leftover?")
        return False
    shutil.copy2(fp, bak)
    src = fp.read_text(encoding="utf-8")
    if m["search"] not in src:
        bak.unlink()
        print(f"[FAIL] search string not found in {m['file']}:")
        print(f"       {m['search']!r}")
        return False
    new = src.replace(m["search"], m["replace"], 1)
    if new == src:
        bak.unlink()
        print(f"[FAIL] replace did not change {m['file']}")
        return False
    fp.write_text(new, encoding="utf-8")
    return True

def revert_mutation(m):
    fp = REPO / m["file"]
    bak = VERIFY / f"mut-bak-{m['file']}"
    if bak.exists():
        shutil.move(str(bak), str(fp))
    else:
        print(f"[WARN] no backup found for {m['file']}")

def main():
    # Confirm baseline
    print("=" * 70)
    print("Baseline test run (no mutation)")
    print("=" * 70)
    rc, out, err = run(["moon", "test", "--target", "native", "--deny-warn"])
    baseline_pass = (rc == 0)
    print(f"Baseline: {'PASS' if baseline_pass else 'FAIL'} (rc={rc})")
    if not baseline_pass:
        print("Baseline failed; aborting mutation sweep")
        print("--- stderr ---")
        print(err[-2000:])
        return 1

    # Run mutation sweep
    results = []
    for m in MUTATIONS:
        print()
        print("=" * 70)
        print(f"Mutation {m['id']}: {m['description']}")
        print(f"  file: {m['file']}")
        print(f"  test filter: {m['test_filter']}")
        print("=" * 70)
        if not apply_mutation(m):
            results.append({**m, "outcome": "SETUP-FAIL", "note": "search/replace failed"})
            continue
        try:
            # Run test (use direct subprocess, NOT powershell pipe — pipe eats moon's exit code)
            cmd = ["moon", "test", "--target", "native", "--deny-warn", "-f", m["test_filter"]]
            rc, out, err = run(cmd, timeout=300)
            killed = (rc != 0)
            outcome = "KILLED" if killed else "SURVIVED"
            # Capture last 12 lines of test output for the report
            out_tail = ((out or "") + "\n" + (err or "")).splitlines()[-12:]
            out_tail_text = "\n      ".join(out_tail)
            print(f"  -> {outcome} (rc={rc})")
            print(f"  expected: {'killed' if m['expect_killed'] else 'survived'}")
            if killed and not m["expect_killed"]:
                print(f"  --- test output tail ---")
                print(f"      {out_tail_text}")
            results.append({**m, "outcome": outcome, "rc": rc, "out_tail": out_tail})
        finally:
            revert_mutation(m)
            # Sanity check: file must be byte-equal to its git HEAD state
            git_diff = subprocess.run(
                ["git", "diff", "--stat", "--", m["file"]], cwd=REPO,
                capture_output=True, text=True, shell=False,
            ).stdout.strip()
            if git_diff:
                print(f"  [WARN] {m['file']} differs from HEAD after revert: {git_diff}")
            time.sleep(0.3)

    # Final restore sanity
    for m in MUTATIONS:
        bak = VERIFY / f"mut-bak-{m['file']}"
        if bak.exists():
            print(f"[WARN] leftover backup {bak}, restoring")
            shutil.move(str(bak), str(REPO / m["file"]))

    print()
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)
    killed = [r for r in results if r["outcome"] == "KILLED"]
    survived = [r for r in results if r["outcome"] == "SURVIVED"]
    print(f"Total: {len(results)}, Killed: {len(killed)}, Survived: {len(survived)}")
    print()
    if survived:
        print("SURVIVING MUTATIONS (coverage gaps):")
        for r in survived:
            verdict = "expected" if not r["expect_killed"] else "UNEXPECTED"
            print(f"  [{verdict}] {r['id']}: {r['description']}")
    if killed:
        unexpected_killed = [r for r in killed if not r["expect_killed"]]
        if unexpected_killed:
            print()
            print("UNEXPECTED KILLED (tests fail on legit behavior change — review):")
            for r in unexpected_killed:
                print(f"  {r['id']}: {r['description']}")
    out_json = VERIFY / "whitebox_mut_results.json"
    out_json.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\nResults written: {out_json}")
    return 0

if __name__ == "__main__":
    sys.exit(main())