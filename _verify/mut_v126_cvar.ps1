# v0.126.0 mutation harness -- `ps_processor_config` on `DoubleMLCVAR`.
#
# Engine (unchanged across v0.120.0 - v0.126.0):
#   * capture the summary with `Total tests: (\d+), passed: (\d+), failed: (\d+)\.`
#     -- the capture groups are MANDATORY, a bare `Total tests: \d+` makes the
#     whole classification collapse to INCONCLUSIVE;
#   * no summary line at all:
#       PanicError | gate failed | precondition failed -> KILLED
#       Error:                                     -> NO-COMPILE
#       anything else                              -> INCONCLUSIVE
#   * a compile failure is NOT a kill;
#   * every mutation restores cvar.mbt by SHA256 and a residue check runs at
#     the end, so a half-restored file can never be mistaken for a clean tree;
#   * two CANARIES run first and are declared SURVIVED. A killed canary aborts
#     the entire run and every verdict after it is untrustworthy.
#
# ANCHOR RULES LEARNED THE HARD WAY (both fired in the first attempt at this
# harness, and both were caught by the canaries rather than silently):
#   1. `moonbit_doubleML/*.mbt` is LF-ONLY (verified: 1516 LF, 0 CRLF). Every
#      multi-line anchor must be joined with a bare LF, NOT `` `r`n ``.
#   2. NEVER put a Markdown backtick inside a PowerShell double-quoted string.
#      The backtick is the escape character: `` `m `` silently becomes `m`, so
#      an anchor lifted straight out of a comment never matches the file.
#   3. A canary must be behaviour-preserving AND compile-preserving. Renaming
#      `m_prelim_clipped` at its single declaration looks harmless but breaks
#      the build at its seven other uses -- that is a NO-COMPILE, not a
#      survivor. Both canaries here are now purely syntactic.
#
# NEVER read, write, or run `moon` against these files while the harness is
# mutating them.

$ErrorActionPreference = 'Continue'
$repo  = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$file  = Join-Path $repo 'moonbit_doubleML\cvar.mbt'
$log   = Join-Path $repo '_verify\_mut_v126.log'
$orig  = [IO.File]::ReadAllText($file)
$baseHash = (Get-FileHash -Algorithm SHA256 $file).Hash
$LF = [char]10

function Restore-Source {
  $cur = (Get-FileHash -Algorithm SHA256 $file).Hash
  if ($cur -ne $script:baseHash) {
    [IO.File]::WriteAllText($file, $script:orig)
    $after = (Get-FileHash -Algorithm SHA256 $file).Hash
    Write-Host ("  !! forced restore, hash ok = " + ($after -eq $script:baseHash))
  }
}

function Classify {
  param([string]$Out, [int]$BaseFail)
  if ($Out -match 'Total tests: (\d+), passed: (\d+), failed: (\d+)\.') {
    $f = [int]$Matches[3]
    if ($f -gt 0) { return 'KILLED' }
    if ($f -ne $BaseFail) { return 'INCONCLUSIVE' }
    return 'SURVIVED'
  }
  if ($Out -match 'PanicError|gate failed|precondition failed') { return 'KILLED' }
  if ($Out -match 'Error:') { return 'NO-COMPILE' }
  return 'INCONCLUSIVE'
}

function Invoke-Run {
  Push-Location $repo
  $env:MOON_COLOR = 0
  $out = moon test --target native 2>&1 | Out-String -Width 400
  Pop-Location
  $out | Out-File -FilePath $log -Encoding utf8
  return $out
}

$baselineOut = Invoke-Run
if ($baselineOut -notmatch 'Total tests: (\d+), passed: (\d+), failed: (\d+)\.') {
  Write-Host 'FATAL: baseline produced no summary'; exit 1
}
$baseTotal = [int]$Matches[1]; $baseFail = [int]$Matches[3]
Write-Host ("baseline: {0} tests, {1} failed" -f $baseTotal, $baseFail)
if ($baseFail -ne 0) { Write-Host 'FATAL: baseline is not green'; exit 1 }

