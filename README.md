# wb-sound-widget · 小鲸鱼提示音挂件

给 WorkBuddy（CodeBuddy Code）加两件事：

1. **两枚完全不同的提示音**
   - 🎵 **任务完成音** —— 一轮任务跑完时响（默认是自制合成音，可换成自己喜欢的任何音频）
   - 🔔 **请求 / 授权音** —— WorkBuddy 需要你批准授权、或需要你回答问题时响（默认是自制的一声"叮-咚"，和完成音完全不一样）
   - 另外附赠一枚轻量的**普通提醒音**（给非授权的通知用）
2. **一只常驻桌面的小鲸鱼挂件** —— 形象参考 [DSH 小鲸鱼记账挂件](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)：小鲸鱼本体 + 冒泡提示。**不依赖 WorkBuddy 也能用**，任何程序都能让它冒泡、出声。

---

## 快速开始（给第一次用的人）

```bash
git clone https://github.com/waxabble-png/wb-sound-widget.git
cd wb-sound-widget
powershell -ExecutionPolicy Bypass -File install.ps1
```

装完**重启一次 WorkBuddy**，之后就不用管了。

> ⚠️ **小鲸鱼图片需要自备**：`widget/assets/whale.png` 带第三方版权、仓库里没有，
> 第一次启动挂件会弹窗告诉你缺什么、要放到哪。放好再启动一次就能看到它了。
> 不执着于鲸鱼形象的话，放**任意一张带透明背景的 PNG** 也行 —— 挂件会自动把四周的透明边裁掉。
>
> 三枚默认提示音是自制合成的，clone 下来就能响；`sounds/presets/` 里的预置音效同样不入库，想要自己补。

安装方式有两种（全局钩子 / 标准 WorkBuddy 插件），见下面「三、安装」和「4）换一种装法」。

---

## 一、效果

| 时机 | 触发的事件 | 提示音 | 挂件表现 |
|---|---|---|---|
| 一轮任务结束 | `Stop` / `FinalStop` 钩子 | `task-done`（默认 Minecraft 经验球） | 绿色气泡「任务完成」+ rua 动图 |
| 需要你批准授权 | `PermissionRequest` / `Notification(permission_prompt)` | `need-attention`（叮-咚，明显不同） | 橙色气泡「需要你确认」+ petpet 动图 |
| 需要你回答问题 | `Elicitation` | 同上 | 同上 |
| 其它通知 | `Notification` | `notify`（轻柔单响） | 蓝色气泡 |

同一件事如果同时命中了两个事件（比如 `Stop` 和 `FinalStop`），内置 1.2 秒去重，**不会响两声**。

### 长这样

待机时是右下角一只安静的小鲸鱼；任务完成弹出**绿色**气泡 + 上扬提示音；需要你确认时弹出**橙色**气泡 +
急促提示音，鲸鱼会抬头张嘴；左键点一下冒出今日/累计统计和一句随机台词。
（截图与素材文件因版权原因不入库，`bin\wb-notify.ps1 -Demo` 可以现场看动画。）

---

## 二、目录结构

```text
wb-sound-widget/
├── install.ps1                    # 安装 / 挂钩子
├── uninstall.ps1                  # 卸载
├── config.default.json            # 默认配置模板
├── .codebuddy-plugin/plugin.json  # 插件元数据（可按标准插件安装）
├── hooks/
│   ├── hooks.json                 # 插件版钩子声明（${CODEBUDDY_PLUGIN_ROOT}）
│   └── notify.mjs                 # 钩子入口：分类事件 → 记日志 → 派发提示音
├── widget/
│   ├── wb-widget.ps1              # 桌面挂件本体（WPF）
│   └── assets/                    # 小鲸鱼 + 动图
├── bin/
│   ├── start-widget.vbs           # 无窗口启动挂件
│   ├── setup-autostart.ps1        # 开机自启开关（加 -Remove 关掉）
│   ├── play-sound.ps1             # 独立播放器（挂件没开时用）
│   ├── wb-notify.ps1              # 手动发提醒（带中文帮助 / -Demo 演示）
│   └── wb-notify.cmd              # 同上，纯命令行版
├── docs/                          # 外观预览图（版权原因不入库）
├── sounds/
│   ├── task-done.wav              # 自制：上行琶音「完成」
│   ├── need-attention.wav         # 自制：叮-咚「请处理」
│   ├── notify.wav                 # 自制：轻响
│   └── presets/                   # 同款素材（Minecraft 经验球、A、小黄鸭、音效1）
└── tools/                         # 生成音效 / 处理 PNG 的小工具（可选）
```

