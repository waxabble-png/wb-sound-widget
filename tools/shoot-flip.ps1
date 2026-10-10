# 快照对比：把挂件分别按「左侧/右侧」渲染成 PNG（用挂件自带的 -SnapshotTo，
# 它直接渲染 WPF 视觉树，不依赖桌面合成，因此在无人值守环境下也能拿到结果）
$ErrorActionPreference = 'Continue'

$Home_ = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget'
$Cfg   = Join-Path $Home_ 'config.json'
$Docs  = Join-Path $Home_ 'docs'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Widget = Join-Path $Home_ 'widget\wb-widget.ps1'

# 结束正在跑的挂件，免得抢互斥体
function Stop-Widget {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
}

function Set-Pos([int]$x, [int]$y, $flip) {
    $j = [System.IO.File]::ReadAllText($Cfg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $j.widget.x = $x
    $j.widget.y = $y
    if ($null -eq $flip) { $j.widget.flipped = $null } else { $j.widget.flipped = [bool]$flip }
    $json = $j | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Cfg, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Shoot([string]$name, [int]$x, [int]$y, $flip) {
    Stop-Widget
    Start-Sleep -Seconds 1
    Set-Pos $x $y $flip
    $png = Join-Path $Docs $name
    if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue }

    # 用 wscript 拉起来（避开 Start-Process 的沙箱限制），-NoTray 避免托盘图标干扰
    $vbs = Join-Path $env:TEMP ("shot_" + [IO.Path]::GetFileNameWithoutExtension($name) + ".vbs")
    $cmd = '"' + $PsExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Widget + '" -NoTray -SnapshotTo "' + $png + '" -SnapshotState idle'
    [System.IO.File]::WriteAllText($vbs, "CreateObject(""WScript.Shell"").Run """ + $cmd.Replace('"', '""') + """, 0, False", [System.Text.Encoding]::ASCII)
    & wscript.exe $vbs
    Start-Sleep -Seconds 4
    if (Test-Path -LiteralPath $png) { return "OK   $name  " + (Get-Item -LiteralPath $png).Length + " 字节" }
    return "FAIL $name"
}

$rep = @()
$rep += "== 快照对比（用于确认镜像方向）=="
$rep += (Shoot 'flip-left.png'  30   700 $null)   # 左侧 → 应镜像
$rep += (Shoot 'flip-right.png' 1450 700 $null)   # 右侧 → 不应镜像
Stop-Widget
$rep += ""
$rep += "== 最终 config widget 段 =="
$j = [System.IO.File]::ReadAllText($Cfg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$rep += ($j.widget | ConvertTo-Json -Depth 5)

[System.IO.File]::WriteAllLines((Join-Path $env:TEMP 'shots.txt'), $rep, (New-Object System.Text.UTF8Encoding($false)))
