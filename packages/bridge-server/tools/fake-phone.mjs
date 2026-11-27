/**
 * Stand-in phone used for local end-to-end checks: speaks the bridge wire
 * protocol over WebSocket without Android in the loop.
 *
 * Usage: node tools/fake-phone.mjs [ws-url]
 */

import WebSocket from 'ws'

/** Operations the fake phone answers, mirroring the v1 app contract. */
export const FAKE_CAPS = [
  'ping',
  'info',
  'shares',
  'clipboard.get',
  'clipboard.set',
  'notify',
  'open',
  'files.save',
  'files.open',
  'fs.roots',
  'fs.list',
  'fs.read',
  'fs.write',
  'fs.mkdir',
  'apps.list',
  'apps.launch',
  'a11y.status',
  'a11y.tree',
  'a11y.screenshot',
  'a11y.tap',
  'a11y.swipe',
  'a11y.global',
  'a11y.find',
  'a11y.text',
  'device.status',
  'media.latest',
]

/** The terminal's drawn canvas: what input focus rests on before anything is typed. */
const XTERM_CANVAS = { class: 'android.view.View', clickable: true, bounds: [0, 400, 1080, 2200] }

/** The terminal's real edit box: one hidden EditText, the screen's only editable node. */
const TERMINAL_INPUT = { hint: '终端输入', class: 'android.widget.EditText', editable: true, bounds: [0, 2360, 1080, 2400] }

/** Nodes the fake phone pretends are on screen; a11y.tree reports the first two. */
const SCREEN_NODES = [
  { text: 'Chats', class: 'android.widget.TextView', bounds: [0, 0, 1080, 160] },
  { text: 'Alice', class: 'android.widget.TextView', clickable: true, bounds: [0, 160, 1080, 320] },
  { text: 'Send', desc: 'Send message', class: 'android.widget.Button', clickable: true, bounds: [800, 2200, 1080, 2400] },
  TERMINAL_INPUT,
]

/** "终端输入" / "Search | dsh": hint and text clipped to 20 characters, as the app reports them. */
const labelOf = (node) => {
  const clip = (value) => {
    if (typeof value !== 'string') return ''
    const text = value.trim().replace(/\s+/g, ' ')
    return text.length > 20 ? `${text.slice(0, 20)}…` : text
  }
  const hint = clip(node.hint)
  const text = clip(node.text)
  if (hint && text && hint !== text) return `${hint} | ${text}`
  return hint || text || '<no label>'
}

/**
 * What a11y.text does on a screen, mirroring A11yService.typeText.
 *
 * The focused field takes the text. When the focus is on a node that takes no text, the screen's
 * only editable node is the auto-focus case; zero or several editable nodes fail with the same
 * wording the app uses, candidates included.
 *
 * @param {{ nodes: Array<object>, focus: object | null, text: unknown }} screen fake screen state
 * @returns {{ ok: true, length: number, focused?: boolean } | { ok: false, error: string }} outcome
 */
export function typeOnScreen({ nodes, focus, text }) {
  const value = String(text ?? '')
  if (focus?.editable) return { ok: true, length: value.length }
  const editable = nodes.filter((node) => node.editable)
  if (editable.length > 1) {
    const labels = editable.map(labelOf).join(' / ')
    return {
      ok: false,
      error: `the screen shows ${editable.length} editable text fields but none of them has input focus; tap the field itself first: ${labels}`,
    }
  }
  if (editable.length === 0) {
    return {
      ok: false,
      error: focus
        ? 'the focused node is not an editable text field; tap the field itself first'
        : 'no text field has input focus; tap the field first',
    }
  }
  return { ok: true, length: value.length, focused: true }
}

/** One tree row: bounds plus the tap centre, as a11y.tree reports them. */
const treeEntry = (node) => ({
  ...node,
  center: [Math.round((node.bounds[0] + node.bounds[2]) / 2), Math.round((node.bounds[1] + node.bounds[3]) / 2)],
})