运行期数据固定在 **`%USERPROFILE%\.workbuddy\wb-sound-widget\`**（配置 `config.json`、事件日志 `state/events.jsonl`、心跳 `state/widget-alive`），和代码分开，升级不丢设置。

---

## 三、安装

### 1）复制文件 + 挂全局钩子

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

会做四件事：

1. 把整个目录复制到 `%USERPROFILE%\.workbuddy\wb-sound-widget\`
2. 在 `~/.workbuddy/settings.json` 的 `hooks` 里挂上 7 个事件（5 个发声事件 + `SessionStart` / `SessionEnd` 挂件生命周期）
   （**会先备份**成 `settings.json.bak-wb-sound-widget-<时间戳>`，只增删自己那几条，别的原样保留）
3. 把挂件加进开机自启
4. 启动挂件

> ⚠️ **改完钩子要重启一次 WorkBuddy** 才会生效。

### 2）只给某个项目挂钩子（不动全局设置）

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Scope project -ProjectDir "D:\我的项目"
```

写在 `<项目>/.workbuddy/settings.json` 里，只在该目录下的任务生效。

### 3）手动挂钩子

不想让脚本碰 `settings.json` 的话，自己把下面这段并进 `hooks` 键即可（路径换成你的实际安装目录）：

```json
{
  "hooks": {
    "Stop":              [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/你/.workbuddy/wb-sound-widget/hooks/notify.mjs\" done",   "async": true, "timeout": 10 }] }],
    "FinalStop":         [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/你/.workbuddy/wb-sound-widget/hooks/notify.mjs\" done",   "async": true, "timeout": 10 }] }],
    "Notification":      [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/你/.workbuddy/wb-sound-widget/hooks/notify.mjs\" notify", "async": true, "timeout": 10 }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/你/.workbuddy/wb-sound-widget/hooks/notify.mjs\" ask",    "async": true, "timeout": 10 }] }],
    "Elicitation":       [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/你/.workbuddy/wb-sound-widget/hooks/notify.mjs\" ask",    "async": true, "timeout": 10 }] }],
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/你/.workbuddy/wb-sound-widget/hooks/notify.mjs\" session-start", "async": true, "timeout": 15 }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "node \"C:/Users/你/.workbuddy/wb-sound-widget/hooks/notify.mjs\" session-end",   "async": true, "timeout": 15 }] }]
  }
}
```

路径里的**正斜杠是有意为之** —— 钩子命令可能跑在 Git Bash 里，反斜杠会被当转义符吃掉。

`SessionStart` / `SessionEnd` 这一对**不发声**，只负责把挂件的启停跟 WorkBuddy 绑在一起；不想要这个绑定就删掉这两条，挂件会退回"只靠 `autoStart` 在任务结束时被拉起"的行为。

### 4）换一种装法：登记成 WorkBuddy 插件

上面 1）~3）都是"把钩子写进全局 `settings.json`"（下称**全局钩子装法**）。本包同时也是一个**标准 WorkBuddy 插件**
（`.codebuddy-plugin/plugin.json` + `hooks/hooks.json`），可以改走 WorkBuddy 自己的插件机制（下称**插件装法**）。
两者随时可切换：

```bat
bin\wb-plugin.cmd status                :: 看现在用的是哪种
bin\wb-plugin.cmd enable                :: 切到插件装法（自动把全局钩子移走，避免重复）
bin\wb-plugin.cmd enable --keep-hooks   :: 只登记插件、先留着全局钩子（用来验证插件有没有被加载）
bin\wb-plugin.cmd disable               :: 切回全局钩子装法
```

**切换会做三件事**（每一步都会先备份到 `~/.workbuddy/backups/`）：

1. 生成一个**本地目录型插件市场** `~/.workbuddy/wb-sound-widget-market/`，
   里面 `.codebuddy-plugin/marketplace.json` 列出本插件，`plugins/wb-sound-widget/` 是插件本体；
2. 把市场登记进 `~/.workbuddy/plugins/known_marketplaces.json`；
3. 在 `settings.json` 里写 `extraKnownMarketplaces` + `enabledPlugins["wb-sound-widget@wb-sound-widget-local"] = true`，
   并按需移走 / 写回全局 `hooks`。

