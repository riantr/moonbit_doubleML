# v0.120.0 mutation harness -- can the v0.120.0 gates actually fail?
#
# WHAT THIS IS FOR
# Two of the previous three rounds shipped a "green" harness that was
# hollow: v0.117.0 reported 10/10 KILLED twice because the KILLED branch
# fired unconditionally, and v0.118.0 reported 9/10 SURVIVED because the
# capture returned null and the verdicts were computed from nothing. Both
# looked perfect because they reported nothing. Hence the rules below.
#
# RULES
#   1. THREE-WAY VERDICT, never two-way. A mutation that fails to COMPILE
#      is not evidence the gate works. Verdict is one of
#        KILLED        -- the suite ran and at least one test failed
#        SURVIVED      -- the suite ran and everything passed
#        NO-COMPILE    -- build error; the mutation was invalid, not survived
#        INCONCLUSIVE  -- no verdict line at all; treated as a harness bug
#   2. INCONCLUSIVE IS NOT SURVIVED. It must print the log tail so the
#      capture problem is visible instead of silently degrading.
#   3. CANARY FIRST. `enet-objective-reassociate-multiply` is a mutation
#      that CANNOT change any result (0.5*x and x*0.5 are the same
#      float64, 0.5 being a power of two). It is declared EXPECTED
#      SURVIVED. If it ever prints KILLED the verdict logic is broken --
#      every other verdict in the run is then untrustworthy, so the run
#      aborts.
#   4. FILE-BASED CAPTURE. `moon test ... 2>&1 | Out-String` returns EMPTY
#      inside a `powershell -File` script. Everything goes through
#      `*>&1 | Out-File` and is read back with `Get-Content -Raw`.
#   5. RESTORE BY HASH. Each mutated file's SHA256 is recorded before and
#      after the run and verified identical, so a harness bug can never
#      leave a mutant behind.
#   6. HANDS OFF. Do not read, write or run moon against any file this
#      harness is touching until it finishes. That mistake corrupted three
#      runs in earlier rounds.
#
# Usage:  powershell -File _verify/mut_v120_regularized.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$pkg = Join-Path $root 'moonbit_doubleML'
$logDir = Join-Path $PSScriptRoot '_mut_v120'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$mutations = @(
  @{ name = 'enet-objective-reassociate-multiply'
     file = 'regularized.mbt'
     from  = '0.5 * rss / n.to_double() +'
     to    = 'rss * 0.5 / n.to_double() +'
     expect = 'SURVIVED'
     why   = 'CANARY: 0.5*x and x*0.5 are the same float64. If this is KILLED the verdict logic is broken.' }

  @{ name = 'enet-soft-threshold-shrunk-by-0.1pc'
     file = 'regularized.mbt'
     from  = 'if a <= thresh {'
     to    = 'if a <= thresh * 0.999 {'
     expect = 'KILLED'
     why   = 'shrinks the L1 kink, so coefficients that should sit exactly at zero stay tiny-nonzero and the exact support gate must catch it. (The first attempt at this mutation was a <= thresh -> a < thresh, which SURVIVED: a computed |rho| landing EXACTLY on the threshold is a measure-zero event, so it is equivalent in practice and was a bad mutation, not a weak gate.)' }

  @{ name = 'enet-l2-penalty-missing-from-denominator'
     file = 'regularized.mbt'
     from  = 'coef[j] = rho / (norm_sq[j] + l2_reg)'
     to    = 'coef[j] = rho / norm_sq[j]'
     expect = 'KILLED'
     why   = 'pure-L2 coordinate step without the ridge term; breaks l1_ratio = 0 (the pure ridge case).' }

  @{ name = 'enet-drop-the-n-normalisation'
     file = 'regularized.mbt'
     from  = 'let l1_reg = self_alpha * l1_ratio * nf'
     to    = 'let l1_reg = self_alpha * l1_ratio'
     expect = 'KILLED'
     why   = 'removes the factor n that puts alpha on the 1/(2n) scale; the whole Lasso/Ridge alpha asymmetry.' }

  @{ name = 'enet-weights-not-renormalised-to-mean-one'
     file = 'regularized.mbt'
     from  = 'out[i] = w[i] * scale'
     to    = 'out[i] = w[i]'
     expect = 'KILLED'
     why   = 'skips the mean-1 renormalisation, so alpha stops being scale-invariant in sample_weight.' }

  @{ name = 'enet-single-sweep-only'
     file = 'regularized.mbt'
     from  = 'while iter < max_iter {'
     to    = 'while iter < 1 {'
     expect = 'KILLED'
     why   = 'coordinate descent truncated to one sweep: the coefficients are simply not at the optimum.' }

  @{ name = 'enet-objective-change-tolerance-1000x-looser'
     file = 'regularized.mbt'
     from  = 'if delta < tol * yn2 {'
     to    = 'if delta < tol * yn2 * 1000.0 {'
     expect = 'KILLED'
     why   = 'makes the objective-change exit fire ~1000x earlier, so the solver stops short of the optimum. (The first attempt at this slot dropped the ||w||_1 scaling on the sweep tolerance, tol*(1+0.001*sqrt(||w||_1)) -> tol. That SURVIVED, and correctly: the factor is a 0.14% effect on a tolerance already 10 orders below anything that binds, so it is unobservable at tol=1e-10. This mutation targets the stopping rule in a way gates can actually see.)' }

  @{ name = 'enet-objective-drops-the-mean-one-weights'
     file = 'regularized.mbt'
     from  = 'rss = rss + wi * acc * acc'
     to    = 'rss = rss + acc * acc'
     expect = 'KILLED'
     why   = 'the reported objective stops honouring sample_weight, so the gate compares a different objective.' }

  @{ name = 'ridge-drop-the-l2-penalty'
     file = 'regularized.mbt'
     from  = 'g.data[j * p + j] = g.data[j * p + j] + self.alpha'
     to    = 'g.data[j * p + j] = g.data[j * p + j]'
     expect = 'KILLED'
     why   = 'Ridge without any regularisation: degenerates to OLS.' }

  @{ name = 'cache-drop-alpha-from-the-memoize-key'
     file = 'fit_cache.mbt'
     from  = 'Ridge(r) => h = fold_mix_double(h, r.alpha)'
     to    = 'Ridge(r) => h = fold_mix_double(h, 0.0)'
     expect = 'KILLED'
     why   = 'two alphas would share a cache key, so the second estimator reads the first one''s cached nuisance predictions. NOTE: the first attempt wrote the arm as `Ridge(_) => h`, which is a NO-COMPILE (an expression statement in a position whose sibling arms are assignments), not a kill -- which is exactly why NO-COMPILE is a separate verdict.' }

  @{ name = 'cache-drop-l1-ratio-from-the-memoize-key'
     file = 'fit_cache.mbt'
     from  = 'h = fold_mix_double(h, e.l1_ratio)'
     to    = 'h = fold_mix_double(h, 0.0)'
     expect = 'KILLED'
     why   = 'ElasticNet(l1_ratio 0.5) and ElasticNet(l1_ratio 0.9) would share a cache key. NOTE: the first attempt rewrote the match pattern to `ElasticNet(_) => {`, which unbind `e` and does not compile.' }

  @{ name = 'lasso-stop-delegating-to-elastic-net'
     file = 'regularized.mbt'
     from  = 'l1_ratio=1.0,'
     to    = 'l1_ratio=1.0000000001,'
     expect = 'KILLED'
     why   = 'Lasso must BE ElasticNet at l1_ratio exactly 1; a perturbed ratio changes the model and must be caught.' }
)