/** One a11y.find row: exactly the keys the app answers with. */
const findEntry = (node) => ({
  ...(node.text ? { text: node.text } : {}),
  ...(node.desc ? { desc: node.desc } : {}),
  ...(node.hint ? { hint: node.hint } : {}),
  view_id: `com.example.chat:id/${String(node.text ?? node.hint ?? 'node').toLowerCase()}`,
  class: node.class,
  ...(node.editable ? { editable: true } : {}),
  bounds: node.bounds,
  x: Math.round((node.bounds[0] + node.bounds[2]) / 2),
  y: Math.round((node.bounds[1] + node.bounds[3]) / 2),
})

/**
 * Open a fake phone connection and complete the hello handshake.
 *
 * @param {{ url: string, deviceId?: string, name?: string, model?: string, headers?: Record<string, string> }} options connection target and identity
 * @returns {Promise<{ ws: WebSocket, id: string, calls: Array<object>, close: () => void }>} live fake phone
 */
export function connectFakePhone({ url, deviceId = 'fake-phone', name = 'Fake Phone', model = 'Pixel (fake)', headers = {} }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers })
    /** @type {Array<object>} */
    const calls = []
    const phone = { ws, id: deviceId, calls, close: () => ws.close() }
    /** Root-relative path -> { data, encoding, mime, at }; mirrors the app's two roots. */
    const files = new Map([
      ['tree:/notes/todo.md', { data: 'buy milk\n', encoding: 'utf8', mime: 'text/markdown', at: Date.now() }],
      ['downloads:/hello.txt', { data: 'hello from the fake phone\n', encoding: 'utf8', mime: 'text/plain', at: Date.now() }],
    ])
    /** Where the keyboard focus sits; the fake terminal starts on its drawn canvas. */
    let focus = XTERM_CANVAS
    const entryOf = (path, meta) => ({
      name: path.slice(path.lastIndexOf('/') + 1),
      path,
      kind: 'file',
      size: meta.data.length,
      mtime: meta.at,
    })
    const listRoot = (root) => {
      const prefix = `${root}/`
      const dirs = new Set()
      const rows = []
      for (const [path, meta] of files) {
        if (!path.startsWith(prefix)) continue
        const rest = path.slice(prefix.length)
        const slash = rest.indexOf('/')
        if (slash < 0) {
          rows.push(entryOf(path, meta))
          continue
        }
        const dir = rest.slice(0, slash)
        if (dirs.has(dir)) continue
        dirs.add(dir)
        rows.push({ name: dir, path: `${prefix}${dir}`, kind: 'directory', size: 0, mtime: Date.now() })
      }
      return rows
    }
    ws.on('error', reject)
    ws.on('open', () => {
      ws.send(JSON.stringify({ t: 'hello', device: { id: deviceId, name, model }, caps: FAKE_CAPS }))
    })
    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString())
      if (msg.t === 'welcome') {
        phone.id = msg.id
        resolve(phone)
        return
      }
      if (msg.t !== 'call') return
      calls.push(msg)
      const answer = (ok, payload) => ws.send(JSON.stringify({ t: 'res', id: msg.id, ok, ...payload }))
      switch (msg.op) {
        case 'ping':
          return answer(true, { data: { pong: true, at: Date.now() } })
        case 'info':
          return answer(true, { data: { id: deviceId, model, caps: FAKE_CAPS } })
        case 'shares':
          return answer(true, {
            data: {
              items: [
                { id: 's1', name: 'report.pdf', mime: 'application/pdf', at: Date.now() },
                { id: 's2', name: 'note', mime: 'text/plain', text: 'shared from another app', at: Date.now() },
              ],
            },
          })
        case 'clipboard.get':
          return answer(true, { data: { text: 'clipboard text from the fake phone' } })
        case 'clipboard.set':
          return answer(true, { data: { ok: true, bytes: String(msg.args?.text ?? '').length } })
        case 'notify':
        case 'open':
          return answer(true, { data: { ok: true } })
        case 'files.save':
          return answer(true, {
            data: {
              uri: `content://media/external/downloads/${msg.args?.name ?? 'file'}`,
              name: msg.args?.name ?? 'file',
              dest: msg.args?.dest ?? 'downloads',
              size: String(msg.args?.data ?? '').length,
            },
          })
        case 'files.open':
          return answer(true, {
            data: {
              ok: true,
              uri: msg.args?.uri ?? (msg.args?.name ? `content://media/external/downloads/${msg.args.name}` : msg.args?.path),
              mime: msg.args?.mime ?? 'application/octet-stream',
            },
          })
        case 'fs.roots':
          return answer(true, {
            data: {
              roots: [
                { kind: 'tree', path: 'tree:/', label: 'Fake Folder', writable: true },
                { kind: 'downloads', path: 'downloads:/', label: 'Downloads/DSH', writable: true },
              ],
              shared: 'content://com.android.externalstorage.documents/tree/primary%3AFake',
            },
          })
        case 'fs.list': {
          const path = String(msg.args?.path ?? '')
          const root = path.replace(/\/+$/, '')
          if (!root.startsWith('tree:') && !root.startsWith('downloads:')) {
            return answer(false, { error: `not a browsable root: ${path}` })
          }
          const slash = root.indexOf('/')
          const base = slash < 0 ? `${root}/` : root
          return answer(true, { data: { path: base, entries: listRoot(base.replace(/\/$/, '')) } })
        }
        case 'fs.read': {
          const path = String(msg.args?.path ?? '')
          const meta = files.get(path)
          if (!meta) return answer(false, { error: `no such file: ${path}` })
          const payload = { path, name: path.slice(path.lastIndexOf('/') + 1), size: meta.data.length, mime: meta.mime }
          if (meta.encoding === 'base64') return answer(true, { data: { ...payload, encoding: 'base64', data: meta.data } })
          return answer(true, { data: { ...payload, encoding: 'utf8', text: meta.data } })
        }
        case 'fs.write': {
          const path = String(msg.args?.path ?? '')
          const data = String(msg.args?.data ?? '')
          const created = !files.has(path)
          files.set(path, {
            data,
            encoding: msg.args?.encoding === 'base64' ? 'base64' : 'utf8',
            mime: msg.args?.mime ?? 'application/octet-stream',
            at: Date.now(),
          })
          return answer(true, {
            data: { path, name: path.slice(path.lastIndexOf('/') + 1), size: data.length, created },
          })
        }
        case 'fs.mkdir': {
          const path = String(msg.args?.path ?? '')
          const prefixed = `${path}/`
          for (const existing of files.keys()) {
            if (existing === path) return answer(false, { error: `already a file: ${path}` })
          }
          const created = ![...files.keys()].some((k) => k.startsWith(prefixed))
          files.set(`${path}/.keep`, { data: '', encoding: 'utf8', mime: 'text/plain', at: Date.now() })
          return answer(true, { data: { path, ok: true, created } })
        }
        case 'apps.list':
          return answer(true, {
            data: {
              apps: [
                { package: 'com.example.chat', label: 'Chat' },
                { package: 'com.example.notes', label: 'Notes' },
              ],
            },
          })
        case 'apps.launch':
          return answer(true, { data: { ok: true, package: msg.args?.package } })
        case 'a11y.status':
          return answer(true, { data: { service: true, allowed: true, sdk: 34 } })
        case 'a11y.tree':
          return answer(true, {
            data: {
              tree: {
                package: 'com.example.chat',
                count: 2,
                nodes: SCREEN_NODES.slice(0, 2).map(treeEntry),
              },
            },
          })
        case 'a11y.screenshot':
          return answer(true, { data: { image: 'ZmFrZS1qcGVn', mime: 'image/jpeg', width: 1080, height: 2400, bytes: 9 } })
        case 'a11y.tap':
        case 'a11y.swipe':
        case 'a11y.global':
          return answer(true, { data: { ok: true } })
        case 'a11y.find': {
          const needle = String(msg.args?.text ?? '').trim().toLowerCase()
          const exact = Boolean(msg.args?.exact)
          const max = Math.max(1, Math.min(Number(msg.args?.max ?? 10) || 10, 50))
          const nodes = SCREEN_NODES.filter((node) => [node.text, node.desc, node.hint]
            .filter((value) => typeof value === 'string')
            .some((value) => (exact ? value.trim().toLowerCase() === needle : value.trim().toLowerCase().includes(needle))))
            .slice(0, max)
            .map(findEntry)
          return answer(true, { data: { count: nodes.length, nodes } })
        }
        case 'a11y.text': {
          const value = String(msg.args?.text ?? '')
          const typed = typeOnScreen({ nodes: SCREEN_NODES, focus, text: value })
          if (!typed.ok) return answer(false, { error: typed.error })
          // The app focuses the only edit box before retrying; from now on the focus is on it.
          if (typed.focused) focus = SCREEN_NODES.find((node) => node.editable)
          if (focus) focus.text = value
          return answer(true, { data: { ok: true, length: typed.length } })
        }
        case 'device.status':
          return answer(true, {
            data: {
              battery_percent: 87,
              battery_charging: true,
              screen_on: true,
              screen_width: 1080,
              screen_height: 2400,
              network: 'wifi',
              a11y: true,
            },
          })
        case 'media.latest': {
          const kind = String(msg.args?.kind ?? 'image')
          const limit = Math.max(1, Math.min(Number(msg.args?.limit ?? 1) || 1, 20))
          const items = [
            { id: 42, name: 'IMG_20260101_120000.jpg', mime: 'image/jpeg', size: 123456, date_added_ms: Date.now() - 60_000, path: '/storage/emulated/0/DCIM/Camera/IMG_20260101_120000.jpg' },
            { id: 41, name: 'Screenshot_20260101.png', mime: 'image/png', size: 78901, date_added_ms: Date.now() - 3_600_000, path: '/storage/emulated/0/Pictures/Screenshots/Screenshot_20260101.png' },
            { id: 40, name: 'VID_20251231.mp4', mime: 'video/mp4', size: 9_876_543, date_added_ms: Date.now() - 7_200_000, path: '/storage/emulated/0/DCIM/Camera/VID_20251231.mp4' },
          ].filter((item) => kind === 'any' || item.mime.startsWith(`${kind}/`))
            .slice(0, limit)
          return answer(true, { data: { count: items.length, items } })
        }
        default:
          return answer(false, { error: `fake phone has no op ${msg.op}` })
      }
    })
  })
}

