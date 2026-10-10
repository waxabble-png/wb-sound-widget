#!/usr/bin/env node
/**
 * wb-plugin.mjs —— 在「插件装法」和「全局钩子装法」之间切换
 * ==================================================================
 * 这个小工具把同一个小鲸鱼挂件包用**两种**方式装进 WorkBuddy，方便对比：
 *
 *   A) 插件装法（推荐）：注册一个本地「目录型插件市场」+ 把本包登记成插件，
 *      hook 由 WorkBuddy 自己从插件包里加载（`<plugin>/hooks/hooks.json`）。
 *      好处：能在 WorkBuddy 的插件/市场里看到、能开关、能随插件更新；
 *      代价：要碰 WorkBuddy 的插件注册表（settings.json + known_marketplaces.json）。
 *
 *   B) 全局钩子装法：直接把 7 条 hook 写进 `~/.workbuddy/settings.json` 顶层 `hooks`。
 *      好处：简单、少两处状态；代价：不是"插件"，插件列表里看不到，也不好开关。
 *
 * 用法：
 *   node bin/wb-plugin.mjs status                # 看现在用的是哪种
 *   node bin/wb-plugin.mjs enable                # 切到插件装法（会移走全局 hooks）
 *   node bin/wb-plugin.mjs enable --keep-hooks   # 只登记插件、先留着全局 hooks（用来验证插件是否被加载）
 *   node bin/wb-plugin.mjs disable               # 切回全局钩子装法（撤销插件登记）
 *
 * 所有被改动的文件都会先备份到 `~/.workbuddy/backups/`。
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const PACKAGE_ROOT = path.resolve(HERE, '..')

const WB_HOME = path.join(os.homedir(), '.workbuddy')
const SETTINGS_FILE = path.join(WB_HOME, 'settings.json')
const PLUGINS_DIR = path.join(WB_HOME, 'plugins')
const KNOWN_MARKETS_FILE = path.join(PLUGINS_DIR, 'known_marketplaces.json')
const BACKUP_DIR = path.join(WB_HOME, 'backups')

// 本地市场 / 插件标识
const MARKET_NAME = 'wb-sound-widget-local'
const PLUGIN_NAME = 'wb-sound-widget'
const PLUGIN_ID = `${PLUGIN_NAME}@${MARKET_NAME}`
const MARKET_DIR = path.join(WB_HOME, 'wb-sound-widget-market')

// 打包进市场的文件 / 目录（数据文件 state/、config.json 一律不带）
const INCLUDE = [
  '.codebuddy-plugin',
  'hooks',
  'bin',
  'widget',
  'sounds',
  'config.default.json',
  'README.md',
]

const HOOK_EVENTS = [
  'SessionStart', 'SessionEnd', 'Stop', 'FinalStop',
  'Notification', 'PermissionRequest', 'Elicitation',
]

// ------------------------------------------------------------------ 工具
function readJson(file, fallback = null) {
  try {
    let text = fs.readFileSync(file, 'utf8')
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1)   // 去 BOM
    return JSON.parse(text)
  } catch { return fallback }
}

function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n', 'utf8')
}

/** 备份（同一分钟内只备份一次，避免刷屏） */
function backup(file) {
  if (!fs.existsSync(file)) return null
  try {
    fs.mkdirSync(BACKUP_DIR, { recursive: true })
    const d = new Date()
    const p = (n) => String(n).padStart(2, '0')
    const stamp = `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
    const dest = path.join(BACKUP_DIR, `${path.basename(file)}.${stamp}.bak`)
    fs.copyFileSync(file, dest)
    return dest
  } catch { return null }
}

function copyRecursive(src, dest) {
  const st = fs.statSync(src)
  if (st.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true })
    for (const name of fs.readdirSync(src)) {
      copyRecursive(path.join(src, name), path.join(dest, name))
    }
  } else {
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.copyFileSync(src, dest)
  }
}

// ------------------------------------------------------------------ 市场
function marketplaceEntry() {
  return {
    manifestName: MARKET_NAME,
    type: 'directory',
    source: { source: 'directory', path: MARKET_DIR },
    installLocation: MARKET_DIR,
    description: '本地插件市场：小鲸鱼提示音 / 桌面挂件',
    autoUpdate: false,
  }
}

/** 生成（或刷新）本地市场目录 */
function buildMarketplace() {
  fs.mkdirSync(path.join(MARKET_DIR, '.codebuddy-plugin'), { recursive: true })

  // 1) 市场清单
  const pj = readJson(path.join(PACKAGE_ROOT, '.codebuddy-plugin', 'plugin.json'), {})
  const manifest = {
    name: MARKET_NAME,
    description: '本地插件市场：小鲸鱼提示音 / 桌面挂件',
    owner: { name: '本地自制' },
    metadata: { version: '1.0.0' },
    plugins: [
      {
        name: PLUGIN_NAME,
        description: pj.description || '任务完成 / 请求授权提示音 + 桌面小鲸鱼挂件',
        source: `./plugins/${PLUGIN_NAME}`,
        version: pj.version || '1.0.0',
        category: 'productivity',
        author: pj.author || { name: '本地自制' },
        license: pj.license || 'MIT',
        // 注意：hooks 只在插件自己的 .codebuddy-plugin/plugin.json 里声明，
        // 不要在这里再声明一遍，否则可能被当成两组钩子加载 → 重复触发。
      },
    ],
  }
  writeJson(path.join(MARKET_DIR, '.codebuddy-plugin', 'marketplace.json'), manifest)

  // 2) 把插件本体拷进去
  const pluginDest = path.join(MARKET_DIR, 'plugins', PLUGIN_NAME)
  try { fs.rmSync(pluginDest, { recursive: true, force: true }) } catch {}
  for (const rel of INCLUDE) {
    const src = path.join(PACKAGE_ROOT, rel)
    if (fs.existsSync(src)) copyRecursive(src, path.join(pluginDest, rel))
  }
  return pluginDest
}

// ------------------------------------------------------------------ hooks 增删
/** 从 settings.hooks 里摘掉所有 command 含 wb-sound-widget 的钩子，返回摘掉几条 */
function stripSettingsHooks(settings) {
  let removed = 0
  const hooks = settings.hooks
  if (!hooks || typeof hooks !== 'object') return 0
  for (const evt of Object.keys(hooks)) {
    const groups = Array.isArray(hooks[evt]) ? hooks[evt] : []
    const keptGroups = []
    for (const g of groups) {
      const inner = Array.isArray(g?.hooks) ? g.hooks : []
      const keptInner = inner.filter((h) => {
        const cmd = String(h?.command || '')
        if (cmd.includes('wb-sound-widget')) { removed++; return false }
        return true
      })
      if (keptInner.length > 0) keptGroups.push({ ...g, hooks: keptInner })
      else if (inner.length === 0) keptGroups.push(g)
    }
    if (keptGroups.length > 0) hooks[evt] = keptGroups
    else delete hooks[evt]
  }
  if (Object.keys(hooks).length === 0) delete settings.hooks
  return removed
}

/** 当前 settings.hooks 里有几条我们的钩子 */
function countSettingsHooks(settings) {
  let n = 0
  const hooks = settings.hooks || {}
  for (const evt of Object.keys(hooks)) {
    for (const g of (Array.isArray(hooks[evt]) ? hooks[evt] : [])) {
      for (const h of (Array.isArray(g?.hooks) ? g.hooks : [])) {
        if (String(h?.command || '').includes('wb-sound-widget')) n++
      }
    }
  }
  return n
}

/** 把我们的 7 条钩子写回 settings.hooks（切回全局钩子装法时用） */
function restoreSettingsHooks(settings) {
  const pj = readJson(path.join(PACKAGE_ROOT, 'hooks', 'hooks.json'), {})
  const hk = pj.hooks || {}
  // ⚠️ 顺序很重要：stripSettingsHooks 在"钩子被摘光"时会把 settings.hooks 整个删掉，
  //    所以必须**先摘、再确保对象存在**，反过来写会读到 undefined 直接崩。
  stripSettingsHooks(settings)
  settings.hooks = settings.hooks || {}
  for (const evt of HOOK_EVENTS) {
    const src = hk[evt]
    if (!src) continue
    // 全局钩子里路径要写死（不依赖 ${CODEBUDDY_PLUGIN_ROOT}），并去掉插件标记
    const remap = JSON.parse(JSON.stringify(src))
    for (const g of remap) {
      for (const h of (g.hooks || [])) {
        h.command = String(h.command).replace('${CODEBUDDY_PLUGIN_ROOT}', PACKAGE_ROOT.replace(/\\/g, '/'))
        h.command = h.command.replace(/\s--via-plugin/g, '')
      }
    }
    const cur = Array.isArray(settings.hooks[evt]) ? settings.hooks[evt] : []
    settings.hooks[evt] = [...cur, ...remap]
  }
  return HOOK_EVENTS.length
}

// ------------------------------------------------------------------ 命令
function cmdStatus() {
  const s = readJson(SETTINGS_FILE, {})
  const enabled = s?.enabledPlugins || {}
  const extra = s?.extraKnownMarketplaces || {}
  const known = readJson(KNOWN_MARKETS_FILE, {})
  const nHooks = countSettingsHooks(s)

  console.log('=== 当前安装状态 ===')
  console.log(`全局 settings.json 里的本项目钩子 : ${nHooks} 条  ${nHooks > 0 ? '（全局钩子装法 = 开）' : '（关）'}`)
  console.log(`enabledPlugins["${PLUGIN_ID}"]    : ${enabled[PLUGIN_ID] === true ? 'true（插件装法 = 开）' : String(enabled[PLUGIN_ID] ?? '未设置（关）')}`)
  console.log(`settings.extraKnownMarketplaces   : ${extra[MARKET_NAME] ? '已登记' : '无'}`)
  console.log(`known_marketplaces.json 里的市场  : ${known[MARKET_NAME] ? '已登记' : '无'}`)
  console.log(`本地市场目录                      : ${MARKET_DIR} ${fs.existsSync(MARKET_DIR) ? '(存在)' : '(不存在)'}`)

  const both = nHooks > 0 && enabled[PLUGIN_ID] === true
  const none = nHooks === 0 && enabled[PLUGIN_ID] !== true
  console.log('')
  if (both) console.log('⚠️  两套装法同时开着 —— 会重复触发（提示音有去重兜着，但 SessionStart/End 会各跑一遍）。建议只留一套。')
  else if (none) console.log('⚠️  两套都关着 —— 提示音和挂件联动都不会生效。')
  else if (enabled[PLUGIN_ID] === true) console.log('✅ 正在用：插件装法')
  else console.log('✅ 正在用：全局钩子装法')
}

function cmdEnable(keepHooks) {
  console.log('=== 切到「插件装法」 ===')
  const dest = buildMarketplace()
  console.log(`1) 本地市场已生成: ${MARKET_DIR}`)
  console.log(`   插件本体:       ${dest}`)

  // known_marketplaces.json
  const known = readJson(KNOWN_MARKETS_FILE, {}) || {}
  const before = Object.keys(known).length
  known[MARKET_NAME] = marketplaceEntry()
  const bk1 = backup(KNOWN_MARKETS_FILE)
  writeJson(KNOWN_MARKETS_FILE, known)
  console.log(`2) known_marketplaces.json: ${before} -> ${Object.keys(known).length} 个市场  ${bk1 ? `(备份 ${path.basename(bk1)})` : ''}`)

  // settings.json
  const s = readJson(SETTINGS_FILE, {})
  s.enabledPlugins = s.enabledPlugins || {}
  s.enabledPlugins[PLUGIN_ID] = true
  s.extraKnownMarketplaces = s.extraKnownMarketplaces || {}
  s.extraKnownMarketplaces[MARKET_NAME] = marketplaceEntry()
  let removed = 0
  if (!keepHooks) removed = stripSettingsHooks(s)
  const bk2 = backup(SETTINGS_FILE)
  writeJson(SETTINGS_FILE, s)
  console.log(`3) settings.json: enabledPlugins["${PLUGIN_ID}"]=true，extraKnownMarketplaces 已登记  ${bk2 ? `(备份 ${path.basename(bk2)})` : ''}`)
  if (keepHooks) console.log('   --keep-hooks：全局钩子保留（两套并存，用于验证插件是否真的被加载）')
  else console.log(`   同时移走了 ${removed} 条全局钩子`)

  console.log('')
  console.log('✅ 完成。**需要重启 WorkBuddy** 才会重新扫描插件市场。')
}

function cmdDisable() {
  console.log('=== 切回「全局钩子装法」 ===')

  const s = readJson(SETTINGS_FILE, {})
  if (s.enabledPlugins) {
    delete s.enabledPlugins[PLUGIN_ID]
    if (Object.keys(s.enabledPlugins).length === 0) delete s.enabledPlugins
  }
  if (s.extraKnownMarketplaces) {
    delete s.extraKnownMarketplaces[MARKET_NAME]
    if (Object.keys(s.extraKnownMarketplaces).length === 0) delete s.extraKnownMarketplaces
  }
  const n = restoreSettingsHooks(s)
  const bk = backup(SETTINGS_FILE)
  writeJson(SETTINGS_FILE, s)
  console.log(`1) settings.json: 已撤销插件登记，并写回 ${n} 组全局钩子  ${bk ? `(备份 ${path.basename(bk)})` : ''}`)

  const known = readJson(KNOWN_MARKETS_FILE, {}) || {}
  if (known[MARKET_NAME]) {
    delete known[MARKET_NAME]
    const bk1 = backup(KNOWN_MARKETS_FILE)
    writeJson(KNOWN_MARKETS_FILE, known)
    console.log(`2) known_marketplaces.json: 已移除 ${MARKET_NAME}  ${bk1 ? `(备份 ${path.basename(bk1)})` : ''}`)
  }

  console.log('')
  console.log('✅ 完成。**需要重启 WorkBuddy** 生效。')
  console.log(`   （本地市场目录还留着：${MARKET_DIR}，想彻底删掉可以手动删）`)
}

// ------------------------------------------------------------------ main
const argv = process.argv.slice(2)
const cmd = (argv.find((a) => !a.startsWith('-')) || 'status').toLowerCase()
const keepHooks = argv.includes('--keep-hooks')

switch (cmd) {
  case 'status': cmdStatus(); break
  case 'enable': cmdEnable(keepHooks); break
  case 'disable': cmdDisable(); break
  default:
    console.log('用法: node bin/wb-plugin.mjs [status|enable|disable] [--keep-hooks]')
    process.exit(1)
}
