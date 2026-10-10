# ============================================================================
#  wb-sound-widget —— 桌面悬浮小鲸鱼挂件
# ============================================================================
#  形象：小鲸鱼（assets/whale.png，与 DSH 小鲸鱼记账挂件同款）
#  作用：常驻桌面，收到事件时冒泡 + 播放对应提示音
#  事件来源：state/events.jsonl
#            · WorkBuddy / CodeBuddy 钩子写（hooks/notify.mjs）
#            · 任何程序都能写；命令行用 bin\wb-notify.cmd
#
#  交互：
#    左键拖动  移动位置（自动记住）
#    左键单击  冒泡（今日统计 + 随机台词）
#    右键      菜单（试听 / 静音 / 音量 / 换音效 / 气泡 / 大小 / 日志 / 退出）
#    托盘图标  同样的入口（挂件被挡住时用）
# ============================================================================
[CmdletBinding()]
param(
    [switch]$NoTray,

    # 调试用：把窗口渲染成 PNG 后退出（不需要桌面会话也能验证外观）
    [string]$SnapshotTo = '',
    [ValidateSet('idle', 'done', 'ask', 'status')][string]$SnapshotState = 'idle',
    # 调试用：启动时从头重放事件日志（配合 -SnapshotTo 验证轮询链路）
    [switch]$Replay,

    # 数据目录覆盖（优先级高于环境变量）。由 start-widget.vbs 从 WB_WIDGET_HOME 转发，
    # 这样"钩子写状态的地方"和"挂件读状态的地方"永远一致。
    [string]$DataHome = ''
)

$ErrorActionPreference = 'Stop'

trap {
    try {
        $lp = Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget\state\widget.log'
        $d = Split-Path -Parent $lp
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        [System.IO.File]::AppendAllText($lp, "FATAL $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $($_.Exception.ToString())`r`n")
    } catch {}
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Xaml, System.Drawing, System.Windows.Forms

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}

# 高 DPI，让挂件清晰
try {
    Add-Type -Namespace WbNative -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
'@
    [void][WbNative.Dpi]::SetProcessDpiAwareness(2)
} catch {}

# ---------------------------------------------------------------------- 单实例
$Mutex = New-Object System.Threading.Mutex($false, 'Local\wb-sound-widget-pet')
$IsNew = $false
try { $IsNew = $Mutex.WaitOne(0, $false) } catch { $IsNew = $true }
if (-not $IsNew) {
    # 已经有一个在跑 → 本次启动接管（把旧实例让出来）。
    # 为什么不让旧的继续跑：旧实例可能是在看不见的桌面/会话里被自动拉起来的，
    # 如果它一直占着互斥体，你手动双击就永远只能看到"已经在桌面上了"。
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' -and $_.ProcessId -ne $PID } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
    } catch {}
    try { $IsNew = $Mutex.WaitOne(3000, $false) } catch { $IsNew = $true }
    if (-not $IsNew) {
        try { [System.Windows.Forms.MessageBox]::Show('小鲸鱼已经在桌面上了，这次不重复启动～') } catch {}
        exit 0
    }
}

# WPF Application 必须最早创建
$App = New-Object System.Windows.Application
$App.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose

# ---------------------------------------------------------------------- 路径
#  $Root     = 包目录（代码/默认素材所在）
#  $DataRoot = 数据目录（配置 + 事件日志 + 心跳），固定一份，升级不丢
$Root       = Split-Path -Parent $PSScriptRoot
# 数据目录优先级：-DataHome 参数 > WB_WIDGET_HOME 环境变量 > 默认 ~/.workbuddy/wb-sound-widget
$DataRoot   = if ($DataHome) { $DataHome }
              elseif ($env:WB_WIDGET_HOME) { $env:WB_WIDGET_HOME }
              else { Join-Path $env:USERPROFILE '.workbuddy\wb-sound-widget' }
$StateDir   = Join-Path $DataRoot 'state'
$EventsFile = Join-Path $StateDir 'events.jsonl'
$AliveFile  = Join-Path $StateDir 'widget-alive'
$ConfigFile = Join-Path $DataRoot 'config.json'
$LogFile    = Join-Path $StateDir 'widget.log'
# 用户从菜单里主动退出时写这个标记，钩子看到它就不会再自动把挂件拉起来
$OffFile    = Join-Path $StateDir 'widget-off'
# WorkBuddy 会话心跳：SessionStart 钩子写下、SessionEnd 钩子删掉，挂件据此判断宿主还在不在
$script:WbSessionFile = Join-Path $StateDir 'wb-session'
$script:UserQuit = $false
# 被 WorkBuddy 生命周期带着退出（而不是用户手动关）——用来区分要不要留 widget-off 标记
$script:Bound = $false

if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

function Write-WidgetLog([string]$msg) {
    try {
        [System.IO.File]::AppendAllText($LogFile, "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $msg`r`n")
    } catch {}
}

# 手动启动 = "我要用它"，清掉上次的退出标记
try { if (Test-Path -LiteralPath $OffFile) { Remove-Item -LiteralPath $OffFile -Force } } catch {}

function Resolve-Asset([string]$rel) {
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }
    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel }
    $clean = $rel -replace '/', '\'
    $inData = Join-Path $DataRoot $clean
    if (Test-Path -LiteralPath $inData) { return $inData }
    return (Join-Path $Root $clean)
}

$WhalePng = Resolve-Asset 'widget/assets/whale.png'

