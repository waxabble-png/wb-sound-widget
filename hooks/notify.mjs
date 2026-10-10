#!/usr/bin/env node
/**
 * wb-sound-widget —— 事件采集与提示音派发（钩子入口）
 * ================================================================
 * 两种用法：
 *   1) 钩子模式（WorkBuddy 调用）：事件名由 argv 给出，事件详情从 stdin 的 JSON 读
 *        node hooks/notify.mjs done
 *        node hooks/notify.mjs ask
 *        node hooks/notify.mjs notify
 *   2) 命令行模式（脱离 WorkBuddy 也能用，任何程序都能调）
 *        node hooks/notify.mjs --kind done --title "构建完成" --text "耗时 12s"
 *        node hooks/notify.mjs ask -t "需要你确认" -m "请选择部署环境"
 *
 * 做的事情：
 *   · 把事件追加到 state/events.jsonl（挂件轮询这个文件来冒泡）
 *   · 如果挂件没在运行，则自己放一次提示音（保证"没人看着也有声音"）
 *   · 会话内同一种提醒做去重，避免 Stop/FinalStop、Notification/PermissionRequest
 *     这些成对事件把同一件事响两声
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
// 只用 spawnSync：钩子进程跑完就 exit，detached 子进程会被一起收掉。
// （曾经 playSound / tryStartWidget 用 spawn+detached，导致"钩子执行了但没声音 / 挂件没起来"）
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const PACKAGE_ROOT = path.resolve(HERE, '..')

/**
 * 数据根目录（配置 + 事件日志 + 心跳）固定放在 ~/.workbuddy/wb-sound-widget，
 * 这样即使插件是从插件市场缓存目录里加载的，数据也只有一份、升级不丢。
 * 代码与素材仍优先用数据目录里的副本，其次回落到包目录。
 */
const DATA_ROOT = process.env.WB_WIDGET_HOME
  || path.join(os.homedir(), '.workbuddy', 'wb-sound-widget')

const STATE_DIR = path.join(DATA_ROOT, 'state')
const EVENTS_FILE = path.join(STATE_DIR, 'events.jsonl')
const ALIVE_FILE = path.join(STATE_DIR, 'widget-alive')
const DEDUPE_FILE = path.join(STATE_DIR, 'last-fire.json')
const OFFLINE_FILE = path.join(STATE_DIR, 'widget-off')       // 用户主动退出挂件时留下的标记
const AUTOSTART_FILE = path.join(STATE_DIR, 'last-autostart.json')
const CONFIG_FILE = path.join(DATA_ROOT, 'config.json')
// WorkBuddy 会话心跳：SessionStart 写下、SessionEnd 删掉。
// 挂件靠它判断"宿主还在不在"，从而做到 WorkBuddy 停 → 挂件停。
const SESSION_FILE = path.join(STATE_DIR, 'wb-session')
const STOPPING_FILE = path.join(STATE_DIR, 'widget-stopping')  // 挂件正在被会话结束时写，避免钩子又把它拉起来

/**
 * 这次是不是由「插件包里的钩子」触发的？
 * 插件版的钩子命令末尾会带 `--via-plugin`，而写进全局 settings.json 的那套不带。
 * 有了这个标记，日志里就能一眼看出"到底哪套钩子在干活"，比较两种安装方式时特别有用。
 */
const VIA_PLUGIN = process.argv.includes('--via-plugin')

/** 解析素材路径：数据目录优先，包目录兜底 */
function resolveAsset(rel) {
  if (!rel) return null
  if (path.isAbsolute(rel)) return rel
  const inData = path.join(DATA_ROOT, rel)
  if (fs.existsSync(inData)) return inData
  return path.join(PACKAGE_ROOT, rel)
}

const DEFAULT_CONFIG = {
  sound: {
    mute: false,
    done: { enabled: true, volume: 1.0, file: 'sounds/presets/minecraft-exp-orb.wav' },
    ask: { enabled: true, volume: 1.0, file: 'sounds/need-attention.wav' },
    notify: { enabled: true, volume: 0.9, file: 'sounds/notify.wav' },
  },
  events: { done: true, ask: true, notify: true },
  widget: { autoStart: true, bindToWorkBuddy: true },
  dedupeMs: 1200,
}