function Get-Sha([string]$p) { (Get-FileHash -Algorithm SHA256 -Path $p).Hash }

$results = @()
$aborted = $false

# Baseline for the residue check at the end. `git status` is useless here:
# the v0.120.0 work is not committed yet, so every file would show as
# modified regardless. Hashes are the honest baseline.
$baseline = @{}
foreach ($f in @('regularized.mbt', 'fit_cache.mbt', 'expand_v120_test.mbt')) {
  $baseline[$f] = Get-Sha (Join-Path $pkg $f)
}

foreach ($m in $mutations) {
  if ($aborted) { break }
  $target = Join-Path $pkg $m.file
  $before = Get-Sha $target
  $text = [IO.File]::ReadAllText($target)
  $n = ([regex]::Matches($text, [regex]::Escape($m.from))).Count
  if ($n -ne 1) {
    Write-Output ("MARKER-MISS {0}: anchor occurs {1}x (need exactly 1)" -f $m.name, $n)
    $results += [pscustomobject]@{ name = $m.name; expect = $m.expect; verdict = 'INCONCLUSIVE'; note = "anchor x$n" }
    $aborted = $true
    continue
  }
  [IO.File]::WriteAllText($target, $text.Replace($m.from, $m.to), (New-Object System.Text.UTF8Encoding($false)))
  if ((Get-Sha $target) -eq $before) {
    Write-Output ("MARKER-NOOP {0}: mutation produced a byte-identical file" -f $m.name)
    $results += [pscustomobject]@{ name = $m.name; expect = $m.expect; verdict = 'INCONCLUSIVE'; note = 'no-op' }
    [IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
    $aborted = $true
    continue
  }

  $log = Join-Path $logDir ("{0}.log" -f $m.name)
  $out = & moon test --target native *>&1 | Out-File -FilePath $log -Encoding utf8
  $exit = $LASTEXITCODE
  $t = Get-Content -LiteralPath $log -Raw
  if ($null -eq $t) { $t = '' }

  # CAPTURE GROUPS ARE MANDATORY. An earlier version of this line wrote
  # `Total tests: \d+, passed: \d+, failed: \d+\.` with no parentheses, so
  # $summary.Groups[3] was $null, `$null -ne '0'` was always true, and
  # every mutation was reported KILLED. It looked perfect because it
  # reported nothing -- the same failure mode as the v0.117.0 harness.
  # The canary below caught it on the first mutation.
  $summary = [regex]::Match($t, 'Total tests: (\d+), passed: (\d+), failed: (\d+)\.')

  # A PANIC IS A KILL, not an unknown. When a gate aborts, the test
  # runner prints the panic and NEVER prints the summary line, so
  # keying only on the summary reported two mutations that demonstrably
  # killed a gate (measured gaps 0.0338 and 0.512) as INCONCLUSIVE.
  $panicked = ($t -match 'PanicError') -or ($t -match 'gate failed') -or
              ($t -match 'moonbit_panic')

  if ($summary.Success) {
    if ($summary.Groups[3].Value -ne '0') {
      $verdict = 'KILLED'
      $note = $summary.Value
    } else {
      $verdict = 'SURVIVED'
      $note = $summary.Value
    }
  } elseif ($panicked) {
    $verdict = 'KILLED'
    $note = 'aborted/panicked; no summary line (exit=' + $exit + ')'
  } elseif ($t -match 'Error:') {
    $verdict = 'NO-COMPILE'
    $note = 'build error (exit=' + $exit + ')'
  } else {
    $verdict = 'INCONCLUSIVE'
    $note = "no verdict signal at all (exit=$exit, captured=$($t.Length) chars)"
  }

  # restore + verify
  [IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
  $after = Get-Sha $target
  if ($after -ne $before) {
    Write-Output ("RESTORE-FAIL {0}: {1} != {2}" -f $m.name, $after, $before)
    $aborted = $true
  }

  Write-Output ("{0,-46} expect={1,-9} got={2,-13} {3}" -f $m.name, $m.expect, $verdict, $note)
  $results += [pscustomobject]@{ name = $m.name; expect = $m.expect; verdict = $verdict; note = $note }

  if ($m.name -eq 'enet-objective-reassociate-multiply' -and $verdict -eq 'KILLED') {
    Write-Output ''
    Write-Output 'CANARY FAILED: an equivalent mutation was reported KILLED.'
    Write-Output 'The verdict logic is broken; every result in this run is untrustworthy.'
    Write-Output 'Log tail:'
    Get-Content -LiteralPath $log -Tail 25
    $aborted = $true
  }
}

Write-Output ''
Write-Output '==================== SUMMARY ===================='
$killed = @($results | Where-Object { $_.verdict -eq 'KILLED' }).Count
$survived = @($results | Where-Object { $_.verdict -eq 'SURVIVED' }).Count
$incon = @($results | Where-Object { $_.verdict -eq 'INCONCLUSIVE' -or $_.verdict -eq 'NO-COMPILE' }).Count
Write-Output ("KILLED={0}  SURVIVED={1}  INCONCLUSIVE/NO-COMPILE={2}" -f $killed, $survived, $incon)
Write-Output ''
$bad = 0
foreach ($r in $results) {
  $ok = ($r.expect -eq $r.verdict)
  if (-not $ok) {
    $bad = $bad + 1
    Write-Output ("UNEXPECTED {0}: expected {1}, got {2} ({3})" -f $r.name, $r.expect, $r.verdict, $r.note)
    Write-Output ("   why: {0}" -f ($mutations | Where-Object { $_.name -eq $r.name } | Select-Object -First 1).why)
  }
}
if ($bad -eq 0) { Write-Output 'All mutation verdicts matched their declared expectation.' }
Write-Output ''
Write-Output 'Residue check (hash of every mutated file vs the run baseline):'
$residue = 0
foreach ($f in $baseline.Keys) {
  $now = Get-Sha (Join-Path $pkg $f)
  if ($now -ne $baseline[$f]) {
    Write-Output ("  RESIDUE {0}: {1} != {2}" -f $f, $now, $baseline[$f])
    $residue = $residue + 1
  } else {
    Write-Output ("  clean   {0}" -f $f)
  }
}
if ($residue -eq 0) { Write-Output 'No mutant survived.' }