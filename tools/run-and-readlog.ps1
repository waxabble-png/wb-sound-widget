# 启动挂件，然后只把 widget.log 读出来（不截图，避免可见性问题）
$ErrorActionPreference = 'Continue'
$Home_ = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget'
$Vbs   = Join-Path $Home_ 'bin\start-widget.vbs'
$st    = Join-Path $Home_ 'state'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
Start-Sleep -Seconds 2

foreach ($f in @('widget-alive', 'widget-stopping', 'widget-off')) {
    Remove-Item -LiteralPath (Join-Path $st $f) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $st 'widget.log') -Force -ErrorAction SilentlyContinue

& wscript.exe $Vbs
Start-Sleep -Seconds 4

$lg = Join-Path $st 'widget.log'
$txt = if (Test-Path -LiteralPath $lg) { [System.IO.File]::ReadAllText($lg, [System.Text.Encoding]::UTF8) } else { '(无 widget.log)' }
[System.IO.File]::WriteAllText("$env:TEMP\widgetlog.txt", $txt, (New-Object System.Text.UTF8Encoding($false)))
