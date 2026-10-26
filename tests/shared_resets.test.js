const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

// Execute the production transport functions, with no WebView, network or real timers.
const html = fs.readFileSync(path.join(__dirname, '../app/web/index.html'), 'utf8')
const start = html.indexOf("const RESETS_URL =")
const end = html.indexOf('function resetsTold(', start)
assert.ok(start >= 0 && end > start, 'production reset transport block is present')
const transport = html.slice(start, end)
const turn = () => new Promise(resolve => setImmediate(resolve))

function page(response = { status: 200, ok: true, json: async () => ({ valid: true }) }) {
  const calls = { bridge: [], fetch: [], parsed: [], render: 0, announce: 0 }
  const timers = new Map()
  let timerID = 0
  const context = vm.createContext({
    AbortController,
    Date,
    window: { webkit: { messageHandlers: { pet: { postMessage: message => calls.bridge.push(message) } } } },
    fetch: async (...args) => { calls.fetch.push(args); return response },
    setTimeout: (callback, delay) => { const id = ++timerID; timers.set(id, { callback, delay }); return id },
    clearTimeout: id => timers.delete(id),
    CodexResets: { parse: raw => { calls.parsed.push(raw); return raw?.valid ? { parsed: true } : null } },
    renderQuota: () => calls.render++,
    announceReset: () => calls.announce++,
  })
  vm.runInContext(`${transport}\nthis.api = { setCodexResets, sharedResetResult, fetchResets, pollResets,
    state: () => ({ on: resetsOn, shared: resetsShared, data: resetsData, at: resetsAt, waiters: sharedResetWaiters.length }) };`, context)
  return { api: context.api, calls, timers }
}
const plain = value => JSON.parse(JSON.stringify(value))

test('shared mac pages enable without web fetch or page polling timers', async () => {
  const pages = [page(), page(), page()]
  for (const p of pages) {
    p.api.setCodexResets(true, true)
    p.api.setCodexResets(true, true)
  }
  await turn()
  for (const p of pages) {
    assert.equal(p.api.state().on, true)
    assert.equal(p.api.state().shared, true)
    assert.equal(p.calls.fetch.length, 0)
    assert.equal(p.calls.bridge.length, 0)
    assert.equal(p.timers.size, 0)
  }
})

test('shared explicit requests use the pet bridge and one broadcast resolves every waiter', async () => {
  const p = page()
  p.api.setCodexResets(true, true)
  const first = p.api.fetchResets()
  const second = p.api.fetchResets()
  assert.deepEqual(plain(p.calls.bridge), [{ resetRequest: true }, { resetRequest: true }])
  assert.equal(p.api.state().waiters, 2)
  assert.equal(p.calls.fetch.length, 0)
  assert.equal(p.timers.size, 0)
  p.api.sharedResetResult({ valid: true }, true, 1800000)
  assert.deepEqual(plain(await Promise.all([first, second])), [
    { ok: true, wait: 1800000 }, { ok: true, wait: 1800000 },
  ])
  assert.equal(p.api.state().waiters, 0)
  assert.deepEqual(plain(p.api.state().data), { parsed: true })
  assert.ok(p.api.state().at > 0)
  assert.equal(p.calls.render, 1)
  assert.equal(p.calls.announce, 1)
  assert.equal(p.timers.size, 0)
})

test('native broadcast updates separate shared pages without per-page network requests', () => {
  const pages = [page(), page()]
  for (const p of pages) p.api.setCodexResets(true, true)
  for (const p of pages) p.api.sharedResetResult({ valid: true }, true, 1800000)
  for (const p of pages) {
    assert.deepEqual(plain(p.api.state().data), { parsed: true })
    assert.equal(p.calls.render, 1)
    assert.equal(p.calls.announce, 1)
    assert.equal(p.calls.fetch.length, 0)
    assert.equal(p.timers.size, 0)
  }
})

test('disabling shared reminders drains pending waiters and late data cannot restore them', async () => {
  const p = page()
  p.api.setCodexResets(true, true)
  p.api.sharedResetResult({ valid: true }, true, 1800000)
  const pending = [p.api.fetchResets(), p.api.fetchResets()]
  p.api.setCodexResets(false, true)
  assert.deepEqual(plain(await Promise.all(pending)), [
    { ok: false, wait: 600000 }, { ok: false, wait: 600000 },
  ])
  assert.equal(p.api.state().waiters, 0)
  assert.equal(p.api.state().data, null)
  assert.equal(p.api.state().at, 0)
  const renders = p.calls.render
  p.api.sharedResetResult({ valid: true }, true, 1800000)
  assert.equal(p.api.state().data, null)
  assert.equal(p.calls.render, renders)
  assert.equal(p.calls.announce, 1)
  assert.equal(p.timers.size, 0)
})

test('invalid shared data resolves requests as failed and preserves the last valid data', async () => {
  const p = page()
  p.api.setCodexResets(true, true)
  p.api.sharedResetResult({ valid: true }, true, 1800000)
  const pending = p.api.fetchResets()
  p.api.sharedResetResult({ valid: false }, true, 600000)
  assert.deepEqual(plain(await pending), { ok: false, wait: 600000 })
  assert.deepEqual(plain(p.api.state().data), { parsed: true })
  assert.equal(p.api.state().waiters, 0)
  assert.equal(p.calls.announce, 1)
})

test('non-shared pages retain direct web fetch and periodic polling', async () => {
  const p = page()
  p.api.setCodexResets(true)
  await turn()
  assert.equal(p.calls.bridge.length, 0)
  assert.equal(p.calls.fetch.length, 1)
  assert.equal(p.calls.fetch[0][0], 'https://codex-resets.com/api/v1/status')
  assert.equal(p.calls.fetch[0][1].cache, 'no-store')
  assert.ok(p.calls.fetch[0][1].signal instanceof AbortSignal)
  assert.deepEqual(plain(p.api.state().data), { parsed: true })
  assert.equal(p.calls.render, 1)
  assert.equal(p.calls.announce, 1)
  assert.equal(p.timers.size, 1)
  const timer = [...p.timers.values()][0]
  assert.equal(timer.delay, 1800000)
  await timer.callback()
  assert.equal(p.calls.fetch.length, 2)
  assert.equal(p.timers.size, 1)
  p.api.setCodexResets(false)
  assert.equal(p.timers.size, 0)
})

test('non-shared retry retains server Retry-After rather than starting a native request', async () => {
  const p = page({ status: 429, ok: false, headers: { get: name => name === 'Retry-After' ? '45' : null } })
  p.api.setCodexResets(true, false)
  await turn()
  assert.equal(p.calls.fetch.length, 1)
  assert.equal(p.calls.bridge.length, 0)
  assert.equal(p.calls.parsed.length, 0)
  assert.equal(p.timers.size, 1)
  assert.equal([...p.timers.values()][0].delay, 45000)
  p.api.setCodexResets(false, false)
  assert.equal(p.timers.size, 0)
})