> ⚠️ **改完要重启 WorkBuddy**，插件市场是启动时扫描的。

两种装法的差别（这也是做这个切换器的意义）：

| | 全局钩子装法 | 插件装法 |
|---|---|---|
| 载体 | 7 条钩子直接写在 `~/.workbuddy/settings.json` | `~/.workbuddy/wb-sound-widget-market/` 里的插件包 |
| 在 WorkBuddy 里可见 | 看不到 | 是正经插件，可在 `settings.json` 的 `enabledPlugins` 里开关 |
| 开关方式 | 手动删/加 `settings.json` 里的钩子 | `enabledPlugins` 置 `true/false`，或跑 `wb-plugin.cmd` |
| 更新代码 | 覆盖安装目录即可 | 要重跑 `enable` 把插件本体同步进市场 |
| 改动面 | 1 个文件 | 3 个位置（市场目录 + `known_marketplaces.json` + `settings.json`） |
| 活动部件 | 最少 | 多一层"插件扫描 / 加载"逻辑 |
| 钩子里路径 | 写死的绝对路径 | `${CODEBUDDY_PLUGIN_ROOT}`（由 WorkBuddy 注入） |

**怎么判断当前哪套在生效**？看 `state\widget.log` 里的生命周期行：

```text
2026-10-10 18:45:30  [钩子] SessionStart 触发（…）        ← 全局钩子装法
2026-10-10 19:02:11  [钩子·插件版] SessionStart 触发（…）  ← 插件装法
```

插件版的钩子命令末尾带一个 `--via-plugin`，脚本据此把日志标成 `[钩子·插件版]`。

---

## 四、用挂件

启动：双击 `bin\start-widget.vbs`（或 `install.ps1` 结束时自动启动）。

| 操作 | 结果 |
|---|---|
| 左键拖动 | 移动位置，自动记住；**拖到屏幕左半边自动镜像**（面朝屏幕内） |
| 左键单击 | 冒泡（今日/累计统计 + 随机台词） |
| 右键 | 菜单：试听三种音 / 更换音效 / 静音 / 音量 / 气泡开关 / 大小 / **贴左自动镜像** / **随 WorkBuddy 一起开关** / 重置位置 / 打开日志 / 打开配置 / 退出 |
| 托盘图标 | 同样的入口（挂件被挡住时用） |

挂件在跑的时候，提示音由挂件播放（支持音量、可静音）；挂件没开的话，钩子会自己起一个独立播放器放一声，**保证"没人看着也有声音"**。

### 拖动 / 镜像 / 贴边

- **跟手（1:1）**：拖动取的是**屏幕坐标系**下的指针位置（`GetPosition(元素)` → `PointToScreen` → `TransformFromDevice`），鼠标走多少、挂件就走多少。
  - ⚠️ 这里踩过一个很隐蔽的坑：WPF 的 `MouseEventArgs.GetPosition($null)` 返回的是**相对窗口**的坐标，**不是屏幕坐标**。
    把它当屏幕坐标喂进"窗口起点 + 指针位移"的算法，解出来是 `窗口位移 = 指针位移 / 2.5` ——
    窗口只走指针的四成，还形成负反馈，拖起来就一直黏在后面追不上。这才是之前"不跟手"的真正原因。
  - 日志里有自检：`拖动结束 … 跟手自检: 指针位移=… 窗口位移=… 比值=…`，没被夹紧时比值应该 ≈ `1.00`。
- **贴边就真的贴边**：窗口尺寸**等于鲸鱼"看得见的部分"**（`whale.png` 四周的透明留白在启动时被自动裁掉），所以拖到边缘时边界是严丝合缝的，不会像以前那样"窗口贴住了、看得见的鲸鱼还差 20 多 DIP"。
- **不出屏**：拖到屏幕边缘会**硬夹紧** —— 窗口四条边都不允许越出工作区，鲸鱼始终完整留在桌面内。
- **贴边后还能往回拖**：夹紧"吃掉"的位移会立刻结算（拖动基准重置到当前指针位置），所以顶到边缘之后再往回拖是即刻跟手的，不会像以前那样"欠着一段位移、拖不动"。
- 鼠标被别的窗口抢走时拖动状态会自愈，不会卡死。
- **自动镜像**：越过屏幕水平中点的瞬间，小鲸鱼会水平翻转（蝴蝶结从右边换到左边），面朝屏幕内侧。拖动途中实时翻转、松手后用 240ms 缓动画收尾，朝向会记进配置。
  - 想关掉：右键 →「贴左自动镜像」。

