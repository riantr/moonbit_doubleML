# v0.117.0 mutation harness for the nonlinear classifiers.
#
# M1  RF classifier splits on MSE instead of Gini    -> the `clf` flag
#                                                    reaching `cart_fit`
# M2  Newton leaf replaced by the node mean          -> the `hess` argument
#                                                    reaching `cart_leaf_value`
# M3  GB initial is the base rate, not the log-odds  -> GBLearner's F_0
#                                                    copied over
# M4  negative gradient sign flipped                 -> `p - y` instead of
#                                                    `y - p`
# M5  GB hessian forced to a constant 1.0           -> Newton step collapses
#                                                    to the mean
# M6  GB predict returns the margin, not sigmoid     -> "probabilities" can
#                                                    leave [0, 1]
# M7  RF predict uses one tree instead of the forest -> the bagging is gone
# M8  classifier cache tag collides with the regressor -> a memoize hit can
#                                                    return a regression fit
# M9  the pure-node guard is removed                 -> classification splits
#                                                    pure nodes forever
# M10 unfitted GB falls back to zeros, not base rate -> the documented
#                                                    fallback changes
#
# M1 IS EXPECTED TO SURVIVE, and that is a proof rather than an excuse.
# An earlier draft of this harness had a gate that claimed exactness
# would distinguish Gini from MSE on a binary fixture. It does not, and
# the reason is an identity: for a node of binary labels with
# proportion p,
#
#     sum (y_i - p)^2 = n*p*(1-p) = (n/2) * [2p(1-p)]
#                        MSE                Gini
#
# so the weighted MSE score is exactly HALF the weighted Gini score at
# every candidate split. Same argmin, same strict-`<` tie-break, same
# `mean(y)` leaf. Checked numerically in `_verify/_m1_gini_vs_mse.py`:
# `2*MSE` matches Gini to 3.9e-16 over 3000 random binary nodes, the
# argmin agrees 2999/3000 (the miss is a float tie), and on
# MULTI-CLASS labels -- where the identity breaks -- they differ 32/3000.
#
# Since BOTH classifiers refuse a non-binary `y`, the equivalence covers
# this API's entire surface: there is no input on which the choice is
# observable. The claim was corrected in
# `expand_v117_test.mbt::v117_rf_classifier_separates_a_single_threshold_exactly`
# rather than the gate being bent to match it.
#
# M4 and M5 are the pair worth reading together. They are the two halves
# of the Newton step, and either one alone is a plausible-looking
# implementation: a sign error still produces a monotone classifier that
# gets XOR right (just with flipped probabilities), and a constant
# hessian produces correct-SHAPED probabilities that are badly
# calibrated. Neither is caught by an accuracy assertion -- both need
# the calibration gates (`v117_gb_probabilities_are_smooth_not_saturated`,
# `v117_gb_initial_is_the_log_odds_not_the_base_rate`) to fail.
#
# M8 is the one that would have been invisible to every other gate in
# this file. It does not change a single learner: it makes a
# classification fit read a cached REGRESSION fit, so every number stays
# finite and plausible. The gate it dies on
# (`v117_classifier_cache_keys_differ_from_regression_siblings`) asserts
# on `hash_hyperparams` precisely because that is the observable
# contract.
#
# Deliberately NOT --deny-warn: that flag is a CI policy, and using it
# here turns "unused parameter" into a build refusal so the suite never
# runs and the mutation is misreported INCONCLUSIVE. The question here
# is "do the ASSERTIONS catch it".
#
# A run with no `Total tests:` line is NOT automatically inconclusive.
# MoonBit's driver ABORTS on the first red assertion, so a gate that
# fires takes the whole run down and never prints the summary line --
# indistinguishable, from the summary alone, from a compile refusal. The
# discriminator is `Active test at executable exit`. Getting this wrong
# misreported two v0.116.0 mutations that had in fact already killed
# their gate. The compile-error check further down splits the remaining
# case, so the three verdicts -- killed / survived / does-not-compile --
# are never conflated.

$ErrorActionPreference = 'Continue'
$repo = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$pkg = Join-Path $repo 'moonbit_doubleML'
$targets = @(
  @{ name = 'rfclf.mbt'; path = (Join-Path $pkg 'rfclf.mbt') },
  @{ name = 'gbclf.mbt'; path = (Join-Path $pkg 'gbclf.mbt') },
  @{ name = 'rfl.mbt'; path = (Join-Path $pkg 'rfl.mbt') },
  @{ name = 'fit_cache.mbt'; path = (Join-Path $pkg 'fit_cache.mbt') }
)
$backupDir = Join-Path $repo '_verify\_bak_v117'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $repo
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
foreach ($t in $targets) {
  Copy-Item -LiteralPath $t.path -Destination (Join-Path $backupDir $t.name) -Force
}
Write-Output ('backup written: ' + $backupDir)