const KIND_TEXT = {
  done: { title: '任务完成', text: '这一轮已经跑完啦～' },
  ask: { title: '需要你确认', text: 'WorkBuddy 在等你回答或授权' },
  notify: { title: '提醒', text: 'WorkBuddy 有新的动静' },
}

// ------------------------------------------------------------------ 工具
function readJson(file, fallback) {
  try {
    let text = fs.readFileSync(file, 'utf8')
    // ⚠️ PowerShell 的 Set-Content -Encoding UTF8 会写 BOM，JSON.parse 见到 BOM 会直接抛错
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1)
    return JSON.parse(text)
  } catch {
    return fallback
  }
}

function ensureDir(dir) {
  try { fs.mkdirSync(dir, { recursive: true }) } catch {}
}

function loadConfig() {
  const cfg = readJson(CONFIG_FILE, null)
  if (!cfg) return DEFAULT_CONFIG
  // 浅合并，保证老配置缺字段时也能跑
  return {
    ...DEFAULT_CONFIG,
    ...cfg,
    sound: { ...DEFAULT_CONFIG.sound, ...(cfg.sound || {}) },
    events: { ...DEFAULT_CONFIG.events, ...(cfg.events || {}) },
    widget: { ...DEFAULT_CONFIG.widget, ...(cfg.widget || {}) },
  }
}

/** 挂件是否活着：看心跳文件的 mtime */
function widgetAlive() {
  try {
    const st = fs.statSync(ALIVE_FILE)
    return Date.now() - st.mtimeMs < 6000
  } catch {
    return false
  }
}

/** 读 stdin（钩子模式下 WorkBuddy 会把事件 JSON 写进来） */
function readStdin(timeoutMs = 400) {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) return resolve('')
    let buf = ''
    let done = false
    const finish = () => { if (!done) { done = true; resolve(buf) } }
    const timer = setTimeout(finish, timeoutMs)
    process.stdin.setEncoding('utf8')
    process.stdin.on('data', (c) => { buf += c })
    process.stdin.on('end', () => { clearTimeout(timer); finish() })
    process.stdin.on('error', () => { clearTimeout(timer); finish() })
    try { process.stdin.resume() } catch { clearTimeout(timer); finish() }
  })
}

// ------------------------------------------------------------------ 参数
function parseArgs(argv) {
  const out = { kind: null, title: null, text: null, silent: false }
  const positional = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--kind' && argv[i + 1]) out.kind = argv[++i]
    else if ((a === '--title' || a === '-t') && argv[i + 1]) out.title = argv[++i]
    else if ((a === '--text' || a === '-m' || a === '--message') && argv[i + 1]) out.text = argv[++i]
    else if (a === '--silent' || a === '--no-sound') out.silent = true
    else if (!a.startsWith('-')) positional.push(a)
  }
  if (!out.kind && positional.length) out.kind = positional[0]
  return out
}

/** 由 WorkBuddy 的钩子事件推出我们关心的三类提醒 */
function classify(hint, payload) {
  const evt = String(payload?.hook_event_name || '').trim()
  const ntype = String(payload?.notification_type || '')
  const name = evt || `hint:${hint}`

  // 会话生命周期：不发声，只负责挂件的启停
  if (hint === 'session-start') return { kind: 'lifecycle', event: name, text: null }
  if (hint === 'session-end') return { kind: 'lifecycle', event: name, text: null }
  if (evt === 'SessionStart') return { kind: 'lifecycle', event: name, text: null }
  if (evt === 'SessionEnd') return { kind: 'lifecycle', event: name, text: null }

  // 需要你回答 / 授权 —— 优先级最高
  if (evt === 'PermissionRequest' || evt === 'PermissionDenied' || evt === 'Elicitation') {
    return { kind: 'ask', event: name, text: payload?.tool_name ? `请求：${payload.tool_name}` : null }
  }
  // Notification 里再细分：permission_prompt 才是"要授权"，其余算普通提醒
  if (evt === 'Notification') {
    if (/permission|approval|授权|allow/i.test(ntype)) return { kind: 'ask', event: name, text: payload?.message || null }
    return { kind: 'notify', event: name, text: payload?.message || null }
  }
  if (hint === 'ask') return { kind: 'ask', event: name, text: null }
  if (hint === 'notify') return { kind: 'notify', event: name, text: null }
  if (evt === 'Stop' || evt === 'FinalStop') return { kind: 'done', event: name, text: null }
  if (evt === 'SubagentStop') return { kind: 'done', event: name, text: '子任务完成' }
  return { kind: hint === 'done' ? 'done' : 'notify', event: name, text: null }
}

