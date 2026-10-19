# v0.108.0 mutation harness for the `tune` gate.
#
# Purpose: prove the new gate in `expand_v108_test.mbt` can fail. The v0.65.0
# gate could not — inverting the argmin left the suite at 808/808. These three
# mutations each model a realistic defect in the selection path, and each must
# turn the suite red. A mutation that survives is not a near-miss, it means the
# gate is decorative.
#
# M1 selection rule inverted      — `tune_argmin` compares with `>` instead of `<`
# M2 selection never applied      — `tune_score_grid` hardcodes `best_index: 0`
# M3 fail-sentinel guard inverted — `pred.length() == n` becomes `!= n`, so every
#                                  well-formed candidate scores the sentinel and the
#                                  argmin keeps index 0
#
# The grid order in the tests is `[worst, best]`, which is what makes all three
# of these lethal. With `[best, worst]`, M2 and M3 would pass.
#
# UTF-8 without BOM, absolute paths, restore-and-verify at the end. Byte-exact:
# no Get-Content/Set-Content anywhere in the mutation path.

$ErrorActionPreference = 'Continue'
$root = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$target = Join-Path $root 'moonbit_doubleML\tune.mbt'
$backup = Join-Path $root '_verify\_bak_tune_v108.mbt'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $root

$mutations = @(
  @{ name = 'M1 selection rule inverted (argmin -> argmax)'
     from  = "      if scores[i] < bv {`n        bv = scores[i]"
     to    = "      if scores[i] > bv {   // MUTATION-M1`n        bv = scores[i]" },

  @{ name = 'M2 selection never applied (best_index hardcoded to 0)'
     from  = "TuneGridScore::{ scores, best_index: tune_argmin(scores, scoring), }"
     to    = "TuneGridScore::{ scores, best_index: 0 }   // MUTATION-M2" },

  @{ name = 'M3 fail-sentinel guard inverted (== -> !=)'
     from  = "    scores[i] = if pred.length() == n {"
     to    = "    scores[i] = if pred.length() != n {   // MUTATION-M3" }
)

$survived = @()

foreach ($m in $mutations) {
  # pristine restore before every attempt
  Copy-Item -LiteralPath $backup -Destination $target -Force
  $src = [System.IO.File]::ReadAllText($target, $enc)
  if ($src.IndexOf($m.from) -lt 0) {
    Write-Output ("SKIP  " + $m.name + "  -- anchor not found (tune.mbt moved?)")
    continue
  }
  $src = $src.Replace($m.from, $m.to)
  [System.IO.File]::WriteAllText($target, $src, $enc)

  $out = moon test --target native 2>&1 | Out-String
  $total = ($out -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1
  $failed = ($out -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1
  $line = if ($total) { $total.Line.Trim() } else { 'suite did not report a total (build error or panic)' }
  $died = $out -match 'PanicError|failed to run test'

  if ($died -or $line -notmatch 'failed: 0') {
    Write-Output ("KILLED  " + $m.name)
    Write-Output ("        -> " + $line)
    if ($died) { Write-Output '        -> suite aborted (panic or non-zero exit)' }
  } else {
    Write-Output ("SURVIVED  " + $m.name)
    Write-Output ("        -> " + $line + "   <-- THE GATE IS DEAD")
    $survived += $m.name
  }
  Write-Output ''
}

# restore and prove the tree is byte-identical to the pre-mutation backup.
Copy-Item -LiteralPath $backup -Destination $target -Force
#
# Compare against the BACKUP, not against HEAD: mid-release the working tree
# is SUPPOSED to differ from HEAD (that is the v0.108.0 work), so a HEAD
# comparison here reports "DIRTY" on a perfectly restored file and teaches
# the reader to ignore the line.
$liveHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
$bakHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
if ($liveHash -eq $bakHash) {
  Write-Output 'restore: byte-identical to the pre-mutation backup (SHA256 match)'
} else {
  Write-Output 'restore: MISMATCH — the working file is not the pre-mutation content'
}
$left = Select-String -Path $target -Pattern 'MUTATION-M' -ErrorAction SilentlyContinue
Write-Output ("mutation markers left in tune.mbt: " + $(if ($left) { $left.Count } else { 0 }))

if ($survived.Count -gt 0) {
  Write-Output ''
  Write-Output ("RESULT: " + $survived.Count + " mutation(s) SURVIVED — the gate is decorative.")
  exit 1
}
Write-Output ''
Write-Output 'RESULT: all mutations killed. The gate has teeth.'
exit 0