# ⚠️ 鲸鱼图片带第三方版权、不入库（见 .gitignore / README 许可一节）。
#    没有它挂件就是一块透明的空白窗口，什么都看不见 —— 与其让人对着一无所知的空白发懵，
#    不如第一次启动就把话说明白：要自己放一张图，放哪，什么样的能用。
if (-not ($WhalePng -and (Test-Path -LiteralPath $WhalePng))) {
    Write-WidgetLog "缺鲸鱼图: $WhalePng -> 给出指引并退出"
    $msg = "没有找到小鲸鱼图片：`r`n`r`n    $WhalePng`r`n`r`n" +
           "这张图片带第三方版权，没有随仓库一起分发，需要你自己准备一张 PNG 放到上面这个路径。`r`n" +
           "要求：带透明背景、四周别留大块透明边（挂件会自动裁掉），方图或竖图都可以。`r`n`r`n" +
           "放好之后再启动一次挂件就能看到它了。"
    if (-not $SnapshotTo) {
        try {
            [System.Windows.Forms.MessageBox]::Show($msg, 'wb-sound-widget 缺少素材',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } catch {}
    }
    exit 1
}

# ---------------------------------------------------------------------- 配置
$DefaultConfig = [ordered]@{
    sound = [ordered]@{
        mute    = $false
        # ⚠️ 默认音效必须指向**随仓库分发**的自制音效（sounds/ 下那三枚）。
        #    sounds/presets/ 里的素材带版权、不入库，新 clone 的机器上根本没有这些文件，
        #    默认值指向它们会让别人 clone 完发现「任务完成不响」。
        #    想用预置音效的话，把文件放回 sounds/presets/ 再在配置里改过来即可。
        done    = [ordered]@{ enabled = $true; volume = 1.0;  file = 'sounds/task-done.wav' }
        ask     = [ordered]@{ enabled = $true; volume = 1.0;  file = 'sounds/need-attention.wav' }
        notify  = [ordered]@{ enabled = $true; volume = 0.9;  file = 'sounds/notify.wav' }
        # 按下 / 松手的轻响（d1.mp3 / d2.mp3 来自 DSH，MIT 协议，已随仓库分发）
        press   = [ordered]@{ enabled = $true; volume = 0.55; file = 'sounds/presets/d1.mp3' }
        release = [ordered]@{ enabled = $true; volume = 0.55; file = 'sounds/presets/d2.mp3' }
    }
    events   = [ordered]@{ done = $true; ask = $true; notify = $true }
    bubble   = [ordered]@{ autoCloseMs = 4600; showOnEvent = $true }
    widget   = [ordered]@{
        scale = 1.0; x = $null; y = $null; autoStart = $true
        # 贴左时是否自动水平镜像（面朝屏幕内）
        autoFlip = $true
        # 记住上次的朝向
        flipped = $null
        # 与 WorkBuddy 生命周期绑定：WorkBuddy 一退出就把挂件一起关掉
        bindToWorkBuddy = $true
    }
    dedupeMs = 1200
}

function Merge-Config($loaded) {
    $cfg = ($DefaultConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    if (-not $loaded) { return $cfg }
    foreach ($k in $loaded.PSObject.Properties.Name) {
        if (@('sound', 'events', 'bubble', 'widget') -contains $k) {
            foreach ($sk in $loaded.$k.PSObject.Properties.Name) { $cfg.$k.$sk = $loaded.$k.$sk }
        } else {
            $cfg.$k = $loaded.$k
        }
    }
    return $cfg
}

function Save-Config($cfg) {
    try {
        # 不带 BOM 的 UTF-8：钩子那边是 Node，JSON.parse 见到 BOM 会抛错
        $json = $cfg | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($ConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Load-Config {
    if (Test-Path -LiteralPath $ConfigFile) {
        try { return (Merge-Config ((Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8) | ConvertFrom-Json)) } catch {}
    }
    $c = Merge-Config $null
    Save-Config $c
    return $c
}

$Cfg = Load-Config

# ---------------------------------------------------------------------- 音效
$SoundCache = @{}

function Play-Asset([string]$rel, [double]$volume) {
    if ([string]::IsNullOrWhiteSpace($rel)) { return }
    $abs = Resolve-Asset $rel
    if (-not (Test-Path -LiteralPath $abs)) { return }
    try {
        if (-not $SoundCache.ContainsKey($abs)) {
            $mp = New-Object System.Windows.Media.MediaPlayer
            $mp.Open([System.Uri]$abs)
            $SoundCache[$abs] = $mp
        }
        $p = $SoundCache[$abs]
        $p.Stop()
        $p.Position = [TimeSpan]::Zero
        $p.Volume = [Math]::Max(0.0, [Math]::Min(1.0, $volume))
        $p.Play()
    } catch {}
}

function Play-Event([string]$kind) {
    if ($Cfg.sound.mute -eq $true) { return }
    $item = $Cfg.sound.$kind
    if (-not $item) { return }
    if ($item.enabled -eq $false) { return }
    Play-Asset ([string]$item.file) ([double]$item.volume)
}

# 预热默认音效，避免第一次触发有延迟
foreach ($k in @('done', 'ask', 'notify')) {
    $f = Resolve-Asset ([string]$Cfg.sound.$k.file)
    if ($f -and (Test-Path -LiteralPath $f)) {
        try {
            $mp = New-Object System.Windows.Media.MediaPlayer
            $mp.Open([System.Uri]$f)
            $SoundCache[$f] = $mp
        } catch {}
    }
}

# ---------------------------------------------------------------------- 界面
$BaseWidth = 210
$BaseWhale = 165

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="小鲸鱼挂件" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" ResizeMode="NoResize"
        Topmost="True" SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Grid x:Name="RootGrid" Background="{x:Null}">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 气泡 -->
    <Border x:Name="Bubble" Grid.Row="0" Visibility="Collapsed"
            Margin="4,0,4,2" Padding="11,8,11,9" VerticalAlignment="Bottom"
            CornerRadius="13" BorderThickness="1"
            Background="#F2FFFFFF" BorderBrush="#332F6FD8"
            RenderTransformOrigin="0.5,1">
      <Border.Effect>
        <DropShadowEffect BlurRadius="14" ShadowDepth="2" Direction="270" Opacity="0.22" Color="#FF1B3A66"/>
      </Border.Effect>
      <Border.RenderTransform>
        <TranslateTransform x:Name="BubbleShift" Y="10"/>
      </Border.RenderTransform>
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="BubbleDot" Width="8" Height="8" Fill="#FF2F6FD8" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBlock x:Name="BubbleTitle" FontFamily="Microsoft YaHei UI" FontSize="12.5"
                     FontWeight="Bold" Foreground="#FF13386B" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="BubbleText" FontFamily="Microsoft YaHei UI" FontSize="12"
                   Foreground="#FF2A3B4D" TextWrapping="Wrap" MaxWidth="186"
                   Margin="14,4,0,0" LineHeight="17"/>
        <Image x:Name="BubbleGif" MaxHeight="92" Margin="14,7,0,0"
               HorizontalAlignment="Left" Visibility="Collapsed" Stretch="Uniform"/>
      </StackPanel>
    </Border>

    <!-- 小鲸鱼 -->
    <Grid x:Name="PetHost" Grid.Row="1" RenderTransformOrigin="0.5,1" HorizontalAlignment="Center" Background="{x:Null}">
      <Grid.RenderTransform>
        <TransformGroup>
          <!-- ⚠️ 顺序要紧：先镜像(FlipScale)再按压(Scale)，否则按压方向会跟着被翻 -->
          <ScaleTransform x:Name="FlipScale" ScaleX="1" ScaleY="1"/>
          <ScaleTransform x:Name="PressScale" ScaleX="1" ScaleY="1"/>
        </TransformGroup>
      </Grid.RenderTransform>
      <Image x:Name="Pet" Stretch="Uniform" RenderTransformOrigin="0.5,1">
        <Image.RenderTransform>
          <ScaleTransform x:Name="BreathScale" ScaleX="1" ScaleY="1"/>
        </Image.RenderTransform>
      </Image>
    </Grid>
  </Grid>
</Window>
'@

$Win         = [System.Windows.Markup.XamlReader]::Parse($Xaml)
$Bubble      = $Win.FindName('Bubble')
$BubbleTitle = $Win.FindName('BubbleTitle')
$BubbleText  = $Win.FindName('BubbleText')
$BubbleGif   = $Win.FindName('BubbleGif')
$BubbleDot   = $Win.FindName('BubbleDot')
$BubbleShift = $Win.FindName('BubbleShift')
$PetHost     = $Win.FindName('PetHost')
$Pet         = $Win.FindName('Pet')
$FlipScale   = $Win.FindName('FlipScale')
$PressScale  = $Win.FindName('PressScale')
$BreathScale = $Win.FindName('BreathScale')

# 镜像动画跑完后把动画值落回属性（否则读 $FlipScale.ScaleX 会一直是动画起始值）
$script:FlipResolveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FlipResolveTimer.Interval = [TimeSpan]::FromMilliseconds(280)
$script:FlipResolveTimer.Add_Tick({
    $script:FlipResolveTimer.Stop()
    try {
        $v = [double]$FlipScale.ScaleX          # 读动画终止值
        $FlipScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $FlipScale.ScaleX = if ($v -lt 0) { -1.0 } else { 1.0 }
    } catch {}
})

# 鲸鱼图的"可见宽高比"。原图四圈有一堆全透明像素（whale.png 是 610x610，
# 但真正画着鲸鱼的只有左边 45px 之后的部分），如果直接按原图铺开，窗口里就会
# 白白多出一圈透明边 —— 拖到屏幕边缘时，**看得见的鲸鱼**永远差 20 多个 DIP 才到边，
# 用户看到的就是"右边边界和屏幕边界没对齐"。所以这里先把透明边裁掉。
$script:WhaleAspect = 1.0

if (Test-Path -LiteralPath $WhalePng) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.UriSource = [System.Uri]$WhalePng
    $bmp.EndInit()
    $bmp.Freeze()
    $Pet.Source = $bmp

    try {
        # 转成 Bgra32，好直接按字节读 alpha（每像素 4 字节，第 4 个是 alpha）
        $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap
        $conv.BeginInit()
        $conv.Source = $bmp
        $conv.DestinationFormat = [System.Windows.Media.PixelFormats]::Bgra32
        $conv.EndInit()
        $conv.Freeze()

        $iw = [int]$conv.PixelWidth
        $ih = [int]$conv.PixelHeight
        $stride = $iw * 4
        $px = New-Object 'byte[]' ($stride * $ih)
        $conv.CopyPixels($px, $stride, 0)

        # 从四条边往里找第一条"有内容"的行/列 —— 比全图扫描快得多
        # （透明边一般只有几十像素宽，扫几十列就停）
        $thr = 12          # alpha 阈值，忽略几乎全透明的边缘噪声
        $minX = 0
        while ($minX -lt $iw) {
            $col = $minX * 4 + 3
            $hit = $false
            for ($y = 0; $y -lt $ih; $y++) { if ($px[$y * $stride + $col] -gt $thr) { $hit = $true; break } }
            if ($hit) { break }
            $minX++
        }
        $maxX = $iw - 1
        while ($maxX -ge 0) {
            $col = $maxX * 4 + 3
            $hit = $false
            for ($y = 0; $y -lt $ih; $y++) { if ($px[$y * $stride + $col] -gt $thr) { $hit = $true; break } }
            if ($hit) { break }
            $maxX--
        }
        $minY = 0
        while ($minY -lt $ih) {
            $row = $minY * $stride
            $hit = $false
            for ($x = 3; $x -lt $stride; $x += 4) { if ($px[$row + $x] -gt $thr) { $hit = $true; break } }
            if ($hit) { break }
            $minY++
        }
        $maxY = $ih - 1
        while ($maxY -ge 0) {
            $row = $maxY * $stride
            $hit = $false
            for ($x = 3; $x -lt $stride; $x += 4) { if ($px[$row + $x] -gt $thr) { $hit = $true; break } }
            if ($hit) { break }
            $maxY--
        }

        if ($maxX -ge $minX -and $maxY -ge $minY -and ($maxX - $minX) -gt 8 -and ($maxY - $minY) -gt 8) {
            $cw = $maxX - $minX + 1
            $ch = $maxY - $minY + 1
            $rect = New-Object System.Windows.Int32Rect($minX, $minY, $cw, $ch)
            $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($conv, $rect)
            $crop.Freeze()
            $Pet.Source = $crop
            $script:WhaleAspect = [double]$cw / [double]$ch
            Write-WidgetLog "鲸鱼图 $iw x $ih -> 裁掉透明留白后 $cw x $ch  可见宽高比=$([Math]::Round($script:WhaleAspect,4))"
        } else {
            Write-WidgetLog "鲸鱼图 $iw x $ih 没量到有效内容，直接用原图"
        }
    } catch {
        try { Write-WidgetLog "鲸鱼图裁边失败，改用原图：$($_.Exception.Message)" } catch {}
    }
}

$script:BubbleVisible = $false
$script:BubbleExtra = 0
$script:WhaleHNow = $BaseWhale
$script:WhaleWNow = $BaseWidth

# ⚠️ 窗口尺寸 == 鲸鱼"看得见的"尺寸，一点不多。
#    以前窗口是 210 宽、鲸鱼只有 165，左右各多出 22.5 DIP 的透明边，
#    结果拖到屏幕边缘时窗口贴住了、**看得见的鲸鱼还差 22.5 DIP**，
#    看起来就是"右边边界没和屏幕边界对齐"。现在两者严格相等，贴边即贴边。
function Apply-Scale([double]$s) {
    if ($s -le 0) { $s = 1.0 }
    $script:WhaleHNow = [int]($BaseWhale * $s)
    $wW = [int][Math]::Round($script:WhaleHNow * $script:WhaleAspect)
    if ($wW -lt 60) { $wW = 60 }
    $script:WhaleWNow = $wW
    $Pet.Width = $wW
    $Pet.Height = $script:WhaleHNow
    $Win.Width = $wW
    if ($script:BubbleVisible) { $Win.Height = $script:WhaleHNow + $script:BubbleExtra }
    else { $Win.Height = $script:WhaleHNow }
}

# ---------------------------------------------------------------------- 镜像（翻转）
#  参考 DSH 小鲸鱼挂件的做法：贴左（越过翻转线）时整体水平镜像，朝向屏幕内侧；
#  自由摆放时按「小鲸鱼中心点」与翻转线比较决定朝向。
#  翻转必须带动画，直接把 ScaleX 从 1 跳到 -1 会很突兀，所以用 DoubleAnimation 过渡。
#  ⚠️ 这两个函数必须定义在"算初始位置"之前 —— 下面初始化朝向时会调用 Should-Flip。
#  ⚠️ $FlipScale 是上面 XAML 里取出来的那个 ScaleTransform，这里**不能**再赋值，
#     否则会把元素引用覆盖成 $null，翻转就静默失效了。
$script:Flipped = $false

function Apply-Flip([bool]$flip, [bool]$animate = $true) {
    if (-not $FlipScale) { return }
    $target = if ($flip) { -1.0 } else { 1.0 }
    $cur = [double]$FlipScale.ScaleX
    if ([Math]::Abs($cur - $target) -lt 0.01) {
        $FlipScale.ScaleX = $target
        return
    }
    # 从当前值动画到目标值（1 → -1 会经过 0，视觉上就是"转了个身"）
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation($cur, $target, [TimeSpan]::FromMilliseconds(240))
    $anim.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $anim.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $FlipScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $anim)
    try {
        # 动画结束后把值落回属性本身，免得后续读取拿到旧值
        $script:FlipResolveTimer.Stop()
        $script:FlipResolveTimer.Start()
    } catch {}
}

# 自由摆放时的翻转线：屏幕水平中点。落点在该线左侧 → 镜像（面朝屏幕内右侧）
function Should-Flip([double]$left) {
    $cx = $left + ([double]$Win.Width / 2.0)
    return ($cx -lt ($script:WpfWork.Left + ($script:WpfWork.Width / 2.0)))
}

# ---------------------------------------------------------------------- 夹紧
#  ⚠️ 需求是"拖到边缘就别跳出桌面"，所以这里是**硬夹紧**：窗口四条边都不许越出工作区。
#     之前为了"贴边还能抓住"故意留了 grab 余量、允许窗口露出一部分到屏幕外 —— 那是错的方向，
#     用户要的是干脆不出屏。窗口完整留在屏内，本来就有整个窗口可抓，不存在抓不到的问题。
#  ⚠️ 单位：$Win.Left/Top 是 DIP，$script:WpfWork 也是 DIP，直接比较。
function Get-ClampedPos([double]$x, [double]$y) {
    $wa = $script:WpfWork
    $w  = [double]$Win.Width
    $h  = [double]$Win.Height
    if ($w -le 0) { $w = [double]$script:WhaleWNow }
    if ($h -le 0) { $h = [double]$script:WhaleHNow }
    $minX = $wa.Left
    $maxX = $wa.Right - $w
    $minY = $wa.Top
    $maxY = $wa.Bottom - $h
    # 工作区比窗口还小时（极端分辨率），退化为居中，避免 min>max
    if ($maxX -lt $minX) { $minX = $wa.Left; $maxX = $wa.Left + [Math]::Max(0, ($wa.Width - $w)) }
    if ($maxY -lt $minY) { $minY = $wa.Top;  $maxY = $wa.Top  + [Math]::Max(0, ($wa.Height - $h)) }
    if ($x -lt $minX) { $x = $minX }
    if ($x -gt $maxX) { $x = $maxX }
    if ($y -lt $minY) { $y = $minY }
    if ($y -gt $maxY) { $y = $maxY }
    return New-Object System.Windows.Point($x, $y)
}

# ⚠️ 单位坑：WPF 的 Window.Left/Top 用的是 **DIP**，而 WinForms 的 Screen 给的是 **物理像素**，
#    两者差一个 DPI 缩放（125% 缩放时差 1.25 倍）。混用会把窗口丢到屏幕外面去 —— 现象就是"挂件明明在跑，但看不见"。
#    WPF 自己的 SystemParameters.WorkArea 就是 DIP，默认位置直接用它，最稳。
$waPhys = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$waWpf = [System.Windows.SystemParameters]::WorkArea
$dpiScale = if ($waWpf.Width -gt 0) { [double]$waPhys.Width / [double]$waWpf.Width } else { 1.0 }
if ($dpiScale -lt 0.2 -or $dpiScale -gt 8) { $dpiScale = 1.0 }
$script:WpfWork = $waWpf
$script:DpiScale = $dpiScale

# 默认落点：右下角。宽高都要用"裁掉透明边之后的真实尺寸"算，
# 否则右下角也会留出那圈透明边（和贴边问题同源）。
$defScale = [double]$Cfg.widget.scale
if ($defScale -le 0) { $defScale = 1.0 }
$defH = [int]($BaseWhale * $defScale)
$defW = [int][Math]::Round($defH * $script:WhaleAspect)
if ($defW -lt 60) { $defW = 60 }
$defX = $waWpf.Right - $defW - 24
$defY = $waWpf.Bottom - $defH - 12

$px = $Cfg.widget.x
$py = $Cfg.widget.y
if ($null -eq $px -or "$px" -eq '' -or $null -eq $py -or "$py" -eq '') { $px = $defX; $py = $defY }

# 存的坐标可能因为换显示器 / 改分辨率 / 改缩放跑到屏幕外 —— 检查一遍，不合理就回右下角
$onScreen = $false
try {
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $r = $scr.WorkingArea
        $l = [double]$r.Left / $dpiScale
        $t = [double]$r.Top / $dpiScale
        $rr = [double]$r.Right / $dpiScale
        $bb = [double]$r.Bottom / $dpiScale
        if ($px -ge ($l - 40) -and $px -le ($rr - 40) -and
            $py -ge ($t - 40) -and $py -le ($bb - 40)) { $onScreen = $true; break }
    }
} catch { $onScreen = $true }
if (-not $onScreen) { $px = $defX; $py = $defY }

Apply-Scale ([double]$Cfg.widget.scale)
# ⚠️ 统一走硬夹紧：无论存的位置哪来的，落到屏幕上时一定完整在屏内
$initPos = Get-ClampedPos ([double]$px) ([double]$py)
$Win.Left = $initPos.X
$Win.Top = $initPos.Y

# 恢复上次的朝向；没有记录或开了 autoFlip 但位置变了就按当前位置重算
$initFlip = $false
if ($Cfg.widget.autoFlip -ne $false) {
    if ($null -ne $Cfg.widget.flipped) { $initFlip = [bool]$Cfg.widget.flipped }
    else { $initFlip = Should-Flip ([double]$px) }
} elseif ($null -ne $Cfg.widget.flipped) {
    $initFlip = [bool]$Cfg.widget.flipped
}
$script:Flipped = $initFlip
if ($FlipScale) { $FlipScale.ScaleX = if ($initFlip) { -1.0 } else { 1.0 } }

# 把"我把自己放在哪了"记一笔，出问题时直接看 widget.log
try {
    $scrDesc = @()
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $scr.Bounds
        $scrDesc += "$($scr.DeviceName)=[$($b.X),$($b.Y) $($b.Width)x$($b.Height)]$(if ($scr.Primary) { '(主)' })"
    }
    $mySess = try { (Get-Process -Id $PID).SessionId } catch { '?' }
    Write-WidgetLog "启动 pid=$PID 会话=$mySess 落点=$([int]$Win.Left),$([int]$Win.Top) 尺寸=$([int]$Win.Width)x$([int]$Win.Height) 缩放=$dpiScale 镜像=$script:Flipped 翻转线=$([int]($script:WpfWork.Left + $script:WpfWork.Width / 2)) 屏幕: $($scrDesc -join ' | ')"
} catch {}

# ---------------------------------------------------------------------- 气泡
$BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
$GifTimer = New-Object System.Windows.Threading.DispatcherTimer
$GifTimer.Interval = [TimeSpan]::FromMilliseconds(90)
$script:GifFrames = @()
$script:GifIndex = 0

function Stop-Bubble {
    if (-not $script:BubbleVisible) { return }
    $script:BubbleVisible = $false
    $BubbleTimer.Stop()
    $GifTimer.Stop()
    $delta = $script:BubbleExtra
    $Bubble.Visibility = 'Collapsed'
    $BubbleShift.Y = 10
    $Win.Height = $script:WhaleHNow
    # 气泡收起 → 窗口变矮，把刚才为气泡让出的高度还回去。
    # ⚠️ 用统一的硬夹紧，保证收泡后窗口仍在屏内；也不单独碰左边，避免冒泡/收泡时横向漂移。
    $tgt = Get-ClampedPos $Win.Left ($Win.Top + $delta)
    $Win.Left = $tgt.X
    $Win.Top = $tgt.Y
}

function Show-Bubble {
    param(
        [string]$Title,
        [string]$Text,
        [string]$Accent = '#FF2F6FD8',
        [string]$Gif = '',
        [int]$AutoCloseMs = 0
    )
    $BubbleTitle.Text = $Title
    $BubbleText.Text = $Text
    try {
        $BubbleDot.Fill = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($Accent))
    } catch {}

    # 动图
    $GifTimer.Stop()
    $script:GifFrames = @()
    $BubbleGif.Visibility = 'Collapsed'
    if ($Gif) {
        $gp = Resolve-Asset $Gif
        if ($gp -and (Test-Path -LiteralPath $gp)) {
            try {
                $dec = New-Object System.Windows.Media.Imaging.GifBitmapDecoder(
                    [System.Uri]$gp,
                    [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                # BitmapFrameDecode 本身就是 ImageSource，直接当帧用即可
                foreach ($fr in $dec.Frames) { $script:GifFrames += $fr }
                if ($script:GifFrames.Count -gt 0) {
                    $script:GifIndex = 0
                    $BubbleGif.Source = $script:GifFrames[0]
                    $BubbleGif.Visibility = 'Visible'
                    if ($script:GifFrames.Count -gt 1) { $GifTimer.Start() }
                }
            } catch {}
        }
    }

    # 量出气泡需要多高（不影响窗口），再把窗口撑开、鲸鱼位置保持不动
    $Bubble.Visibility = 'Visible'
    $availW = [Math]::Max(120, $Win.Width - 12)
    $Bubble.Measure((New-Object System.Windows.Size($availW, [double]::PositiveInfinity)))
    $extra = [int][Math]::Ceiling($Bubble.DesiredSize.Height) + 6
    if ($extra -lt 40) { $extra = 90 }

    $oldExtra = $script:BubbleExtra
    $script:BubbleExtra = $extra
    $script:BubbleVisible = $true
    $Win.Height = $script:WhaleHNow + $extra
    # 气泡从下方长出 → 窗口向上撑开，用统一夹紧保证不越出屏幕（含底部与顶部）
    $tgt = Get-ClampedPos $Win.Left ($Win.Top - ($extra - $oldExtra))
    $Win.Left = $tgt.X
    $Win.Top = $tgt.Y

    # 淡入 + 上滑
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(170))
    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation(10.0, 0.0, [TimeSpan]::FromMilliseconds(190))
    $slide.EasingFunction = New-Object System.Windows.Media.Animation.BackEase
    $Bubble.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $BubbleShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)

    $BubbleTimer.Stop()
    $ms = if ($AutoCloseMs -gt 0) { $AutoCloseMs } else { [int]$Cfg.bubble.autoCloseMs }
    if ($ms -gt 0) {
        $BubbleTimer.Interval = [TimeSpan]::FromMilliseconds($ms)
        $BubbleTimer.Start()
    }
}