// ------------------------------------------------------------------ 播放
function playSound(file, volume) {
  const abs = resolveAsset(file)
  if (!abs || !fs.existsSync(abs)) return false
  const script = path.join(PACKAGE_ROOT, 'bin', 'play-sound.ps1')
  if (!fs.existsSync(script)) return false
  try {
    // ⚠️ 这里也必须用**同步** spawnSync。
    //    钩子进程（本 node 进程）在 main 里跑完就 exit 了，detached 起来的
    //    powershell 还没开始播就被一起收掉 —— 表现就是"钩子触发了却没有声音"。
    //    提示音本来很短（<2s），同步等一下完全可以接受；
    //    timeout 给 5s，防止某个音频设备卡死把钩子拖住。
    spawnSync(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
       '-ExecutionPolicy', 'Bypass', '-File', script,
       '-Path', abs, '-Volume', String(volume ?? 1)],
      { stdio: 'ignore', windowsHide: true, timeout: 5000 },
    )
    return true
  } catch {
    return false
  }
}

/** 同步睡一会儿（钩子是短命进程，用同步等待最简单，也最不会出岔子） */
function sleepSync(ms) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
  } catch {
    const end = Date.now() + ms
    while (Date.now() < end) { /* busy wait */ }
  }
}

/**
 * 挂件不在跑的时候顺手拉起来 —— 这样即使没做开机自启，下一次任务结束时它也会自己回来。
 *
 * force = true（SessionStart）时语义不同：那是「WorkBuddy 启动了，挂件就该起来」，
 * 属于用户在配置里明确要的绑定行为，所以会**清掉 widget-off 标记**再拉，
 * 而且拉完还会**盯着确认它真的起来了**（见下）。
 * 非 force（任务结束顺手拉起）时，尊重用户的「退出挂件」，不越过那个标记。
 */
function tryStartWidget(cfg, force = false) {
  try {
    if (cfg.widget?.autoStart === false && !force) return
    if (widgetAlive()) return

    if (force) {
      // SessionStart：绑定语义优先，清掉「用户退出过」的标记，让挂件真的回来
      try { fs.rmSync(OFFLINE_FILE, { force: true }) } catch {}
    } else {
      if (fs.existsSync(OFFLINE_FILE)) return
      const last = readJson(AUTOSTART_FILE, { ts: 0 })
      if (Date.now() - Number(last.ts || 0) < 300000) return
    }
    fs.writeFileSync(AUTOSTART_FILE, JSON.stringify({ ts: Date.now() }))

    const vbs = [path.join(DATA_ROOT, 'bin', 'start-widget.vbs'),
                 path.join(PACKAGE_ROOT, 'bin', 'start-widget.vbs')]
      .find((p) => fs.existsSync(p))
    if (!vbs) return

    // ⚠️ 必须用**同步** spawnSync，和 stopWidget 同样的道理：
    //    tryStartWidget 经常是钩子里的最后一个动作，node 进程随即 exit。
    //    如果这里用 spawn(detached:true)+unref()，那个 wscript.exe 子进程
    //    在父进程退出时经常还没真正跑起来，就被一起带走了 ——
    //    表现就是"session-start 明明执行了，挂件却没出现"。
    const launch = () =>
      spawnSync('wscript.exe', [vbs], { stdio: 'ignore', windowsHide: true, timeout: 8000 })

    launch()

    // 只有 SessionStart 才做"确认 + 重试"：
    //   这是「绑定」最关键的一环，拉不起来就等于绑定失效；
    //   而普通钩子（任务结束）每次都等几秒会把钩子拖得很慢，没必要。
    // 挂件要启动 PowerShell + WPF + 读图，正常 1~2 秒，所以轮询等一会儿；
    // 万一没起来（杀软拦了 wscript、上一个实例的互斥体还没放开……）就再拉一次。
    if (!force) return
    for (let attempt = 0; attempt < 2; attempt++) {
      for (let i = 0; i < 15; i++) {          // 15 × 200ms = 3s
        sleepSync(200)
        if (widgetAlive()) return
      }
      launch()
    }
  } catch {}
}