$mutations = @(
  @{ file = 'rfclf.mbt'
     name = 'M1 RF classifier splits on MSE instead of Gini (expected-equivalent)'
     from  = "        feature_rng,`n        true,`n        [],"
     to    = "        feature_rng,`n        false,   // MUT-M1`n        [],"
     equivalent = $true },

  @{ file = 'rfl.mbt'
     name = 'M2 Newton leaf replaced by the node mean'
     from  = "  if hess.length() == 0 {`n    return s / n.to_double()`n  }"
     to    = "  if true {   // MUT-M2`n    return s / n.to_double()`n  }" },

  @{ file = 'gbclf.mbt'
     name = 'M3 GB initial is the base rate, not the log-odds'
     from  = 'let initial = @math.ln(base_rate / (1.0 - base_rate))'
     to    = 'let initial = base_rate   // MUT-M3' },

  @{ file = 'gbclf.mbt'
     name = 'M4 negative gradient sign flipped'
     from  = 'neg_grad[i] = y[i] - p'
     to    = 'neg_grad[i] = p - y[i]   // MUT-M4' },

  @{ file = 'gbclf.mbt'
     name = 'M5 GB hessian forced to a constant 1.0'
     from  = 'hess[i] = p * (1.0 - p)'
     to    = 'hess[i] = 1.0   // MUT-M5' },

  @{ file = 'gbclf.mbt'
     name = 'M6 GB predict returns the margin, not sigmoid'
     from  = '    out[i] = sigmoid(f)'
     to    = '    out[i] = f   // MUT-M6' },

  @{ file = 'rfclf.mbt'
     name = 'M7 RF predict uses one tree instead of the forest'
     from  = '    let mut s = 0.0
    for t = 0; t < n_trees; t = t + 1 {
      s = s + cart_predict(self.trees[t], x, i)
    }
    out[i] = s / n_trees.to_double()'
     to    = '    out[i] = cart_predict(self.trees[0], x, i)   // MUT-M7' },

  @{ file = 'fit_cache.mbt'
     name = 'M8 classifier cache tag collides with the regressor'
     from  = 'RandomForestClassifier(_) => "random_forest_classifier"'
     to    = 'RandomForestClassifier(_) => "random_forest"   // MUT-M8' },

  @{ file = 'rfl.mbt'
     name = 'M9 the pure-node guard is removed'
     from  = '    if pure {
      return CART::Leaf(cart_leaf_value(y, sample_idx, hess))
    }'
     to    = '    if pure {
      ignore(0)   // MUT-M9
    }' },

  @{ file = 'gbclf.mbt'
     name = 'M10 unfitted GB falls back to zeros, not the base rate'
     from  = '    for i = 0; i < n; i = i + 1 {
      out[i] = sigmoid(self.initial)
    }'
     to    = '    ignore(sigmoid(self.initial))   // MUT-M10' }
)

$survivors = @()
$equivalent = @()
$inconclusive = @()

foreach ($m in $mutations) {
  $tpath = $targets | Where-Object { $_.name -eq $m.file }
  Copy-Item -LiteralPath (Join-Path $backupDir $m.file) -Destination $tpath.path -Force
  $src = [System.IO.File]::ReadAllText($tpath.path, $enc)
  $count = ([regex]::Matches($src, [regex]::Escape($m.from))).Count
  if ($count -ne 1) {
    Write-Output ("SKIP    " + $m.name + "  -- anchor matched " + $count + " times (need exactly 1)")
    $inconclusive += $m.name
    continue
  }
  $src = $src.Replace($m.from, $m.to)
  [System.IO.File]::WriteAllText($tpath.path, $src, $enc)

  $t = moon test --target native 2>&1 | Out-String
  $tLine = ($t -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1
  $activeLine = ($t -split "`r?`n") | Select-String -Pattern 'Active test at executable exit' | Select-Object -First 1

  Write-Output ("MUTATION  " + $m.name)
  Write-Output ("  tests " + $(if ($tLine) { $tLine.Line.Trim() } else { '*** NO TOTAL ***' }))
  if ($activeLine) {
    Write-Output ("  killed by abort inside: " + (($activeLine.Line -split '-')[-1]).Trim())
  }

  $testsRan = $null -ne $tLine
  $testsRed = $testsRan -and ($tLine.Line -notmatch 'failed: 0')
  # The suite aborted inside a test and never printed the summary.
  $abortedInTest = (-not $testsRan) -and ($null -ne $activeLine)
  # THREE outcomes, not two. A mutation that does not COMPILE is
  # genuinely inconclusive -- the question "do the assertions catch it"
  # was never asked. A mutation that COMPILES and then makes the test
  # binary die (a segfault, a stack overflow, an abort before any test
  # prints) IS a kill: the suite did not pass.
  #
  # This distinction was learned the hard way. M4 was first written as
  # `neg_grad[i] = p - y`, which does not compile -- `p` is a Double and
  # `y` is an Array[Double] -- and the harness reported INCONCLUSIVE.
  # That verdict was CORRECT; the MUTATION was malformed, and the fix
  # was `p - y[i]`. Reading "INCONCLUSIVE" as "the gate missed it"
  # would have been wrong in the other direction too.
  $compileErr = ($t -match '\.mbt:\d+:\d+\]') -or ($t -match '╭─\[') -or ($t -match 'Failed with \d+ warnings, \d+ errors')
  if ($compileErr) {
    Write-Output "  VERDICT INCONCLUSIVE  <-- the mutation does not compile"
    ($t -split "`r?`n") | Where-Object { $_ -match '\.mbt:\d+:\d+\]|╭─\[|Error: \[' } | Select-Object -First 6 | ForEach-Object { Write-Output ('    ' + $_.Trim()) }
    $inconclusive += $m.name
  } elseif ($abortedInTest -or $testsRed) {
    Write-Output "  VERDICT KILLED"
  } else {
    if ($m.ContainsKey('equivalent') -and $m.equivalent) {
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
  Copy-Item -LiteralPath (Join-Path $backupDir $t.name) -Destination $t.path -Force
  $a = (Get-FileHash -LiteralPath $t.path -Algorithm SHA256).Hash
  $b = (Get-FileHash -LiteralPath (Join-Path $backupDir $t.name) -Algorithm SHA256).Hash
  Write-Output ("restore {0} byte-identical: {1}" -f $t.name, ($a -eq $b))
}
$left = Select-String -Path ($targets | ForEach-Object { $_.path }) -Pattern 'MUT-M\d' -ErrorAction SilentlyContinue
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
Write-Output 'RESULT: every mutation ran the suite and was killed. The classifier gates have teeth.'
exit 0