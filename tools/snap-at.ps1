# 把挂件按指定落点渲染成 PNG（用 -SnapshotTo 直接渲染视觉树）
param(
    [int]$X = 30,
    [int]$Y = 800,
    [string]$OutName = 'flip-check.png'
)
$ErrorActionPreference = 'Continue'
$Home_ = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget'
$Cfg   = Join-Path $Home_ 'config.json'
$Docs  = Join-Path $Home_ 'docs'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Widget = Join-Path $Home_ 'widget\wb-widget.ps1'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
Start-Sleep -Seconds 2

# 写落点（flipped=null → 让挂件自己按位置算）
$j = [System.IO.File]::ReadAllText($Cfg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$j.widget.x = $X
$j.widget.y = $Y
$j.widget.flipped = $null
[System.IO.File]::WriteAllText($Cfg, ($j | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

foreach ($f in @('widget-alive', 'widget-stopping', 'widget-off')) {
    Remove-Item -LiteralPath (Join-Path $Home_ "state\$f") -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $Home_ 'state\widget.log') -Force -ErrorAction SilentlyContinue

$png = Join-Path $Docs $OutName
if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue }

$vbs = Join-Path $env:TEMP 'snap1.vbs'
$cmd = '"' + $PsExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Widget + '" -NoTray -SnapshotTo "' + $png + '" -SnapshotState idle'
[System.IO.File]::WriteAllText($vbs, 'CreateObject("WScript.Shell").Run "' + $cmd.Replace('"', '""') + '", 0, False', [System.Text.Encoding]::ASCII)
& wscript.exe $vbs
Start-Sleep -Seconds 5

$rep = @()
$rep += "落点: $X,$Y"
$rep += "快照: " + $(if (Test-Path -LiteralPath $png) { (Get-Item -LiteralPath $png).Length.ToString() + ' 字节' } else { 'FAIL' })
$lg = Join-Path $Home_ 'state\widget.log'
$rep += "日志: " + $(if (Test-Path -LiteralPath $lg) { [System.IO.File]::ReadAllText($lg, [System.Text.Encoding]::UTF8).Trim() } else { '(无)' })
[System.IO.File]::WriteAllText("$env:TEMP\snaprep.txt", ($rep -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
