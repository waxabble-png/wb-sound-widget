# 无人值守自检：在独立数据目录里跑一次挂件，抓快照，然后把日志/产物收上来。
# 用法： powershell -ExecutionPolicy Bypass -File tools/selftest.ps1
$ErrorActionPreference = 'Continue'

$Src = Split-Path -Parent $PSScriptRoot
$Tmp = Join-Path $env:TEMP 'wb-selftest'
if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

$env:WB_WIDGET_HOME = $Tmp
$png = Join-Path $Tmp 'shot.png'

$args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', (Join-Path $Src 'widget\wb-widget.ps1'),
    '-NoTray', '-SnapshotTo', $png, '-SnapshotState', 'idle'
)

# 用 wscript 拉起来，避免直接被沙箱回收
$vbs = Join-Path $Tmp 'run.vbs'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmdLine = '"' + $psExe + '" ' + (($args | ForEach-Object { '"' + $_ + '"' }) -join ' ')
$vbsBody = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "$cmdLine", 0, False
"@
[System.IO.File]::WriteAllText($vbs, $vbsBody, [System.Text.Encoding]::ASCII)

& wscript.exe $vbs
Start-Sleep -Seconds 5

$lines = @()
$lines += "== 产物 =="
if (Test-Path -LiteralPath $png) {
    $lines += ("shot.png  {0} 字节" -f (Get-Item -LiteralPath $png).Length)
} else {
    $lines += "shot.png  未生成"
}
$log = Join-Path $Tmp 'state\widget.log'
if (Test-Path -LiteralPath $log) {
    $lines += ""
    $lines += "== widget.log =="
    $lines += [System.IO.File]::ReadAllText($log, [System.Text.Encoding]::UTF8)
} else {
    $lines += ""
    $lines += "widget.log 未生成（说明还没走到写日志那一步）"
}
$cfg = Join-Path $Tmp 'config.json'
if (Test-Path -LiteralPath $cfg) {
    $lines += ""
    $lines += "== config.json (widget 段) =="
    $j = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $lines += ($j.widget | ConvertTo-Json -Depth 5)
}

[System.IO.File]::WriteAllLines((Join-Path $Tmp 'RESULT.txt'), $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("结果写入: " + (Join-Path $Tmp 'RESULT.txt'))
