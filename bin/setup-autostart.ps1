# ============================================================================
#  wb-sound-widget —— 开机自启开关
# ----------------------------------------------------------------------------
#  安装： powershell -ExecutionPolicy Bypass -File setup-autostart.ps1
#  移除： powershell -ExecutionPolicy Bypass -File setup-autostart.ps1 -Remove
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'

if (-not $InstallDir) { $InstallDir = Split-Path -Parent $PSScriptRoot }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup '小鲸鱼挂件.lnk'

if ($Remove) {
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "  ✓ 已移除开机自启：$lnk" -ForegroundColor Green
    } else {
        Write-Host "  · 本来就没有开机自启" -ForegroundColor DarkGray
    }
    exit 0
}

$vbs = Join-Path $InstallDir 'bin\start-widget.vbs'
if (-not (Test-Path -LiteralPath $vbs)) {
    Write-Host "  ! 找不到 $vbs" -ForegroundColor Red
    exit 1
}

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = 'wscript.exe'
$sc.Arguments = '"' + $vbs + '"'
$sc.WorkingDirectory = $InstallDir
$sc.Description = '小鲸鱼挂件 · 任务完成 / 请求提示音'
$sc.Save()

Write-Host "  ✓ 已加入开机自启：$lnk" -ForegroundColor Green