$BubbleTimer.Add_Tick({ Stop-Bubble })
$GifTimer.Add_Tick({
    if ($script:GifFrames.Count -gt 1) {
        $script:GifIndex = ($script:GifIndex + 1) % $script:GifFrames.Count
        $BubbleGif.Source = $script:GifFrames[$script:GifIndex]
    }
})

# ---------------------------------------------------------------------- 台词
$Quips = @(
    '今天也一起把它做完吧～'
    '有需要就叫我，我一直在这儿'
    '喝口水，顺便看看远处'
    '唔…刚才那件事好像挺难的'
    '记得保存一下手头的活儿哦'
    '小鲸鱼在旁边看着呢'
    '下一件事准备开始了嘛？'
)

# ---------------------------------------------------------------------- 事件
$script:EventsOffset = 0
if ((Test-Path -LiteralPath $EventsFile) -and -not $Replay) {
    try { $script:EventsOffset = (New-Object System.IO.FileInfo($EventsFile)).Length } catch { $script:EventsOffset = 0 }
}

$script:StatDone = 0
$script:StatAsk = 0
$script:StatNotify = 0
$script:TotalDone = 0
$script:TotalAsk = 0

try {
    if (Test-Path -LiteralPath $EventsFile) {
        foreach ($line in [System.IO.File]::ReadLines($EventsFile)) {
            if ($line -match '"kind"\s*:\s*"done"') { $script:TotalDone++ }
            elseif ($line -match '"kind"\s*:\s*"ask"') { $script:TotalAsk++ }
        }
    }
} catch {}

