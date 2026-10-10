# ============================================================================
#  wb-sound-widget —— 卸载
# ----------------------------------------------------------------------------
#  做四件事：
#    1. 从 ~/.workbuddy/settings.json 里摘掉我们挂的钩子（其它设置原样保留）
#    2. 结束正在运行的挂件
#    3. 删掉开机自启快捷方式
#    4. 删掉安装目录（用 -KeepFiles 可保留，只摘钩子）
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File uninstall.ps1
#     powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepFiles
# ============================================================================
[CmdletBinding()]
param(
    [ValidateSet('user', 'project')][string]$Scope = 'user',
    [string]$ProjectDir,
    [string]$InstallDir,
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Continue'

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

if ($Scope -eq 'project') {
    if (-not $ProjectDir) { $ProjectDir = (Get-Location).Path }
    $SettingsPath = Join-Path ([System.IO.Path]::GetFullPath($ProjectDir)) '.workbuddy\settings.json'
} else {
    $SettingsPath = Join-Path $env:USERPROFILE '.workbuddy\settings.json'
}

Say ""
Say "  wb-sound-widget 卸载" 'Cyan'
Say "  ────────────────────────────────────────────" 'DarkGray'

# --------------------------------------------------------------- 1. 摘钩子
if (Test-Path -LiteralPath $SettingsPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak-uninstall-$stamp" -Force

    $raw = [System.IO.File]::ReadAllText($SettingsPath)
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    $settings = $raw | ConvertFrom-Json

    $removed = 0
    if ($settings.PSObject.Properties.Name -contains 'hooks') {
        $hk = $settings.hooks
        foreach ($evt in @($hk.PSObject.Properties.Name)) {
            $keep = @()
            foreach ($group in @($hk.$evt)) {
                $isOurs = $false
                if ($group -and $group.PSObject.Properties.Name -contains 'hooks') {
                    foreach ($h in @($group.hooks)) {
                        if ($h -and $h.command -and ($h.command -like '*wb-sound-widget*')) { $isOurs = $true }
                    }
                }
                if ($isOurs) { $removed++ } else { $keep += $group }
            }
            if ($keep.Count -gt 0) {
                $hk.$evt = @($keep)
            } else {
                $hk.PSObject.Properties.Remove($evt) | Out-Null
            }
        }
    }

    $json = $settings | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Say "  ✓ 已摘掉 $removed 组钩子（原文件已备份）" 'Green'
} else {
    Say "  · 没找到 settings.json，跳过" 'DarkGray'
}

# --------------------------------------------------------------- 2. 关挂件
$killed = 0
try {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {}
        }
} catch {}
Say "  ✓ 已结束挂件进程 $killed 个" 'Green'

# --------------------------------------------------------------- 3. 自启
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '小鲸鱼挂件.lnk'
if (Test-Path -LiteralPath $startupLnk) {
    Remove-Item -LiteralPath $startupLnk -Force -ErrorAction SilentlyContinue
    Say "  ✓ 已删除开机自启" 'Green'
}

# --------------------------------------------------------------- 4. 删文件
if ($KeepFiles) {
    Say "  · 按参数要求保留安装目录：$InstallDir" 'DarkGray'
} else {
    if (Test-Path -LiteralPath $InstallDir) {
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
            Say "  ✓ 已删除安装目录" 'Green'
        } catch {
            Say "  ! 删除失败（可能被占用）：$($_.Exception.Message)" 'Yellow'
        }
    }
}

Say ""
Say "  卸载完成。重启 WorkBuddy 生效。" 'Cyan'
Say ""
