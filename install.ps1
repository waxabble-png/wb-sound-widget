# ============================================================================
#  wb-sound-widget —— 安装 / 挂载钩子
# ----------------------------------------------------------------------------
#  默认（-Scope user）做四件事：
#    1. 把插件复制到稳定目录 %USERPROFILE%\.workbuddy\wb-sound-widget
#    2. 在 ~/.workbuddy/settings.json 里挂上钩子
#         Stop / FinalStop   → 任务完成提示音
#         PermissionRequest  → 请求 / 授权提示音
#         Elicitation        → 需要你回答的提示音
#         Notification       → permission_prompt 归为请求音，其余为普通提醒
#       （原 settings.json 会先备份，只增删我们自己那几条钩子，别的原样保留）
#    3. 把挂件加入开机自启
#    4. 启动桌面小鲸鱼挂件
#
#  只给某个项目挂钩子（不动全局设置）：
#     powershell -ExecutionPolicy Bypass -File install.ps1 -Scope project -ProjectDir "C:\path\to\proj"
#
#  只挂钩子，不复制文件 / 不设自启 / 不启动挂件：
#     powershell -ExecutionPolicy Bypass -File install.ps1 -HooksOnly -Scope project
# ============================================================================
[CmdletBinding()]
param(
    [ValidateSet('user', 'project')][string]$Scope = 'user',
    [string]$ProjectDir,
    [string]$InstallDir,
    [switch]$NoAutostart,
    [switch]$NoLaunch,
    [switch]$HooksOnly,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Say([string]$msg, [string]$color = 'Gray') {
    if (-not $Quiet) { Write-Host $msg -ForegroundColor $color }
}

$Source = $PSScriptRoot
if (-not $InstallDir) { $InstallDir = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget' }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

if ($Scope -eq 'project') {
    if (-not $ProjectDir) { $ProjectDir = (Get-Location).Path }
    $ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
    $WbDir = Join-Path $ProjectDir '.workbuddy'
    $SettingsPath = Join-Path $WbDir 'settings.json'
} else {
    $WbDir = Join-Path $env:USERPROFILE '.workbuddy'
    $SettingsPath = Join-Path $WbDir 'settings.json'
}

Say ""
Say "  wb-sound-widget 安装" 'Cyan'
Say "  ────────────────────────────────────────────" 'DarkGray'
Say "  范围     : $(if ($Scope -eq 'project') { "仅项目 $ProjectDir" } else { '用户全局' })"
Say "  安装到   : $(if ($HooksOnly) { '(跳过，只挂钩子)' } else { $InstallDir })"
Say "  钩子写入 : $SettingsPath"

# --------------------------------------------------------------- 1. 复制文件
function Sync-Tree {
    param([string]$From, [string]$To)
    if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Path $To -Force | Out-Null }
    foreach ($item in (Get-ChildItem -LiteralPath $From -Force)) {
        if ($item.PSIsContainer) {
            if ($item.Name -in @('state', '.git', 'node_modules')) { continue }
            Sync-Tree -From $item.FullName -To (Join-Path $To $item.Name)
        } else {
            if ($item.Name -in @('config.json')) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $To $item.Name) -Force
        }
    }
}

if (-not $HooksOnly) {
    $sameDir = ($Source.TrimEnd('\') -ieq $InstallDir.TrimEnd('\'))
    if ($sameDir) {
        Say "  · 已在安装目录里运行，跳过复制" 'DarkGray'
    } else {
        Sync-Tree -From $Source -To $InstallDir
        Say "  ✓ 文件已复制" 'Green'
    }

    $cfgPath = Join-Path $InstallDir 'config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Copy-Item -LiteralPath (Join-Path $InstallDir 'config.default.json') -Destination $cfgPath -Force
        Say "  ✓ 已写入默认配置 config.json" 'Green'
    } else {
        Say "  · config.json 已存在，保留你的设置" 'DarkGray'
    }
}

$stateDir = Join-Path $InstallDir 'state'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$eventsFile = Join-Path $stateDir 'events.jsonl'
if (-not (Test-Path -LiteralPath $eventsFile)) { New-Item -ItemType File -Path $eventsFile -Force | Out-Null }

# --------------------------------------------------------------- 2. 挂钩子
$notifyScript = (Join-Path $InstallDir 'hooks\notify.mjs') -replace '\\', '/'
$hookPlan = [ordered]@{
    'SessionStart'      = @{ hint = 'session-start'; desc = 'WorkBuddy 启动 / 会话开始 → 拉起小鲸鱼挂件' }
    'SessionEnd'        = @{ hint = 'session-end';   desc = 'WorkBuddy 退出 / 会话结束 → 关掉小鲸鱼挂件' }
    'Stop'              = @{ hint = 'done';   desc = '一轮任务结束 → 任务完成提示音' }
    'FinalStop'         = @{ hint = 'done';   desc = '任务收尾 → 任务完成提示音' }
    'Notification'      = @{ hint = 'notify'; desc = '通知事件（permission_prompt 自动归为请求音）' }
    'PermissionRequest' = @{ hint = 'ask';    desc = '需要你批准授权 → 请求提示音' }
    'Elicitation'       = @{ hint = 'ask';    desc = '需要你回答问题 → 请求提示音' }
}

function Read-SettingsJson([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return (New-Object psobject) }
    $raw = [System.IO.File]::ReadAllText($path)
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-Object psobject) }
    return ($raw | ConvertFrom-Json)
}