function Read-NewEvents {
    if (-not (Test-Path -LiteralPath $EventsFile)) { return @() }
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($EventsFile, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -lt $script:EventsOffset) { $script:EventsOffset = 0 }
        if ($fs.Length -le $script:EventsOffset) { return @() }
        $len = [int]($fs.Length - $script:EventsOffset)
        $bytes = New-Object byte[] $len
        [void]$fs.Seek($script:EventsOffset, [System.IO.SeekOrigin]::Begin)
        [void]$fs.Read($bytes, 0, $len)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $lastNl = $text.LastIndexOf("`n")
        if ($lastNl -lt 0) { return @() }
        $complete = $text.Substring(0, $lastNl + 1)
        $script:EventsOffset += [System.Text.Encoding]::UTF8.GetByteCount($complete)
        $out = New-Object System.Collections.ArrayList
        foreach ($line in ($complete -split "`n")) {
            $t = $line.Trim()
            if ($t) { try { [void]$out.Add(($t | ConvertFrom-Json)) } catch {} }
        }
        return $out
    } catch {
        return @()
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Write-WidgetLog([string]$msg) {
    try {
        [System.IO.File]::AppendAllText($LogFile, "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $msg`r`n")
    } catch {}
}

function Handle-Event($ev) {
    if (-not $ev) { return }
    $kind = [string]$ev.kind
    if ([string]::IsNullOrEmpty($kind)) { $kind = 'notify' }
    if ($Cfg.events.$kind -eq $false) {
        Write-WidgetLog "skip  kind=$kind（该类事件已关闭）"
        return
    }
    switch ($kind) {
        'done' {
            $script:StatDone++; $script:TotalDone++
            Play-Event 'done'
            if ($Cfg.bubble.showOnEvent -ne $false) {
                Show-Bubble -Title ([string]$ev.title) -Text ([string]$ev.text) -Accent '#FF1FA971' -Gif 'widget/assets/rua.gif'
            }
        }
        'ask' {
            $script:StatAsk++; $script:TotalAsk++
            Play-Event 'ask'
            if ($Cfg.bubble.showOnEvent -ne $false) {
                Show-Bubble -Title ([string]$ev.title) -Text ([string]$ev.text) -Accent '#FFE0870B' -Gif 'widget/assets/petpet.gif'
            }
        }
        default {
            $script:StatNotify++
            Play-Event 'notify'
            if ($Cfg.bubble.showOnEvent -ne $false) {
                Show-Bubble -Title ([string]$ev.title) -Text ([string]$ev.text) -Accent '#FF2F6FD8'
            }
        }
    }
    $muted = if ($Cfg.sound.mute -eq $true) { '静音中' } else { '已播放' }
    Write-WidgetLog "event kind=$kind 音效=$muted 标题=$([string]$ev.title)"
}

$script:LastBeat = [DateTime]::MinValue

# ---------------------------------------------------------------------- 与 WorkBuddy 绑定
#  钩子里挂了 SessionStart → 启动挂件、SessionEnd → 关掉挂件（正常路径）。
#  但钩子只在「会话正常结束」时可靠；WorkBuddy 被强杀 / 崩溃 / 从任务管理器结束进程时
#  SessionEnd 不一定跑得到。所以这里再做一层兜底：
#      · 会话心跳文件 state/wb-session 由 SessionStart 钩子写下，
#        并且**每次普通钩子（Stop / Notification / …）都会刷新它的 mtime**；
#      · 挂件每隔几秒看一次：绑定开着、且心跳**超过阈值没被刷新**，
#        说明 WorkBuddy 那边的钩子已经不跑了（进程没了 / 被强杀）→ 挂件自己也退。
#  ⚠️ 只判断"文件存不存在"是不够的：WorkBuddy 主进程常年有好几个，
#     单看进程名永远为真，兜底就永远不会触发。必须看**新鲜度**。
$script:WbGraceUntil = [DateTime]::Now.AddSeconds(15)   # 启动后给 15 秒宽限，别自己没站稳就退出
$script:WbSeenHeartbeat = $false
$script:WbAttached = $false    # 是否曾经确认过 WorkBuddy 在跑
$script:WbClosing = $false     # 已经在退了，别再重复触发
$script:WbMissCount = 0        # 连续几次看不到 WorkBuddy 进程（防一次查询抽风就误关）
$script:WbSessionStaleSec = 180  # 心跳多久没刷新算"宿主已停"（3 分钟）

function Test-WorkBuddyRunning {
    # 1) 进程名匹配（主进程 + CLI 子进程都算）
    try {
        foreach ($n in @('WorkBuddy', 'workbuddy', 'codebuddy')) {
            $ps = Get-Process -Name $n -ErrorAction SilentlyContinue
            if ($ps) { return $true }
        }
    } catch {}
    return $false
}

# 会话心跳是否"新鲜"。返回 $true 表示宿主还活着。
function Test-SessionFresh {
    try {
        if (-not (Test-Path -LiteralPath $script:WbSessionFile)) { return $false }
        $age = ([DateTime]::Now - (Get-Item -LiteralPath $script:WbSessionFile).LastWriteTime).TotalSeconds
        if ($age -lt 0) { $age = 0 }
        return ($age -lt $script:WbSessionStaleSec)
    } catch { return $false }
}

$PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$PollTimer.Add_Tick({
    try { foreach ($e in (Read-NewEvents)) { Handle-Event $e } } catch {}
    try {
        if ([DateTime]::Now - $script:LastBeat -gt [TimeSpan]::FromSeconds(2)) {
            [System.IO.File]::WriteAllText($AliveFile, "$PID|$([DateTime]::Now.Ticks)")
            $script:LastBeat = [DateTime]::Now
        }
    } catch {}
})

# 单独一个慢速定时器盯 WorkBuddy 的死活（5 秒一次，够快又不费 CPU）
$script:WbWatchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WbWatchTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:WbWatchTimer.Add_Tick({
    if ($script:WbClosing) { return }
    if ($Cfg.widget.bindToWorkBuddy -eq $false) { return }
    if ([DateTime]::Now -lt $script:WbGraceUntil) { return }

    $hasHeart = $false
    try { $hasHeart = Test-Path -LiteralPath $script:WbSessionFile } catch {}

    # 1) 心跳新鲜 → 宿主活着，记下"确实绑定过"
    if (Test-SessionFresh) {
        $script:WbSeenHeartbeat = $true
        $script:WbAttached = $true
        $script:WbMissCount = 0
        return
    }

    # 只有"曾经确认过 WorkBuddy 在跑"才跟着退，避免单独当桌面宠物用时被误关
    if (-not ($script:WbAttached -or $script:WbSeenHeartbeat)) { return }

    # 2) 心跳文件**不见了** —— 这是 SessionEnd 的明确信号（那个钩子第一件事就是删掉它），
    #    说明会话真的结束了。这时**不要再等进程**：WorkBuddy 退出时经常会残留
    #    几个进程，旧逻辑"进程还在就再等等"会一直等下去，挂件永远不退。
    if (-not $hasHeart) {
        $script:WbClosing = $true
        Write-WidgetLog "会话心跳已被 SessionEnd 删除 → 挂件随之退出"
        $script:UserQuit = $false
        $script:Bound = $true
        try { $Win.Close() } catch {}
        return
    }

    # 3) 心跳文件还在但已经不新鲜 —— 也可能只是长时间没触发钩子（空闲中），
    #    所以**不能只看心跳**，还要看进程。而且要连续几次都看不见才算，避免
    #    某一次查询抽风就把挂件误关了。
    if (Test-WorkBuddyRunning) { $script:WbMissCount = 0; return }
    $script:WbMissCount++
    if ($script:WbMissCount -ge 3) {
        $script:WbClosing = $true
        Write-WidgetLog "连续 $($script:WbMissCount) 次都找不到 WorkBuddy 进程（心跳也已陈旧）→ 挂件随之退出"
        $script:UserQuit = $false
        $script:Bound = $true
        try { $Win.Close() } catch {}
    }
})
$script:WbWatchTimer.Start()

# ---------------------------------------------------------------------- 拖动 / 点击
#（Apply-Flip / Should-Flip 已在上面「镜像」一节定义，必须早于初始位置计算）
$script:Drag = $false
$script:Moved = $false
$script:DragStart = $null      # 按下瞬间，指针在「屏幕 DIP 坐标系」里的位置
$script:WinStart = $null       # 按下瞬间的窗口左上角（DIP）
$script:DragBeginPointer = $null  # 本次拖动最开始的指针位置（全程不动，用于跟手自检）
$script:DragBeginWin = $null      # 本次拖动最开始的窗口位置（全程不动，用于跟手自检）
$script:DragLastPointer = $null   # 最近一次 MouseMove 时的指针位置
$script:DragClamped = $false      # 本次拖动有没有被硬夹紧过（决定跟手自检的比值是否适用）
$script:Squish = 0.90          # 按下时的缩小比例

# ⚠️ 指针坐标换算（"拖动跟手"的关键 —— 这里之前一直是错的）
#
#  ❌ 千万、千万不要拿 $mouseArgs.GetPosition($null) 当"屏幕坐标"用！
#     它返回的是**相对于窗口**的坐标（而且本来就是 DIP）。
#     而拖动算法是「窗口起点 + 指针位移」，一旦喂进去的是"相对窗口"的坐标：
#         dx = 屏幕位移 - 窗口位移   （窗口自己在动，把相对位移抵消掉了一部分）
#         → 解出来  窗口位移 = 屏幕位移 / 2.5
#     也就是**窗口只走指针的四成**，还形成负反馈 —— 怎么拖都黏在后面追不上。
#     这就是"不跟手"的真正原因（比单纯 DPI 换算错要离谱得多）。
#
#  ✅ 正确做法：拿真正的**屏幕**坐标。
#     WinForms 的 Cursor.Position 给的就是屏幕物理像素（本进程已声明 DPI 感知）；
#     再用 WPF 官方的 TransformFromDevice 逆矩阵换成该窗口所在的 DIP 空间。
#     起点和终点用同一个变换，位移就是准的 —— 1:1 跟手。
function Convert-PhysPointToDip([System.Windows.Point]$phys, $visual) {
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($visual)
        if ($src -and $src.CompositionTarget) {
            $m = $src.CompositionTarget.TransformFromDevice
            return $m.Transform($phys)   # 物理 -> DIP，按该窗口实际 DPI
        }
    } catch {}
    $s = $script:DpiScale
    if (-not $s -or $s -le 0) { $s = 1.0 }
    return New-Object System.Windows.Point(($phys.X / $s), ($phys.Y / $s))
}

