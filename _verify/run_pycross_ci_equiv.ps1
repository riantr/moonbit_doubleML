# Mirrors the CI job in .github/workflows/check.yml EXACTLY:
#   line="$(python "$s" | tail -1)"
#   case "$line" in *PASS*) ;; *) fail ;; esac
#
# The earlier local check used PowerShell -like '*PASS*', which is
# case-INSENSITIVE and therefore accepted a trailing "passed". That
# masked five validators whose last line was lowercase. Use
# -clike (case-sensitive) or an explicit check below.
$ErrorActionPreference = 'Continue'
$root = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
Set-Location $root

# v0.105.0: the meta-gate runs first and its verdict is part of the
# summary. It mechanically classifies every validator (does it really
# spawn `moon`, can it exit non-zero, is its verdict computed or
# typed) and fails if any file drifts off its expected classification.
# Without it, a refactor could quietly undo the v0.103.0 audit.
$meta = & python validate_suite_meta.py 2>$null | Out-String
$metaOk = $LASTEXITCODE -eq 0
$metaLast = (($meta -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
Write-Output ("[{0}] {1,-42} {2}" -f ($(if ($metaOk) { 'PASS' } else { 'FAIL' })), 'validate_suite_meta.py', $metaLast.Trim())
Write-Output ''

$scripts = Get-ChildItem -Path $root -Filter 'validate_*_with_python.py' -File | Sort-Object Name
$pass = 0
$fail = @()
foreach ($s in $scripts) {
    # stdout only, exactly like the CI pipe
    $stdout = & python $s.Name 2>$null | Out-String
    $lines = $stdout -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    $last = if ($lines.Count -gt 0) { $lines[-1].Trim() } else { '' }
    # case-SENSITIVE, like bash's *PASS* glob
    $ok = ($last -cmatch 'PASS')
    if ($ok) { $pass++ } else { $fail += $s.Name }
    Write-Output ("[{0}] {1,-42} {2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $s.Name, $last)
}
Write-Output ''
Write-Output ("SUMMARY (CI-equivalent, case-sensitive): {0} pass, {1} fail" -f $pass, $fail.Count)
foreach ($f in $fail) { Write-Output ("  FAIL " + $f) }
if (-not $metaOk) {
    Write-Output ("  FAIL validate_suite_meta.py (validator classification drifted)")
    exit 1
}
if ($fail.Count -gt 0) { exit 1 }