/**
 * Self-check for the typing simulation, no server needed:
 * node tools/fake-phone.mjs --selftest
 *
 * Covers the four shapes A11yService.typeText distinguishes: the focused field, exactly one
 * editable node (auto-focused, the terminal case), several edit boxes, and none.
 */
if (process.argv[2] === '--selftest') {
  let failed = 0
  const expect = (name, ok) => {
    console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${name}`)
    if (!ok) failed += 1
  }
  const focused = typeOnScreen({ nodes: SCREEN_NODES, focus: TERMINAL_INPUT, text: 'ls' })
  expect('the focused field takes the text', focused.ok === true && focused.length === 2 && !focused.focused)
  const single = typeOnScreen({ nodes: SCREEN_NODES, focus: XTERM_CANVAS, text: 'ls' })
  expect('the only editable node is focused and typed into', single.ok === true && single.length === 2 && single.focused === true)
  const several = typeOnScreen({ nodes: [TERMINAL_INPUT, { hint: 'Search', editable: true }], focus: XTERM_CANVAS, text: 'ls' })
  expect('several edit boxes fail and name both labels', several.ok === false && several.error.includes('终端输入') && several.error.includes('Search'))
  const none = typeOnScreen({ nodes: [SCREEN_NODES[0]], focus: XTERM_CANVAS, text: 'ls' })
  expect('no edit box keeps the original error', none.ok === false && none.error === 'the focused node is not an editable text field; tap the field itself first')
  const unfocused = typeOnScreen({ nodes: [SCREEN_NODES[0]], focus: null, text: 'ls' })
  expect('no input focus keeps the original error', unfocused.ok === false && unfocused.error === 'no text field has input focus; tap the field first')
  console.log(`\n${5 - failed}/5 self-checks passed`)
  process.exit(failed === 0 ? 0 : 1)
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const url = process.argv[2] ?? 'ws://127.0.0.1:3082/bridge/ws'
  const phone = await connectFakePhone({ url })
  console.log(`[fake-phone] connected as ${phone.id}; waiting for calls`)
  phone.ws.on('close', () => console.log('[fake-phone] closed'))
}