# 取"屏幕坐标系"下的指针位置并转成 DIP（真正能让拖动跟手的那个坐标）
function Get-PointerDip($element, $mouseArgs) {
    # 1) 首选：把"相对元素"的点用 PointToScreen 映射回屏幕，再转成 DIP。
    #    这一对（GetPosition + PointToScreen + TransformFromDevice）都是 WPF 自己
    #    的换算，天然自洽，不受"进程 DPI 感知方式"影响。注意 GetPosition/PointToScreen
    #    必须用**同一个元素**，这样镜像（RenderTransform 翻转）会自己抵消掉。
    try {
        $rel  = $mouseArgs.GetPosition($element)
        $phys = $element.PointToScreen($rel)
        return Convert-PhysPointToDip $phys $element
    } catch {}
    # 2) 兜底：WinForms 的 Cursor.Position（也是屏幕物理像素；前提是进程已 DPI 感知）
    try {
        $pos = [System.Windows.Forms.Cursor]::Position
        return Convert-PhysPointToDip (New-Object System.Windows.Point([double]$pos.X, [double]$pos.Y)) $Win
    } catch {}
    return New-Object System.Windows.Point(0, 0)
}

$PetHost.Add_MouseLeftButtonDown({
    param($s, $e)
    $script:Drag = $true
    $script:Moved = $false
    $script:DragStart = Get-PointerDip $PetHost $e
    $script:WinStart = New-Object System.Windows.Point($Win.Left, $Win.Top)
    # 这两个是"全程不动"的基准，只用来在松手时核对"指针走了多少 / 窗口走了多少"
    $script:DragBeginPointer = $script:DragStart
    $script:DragBeginWin = $script:WinStart
    $script:DragClamped = $false
    [void]$PetHost.CaptureMouse()
    $PressScale.ScaleX = $script:Squish
    $PressScale.ScaleY = $script:Squish
    Play-Event 'press'
    # 窗内偏移 = 屏幕指针 - 窗口左上角，应该落在 [0..宽, 0..高] 之内。
    # 这是个自检：如果它又变成 0 附近的奇怪小数，说明指针坐标系又用错了。
    Write-WidgetLog ("拖动开始 屏幕指针(DIP)={0:N1},{1:N1} 窗口(DIP)={2:N1},{3:N1} 窗内偏移={4:N1},{5:N1} 尺寸={6}x{7} 工作区={8}x{9}" -f `
        $script:DragStart.X, $script:DragStart.Y, $Win.Left, $Win.Top, `
        ($script:DragStart.X - $Win.Left), ($script:DragStart.Y - $Win.Top), `
        $Win.Width, $Win.Height, $script:WpfWork.Width, $script:WpfWork.Height)
    $e.Handled = $true
})

$PetHost.Add_MouseMove({
    param($s, $e)
    if (-not $script:Drag) { return }

    # 松手但没收到 MouseUp（指针被别的窗口抢走）时自愈
    if (-not ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed)) {
        try { $script:EndDrag.Invoke($false) } catch {}
        return
    }

    $cur = Get-PointerDip $PetHost $e
    $script:DragLastPointer = $cur
    $dx = $cur.X - $script:DragStart.X
    $dy = $cur.Y - $script:DragStart.Y
    if ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3) { $script:Moved = $true }

    # 目标位置 = 按下时的窗口位置 + 指针位移，再过硬夹紧。
    # ⚠️ 关键：夹紧"吃掉"的那段位移必须立刻算清 —— 把拖动基准重置到当前
    #    指针 / 窗口位置。否则被吃掉的那段位移会一直欠着：顶到边缘后再往回拖，
    #    指针得先把"多走出去的那段"原路走完窗口才动，手感就是「贴边就拖不动了」。
    $rawX = $script:WinStart.X + $dx
    $rawY = $script:WinStart.Y + $dy
    $tgt = Get-ClampedPos $rawX $rawY
    $Win.Left = $tgt.X
    $Win.Top = $tgt.Y
    if ([Math]::Abs($tgt.X - $rawX) -gt 0.01 -or [Math]::Abs($tgt.Y - $rawY) -gt 0.01) {
        $script:WinStart = New-Object System.Windows.Point($tgt.X, $tgt.Y)
        $script:DragStart = $cur
        $script:DragClamped = $true
    }

    # 拖动途中就实时预览翻转（不带动画，跟手才自然）
    $should = Should-Flip $tgt.X
    if ($should -ne $script:Flipped) {
        $script:Flipped = $should
        if ($FlipScale) { $FlipScale.ScaleX = if ($should) { -1.0 } else { 1.0 } }
        Write-WidgetLog "拖动中翻转 镜像=$should 窗口X=$([int]$tgt.X)"
    }
})

$script:EndDrag = {
    param([bool]$clickAllowed = $true)
    if (-not $script:Drag) { return }
    $script:Drag = $false
    try { [void]$PetHost.ReleaseMouseCapture() } catch {}
    $PressScale.ScaleX = 1
    $PressScale.ScaleY = 1
    Play-Event 'release'

    if ($script:Moved) {
        # 松手后再夹一次（气泡收起/尺寸变化都可能让窗口越界），并确认朝向
        $tgt = Get-ClampedPos $Win.Left $Win.Top
        $Win.Left = $tgt.X
        $Win.Top = $tgt.Y
        $should = Should-Flip $tgt.X
        $script:Flipped = $should
        Apply-Flip $should $true
        $Cfg.widget.x = [Math]::Round($tgt.X, 2)
        $Cfg.widget.y = [Math]::Round($tgt.Y, 2)
        $Cfg.widget.flipped = [bool]$should
        Save-Config $Cfg
        # 跟手自检：把"指针总共走了多少"和"窗口总共走了多少"并排记下来。
        # ⚠️ 只有**全程没被夹紧**时，"窗口位移 / 指针位移"才该等于 1。
        #    一旦中途顶到屏幕边缘，窗口会被硬夹住不再走，比值自然掉到 0 附近 —— 那是**正常的**。
        #    所以这里把"有没有被夹紧"一起记下来，免得看到 0.01 就以为又不跟手了。
        $pDx = 0.0; $pDy = 0.0
        try {
            $pDx = $script:DragLastPointer.X - $script:DragBeginPointer.X
            $pDy = $script:DragLastPointer.Y - $script:DragBeginPointer.Y
        } catch {}
        $wDx = $tgt.X - $script:DragBeginWin.X
        $wDy = $tgt.Y - $script:DragBeginWin.Y
        if ($script:DragClamped) {
            Write-WidgetLog ("拖动结束 落点={0},{1} 镜像={2} | 跟手自检: 指针位移={3:N1},{4:N1} 窗口位移={5:N1},{6:N1} —— 本次贴过边被夹紧，比值不适用（顶到边缘就该停住）" -f `
                [int]$tgt.X, [int]$tgt.Y, $should, $pDx, $pDy, $wDx, $wDy)
        } else {
            $ratio = 1.0
            if ([Math]::Abs($pDx) -gt 1) { $ratio = $wDx / $pDx }
            Write-WidgetLog ("拖动结束 落点={0},{1} 镜像={2} | 跟手自检: 指针位移={3:N1},{4:N1} 窗口位移={5:N1},{6:N1} 比值={7:N2} (未夹紧，应≈1.00)" -f `
                [int]$tgt.X, [int]$tgt.Y, $should, $pDx, $pDy, $wDx, $wDy, $ratio)
        }
    } else {
        if ($clickAllowed) { Show-Status }
    }
}

$PetHost.Add_MouseLeftButtonUp({
    param($s, $e)
    $script:EndDrag.Invoke($true)
    $e.Handled = $true
})

# 指针跑出窗口 / 被抢走时别让拖动状态卡住（卡住 = 之后再也拖不动）
$PetHost.Add_LostMouseCapture({
    param($s, $e)
    if ($script:Drag) { $script:EndDrag.Invoke($false) }
})

function Show-Status {
    $quip = $Quips[(Get-Random -Minimum 0 -Maximum $Quips.Count)]
    $txt = "今天：完成 $($script:StatDone) · 待确认 $($script:StatAsk) · 提醒 $($script:StatNotify)`n" +
           "累计：完成 $($script:TotalDone) · 待确认 $($script:TotalAsk)`n`n" + $quip
    Show-Bubble -Title '小鲸鱼' -Text $txt -Accent '#FF2F6FD8'
}

# ---------------------------------------------------------------------- 菜单
function New-MenuItem {
    param([string]$Header, $OnClick = $null, [bool]$IsCheck = $false, [bool]$Checked = $false, $Tag = $null)
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $Header
    if ($Tag -ne $null) { $mi.Tag = $Tag }
    if ($IsCheck) { $mi.IsCheckable = $true; $mi.IsChecked = $Checked }
    if ($OnClick) { $mi.Add_Click($OnClick) }
    return $mi
}

function Get-SoundList {
    $seen = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($base in @($DataRoot, $Root)) {
        $dir = Join-Path $base 'sounds'
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -Include *.wav, *.mp3 -ErrorAction SilentlyContinue)) {
            $rel = ($f.FullName.Substring($base.Length + 1) -replace '\\', '/')
            if ($seen.ContainsKey($rel)) { continue }
            $seen[$rel] = $true
            $label = if ($f.Directory.Name -eq 'sounds') { $f.Name } else { "$($f.Directory.Name)/$($f.Name)" }
            [void]$list.Add([pscustomobject]@{ Rel = $rel; Label = $label })
        }
    }
    return $list
}