左右两种朝向：拖到屏幕**左侧**会自动水平镜像（面朝屏幕内），拖到**右侧**恢复原朝向 ——
同一只鲸鱼，蝴蝶结从一边换到另一边，试着拖一下就明白了。

- **重置位置**：右键 →「重置位置」回到右下角，并恢复右朝向。

### 跟 WorkBuddy 一起开关

装完钩子（含 `SessionStart` / `SessionEnd`）之后：

- **WorkBuddy 启动 / 开会话** → 自动把小鲸鱼拉起来。这一步是**强制**的：就算你上次从菜单退出了挂件（留了 `widget-off` 标记），只要 WorkBuddy 重新开会话，挂件也会回来 —— 这正是"绑定"该有的样子。
  拉起来之后钩子还会**盯着确认挂件真的活了**（最多轮询 3 秒、不行就再拉一次），避免"钩子跑了但挂件没出现"。
- **WorkBuddy 退出** → 自动把小鲸鱼一起关掉，并且**不会**留下"用户主动退出"的标记，下次启动还能被拉起来。
  `SessionEnd` 这个钩子在配置里是**同步**（`async: false`）的，WorkBuddy 会等它跑完再退出 —— 否则 WorkBuddy 一退出就可能把这个钩子进程一起收掉，关挂件的动作做不完。

**兜底（钩子失灵时）**：挂件每 5 秒自查一次，有三道信号：

1. 会话心跳 `state/wb-session` **被删掉了** → `SessionEnd` 的明确信号，立即退（正常退出都走这条，约 5 秒内生效，哪怕关挂件的命令没跑完）；
2. 心跳陈旧且**连续 3 次都找不到 WorkBuddy 进程** → 被强杀的情况，退；
3. 心跳文件还在、只是长时间没被刷新 → 那可能只是你在空闲没触发钩子，只要 WorkBuddy 进程还在就按兵不动。

**绑定有没有生效，看日志就行**：钩子每次触发都会往 `state\widget.log` 追加一行 `[钩子] …`，例如

```text
2026-10-10 18:45:30  [钩子] SessionStart 触发（autoStart=true bind=true）
2026-10-10 18:45:30  [钩子] SessionStart 处理完，挂件已运行（进程数 1）
2026-10-10 18:46:00  [钩子] SessionEnd 触发（bind=true）
2026-10-10 18:46:02  [钩子] SessionEnd 处理完，剩余挂件进程数 0
```

有了这几行，"WorkBuddy 启停时钩子到底有没有触发、挂件最后关没关掉"就一目了然，不用猜。

> 这里判的是心跳的**新鲜度**（mtime），不是"文件在不在"。早先按"文件存在 + 进程名匹配"判是没用的 —— 本机实测常驻 9 个 `WorkBuddy` 进程，进程名永远匹配得上，兜底逻辑根本不会触发。
>
> 另有一个刻意的保守设计：**只有"曾经确认过 WorkBuddy 在跑"（见过新鲜心跳）才会跟着退**。所以你把挂件单独当桌面宠物用时，不会被误关。
> 想改成互不影响：右键 →「随 WorkBuddy 一起开关」取消勾选，或把配置里 `widget.bindToWorkBuddy` 设成 `false`。

### 脱离 WorkBuddy 也能用

任何脚本、CI、编辑器都能让它冒泡 + 出声：

```bat
bin\wb-notify.cmd done
bin\wb-notify.cmd ask -t "需要确认" -m "要不要继续部署？"
bin\wb-notify.cmd notify --silent
```

```powershell
bin\wb-notify.ps1 -Demo          # 三种提示音依次演示
bin\wb-notify.ps1 -Status        # 看挂件是否在跑、数据目录在哪
```

---

## 五、配置（`config.json`）

