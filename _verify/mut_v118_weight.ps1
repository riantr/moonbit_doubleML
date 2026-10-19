# v0.118.0 mutation harness for `sample_weight`.
#
# M1  LinearRegression ignores the weights          -> WLS never runs
# M2  the leaf value ignores the weights            -> every tree learner
#                                                      fits an unweighted mean
# M3  the weighted split score falls back to unweighted
# M4  the IRLS working weight ignores sample_weight -> logistic ignores them
# M5  cross_fit_predict does not slice the weights  -> weights fitted against
#                                                      the WRONG observations
# M6  double_cross_fit_predict slices the WRONG index -> inner folds mismatch
# M7  the boosting subsample drops the weight remap -> GB ignores them under
#                                                      subsample < 1
# M8  negative-weight validation removed (trees)     -> a sign-flipped residual
#                                                      is silently accepted
# M9  negative-weight validation removed (logistic)
# M10 the length guard removed in cross_fit_predict -> a short vector is
#                                                      padded or truncated
#
# M2 and M4 are the interesting pair: each kills a whole FAMILY
# (four learners) through one line, and each produces a fit that is still
# finite, still monotone in `k` on a separable fixture, and still
# passes any accuracy assertion. Only the closed-form comparison in
# `v118_weights_move_the_*` catches them.
#
# M5 is the one with no analogue in the earlier rounds. A weight that is
# not sliced fails SILENTLY and in a way that looks plausible: the fit
# still runs, the weights still "reach" it, and only the per-fold values
# are wrong. It is why
# `v118_cross_fit_slices_the_weights_with_the_rows` computes the
# expected per-fold answer by hand instead of only asserting "the
# weighted run differs from the unweighted run".
#
# The three-way verdict (KILLED / SURVIVED / INCONCLUSIVE) and its
# `Active test at executable exit` discriminator are described in the
# v0.117.0 harness, which learned both the hard way. Keep M10 and the
# compile-error branch when editing.