function Build-Menu {
    $m = New-Object System.Windows.Controls.ContextMenu
    $m.FontFamily = 'Microsoft YaHei UI'
    $m.FontSize = 12.5

    $snd = New-Object System.Windows.Controls.MenuItem
    $snd.Header = '提示音'
    $snd.Items.Add((New-MenuItem "▶ 试听：任务完成音" { Play-Event 'done' })) | Out-Null
    $snd.Items.Add((New-MenuItem "▶ 试听：请求 / 授权音" { Play-Event 'ask' })) | Out-Null
    $snd.Items.Add((New-MenuItem "▶ 试听：普通提醒音" { Play-Event 'notify' })) | Out-Null
    $snd.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

    foreach ($pair in @(@('done', '更换任务完成音'), @('ask', '更换请求 / 授权音'), @('notify', '更换普通提醒音'))) {
        $key = [string]$pair[0]
        $sub = New-Object System.Windows.Controls.MenuItem
        $sub.Header = $pair[1]
        foreach ($s in (Get-SoundList)) {
            # Tag 里同时带 kind 与相对路径，避免脚本块闭包只记住最后一个 kind
            $tagObj = [pscustomobject]@{ Kind = $key; Rel = [string]$s.Rel }
            $mi = New-MenuItem $s.Label $null $true ($Cfg.sound.$key.file -eq $s.Rel) $tagObj
            $mi.Add_Click({
                param($s2, $e2)
                $k = [string]$s2.Tag.Kind
                $r = [string]$s2.Tag.Rel
                $Cfg.sound.$k.file = $r
                Save-Config $Cfg
                Play-Event $k
            })
            $sub.Items.Add($mi) | Out-Null
        }
        $snd.Items.Add($sub) | Out-Null
    }
    $m.Items.Add($snd) | Out-Null

    $m.Items.Add((New-MenuItem '静音（所有提示音）' {
        $Cfg.sound.mute = -not ($Cfg.sound.mute -eq $true)
        Save-Config $Cfg
    } $true ($Cfg.sound.mute -eq $true))) | Out-Null

    $vol = New-Object System.Windows.Controls.MenuItem
    $vol.Header = '音量'
    foreach ($v in @(0.25, 0.5, 0.75, 1.0)) {
        $mi = New-MenuItem "$([int]($v * 100))%" {
            param($s2, $e2)
            foreach ($k in @('done', 'ask', 'notify')) { $Cfg.sound.$k.volume = [double]$s2.Tag }
            Save-Config $Cfg
            Play-Event 'done'
        } $false $false $v
        $vol.Items.Add($mi) | Out-Null
    }
    $m.Items.Add($vol) | Out-Null
    $m.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

    $ev = New-Object System.Windows.Controls.MenuItem
    $ev.Header = '气泡与事件'
    foreach ($pair in @(@('done', '任务完成时冒泡'), @('ask', '请求 / 授权时冒泡'), @('notify', '普通提醒时冒泡'))) {
        $key = $pair[0]
        $mi = New-MenuItem $pair[1] {
            param($s2, $e2)
            $k = [string]$s2.Tag
            $Cfg.events.$k = [bool]$s2.IsChecked
            Save-Config $Cfg
        } $true ($Cfg.events.$key -ne $false) $key
        $ev.Items.Add($mi) | Out-Null
    }
    $ev.Items.Add((New-MenuItem '试一条气泡' { Show-Bubble -Title '试一下' -Text '事件冒泡大概就是这个样子～' -Accent '#FF2F6FD8' })) | Out-Null
    $m.Items.Add($ev) | Out-Null

    $sz = New-Object System.Windows.Controls.MenuItem
    $sz.Header = '挂件大小'
    foreach ($pair in @(@(0.85, '小'), @(1.0, '中'), @(1.25, '大'), @(1.5, '特大'))) {
        $mi = New-MenuItem $pair[1] {
            param($s2, $e2)
            $Cfg.widget.scale = [double]$s2.Tag
            Apply-Scale ([double]$s2.Tag)
            # 变大之后可能顶出屏幕 → 统一硬夹紧拉回屏内
            $tgt = Get-ClampedPos $Win.Left $Win.Top
            $Win.Left = $tgt.X
            $Win.Top = $tgt.Y
            $Cfg.widget.x = [int]$tgt.X
            $Cfg.widget.y = [int]$tgt.Y
            Save-Config $Cfg
            if ($Cfg.widget.autoFlip -ne $false) {
                $f = Should-Flip $tgt.X
                $script:Flipped = $f
                Apply-Flip $f $true
                $Cfg.widget.flipped = [bool]$f
                Save-Config $Cfg
            }
        } $false $false $pair[0]
        $sz.Items.Add($mi) | Out-Null
    }
    $m.Items.Add($sz) | Out-Null

    $m.Items.Add((New-MenuItem '重置位置' {
        if ($script:BubbleVisible) { Stop-Bubble }
        $tgt = Get-ClampedPos ($script:WpfWork.Right - $Win.Width - 24) ($script:WpfWork.Bottom - $Win.Height - 12)
        $Win.Left = $tgt.X
        $Win.Top = $tgt.Y
        $script:Flipped = $false
        if ($FlipScale) { $FlipScale.ScaleX = 1.0 }
        $Cfg.widget.x = [Math]::Round($tgt.X, 2)
        $Cfg.widget.y = [Math]::Round($tgt.Y, 2)
        $Cfg.widget.flipped = $false
        Save-Config $Cfg
    })) | Out-Null

    $m.Items.Add((New-MenuItem '贴左自动镜像' {
        $Cfg.widget.autoFlip = -not ($Cfg.widget.autoFlip -ne $false)
        Save-Config $Cfg
        if ($Cfg.widget.autoFlip -ne $false) {
            $f = Should-Flip $Win.Left
            $script:Flipped = $f
            Apply-Flip $f $true
        }
    } $true ($Cfg.widget.autoFlip -ne $false))) | Out-Null

    $m.Items.Add((New-MenuItem '随 WorkBuddy 一起开关' {
        $Cfg.widget.bindToWorkBuddy = -not ($Cfg.widget.bindToWorkBuddy -ne $false)
        Save-Config $Cfg
        # 刚打开绑定时别立刻把自己关掉：重新给一段宽限
        if ($Cfg.widget.bindToWorkBuddy -ne $false) { $script:WbGraceUntil = [DateTime]::Now.AddSeconds(20) }
    } $true ($Cfg.widget.bindToWorkBuddy -ne $false))) | Out-Null

    $m.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    $m.Items.Add((New-MenuItem '打开事件日志' { if (Test-Path -LiteralPath $EventsFile) { Start-Process notepad.exe $EventsFile } })) | Out-Null
    $m.Items.Add((New-MenuItem '打开配置' { Start-Process notepad.exe $ConfigFile })) | Out-Null
    $m.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    $m.Items.Add((New-MenuItem '退出挂件' { $script:UserQuit = $true; $Win.Close() })) | Out-Null
    return $m
}

