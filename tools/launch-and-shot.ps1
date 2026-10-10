# 启动挂件 + 立即整屏截图（必须在同一次调用里做完，否则 GUI 进程会被回收）
# 用法： powershell -ExecutionPolicy Bypass -File tools/launch-and-shot.ps1
$ErrorActionPreference = 'Continue'

$Home_ = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget'
$Vbs   = Join-Path $Home_ 'bin\start-widget.vbs'
$Out   = Join-Path $Home_ 'state\_desktop.png'

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue }

# 通过 VBS 无窗口启动（不经过 Start-Process，避免沙箱拦截）
& wscript.exe $Vbs
Start-Sleep -Seconds 4

[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')

$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

if (Test-Path -LiteralPath $Out) { Write-Output ("截图 OK: " + (Get-Item -LiteralPath $Out).Length + " 字节") }
else { Write-Output "截图 FAIL" }