# The prelim adjust_ps call, verbatim, LF-joined. This exact shape occurs ONCE,
# so it is safe as a multi-line anchor.
$PRELIM_OLD = 'let m_prelim_clipped = PSProcessor::from_config(ps_processor_config).adjust_ps(' + $LF + '    m_prelim,' + $LF + '    slice_vector(d, train_1),' + $LF + '  )'
$PRELIM_HDR = 'let m_prelim_clipped = PSProcessor::from_config(ps_processor_config).adjust_ps('
$FINAL_HDR  = 'let m_clipped = PSProcessor::from_config(self.ps_processor_config).adjust_ps('
$RESOLVE_OLD = '  let ps_processor_config = resolve_ps_processor_config(' + $LF + '    ps_processor_config~,' + $LF + '    trimming_threshold=propensity_clip,' + $LF + '  )'
$FIT_OLD    = '      propensity_clip: self.propensity_clip,' + $LF + '      ps_processor_config: self.ps_processor_config,'

$mutations = @(
  @{ N = 'C1-canary-comment'; E = 'SURVIVED'
     O = '    let flipped = Array::make(m_prelim_clipped.length(), 0.0)'
     W = '    // canary C1: comment only, behaviour preserved' + $LF + '    let flipped = Array::make(m_prelim_clipped.length(), 0.0)' }

  @{ N = 'C2-canary-reformat'; E = 'SURVIVED'
     O = $RESOLVE_OLD
     W = '  let ps_processor_config = resolve_ps_processor_config(ps_processor_config~, trimming_threshold=propensity_clip)' }

  # cvar.py:293 -- freeze the PRELIMINARY site to the deprecated default.
  # MEASURED coef row: 3.664307496539196 / 3.64462711215576 / 3.6409745892010417
  #                     / 3.6401130431711732 / 3.6431144358643284
  @{ N = 'M1-prelim-site-frozen-to-default'; E = 'KILLED'
     O = $PRELIM_HDR
     W = 'let m_prelim_clipped = PSProcessor::from_config(resolve_ps_processor_config(trimming_threshold=1.0e-6)).adjust_ps(' }

  # cvar.py:343 -- freeze the FINAL site to the deprecated default.
  # MEASURED coef row: 3.664307496539196 / 3.9589090122807122 / 3.9761158569596606
  #                     / 3.9656198245812257 / 3.9678982615979637
  @{ N = 'M2-final-site-frozen-to-default'; E = 'KILLED'
     O = $FINAL_HDR
     W = 'let m_clipped = PSProcessor::from_config(resolve_ps_processor_config(trimming_threshold=1.0e-6)).adjust_ps(' }

  # the second argument must be d_train_1, not the full d: adjust_ps checks
  # lengths, so this must abort rather than quietly read the wrong rows.
  @{ N = 'M3-prelim-second-arg-is-full-d'; E = 'KILLED'
     O = $PRELIM_OLD
     W = 'let m_prelim_clipped = PSProcessor::from_config(ps_processor_config).adjust_ps(' + $LF + '    m_prelim,' + $LF + '    d,' + $LF + '  )' }

  # wrong canary shape: adjust_ps validates its SECOND argument, so swapping
  # aborts on the propensity vector. Proves the argument order is load-bearing.
  @{ N = 'M4-prelim-arguments-swapped'; E = 'KILLED'
     O = $PRELIM_OLD
     W = 'let m_prelim_clipped = PSProcessor::from_config(ps_processor_config).adjust_ps(' + $LF + '    slice_vector(d, train_1),' + $LF + '    m_prelim,' + $LF + '  )' }

  # init_ps_processor precedence: the config must win, not the scalar.
  @{ N = 'M5-config-ignored-by-resolution'; E = 'KILLED'
     O = $RESOLVE_OLD
     W = '  let ps_processor_config = resolve_ps_processor_config(' + $LF + '    trimming_threshold=propensity_clip,' + $LF + '  )' }

  # cvar.py:156 -- upstream redirects the deprecated scalar to the config.
  @{ N = 'M6-upstream-scalar-redirect-dropped'; E = 'KILLED'
     O = '    propensity_clip: ps_processor_config.clipping_threshold,'
     W = '    propensity_clip,' }

  # fit() writes a FULL struct literal, so this is the one rebuild that can
  # silently drop a stored config. `resolve_ps_processor_config()` rather than
  # `PSProcessorConfig::new()`: the latter is `raise`, and `fit` is not, so the
  # first attempt at this mutation was NO-COMPILE rather than a verdict.
  @{ N = 'M7-fit-rebuild-drops-the-config'; E = 'KILLED'
     O = $FIT_OLD
     W = '      propensity_clip: self.propensity_clip,' + $LF + '      ps_processor_config: resolve_ps_processor_config(trimming_threshold=1.0e-6),' }

  # final site rebuilt from the scalar threshold -> calibration never applied.
  @{ N = 'M8-final-site-drops-the-calibration'; E = 'KILLED'
     O = $FINAL_HDR
     W = 'let m_clipped = PSProcessor::from_config(resolve_ps_processor_config(trimming_threshold=self.propensity_clip)).adjust_ps(' }

  # DECLARED SURVIVED, and it is a real finding rather than a weak gate.
  # `irm_style_sensitivity(theta, residuals, psi_a, cf_y, cf_d)` has NO psi_b
  # parameter, so CVaR's `psi_b` -- and the `m_clip` it computes -- never
  # reach the returned SensitivityResult. Measured: under this mutation
  # rv / sigma2 / nu2 / max_bias are BIT-IDENTICAL to the baseline.
  # See `v126_sensitivity_reclip_is_structurally_inert`.
  @{ N = 'M9-sensitivity-threshold-hardcoded'; E = 'SURVIVED'
     O = '    let m_clip = if m_i < self.propensity_clip {' + $LF + '      self.propensity_clip'
     W = '    let m_clip = if m_i < 1.0e-12 {' + $LF + '      1.0e-12' }

  # DECLARED SURVIVED: fit_cache is per-instance, fit() takes no config
  # override, and set_sample_splitting is the only setter, so two fits of one
  # instance cannot differ in calibration. Documented-equivalent by the same
  # construction argued in v0.123.0 / v0.124.0 / v0.125.0.
  @{ N = 'M10-cache-key-drops-the-config'; E = 'SURVIVED'
     O = '        ps_processor_config=Some(self.ps_processor_config),'
     W = '        ps_processor_config=None,' }
)