$PetHost.Add_MouseRightButtonUp({
    param($s, $e)
    $menu = Build-Menu
    $menu.PlacementTarget = $PetHost
    $menu.IsOpen = $true
    $e.Handled = $true
})

# ---------------------------------------------------------------------- 托盘
$script:Tray = $null
if (-not $NoTray) {
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        if (Test-Path -LiteralPath $WhalePng) {
            $b = New-Object System.Drawing.Bitmap($WhalePng)
            $ico = New-Object System.Drawing.Bitmap($b, 32, 32)
            $ni.Icon = [System.Drawing.Icon]::FromHandle($ico.GetHicon())
            $b.Dispose()
        }
        $ni.Text = '小鲸鱼挂件 · 任务提示音'
        $cms = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$cms.Items.Add('显示 / 隐藏挂件')
        $cms.Items[0].Add_Click({ if ($Win.Visibility -eq 'Visible') { $Win.Visibility = 'Hidden' } else { $Win.Visibility = 'Visible' } })
        [void]$cms.Items.Add('试听：任务完成音')
        $cms.Items[1].Add_Click({ Play-Event 'done' })
        [void]$cms.Items.Add('试听：请求 / 授权音')
        $cms.Items[2].Add_Click({ Play-Event 'ask' })
        [void]$cms.Items.Add('静音开关')
        $cms.Items[3].Add_Click({ $Cfg.sound.mute = -not ($Cfg.sound.mute -eq $true); Save-Config $Cfg })
        [void]$cms.Items.Add('-')
        [void]$cms.Items.Add('打开事件日志')
        $cms.Items[5].Add_Click({ if (Test-Path -LiteralPath $EventsFile) { Start-Process notepad.exe $EventsFile } })
        [void]$cms.Items.Add('退出')
        $cms.Items[6].Add_Click({ $script:UserQuit = $true; $Win.Close() })
        $ni.ContextMenuStrip = $cms
        $ni.Add_MouseDoubleClick({ $Win.Visibility = 'Visible'; $Win.Activate() })
        $ni.Visible = $true
        $script:Tray = $ni
    } catch { $script:Tray = $null }
}

