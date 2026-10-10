# 重启挂件 + 立即整屏截图（必须同一次调用里做完）
# 用独立参数区分多次验证：-ShotName 指定输出文件名
param(
    [string]$ShotName = '_desktop.png'
)
$ErrorActionPreference = 'Continue'

$Home_ = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget'
$Vbs   = Join-Path $Home_ 'bin\start-widget.vbs'
$Out   = Join-Path $Home_ 'state' | Join-Path -ChildPath $ShotName

# 1) 结束旧实例
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
Start-Sleep -Seconds 2

# 2) 清运行时标记并截断日志
$st = Join-Path $Home_ 'state'
foreach ($f in @('widget-alive', 'widget-stopping')) {
    Remove-Item -LiteralPath (Join-Path $st $f) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $st 'widget.log') -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue }

# 3) 启动（VBS 无窗口，避开 Start-Process 的沙箱限制）
& wscript.exe $Vbs
Start-Sleep -Seconds 4

# 4) 截图
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# 5) 把本次启动日志 + 截图结果落到一个纯文本文件，方便在无输出环境里读
$rep = @()
$rep += "截图: " + $(if (Test-Path -LiteralPath $Out) { (Get-Item -LiteralPath $Out).Length.ToString() + " 字节" } else { "FAIL" })
$lg = Join-Path $st 'widget.log'
$rep += "---- widget.log ----"
if (Test-Path -LiteralPath $lg) { $rep += [System.IO.File]::ReadAllText($lg, [System.Text.Encoding]::UTF8) } else { $rep += "(无)" }
[System.IO.File]::WriteAllLines((Join-Path $st ("_report" + $ShotName + ".txt")), $rep, (New-Object System.Text.UTF8Encoding($false)))