$ErrorActionPreference = 'Continue'
$repo = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$pkg = Join-Path $repo 'moonbit_doubleML'
$targets = @(
  @{ name = 'linear.mbt' },
  @{ name = 'rfl.mbt' },
  @{ name = 'rfclf.mbt' },
  @{ name = 'gbl.mbt' },
  @{ name = 'logistic.mbt' },
  @{ name = 'kfold.mbt' }
)
$backupDir = Join-Path $repo '_verify\_bak_v118'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $repo
if (Test-Path $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
foreach ($t in $targets) {
  Copy-Item -LiteralPath (Join-Path $pkg $t.name) -Destination (Join-Path $backupDir $t.name) -Force
}
Write-Output ('backup written: ' + $backupDir)

$mutations = @(
  @{ file = 'linear.mbt'
     name = 'M1 LinearRegression ignores the weights'
     from  = "    self.fit_weighted(x, y, w)`n  }"
     to    = "    self.fit(x, y)   // MUT-M1`n  }" },

  @{ file = 'rfl.mbt'
     name = 'M2 the leaf value ignores the weights'
     from  = "      let wi = w[row]`n      s = s + wi * y[row]"
     to    = "      let wi = 1.0   // MUT-M2`n      s = s + wi * y[row]" },

  @{ file = 'rfl.mbt'
     name = 'M3 the weighted split score is replaced by the unweighted one'
     from  = "      } else if !clf {`n        // v0.118.0: WEIGHTED variance."
     to    = "      } else if !clf {`n        // MUT-M3`n        let w = []   // MUT-M3" },

  @{ file = 'logistic.mbt'
     name = 'M4 the IRLS working weight ignores sample_weight'
     from  = "        w[i] = if weighted { wi * sample_weight[i] } else { wi }"
     to    = "        w[i] = wi   // MUT-M4" },

  @{ file = 'kfold.mbt'
     name = 'M5 cross_fit_predict does not slice the weights'
     from  = "    let wt = if weighted {`n      slice_vector(sample_weight, fold.train_idx)`n    } else {`n      []`n    }"
     to    = "    let wt = if weighted {`n      sample_weight   // MUT-M5`n    } else {`n      []`n    }" },

  @{ file = 'kfold.mbt'
     name = 'M6 double_cross_fit slices the wrong index'
     from  = "        slice_vector(sample_weight, xt_rows)"
     to    = "        slice_vector(sample_weight, ifold.train_idx)   // MUT-M6" },

  @{ file = 'gbl.mbt'
     name = 'M7 the boosting subsample drops the weight remap'
     from  = "        w_sub[j] = if w_is_unweighted(w) { 0.0 } else { w[sample_idx[j]] }"
     to    = "        w_sub[j] = 0.0   // MUT-M7" },

  @{ file = 'rfclf.mbt'
     name = 'M8 negative-weight validation removed (forest)'
     from  = "    for i = 0; i < w.length(); i = i + 1 {`n      require(w[i] >= 0.0)`n    }"
     to    = "    ignore(w)   // MUT-M8" },

  @{ file = 'logistic.mbt'
     name = 'M9 negative-weight validation removed (logistic)'
     from  = "    for wi in sample_weight {`n      require(wi >= 0.0)`n    }"
     to    = "    ignore(sample_weight)   // MUT-M9" },

  @{ file = 'kfold.mbt'
     name = 'M10 the length guard removed in cross_fit_predict'
     from  = "  if weighted && sample_weight.length() != n_obs {"
     to    = "  if false {   // MUT-M10" }
)

$survivors = @()
$equivalent = @()
$inconclusive = @()

foreach ($m in $mutations) {
  $tpath = Join-Path $pkg $m.file
  Copy-Item -LiteralPath (Join-Path $backupDir $m.file) -Destination $tpath -Force
  $src = [System.IO.File]::ReadAllText($tpath, $enc)
  $count = ([regex]::Matches($src, [regex]::Escape($m.from))).Count
  if ($count -ne 1) {
    Write-Output ("SKIP    " + $m.name + "  -- anchor matched " + $count + " times (need exactly 1)")
    $inconclusive += $m.name
    continue
  }
  $src = $src.Replace($m.from, $m.to)
  [System.IO.File]::WriteAllText($tpath, $src, $enc)

  # Capture through a FILE, not a pipeline.
  #
  # `moon test 2>&1 | Out-String` inside this script produced an EMPTY
  # result for every mutation -- including ones that hand-run perfectly
  # and print `Total tests: 890, passed: 888, failed: 2.` -- so the
  # harness reported 9/10 SURVIVED against mutations that kill two gates
  # each. The failure mode is silent and maximally misleading: the run
  # appears to work, the verdict is invented from nulls, and the
  # investigation lands on the GATES instead of on the capture.
  #
  # Redirecting to a file and reading it back removes the stream
  # translation from the path entirely.
  $log = Join-Path $backupDir 'run.log'
  & moon test --target native *>&1 | Out-File -FilePath $log -Encoding utf8
  $exitCode = $LASTEXITCODE
  $t = if (Test-Path $log) { Get-Content -LiteralPath $log -Raw } else { '' }
  $tLine = ($t -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1
  $activeLine = ($t -split "`r?`n") | Select-String -Pattern 'Active test at executable exit' | Select-Object -First 1

  Write-Output ("MUTATION  " + $m.name)
  Write-Output ("  exit=" + $exitCode + " captured=" + $t.Length + " chars")
  Write-Output ("  tests " + $(if ($tLine) { $tLine.Line.Trim() } else { '*** NO TOTAL ***' }))
  if ($activeLine) {
    Write-Output ("  killed by abort inside: " + (($activeLine.Line -split '-')[-1]).Trim())
  }

  $testsRan = $null -ne $tLine
  $testsRed = $testsRan -and ($tLine.Line -notmatch 'failed: 0')
  $abortedInTest = (-not $testsRan) -and ($null -ne $activeLine)
  $compileErr = ($t -match '\.mbt:\d+:\d+\]') -or ($t -match '╭─\[') -or ($t -match 'Failed with \d+ warnings, \d+ errors')
  if ($compileErr) {
    Write-Output "  VERDICT INCONCLUSIVE  <-- the mutation does not compile"
    ($t -split "`r?`n") | Where-Object { $_ -match '\.mbt:\d+:\d+\]|╭─\[|Error: \[' } | Select-Object -First 6 | ForEach-Object { Write-Output ('    ' + $_.Trim()) }
    $inconclusive += $m.name
  } elseif ($abortedInTest -or $testsRed) {
    Write-Output "  VERDICT KILLED"
  } else {
    # No total line, no compile error, no abort line: the run produced
    # something we cannot classify. Reporting that as SURVIVED would
    # repeat the original bug, so it is inconclusive WITH the tail.
    if (-not $testsRan -and -not $abortedInTest) {
      Write-Output "  VERDICT INCONCLUSIVE  <-- the run produced no verdict line"
      ($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 12 | ForEach-Object { Write-Output ('    ' + $_.Trim()) }
      $inconclusive += $m.name
    } elseif ($m.ContainsKey('equivalent') -and $m.equivalent) {
      Write-Output "  VERDICT SURVIVED (EXPECTED-EQUIVALENT)"
      $equivalent += $m.name
    } else {
      Write-Output "  VERDICT SURVIVED  <-- the gate is decorative"
      $survivors += $m.name
    }
  }
  Write-Output ''
}

foreach ($t in $targets) {
  Copy-Item -LiteralPath (Join-Path $backupDir $t.name) -Destination (Join-Path $pkg $t.name) -Force
  $a = (Get-FileHash -LiteralPath (Join-Path $pkg $t.name) -Algorithm SHA256).Hash
  $b = (Get-FileHash -LiteralPath (Join-Path $backupDir $t.name) -Algorithm SHA256).Hash
  Write-Output ("restore {0} byte-identical: {1}" -f $t.name, ($a -eq $b))
}
$left = Select-String -Path ($targets | ForEach-Object { Join-Path $pkg $_.name }) -Pattern 'MUT-M\d' -ErrorAction SilentlyContinue
Write-Output ("mutation markers left: " + $(if ($left) { $left.Count } else { 0 }))

if ($survivors.Count -gt 0) {
  Write-Output ''
  Write-Output ("RESULT: " + $survivors.Count + " mutation(s) SURVIVED non-equivalently.")
  exit 1
}
if ($equivalent.Count -gt 0) {
  Write-Output ("NOTE: " + $equivalent.Count + " mutation(s) survived as EQUIVALENT.")
}
if ($inconclusive.Count -gt 0) {
  Write-Output ''
  Write-Output ("RESULT: " + $inconclusive.Count + " mutation(s) INCONCLUSIVE.")
  exit 1
}
Write-Output ''
Write-Output 'RESULT: every mutation ran the suite and was killed. The sample_weight gates have teeth.'
exit 0