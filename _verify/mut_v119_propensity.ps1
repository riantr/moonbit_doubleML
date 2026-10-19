# v0.119.0 mutation harness for the propensity subsystem on APO/APOS.
#
# M1  the control denominator uses `p` instead of `1 - p`   -> THE BUG THIS
#                                                          ROUND ACTUALLY
#                                                          SHIPPED AND FIXED
# M2  `propensity_score_adjustment` ignores the flag        -> `normalize_ipw`
#                                                          is a no-op option
# M3  `mean_treat0` computed from the treated group         -> groups swapped
# M4  the leaf `w1` term drops the `p` factor               -> a plausible-looking
#                                                          non-IPW weight
# M5  the 1e-12 denominator clamp removed                  -> back to upstream's
#                                                          unguarded divide
# M6  `trim_predictions` always truncates                  -> the identity branch
#                                                          is unreachable
# M7  APO normalises BEFORE the cross-fit clip              -> normalisation sees
#                                                          unclipped propensities
# M8  APO's `normalize_ipw` flag hardcoded false           -> the option is
#                                                          unwired at the
#                                                          estimator
# M9  APOS drops the flag on its child constructors        -> works through APO,
#                                                          not through APOS
#
# M1 is the canary, and it is not hypothetical. The `1 - p` mix-up was
# WRITTEN during this round's first pass, then found by
# `v119_normalized_ipw_matches_upstream_byte_for_byte`: on the fixture's
# row 18 the port returned +0.9019 where upstream returns -0.0136. It
# survived all 890 pre-existing tests, including `cvar_test.mbt`, which
# exercises the same formula -- because `cvar.mbt` had been switched to
# delegate here, so the bug was live in CVAR too. One external oracle
# bought more than the entire internal suite. The bound in that gate is
# 1e-12 relative; M1 scores 67, which is 16 orders worse, so there is no
# doubt about which failure it is watching.
#
# Output capture goes through a FILE. `moon test 2>&1 | Out-String`
# returned EMPTY for every mutation when this was written first --
# reported 9/10 SURVIVED against mutations that hand-run perfectly, and
# sent the investigation at the gates. See the v0.118.0 harness header.
#
# Three-way verdict (KILLED / SURVIVED / does-not-compile), and a run
# with no verdict line at all is INCONCLUSIVE with the tail rather than
# a silent SURVIVED.
#
# Result: 9/9 KILLED, including M9, which this harness originally declared
# expected-equivalent on the reasoning that "APOS dropping the flag is not
# observable through DoubleMLAPO". That reasoning was wrong -- forcing
# `normalize_ipw: false` in `DoubleMLAPOS::new` is caught by the existing
# `apo_test.mbt` APOS coverage. Declaring a mutation equivalent is a
# claim about observability, and it is as falsifiable as any other
# assertion in the file.

$ErrorActionPreference = 'Continue'
$repo = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$pkg = Join-Path $repo 'moonbit_doubleML'
$files = @('ps_processor.mbt', 'apo.mbt')
$backupDir = Join-Path $repo '_verify\_bak_v119'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $repo
if (Test-Path $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
foreach ($n in $files) {
  Copy-Item -LiteralPath (Join-Path $pkg $n) -Destination (Join-Path $backupDir $n) -Force
}
Write-Output ('backup written: ' + $backupDir)

$mutations = @(
  @{ file = 'ps_processor.mbt'
     name = 'M1 the control denominator uses p instead of 1 - p (the real bug)'
     from  = '    let om = 1.0 - m_clip[i]'
     to    = '    let om = m_clip[i]   // MUT-M1' },

  @{ file = 'ps_processor.mbt'
     name = 'M2 propensity_score_adjustment ignores the flag'
     from  = '  if do_normalize {'
     to    = '  if false {   // MUT-M2' },

  @{ file = 'ps_processor.mbt'
     name = 'M3 mean_treat0 computed from the treated group'
     from  = '    sum_t0 = sum_t0 + (1.0 - treatment[i]) / om_clip[i]'
     to    = '    sum_t0 = sum_t0 + treatment[i] / om_clip[i]   // MUT-M3' },

  @{ file = 'ps_processor.mbt'
     name = 'M4 the leaf w1 term drops the p factor'
     from  = '    let w1 = treatment[i] * m_clip[i] * mean_t1'
     to    = '    let w1 = treatment[i] * mean_t1   // MUT-M4' },

  @{ file = 'ps_processor.mbt'
     name = 'M5 the 1e-12 denominator clamp removed'
     from  = '    om_clip[i] = if om < 1.0e-12 { 1.0e-12 } else { om }'
     to    = '    om_clip[i] = om   // MUT-M5' },

  @{ file = 'ps_processor.mbt'
     name = 'M6 trim_predictions always truncates'
     from  = '  if rule == "truncate" {'
     to    = '  if true {   // MUT-M6' },

  @{ file = 'apo.mbt'
     name = 'M7 APO normalises before the clip'
     from  = '(g, propensity_score_adjustment(m_clipped, treated, do_normalize=normalize_ipw))'
     to    = '(g, propensity_score_adjustment(m, treated, do_normalize=normalize_ipw))   // MUT-M7' },

  @{ file = 'apo.mbt'
     name = 'M8 APO normalize_ipw flag hardcoded false'
     from  = '  (g, propensity_score_adjustment(m_clipped, treated, do_normalize=normalize_ipw))'
     to    = '  (g, propensity_score_adjustment(m_clipped, treated, do_normalize=false))   // MUT-M8' },

  @{ file = 'apo.mbt'
     name = 'M9 APOS drops the flag when it builds its struct'
     from  = '    normalize_ipw,' + [char]10 + '    ml_g,'
     to    = '    normalize_ipw: false,   // MUT-M9' + [char]10 + '    ml_g,' }
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

foreach ($n in $files) {
  Copy-Item -LiteralPath (Join-Path $backupDir $n) -Destination (Join-Path $pkg $n) -Force
  $a = (Get-FileHash -LiteralPath (Join-Path $pkg $n) -Algorithm SHA256).Hash
  $b = (Get-FileHash -LiteralPath (Join-Path $backupDir $n) -Algorithm SHA256).Hash
  Write-Output ("restore {0} byte-identical: {1}" -f $n, ($a -eq $b))
}
$left = Select-String -Path ($files | ForEach-Object { Join-Path $pkg $_ }) -Pattern 'MUT-M\d' -ErrorAction SilentlyContinue
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
Write-Output 'RESULT: every mutation ran the suite and was killed. The propensity gates have teeth.'
exit 0