$results = @()
$canaryFail = $false
foreach ($m in $mutations) {
  $cur = [IO.File]::ReadAllText($file)
  if (-not $cur.Contains($m.O)) {
    Write-Host ("{0}: ANCHOR MISS -- verdict withheld" -f $m.N)
    $results += [pscustomobject]@{ Name = $m.N; Got = 'ANCHOR-MISS'; Exp = $m.E }
    if ($m.N -like 'C*') { $canaryFail = $true }
    continue
  }
  [IO.File]::WriteAllText($file, $cur.Replace($m.O, $m.W))
  $out = Invoke-Run
  $got = Classify $out $baseFail
  Restore-Source
  Write-Host ("{0}: {1} (expected {2})" -f $m.N, $got, $m.E)
  $results += [pscustomobject]@{ Name = $m.N; Got = $got; Exp = $m.E }
  if ($m.N -like 'C*' -and $got -ne 'SURVIVED') { $canaryFail = $true }
  if ($canaryFail) {
    Write-Host 'ABORT: a canary did not survive; every verdict above is untrustworthy'
    break
  }
}

Restore-Source
$finalHash = (Get-FileHash -Algorithm SHA256 $file).Hash
Write-Host ''
Write-Host '--- summary ---'
$killed = @($results | Where-Object { $_.Got -eq 'KILLED' }).Count
$surv   = @($results | Where-Object { $_.Got -eq 'SURVIVED' }).Count
$noc    = @($results | Where-Object { $_.Got -eq 'NO-COMPILE' }).Count
$miss   = @($results | Where-Object { $_.Got -eq 'ANCHOR-MISS' }).Count
$inc    = @($results | Where-Object { $_.Got -eq 'INCONCLUSIVE' }).Count
Write-Host ("KILLED={0} SURVIVED={1} NO-COMPILE={2} ANCHOR-MISS={3} INCONCLUSIVE={4}" -f $killed,$surv,$noc,$miss,$inc)
Write-Host ("source residue clean = " + ($finalHash -eq $baseHash))
$results | ForEach-Object { '  {0,-42} {1,-14} expected {2}' -f $_.Name, $_.Got, $_.Exp }