/**
 * 结束所有挂件进程（SessionEnd 时用）。
 *
 * ⚠️ 必须用**同步** spawnSync，不能 spawn + detached：
 *    SessionEnd 是钩子里的最后一个动作，node 进程随即就 exit 了。
 *    detached 的子进程在父进程退出时经常还没跑起来就被一起收掉，
 *    表现就是"session-end 明明执行了，挂件却还活着"。
 *    而且退出码不重要，这里只看它有没有跑完。
 */
function stopWidget() {
  try {
    const ps = path.join(
      process.env.SystemRoot || 'C:\\Windows',
      'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe',
    )
    // -WindowStyle Hidden 避免闪一下黑框；命令本身只找挂件进程
    const cmd = [
      "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -ErrorAction SilentlyContinue",
      "Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' }",
      "ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }",
    ].join(' | ')
    spawnSync(ps, ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
                   '-ExecutionPolicy', 'Bypass', '-Command', cmd],
              { stdio: 'ignore', windowsHide: true, timeout: 10000 })
  } catch {}
}

/** 刷新会话心跳（任何钩子触发都代表会话还活着） */
function touchSession() {
  try {
    ensureDir(STATE_DIR)
    fs.writeFileSync(SESSION_FILE, JSON.stringify({ ts: Date.now(), pid: process.pid }))
  } catch {}
}

/**
 * 把生命周期事件写进挂件日志（同一个 widget.log）。
 * 这样"WorkBuddy 启停时钩子到底有没有触发"就有据可查了，
 * 排查"绑定不生效"时第一眼看这里。
 */
function logLifecycle(msg) {
  try {
    ensureDir(STATE_DIR)
    const t = new Date()
    const p = (n) => String(n).padStart(2, '0')
    const stamp = `${t.getFullYear()}-${p(t.getMonth() + 1)}-${p(t.getDate())} ` +
                  `${p(t.getHours())}:${p(t.getMinutes())}:${p(t.getSeconds())}`
    fs.appendFileSync(path.join(STATE_DIR, 'widget.log'),
      `${stamp}  [钩子${VIA_PLUGIN ? '·插件版' : ''}] ${msg}\r\n`)
  } catch {}
}

/** 当前还活着的挂件进程数（诊断用） */
function widgetProcessCount() {
  try {
    const ps = path.join(process.env.SystemRoot || 'C:\\Windows',
      'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    const r = spawnSync(ps, ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
      '-ExecutionPolicy', 'Bypass', '-Command',
      "@(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -ErrorAction SilentlyContinue | " +
      "Where-Object { $_.CommandLine -and $_.CommandLine -like '*wb-widget.ps1*' }).Count"],
      { encoding: 'utf8', windowsHide: true, timeout: 8000 })
    const n = parseInt(String(r.stdout || '').trim(), 10)
    return Number.isFinite(n) ? n : -1
  } catch { return -1 }
}

/**
 * 会话开始（WorkBuddy 启动 / 新建会话）：
 *   · 写下会话心跳，挂件据此知道宿主还在
 *   · 清掉上次结束时的"正在停止"标记
 *   · 把挂件拉起来
 */
function onSessionStart(cfg) {
  logLifecycle(`SessionStart 触发（autoStart=${cfg.widget?.autoStart} bind=${cfg.widget?.bindToWorkBuddy}）`)
  touchSession()
  try { fs.rmSync(STOPPING_FILE, { force: true }) } catch {}
  tryStartWidget(cfg, true)
  logLifecycle(`SessionStart 处理完，挂件${widgetAlive() ? '已运行' : '未运行'}（进程数 ${widgetProcessCount()}）`)
}

