# 把 SessionStart / SessionEnd 两条钩子补进全局 settings.json
#  - 只增删含 wb-sound-widget 的钩子组，其它设置原样保留
#  - 写前备份
$ErrorActionPreference = 'Stop'

$SettingsPath = Join-Path $env:USERPROFILE '.workbuddy\settings.json'
$InstallDir   = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget'
$notify = (Join-Path $InstallDir 'hooks\notify.mjs') -replace '\\', '/'

if (-not (Test-Path -LiteralPath $SettingsPath)) { throw "找不到 $SettingsPath" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = "$SettingsPath.bak-wb-bind-$stamp"
Copy-Item -LiteralPath $SettingsPath -Destination $bak -Force

$raw = [System.IO.File]::ReadAllText($SettingsPath)
if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
$settings = $raw | ConvertFrom-Json

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value (New-Object psobject)
}
$hk = $settings.hooks

$plan = [ordered]@{
    'SessionStart' = @{ hint = 'session-start'; desc = 'WorkBuddy 启动 / 会话开始 → 拉起小鲸鱼挂件'; timeout = 15 }
    'SessionEnd'   = @{ hint = 'session-end';   desc = 'WorkBuddy 退出 / 会话结束 → 关掉小鲸鱼挂件'; timeout = 15 }
}

foreach ($evt in $plan.Keys) {
    $p = $plan[$evt]
    $keep = @()
    if ($hk.PSObject.Properties.Name -contains $evt) {
        foreach ($g in @($hk.$evt)) {
            $ours = $false
            if ($g -and $g.PSObject.Properties.Name -contains 'hooks') {
                foreach ($h in @($g.hooks)) {
                    if ($h -and $h.command -and ($h.command -like '*wb-sound-widget*')) { $ours = $true }
                }
            }
            if (-not $ours) { $keep += $g }
        }
    }
    $keep += [pscustomobject]@{
        hooks = @(
            [pscustomobject]@{
                type        = 'command'
                command     = ('node "' + $notify + '" ' + $p.hint)
                description = $p.desc
                async       = $true
                timeout     = $p.timeout
            }
        )
    }
    if ($hk.PSObject.Properties.Name -contains $evt) { $hk.$evt = @($keep) }
    else { $hk | Add-Member -MemberType NoteProperty -Name $evt -Value @($keep) }
}

$json = $settings | ConvertTo-Json -Depth 40
[System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))

$out = @()
$out += "已备份 -> $(Split-Path -Leaf $bak)"
$out += "当前全部钩子："
foreach ($evt in $hk.PSObject.Properties.Name) {
    foreach ($g in @($hk.$evt)) {
        foreach ($h in @($g.hooks)) {
            if ($h.command -like '*wb-sound-widget*') { $out += ("  {0,-18} {1}" -f $evt, $h.command) }
        }
    }
}
[System.IO.File]::WriteAllLines((Join-Path $env:TEMP 'hooksupdate.txt'), $out, (New-Object System.Text.UTF8Encoding($false)))
