# 语法自检：对所有 .ps1 做解析，只报错不执行
$files = @(
    'widget\wb-widget.ps1',
    'bin\wb-notify.ps1',
    'bin\play-sound.ps1',
    'bin\setup-autostart.ps1',
    'install.ps1',
    'uninstall.ps1'
)
$bad = 0
foreach ($f in $files) {
    $p = Join-Path $PSScriptRoot "..\$f"
    if (-not (Test-Path -LiteralPath $p)) { Write-Output "MISS $f"; continue }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $bad++
        Write-Output "FAIL $f"
        foreach ($e in $errors) { Write-Output ("     line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) }
    } else {
        Write-Output "OK   $f"
    }
}
Write-Output ("---- 失败 {0} 个 ----" -f $bad)
if ($bad -gt 0) { exit 1 }
