# ============================================================================
#  wb-notify —— 手动往小鲸鱼挂件发一条提醒（挂件没开也能响）
# ----------------------------------------------------------------------------
#  用法：
#     .\wb-notify.ps1 done                        任务完成音
#     .\wb-notify.ps1 ask                         请求 / 授权音
#     .\wb-notify.ps1 notify                      普通提醒音
#     .\wb-notify.ps1 done -Title "构建完成" -Message "耗时 12 秒"
#     .\wb-notify.ps1 ask -Silent                 只冒泡、不响
#     .\wb-notify.ps1 -Demo                       把三种音效依次演示一遍
#     .\wb-notify.ps1 -StartWidget                顺便把挂件拉起来
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('done', 'ask', 'notify')]
    [string]$Kind = 'done',

    [Alias('t')][string]$Title,
    [Alias('m')][string]$Message,
    [switch]$Silent,
    [switch]$Demo,
    [switch]$StartWidget,
    [switch]$Status
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$Entry = Join-Path $Root 'hooks\notify.mjs'
$DataRoot = if ($env:WB_WIDGET_HOME) { $env:WB_WIDGET_HOME } else { Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget' }
$Alive = Join-Path $DataRoot 'state\widget-alive'

function Find-Node {
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
            (Join-Path $env:USERPROFILE '.workbuddy\binaries\node\versions\22.22.2-6\node.exe'),
            'D:\Nodejs\node.exe',
            (Join-Path $env:ProgramFiles 'nodejs\node.exe')
        )) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-WidgetState {
    if (-not (Test-Path -LiteralPath $Alive)) { return $false }
    try { return (((Get-Date) - (Get-Item -LiteralPath $Alive).LastWriteTime).TotalSeconds -lt 8) } catch { return $false }
}

function Start-Widget {
    $vbs = Join-Path $PSScriptRoot 'start-widget.vbs'
    if (Test-Path -LiteralPath $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') | Out-Null
        Start-Sleep -Milliseconds 900
    }
}

if ($Status) {
    $on = Get-WidgetState
    Write-Host ("挂件状态 : " + $(if ($on) { '运行中 ✅' } else { '未运行' })) -ForegroundColor $(if ($on) { 'Green' } else { 'Yellow' })
    Write-Host ("数据目录 : $DataRoot")
    Write-Host ("事件日志 : $(Join-Path $DataRoot 'state\events.jsonl')")
    exit 0
}

$node = Find-Node
if (-not $node) {
    Write-Host "找不到 node.exe，无法发送提醒。" -ForegroundColor Red
    Write-Host "装一个 Node.js，或者把安装目录里的钩子改成用 node 的绝对路径。" -ForegroundColor DarkGray
    exit 1
}
if (-not (Test-Path -LiteralPath $Entry)) {
    Write-Host "找不到 $Entry" -ForegroundColor Red
    exit 1
}

if ($StartWidget -and -not (Get-WidgetState)) { Start-Widget }

function Send([string]$k, [string]$t, [string]$m, [bool]$silent) {
    $a = @($Entry, '--kind', $k)
    if ($t) { $a += @('--title', $t) }
    if ($m) { $a += @('--text', $m) }
    if ($silent) { $a += '--silent' }
    & $node @a | Out-Null
}

if ($Demo) {
    $on = Get-WidgetState
    if (-not $on) { Start-Widget }
    Write-Host "演示三种提醒（挂件没开也能听到声音）..." -ForegroundColor Cyan
    $samples = @(
        @('notify', '普通提醒', '这是一条普通提醒'),
        @('ask', '需要你确认', 'WorkBuddy 在等你授权（请求音）'),
        @('done', '任务完成', '这一轮已经跑完啦（完成音）')
    )
    foreach ($s in $samples) {
        Write-Host ("  ▶ " + $s[1]) -ForegroundColor Yellow
        Send $s[0] $s[1] $s[2] $false
        Start-Sleep -Milliseconds 900
        Start-Sleep -Milliseconds 1100
    }
    Write-Host "演示结束。" -ForegroundColor Green
    exit 0
}

Send $Kind $Title $Message ([bool]$Silent)