/**
 * 会话结束（WorkBuddy 退出）：
 *   · 删掉会话心跳
 *   · 若开启了绑定，则关掉挂件
 * 注意：SessionEnd 在「clear / resume / 正常退出」时都会触发，
 * 所以只有配置里开了 bindToWorkBuddy 才真的关挂件。
 */
function onSessionEnd(cfg) {
  logLifecycle(`SessionEnd 触发（bind=${cfg.widget?.bindToWorkBuddy}）`)
  try { fs.rmSync(SESSION_FILE, { force: true }) } catch {}
  if (cfg.widget?.bindToWorkBuddy === false) {
    logLifecycle('SessionEnd：bindToWorkBuddy=false，不动挂件')
    return
  }
  try {
    // 打个短时标记，防止紧接着的某次 Stop 钩子又把挂件拉回来
    fs.writeFileSync(STOPPING_FILE, JSON.stringify({ ts: Date.now() }))
  } catch {}
  stopWidget()
  logLifecycle(`SessionEnd 处理完，剩余挂件进程数 ${widgetProcessCount()}`)
}

// ------------------------------------------------------------------ 主流程
async function main() {
  ensureDir(STATE_DIR)
  const args = parseArgs(process.argv.slice(2))

  let payload = null
  const raw = await readStdin()
  if (raw.trim()) {
    try { payload = JSON.parse(raw) } catch { payload = null }
  }

  const { kind, event, text } = classify(args.kind, payload)
  const cfg = loadConfig()

  // ---- 会话生命周期：只做挂件的启停，不发声、不写事件 ----
  if (kind === 'lifecycle') {
    const isStart = args.kind === 'session-start' || event === 'SessionStart'
    if (isStart) onSessionStart(cfg)
    else onSessionEnd(cfg)
    process.exit(0)
  }

  // 任何一次普通钩子都说明 WorkBuddy 还活着 → 顺手刷新会话心跳。
  // 这样挂件的兜底判断（心跳过期 = 宿主没了）才有意义：
  // 正常跑着的会话心跳一直是新的，一旦 WorkBuddy 被强杀、钩子停摆，
  // 心跳会在阈值后变"陈旧"，挂件据此自己退出。
  touchSession()

  // 挂件正在被"随 WorkBuddy 退出"收掉时，别再把它拉回来
  if (fs.existsSync(STOPPING_FILE) && kind !== 'ask') {
    const st = readJson(STOPPING_FILE, { ts: 0 })
    if (Date.now() - Number(st.ts || 0) < 15000) { process.exit(0) }
  }

  // 事件总开关
  if (cfg.events?.[kind] === false) { process.exit(0) }

  // 去重：Stop/FinalStop、Notification/PermissionRequest 常常同一瞬间成对触发
  const now = Date.now()
  const last = readJson(DEDUPE_FILE, {})
  const window = Number(cfg.dedupeMs ?? 1200)
  if (last.kind === kind && now - Number(last.ts || 0) < window) { process.exit(0) }
  try { fs.writeFileSync(DEDUPE_FILE, JSON.stringify({ kind, ts: now })) } catch {}

  const preset = KIND_TEXT[kind] || KIND_TEXT.notify
  const record = {
    id: `${now}-${Math.random().toString(36).slice(2, 8)}`,
    ts: now,
    kind,
    event,
    title: args.title || preset.title,
    text: args.text || text || preset.text,
    session: payload?.session_id || null,
    cwd: payload?.cwd || process.cwd(),
    src: payload ? 'workbuddy' : 'cli',
  }

  try { fs.appendFileSync(EVENTS_FILE, JSON.stringify(record) + '\n') } catch {}

  // 挂件在跑 → 由挂件放音（体验更好、支持音量）；否则自己放一声，并把挂件拉起来
  const s = cfg.sound || {}
  const item = s[kind] || {}
  if (!args.silent && s.mute !== true && item.enabled !== false && !widgetAlive()) {
    playSound(item.file || DEFAULT_CONFIG.sound[kind].file, item.volume)
    tryStartWidget(cfg)
  }

  process.exit(0)
}

main().catch(() => process.exit(0))