# ---------------------------------------------------------------------- 呼吸动画
try {
    $bAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $bAnim.From = 1.0
    $bAnim.To = 1.028
    $bAnim.Duration = [System.Windows.Duration][TimeSpan]::FromSeconds(2.4)
    $bAnim.AutoReverse = $true
    $bAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $bAnim.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
    [System.Windows.Media.Animation.Storyboard]::SetTarget($bAnim, $BreathScale)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($bAnim, 'ScaleY')
    $sb = New-Object System.Windows.Media.Animation.Storyboard
    [void]$sb.Children.Add($bAnim)
    $sb.Begin()
} catch {}

# ---------------------------------------------------------------------- 启动
$Win.Add_Closing({
    try { $PollTimer.Stop(); $BubbleTimer.Stop(); $GifTimer.Stop(); $script:WbWatchTimer.Stop() } catch {}
    try { if (Test-Path -LiteralPath $AliveFile) { Remove-Item -LiteralPath $AliveFile -Force } } catch {}
    try {
        if ($script:UserQuit) {
            # 主动退出 → 留标记，钩子不会再把挂件拉起来（下次手动打开会自动清掉这个标记）
            [System.IO.File]::WriteAllText($OffFile, (Get-Date).ToString('s'))
            Write-WidgetLog "用户主动退出，已写入 widget-off 标记"
        } elseif ($script:Bound) {
            # 跟着 WorkBuddy 一起退 → 不留标记，下次 WorkBuddy 启动时还能被钩子拉起来
            if (Test-Path -LiteralPath $OffFile) { Remove-Item -LiteralPath $OffFile -Force }
            Write-WidgetLog "随 WorkBuddy 退出（不留 widget-off 标记）"
        } else {
            if (Test-Path -LiteralPath $OffFile) { Remove-Item -LiteralPath $OffFile -Force }
        }
    } catch {}
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch {}
    try {
        # ⚠️ 存位置要存"气泡收起之后"的落点。
        #    气泡是把窗口**向上撑开**的，退出时如果气泡正开着，$Win.Top 是抬高过的值，
        #    直接存下去下次启动就会比原来高一截（就是气泡那点高度），反复几次挂件会一路往上爬。
        #    ⚠️ 而且必须**先把高度恢复成收泡后的值**再夹紧 —— 否则 Get-ClampedPos 会
        #       拿"气泡撑开时的大高度"去算 maxY，把已经补正的位置又压回抬高状态。
        $saveX = [double]$Win.Left
        $saveY = [double]$Win.Top
        if ($script:BubbleVisible) {
            $Win.Height = $script:WhaleHNow          # 恢复收泡后的高度，供下面夹紧用
            $saveY = $saveY + [double]$script:BubbleExtra
        }
        $rp = Get-ClampedPos $saveX $saveY
        $Cfg.widget.x = [Math]::Round($rp.X, 2)
        $Cfg.widget.y = [Math]::Round($rp.Y, 2)
        $Cfg.widget.flipped = [bool]$script:Flipped
        Save-Config $Cfg
    } catch {}
})

$PollTimer.Start()
$App.MainWindow = $Win

# 任何漏网的 UI 线程异常都记下来，别让挂件默默消失
try {
    $App.add_DispatcherUnhandledException({
        param($s, $e)
        try {
            [System.IO.File]::AppendAllText($LogFile, "UNHANDLED $((Get-Date).ToString('HH:mm:ss'))  $($e.Exception.ToString())`r`n")
        } catch {}
        $e.Handled = $true
    })
} catch {}

# ---------------------------------------------------------------------- 调试快照
if ($SnapshotTo) {
    $script:ShotStep = 0
    $ShotTimer = New-Object System.Windows.Threading.DispatcherTimer
    $ShotTimer.Interval = [TimeSpan]::FromMilliseconds(900)
    $script:ShotTimerRef = $ShotTimer
    $script:ShotPath = $SnapshotTo
    $script:ShotState = $SnapshotState
    $ShotTimer.Add_Tick({
        $script:ShotStep++
        if ($script:ShotStep -eq 1) {
            try {
                switch ($script:ShotState) {
                    'done' { Show-Bubble -Title '任务完成' -Text '这一轮已经跑完啦～' -Accent '#FF1FA971' -Gif 'widget/assets/rua.gif' -AutoCloseMs 0 }
                    'ask' { Show-Bubble -Title '需要你确认' -Text 'WorkBuddy 在等你回答或授权' -Accent '#FFE0870B' -Gif 'widget/assets/petpet.gif' -AutoCloseMs 0 }
                    'status' { Show-Status }
                }
                $Win.UpdateLayout()
            } catch {}
            return
        }
        $script:ShotTimerRef.Stop()
        try {
            $sx = 1.0
            $sy = 1.0
            try {
                $src = [System.Windows.PresentationSource]::FromVisual($Win)
                if ($src -and $src.CompositionTarget) {
                    $mtx = $src.CompositionTarget.TransformToDevice
                    $sx = [double]$mtx.M11
                    $sy = [double]$mtx.M22
                }
            } catch {}
            if ($sx -le 0) { $sx = 1.0 }
            if ($sy -le 0) { $sy = 1.0 }

            $wpx = [int][Math]::Ceiling([double]$Win.ActualWidth * $sx)
            $hpx = [int][Math]::Ceiling([double]$Win.ActualHeight * $sy)
            if ($wpx -lt 1) { $wpx = 1 }
            if ($hpx -lt 1) { $hpx = 1 }

            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap -ArgumentList @(
                [int]$wpx, [int]$hpx, [double](96.0 * $sx), [double](96.0 * $sy),
                [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($Win)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fsx = [System.IO.File]::Open($script:ShotPath, [System.IO.FileMode]::Create)
            $enc.Save($fsx)
            $fsx.Close()
        } catch {
            [System.IO.File]::WriteAllText("$($script:ShotPath).err.txt", $_.Exception.ToString() + "`r`n---`r`n" + $_.InvocationInfo.PositionMessage)
        }
        $Win.Close()
    })
    $ShotTimer.Start()
    $Win.Show()
    [void]$App.Run()
    try { $Mutex.ReleaseMutex() } catch {}
    exit 0
}

try {
    $Win.Show()
    [void]$Win.Activate()
    [void]$App.Run()
} finally {
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
}
