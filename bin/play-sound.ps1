# wb-sound-widget —— 独立播放器（挂件没在运行时，由钩子直接调用）
# 支持 wav / mp3；用 WPF MediaPlayer 以便控制音量；失败则回退 SoundPlayer。
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [double]$Volume = 1.0,
    [int]$MaxWaitMs = 20000
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath $Path)) { exit 1 }
if ($Volume -lt 0) { $Volume = 0 }
if ($Volume -gt 1) { $Volume = 1 }

function Play-WithSoundPlayer {
    param([string]$File)
    try {
        $sp = New-Object System.Media.SoundPlayer $File
        $sp.PlaySync()
        return $true
    } catch {
        return $false
    }
}

$played = $false
try {
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    $mp = New-Object System.Windows.Media.MediaPlayer
    $mp.Volume = $Volume
    $mp.Open((New-Object System.Uri($Path)))
    $mp.Play()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPos = -1.0
    $stalled = 0
    while ($sw.ElapsedMilliseconds -lt $MaxWaitMs) {
        Start-Sleep -Milliseconds 60
        $pos = 0.0
        try { $pos = $mp.Position.TotalMilliseconds } catch { $pos = 0.0 }
        $dur = 0.0
        try { if ($mp.NaturalDuration.HasTimeSpan) { $dur = $mp.NaturalDuration.TimeSpan.TotalMilliseconds } } catch {}
        if ($dur -gt 0 -and $pos -ge ($dur - 60)) { break }
        if ([Math]::Abs($pos - $lastPos) -lt 0.5) {
            $stalled++
            # 起播后 1.5 秒内位置一直不动，说明这个格式 MediaPlayer 吃不下
            if ($stalled -gt 25 -and $pos -lt 1) { throw 'mediaplayer stalled' }
        } else {
            $stalled = 0
        }
        $lastPos = $pos
    }
    try { $mp.Stop(); $mp.Close() } catch {}
    $played = $true
} catch {
    $played = $false
}

if (-not $played) {
    # MediaPlayer 失败（极少见）：wav 走 SoundPlayer，mp3 就静默放弃
    if ($Path -match '\.wav$') { Play-WithSoundPlayer -File $Path | Out-Null }
}

exit 0