```jsonc
{
  "sound": {
    "mute": false,
    "done":    { "enabled": true, "volume": 1.0,  "file": "sounds/presets/minecraft-exp-orb.wav" },
    "ask":     { "enabled": true, "volume": 1.0,  "file": "sounds/need-attention.wav" },
    "notify":  { "enabled": true, "volume": 0.9,  "file": "sounds/notify.wav" },
    "press":   { "enabled": true, "volume": 0.55, "file": "sounds/presets/d1.mp3" },
    "release": { "enabled": true, "volume": 0.55, "file": "sounds/presets/d2.mp3" }
  },
  "events": { "done": true, "ask": true, "notify": true },   // 哪类事件要提醒
  "bubble": { "autoCloseMs": 4600, "showOnEvent": true },    // 冒泡自动关闭（0 = 不自动关）
  "widget": {
    "scale": 1.0, "x": null, "y": null,
    "autoStart": true,          // 钩子发现挂件没跑就顺手拉起
    "autoFlip": true,           // 贴左自动水平镜像（面朝屏幕内）
    "flipped": null,            // 记住上次朝向；null = 按当前位置自动判断
    "bindToWorkBuddy": true     // 与 WorkBuddy 生命周期绑定
  },
  "dedupeMs": 1200                                            // 同类提醒去重窗口
}
```

- **`widget.autoStart`（默认开）**：钩子发现挂件没在跑就顺手拉起来 —— 这样**不做开机自启也不会丢挂件**，
  下一次任务结束时它自己回来。（5 分钟内只试一次，避免反复起进程。）
- **`widget.autoFlip`（默认开）**：拖到屏幕左半边自动镜像。
- **`widget.flipped`**：上次朝向。`null` 表示启动时按落点自动判断。
- **`widget.bindToWorkBuddy`（默认开）**：WorkBuddy 启动挂件也启动、WorkBuddy 退出挂件也退出。
- **从菜单里「退出挂件」＝真的退出**：会写一个 `state/widget-off` 标记，钩子不再自动拉起；
  下次你手动双击 `start-widget.vbs` 打开，标记自动清掉，自愈恢复。
  （**随 WorkBuddy 退出时不会写这个标记**，所以下次启动还能被拉回来。）
- 想换成自己的音频：把 `wav` / `mp3` 丢进 `sounds/` 下任意子目录，然后在挂件右键菜单里选，或直接改 `file`（相对数据目录 `%USERPROFILE%\.workbuddy\wb-sound-widget`，找不到就回落到安装目录）。
- 挂件里改的设置在菜单操作时**立刻存盘**，不用重启。

### 自制音效

三枚自研音效是脚本合成的（`tools/make-sounds.py`，纯标准库、无版权素材）：

```bash
python tools/make-sounds.py sounds
```

---

