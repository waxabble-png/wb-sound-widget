# 拖动/夹紧逻辑自检（纯算术，不依赖 GUI）
# 复刻 wb-widget.ps1 的夹紧公式，验证"靠边之后还能拖动"
$ErrorActionPreference = 'Stop'

[void][System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework')

$waL = 0.0; $waT = 0.0
$waR = [double][System.Windows.SystemParameters]::WorkArea.Right
$waB = [double][System.Windows.SystemParameters]::WorkArea.Bottom
if ($waR -le 0) { $waR = 1707.0 }
if ($waB -le 0) { $waB = 1067.0 }
$winW = 210.0

$lines = @()
$lines += ("工作区(DIP): x[{0}..{1}] y[{2}..{3}]   窗口宽={4}" -f $waL, $waR, $waT, $waB, $winW)
$lines += ""

function Clamp-Pos([double]$nx, [double]$ny) {
    $grab = [Math]::Max(72.0, [Math]::Min(120.0, $winW * 0.45))
    $minX = $waL - ($winW - $grab)
    $maxX = $waR - $grab
    $minY = $waT
    $maxY = $waB - $grab
    if ($nx -lt $minX) { $nx = $minX }
    if ($nx -gt $maxX) { $nx = $maxX }
    if ($ny -lt $minY) { $ny = $minY }
    if ($ny -gt $maxY) { $ny = $maxY }
    return @($nx, $ny)
}

$grab = [Math]::Max(72.0, [Math]::Min(120.0, $winW * 0.45))
$lines += ("夹紧余量 grab = {0}  →  允许 x∈[{1}..{2}]  y∈[{3}..{4}]" -f `
        $grab, [int]($waL - ($winW - $grab)), [int]($waR - $grab), [int]$waT, [int]($waB - $grab))
$lines += ""

$cases = @(
    @{ n = '往左狠拖';   x = -9999; y = 500 },
    @{ n = '往右狠拖';   x = 99999; y = 500 },
    @{ n = '往上狠拖';   x = 500;  y = -9999 },
    @{ n = '往下狠拖';   x = 500;  y = 99999 },
    @{ n = '停左边缘';   x = 0;    y = 500 },
    @{ n = '停右边缘';   x = $waR; y = 500 },
    @{ n = '正常位置';   x = 800;  y = 500 }
)
$lines += "拖动落点夹紧结果："
$ok = $true
foreach ($c in $cases) {
    $r = Clamp-Pos $c.x $c.y
    $rx = [int]$r[0]; $ry = [int]$r[1]
    # 关键：贴边后留在屏幕内的部分必须够宽/够高，鼠标还能点到
    $visW = [Math]::Min($winW, ($waR - $rx))
    $visH = [Math]::Min($winW, ($waB - $ry))
    $grabbable = ($visW -ge $grab -and $visH -ge $grab)
    if (-not $grabbable) { $ok = $false }
    $lines += ("  {0,-10} 输入({1,7},{2,6}) → 落点({3,6},{4,6})  露在屏内 {5}x{6}  可抓={7}" -f `
            $c.n, [int]$c.x, [int]$c.y, $rx, $ry, [int]$visW, [int]$visH, $grabbable)
}
$lines += ""
$lines += if ($ok) { "结论：全部用例贴边后仍可抓住 ✓ （修好了「靠边拖不动」）" }
         else { "结论：有用例贴边后抓不到 ✗" }

[System.IO.File]::WriteAllLines("$env:TEMP\clampcheck.txt", $lines, (New-Object System.Text.UTF8Encoding($false)))