if (Test-Path -LiteralPath $SettingsPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$SettingsPath.bak-wb-sound-widget-$stamp"
    Copy-Item -LiteralPath $SettingsPath -Destination $bak -Force
    Say "  ✓ 已备份原设置 → $(Split-Path -Leaf $bak)" 'Green'
} else {
    if (-not (Test-Path -LiteralPath $WbDir)) { New-Item -ItemType Directory -Path $WbDir -Force | Out-Null }
}

$settings = Read-SettingsJson $SettingsPath

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value (New-Object psobject)
}

$hookRoot = $settings.hooks
$added = 0
$removed = 0

foreach ($evt in $hookPlan.Keys) {
    $plan = $hookPlan[$evt]
    $cmd = 'node "' + $notifyScript + '" ' + $plan.hint

    $keep = @()
    if ($hookRoot.PSObject.Properties.Name -contains $evt) {
        foreach ($group in @($hookRoot.$evt)) {
            $isOurs = $false
            if ($group -and $group.PSObject.Properties.Name -contains 'hooks') {
                foreach ($h in @($group.hooks)) {
                    if ($h -and $h.command -and ($h.command -like '*wb-sound-widget*')) { $isOurs = $true }
                }
            }
            if ($isOurs) { $removed++ } else { $keep += $group }
        }
    }

    $keep += [pscustomobject]@{
        hooks = @(
            [pscustomobject]@{
                type        = 'command'
                command     = $cmd
                description = $plan.desc
                async       = $true
                timeout     = 10
            }
        )
    }
    $added++

    if ($hookRoot.PSObject.Properties.Name -contains $evt) {
        $hookRoot.$evt = @($keep)
    } else {
        $hookRoot | Add-Member -MemberType NoteProperty -Name $evt -Value @($keep)
    }
}

$json = $settings | ConvertTo-Json -Depth 40
[System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Say "  ✓ 钩子已写入（新增 $added 组，清理旧钩子 $removed 组）" 'Green'

# --------------------------------------------------------------- 3/4. 自启与启动
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '小鲸鱼挂件.lnk'
if ($HooksOnly -or $NoAutostart) {
    Say "  · 跳过开机自启" 'DarkGray'
} else {
    try {
        $vbs = Join-Path $InstallDir 'bin\start-widget.vbs'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($startupLnk)
        $sc.TargetPath = 'wscript.exe'
        $sc.Arguments = '"' + $vbs + '"'
        $sc.WorkingDirectory = $InstallDir
        $sc.Description = '小鲸鱼挂件 · 任务完成 / 请求提示音'
        $sc.Save()
        Say "  ✓ 已加入开机自启：$startupLnk" 'Green'
    } catch {
        Say "  ! 开机自启创建失败（不影响使用）：$($_.Exception.Message)" 'Yellow'
    }
}

if ($HooksOnly -or $NoLaunch) {
    Say "  · 跳过启动挂件" 'DarkGray'
} else {
    $running = $false
    try {
        $alive = Join-Path $stateDir 'widget-alive'
        if (Test-Path -LiteralPath $alive) {
            $running = ((Get-Date) - (Get-Item -LiteralPath $alive).LastWriteTime).TotalSeconds -lt 8
        }
    } catch {}
    if ($running) {
        Say "  · 挂件已经在运行了" 'DarkGray'
    } else {
        try {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $InstallDir 'bin\start-widget.vbs') + '"') -WorkingDirectory $InstallDir
            Say "  ✓ 挂件已启动，看一下桌面右下角" 'Green'
        } catch {
            Say "  ! 挂件启动失败：$($_.Exception.Message)" 'Yellow'
        }
    }
}

Say ""
Say "  完成 " 'Cyan'
Say "  ────────────────────────────────────────────" 'DarkGray'
Say "  试听三种提示音："
Say "    powershell -ExecutionPolicy Bypass -File `"$InstallDir\bin\wb-notify.ps1`" -Demo"
Say "  卸载："
Say "    powershell -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""
Say "  ⚠ 钩子改动需要重启 WorkBuddy 才会生效。"
Say ""