## 六、卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1              # 摘钩子 + 关挂件 + 删自启 + 删目录
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepFiles    # 只摘钩子，保留文件
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Scope project -ProjectDir "D:\我的项目"
```

---

## 七、常见问题

**Q：装完没声音？**
1. 先试听：`bin\wb-notify.ps1 -Demo` —— 有声音说明播放链路通。
2. 没有就检查系统音量 / 应用音量混合器。
3. 有声音但任务结束时不出声 → **重启一次 WorkBuddy**（钩子是启动时加载的）。

**Q：`settings.json` 里有别的东西，会被覆盖吗？**
不会。只增删 `command` 里含 `wb-sound-widget` 的那几条钩子，其余键值原样保留；写入前还会自动备份。

**Q：挂件不想要开机自启？**
不用管它也基本能活着 —— 钩子在挂件没运行时会自动把它拉起来（`widget.autoStart`）。
真的想彻底关掉：挂件右键 →「退出挂件」（此后不再自动拉起），或者把配置里 `widget.autoStart` 改成 `false`。
已经加过开机自启想取消：

```powershell
powershell -ExecutionPolicy Bypass -File bin\setup-autostart.ps1 -Remove
```

或者直接删掉启动文件夹里的 `小鲸鱼挂件.lnk`；安装时也可以加 `-NoAutostart` 跳过。

**Q：换了显示器 / 改了分辨率或缩放，挂件不见了？**
启动时会检查存的位置是否还落在某个屏幕里，不合理就自动回到右下角。
另外启动时会把"我把自己放在哪了"写进 `state\widget.log`，出问题先看这一行：
`启动 pid=… 会话=… 落点=… 尺寸=… 缩放=… 屏幕: …`

**Q：挂件进程在跑，但屏幕上就是看不到？**
两种常见原因，都已经处理掉了：

1. **坐标单位混用**（曾经的真 bug）：WPF 的 `Window.Left/Top` 是 **DIP**，WinForms 的 `Screen` 给的是
   **物理像素**，在 150% 缩放下差 1.5 倍 —— 直接混用会把窗口送到屏幕外面。现在默认位置改用 WPF 自己的
   `SystemParameters.WorkArea`，纯 DIP，不再换算。
2. **旧实例占着互斥体**：如果有一个在你看不见的地方跑着，手动启动会提示"已经在桌面上了"然后退出。
   现在手动启动会**强制接管**（结束旧实例），一定以你这次启动的为准。

排除法：双击 `bin\start-widget.vbs`，然后看 `state\widget.log` 最后一行；再把那个「落点」乘以日志里的
「缩放」就是屏幕上的物理坐标。

**Q：想让挂件一直显示在其它窗口上面？**
默认就是 `Topmost`。被挡住在托盘里双击即可唤出。

**Q：拖动时鼠标和挂件"不同步"、感觉发飘？**

这里有两层原因，第二层才是真凶（第一层我以前只修了一半，所以一直"还是不跟手"）：

1. **DPI 单位**：`Window.Left/Top` 是 WPF 的 **DIP**，而屏幕坐标是**物理像素**，150% 下差 1.5 倍。
   用 `PresentationSource.CompositionTarget.TransformFromDevice` 换算（实测 150 物理像素 → 100 DIP）。
2. **坐标系本身用错了**（关键）：`MouseEventArgs.GetPosition($null)` 给的是**相对窗口**的坐标，**不是屏幕坐标**。
   拖动算法是「按下时的窗口位置 + 指针位移」，一旦喂进去"相对窗口"的坐标，因为窗口自己在动，
   相对位移被抵消一部分，解出来是：

   ```text
   窗口位移 = 指针位移 / 2.5      ← 窗口只走四成，且形成负反馈，怎么拖都黏在后面
   ```

   现在改成真正的屏幕坐标：`GetPosition(元素)` → `元素.PointToScreen()` → `TransformFromDevice`，
   三者都是 WPF 自己的换算、天然自洽，实测**元素内位移 20 DIP → 屏幕上也是 20 DIP，1:1**。

> 怎么自己验证？看 `state\widget.log`：
> `拖动开始 … 窗内偏移=…`（应该落在 0~宽 / 0~高 之内）
> `拖动结束 … 跟手自检: 指针位移=… 窗口位移=… 比值=…`（没顶到屏幕边缘时该 ≈ `1.00`）

**Q：拖到屏幕边缘之后会跑到桌面外面？ / 贴边没贴齐？**
两件事都修了，而且根因不一样：

1. **会跑到外面** → 现在拖动时对窗口做**硬夹紧**：四条边都不允许越出工作区，鲸鱼永远完整留在屏幕内。
   （早先为了"贴边也能抓住"故意留了可抓余量、允许窗口露出一部分到屏幕外 —— 方向错了，已改掉。）
2. **贴不齐（右边总差一小截）** → 这是**窗口比鲸鱼宽**造成的：`whale.png` 是 610×610，鲸鱼实际只画在
   中间 565×600 的区域，而窗口按 210 DIP 开、鲸鱼只占 165 DIP，于是左右各多出 22.5 DIP 的透明边 ——
   窗口贴住了屏幕，**看得见的鲸鱼还差 22.5 DIP（150% 缩放下约 34 物理像素）**。
   现在启动时会自动裁掉鲸鱼图四周的透明留白，**窗口尺寸直接等于鲸鱼可见尺寸**（1.0 倍时 155×165），
   贴边就是严丝合缝。
3. 另外补了 `LostMouseCapture` 自愈：指针被别的窗口抢走时拖动状态会复位，不会卡死。

**Q：顶到边缘之后要往回拖一大段才动？**
早先是这样的：拖动时算的是"按下时的窗口位置 + 指针总位移"，被夹紧吃掉的那段位移一直欠着，
所以贴边后指针得先原路走回来窗口才动。现在**被吃掉的位移会立刻结算**（夹紧后把拖动基准重置到当前指针位置），
离开边缘即刻跟手。

**Q：怎么判断当前朝向 / 为什么贴左没镜像？**
启动日志里有这两个字段：

```text
启动 pid=… 落点=… 尺寸=155x165 缩放=1.5 镜像=True 翻转线=853 屏幕: …
```

`翻转线` 就是屏幕水平中点（DIP）。挂件中心越过它就镜像。没生效的话检查右键菜单「贴左自动镜像」是否被关了，
或配置里 `widget.autoFlip` 是不是 `false`。

**Q：用小鲸鱼自己做桌面宠物，不想被 WorkBuddy 关掉？**
右键 →「随 WorkBuddy 一起开关」取消勾选（或把 `widget.bindToWorkBuddy` 设成 `false`）。
另外兜底逻辑本身也保守：**只有确认过 WorkBuddy 在跑**才会跟着退，所以单独使用时本来就不会被误关。

**Q：事件日志在哪？**
`%USERPROFILE%\.workbuddy\wb-sound-widget\state\events.jsonl`，右键菜单「打开事件日志」直接打开。
同目录还有：

- `widget.log` —— 挂件每次处理事件、以及万一崩了的堆栈，都记在这里；
- `widget-alive` —— 心跳文件（钩子靠它判断挂件在不在跑，mtime 超 6 秒即视为不在）；
- `wb-session` —— WorkBuddy 会话心跳：`SessionStart` 写下，**之后每次普通钩子都会顺手刷新**；
  挂件每 5 秒看一次：文件**被删**= `SessionEnd` 的明确信号（立即退）；文件在但很久没刷新，
  还要再看 WorkBuddy 进程在不在（在就说明只是空闲）；
- `widget-off` —— 用户主动从菜单退出的标记（非强制路径的钩子不再自动拉起；但 `SessionStart` 会清掉它）；
- `widget-stopping` —— 极短时的过渡标记，避免"随 WorkBuddy 退出"的瞬间又被紧接着的 `Stop` 钩子拉回来；
- `config.json` —— 位于上一级目录，右键菜单「打开配置」直接打开。

**Q：钩子明明执行了，却没声音 / 挂件没被拉起来？**

这是个很隐蔽的坑，已经修掉了。原因：钩子进程（`node notify.mjs`）跑完 main 就立刻 `exit()`，
而当时启动播放器和挂件用的是 `spawn(..., {detached:true})` + `unref()` ——
**那个子进程在父进程退出时经常还没真正跑起来，就被一起收走了**，表现为"钩子日志有、效果没有"。

现在所有"启动别的进程"的地方（放提示音、拉起挂件、结束挂件）**一律改用同步的 `spawnSync`**，
等子进程真正跑起来再返回。代价是每次钩子多等 1~2 秒（提示音播放时长），换来的是"一定有效"。

所以：**升级后第一次用，如果发现行为跟以前不一样，那是修好了，不是坏了。**

**Q：挂件用久了会自己往上爬 / 位置越跑越偏？**

以前会，已修。原因是气泡是把窗口**向上撑开**的：如果退出那一刻气泡正开着（比如你刚收到一条提醒就关掉了挂件），
存下去的位置就是被抬高过的值，下次启动就比原来高一截，反复几次就一路爬到屏幕顶上。
现在退出时会先把高度恢复成"收起气泡"的状态，再算落点，位置不会再漂。

**Q：想把挂件外观截下来发给别人？**

```powershell
# 把窗口渲染成 PNG（不需要桌面会话，远程/无头环境也能用）
powershell -File widget\wb-widget.ps1 -SnapshotTo "$env:TEMP\shot.png" -SnapshotState done
# -SnapshotState 可选 idle / done / ask / status
```

> 顺带一提：`whale.png` 四周的透明留白是在**运行时**自动裁掉的（`FormatConvertedBitmap` + `CroppedBitmap`），
> 不会修改你的图片文件。所以以后你换成别的鲸鱼图（只要是不透明的紧致裁剪），窗口也会自动跟着贴合。

---

## 许可

代码 MIT（见 `LICENSE`）。

**版权素材不入库**：`widget/assets/`（鲸鱼图片与动图）、`sounds/presets/`（预置音效）、`docs/`（截图）
来自第三方（DSH 小鲸鱼挂件），仅限自用，**本仓库不分发它们**，所以仓库里看不到这几个目录。
自己使用时把它们放回对应位置即可，`.gitignore` 已按此配置。

`sounds/*.wav`（三枚自制音效）由 `tools/make-sounds.py` 合成，无第三方版权，可随仓库分发。
