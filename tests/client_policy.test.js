'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')
const P = require('../app/web/client-policy.js')
const scope = { family: 'deepseek', client: 'desktop', staleAfter: 180 }
const claude = { family: 'claude', client: 'tui', staleAfter: 180 }
const snapshot = (extra = {}) => ({ schema: 1, family: 'deepseek', source: 'deepseek-harness', client: 'desktop', sessionId: 'same-session', model: 'claude-test', status: 'Thinking', pose: 'thinking', event: 'PreInvocation', ts: 1000, observedAt: 1000, sequence: 1, producerId: 'process-a', pid: 123, ...extra })
const update = (state, extra, which = scope) => P.ingest(state, snapshot(extra), which)
const reduce = (entries, which = scope) => entries.reduce((s, e) => update(s, e, which).state, {})
const view = (state, now = 1000, which = scope) => P.aggregate(state, now, which)

const fixture = require('./fixtures/client-policy.json')
test('shared Node/JavaScriptCore fixture is deterministic', () => {
  const state = fixture.snapshots.reduce((s, row) => P.ingest(s, row, fixture.scope).state, {})
  assert.deepEqual(P.aggregate(state, fixture.now, fixture.scope), fixture.expected)
  assert.deepEqual(P.hosts(fixture.processes), fixture.expectedHosts)
  const sandbox = vm.createContext({})
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../app/web/client-policy.js'), 'utf8'), sandbox)
  sandbox.fixture = fixture
  const actual = vm.runInContext('JSON.stringify(ClientPolicy.aggregate(fixture.snapshots.reduce((s, row) => ClientPolicy.ingest(s, row, fixture.scope).state, {}), fixture.now, fixture.scope))', sandbox)
  assert.deepEqual(JSON.parse(actual), fixture.expected)
})
test('no session evidence is unknown, never success or offline', () => {
  assert.equal(view({}).event, 'NoSessions')
  assert.equal(view({}).payload.confidence, 'unknown')
  assert.equal(view({}).count, 0)
})
test('source family is independent of model and validates before routing', () => {
  assert.equal(update({}, {}).result, 'applied')
  assert.equal(update({}, {}, claude).result, 'invalid')
  for (const extra of [{ source: 'claude-code' }, { status: 'Maybe' }, { client: 'invented' }, { schema: 2 }, { status: 'Success', event: 'Timeout' }, { status: 'Success', event: 'SessionEnd' }, { status: 'Success', event: 'StopFailure' }, { ts: NaN }, { ts: -1 }, { observedAt: Infinity }, { sessionId: '' }, { sequence: -1 }]) assert.equal(update({}, extra).result, 'invalid')
})
test('reducers do not mutate previous state or input', () => {
  const first = update({}, {}).state, before = JSON.stringify(first)
  update(first, { sequence: 2, ts: 1001, observedAt: 1001 })
  P.processExited(first, Object.keys(first.records)[0], 'process-a', 1002)
  P.aggregate(first, 1500, scope)
  assert.equal(JSON.stringify(first), before)
})
test('duplicate, old sequence, old timestamp and old observation do not regress', () => {
  const first = update({}, {}).state
  for (const extra of [{}, { sequence: 0, observedAt: 1001 }, { sequence: 3, observedAt: 1001, ts: 999 }, { sequence: 3, observedAt: 999, ts: 1001 }]) assert.equal(update(first, extra).result, 'ignored')
  assert.equal(update(first, { sequence: 2, ts: 1001, observedAt: 1001 }).result, 'applied')
})
test('explicit completion settles presentation after four seconds but preserves truth', () => {
  const state = reduce([{ turnId: 'a', status: 'Success', pose: 'happy', event: 'turn/end' }])
  assert.equal(view(state, 1001).status, 'Success')
  assert.equal(view(state, 1004).status, 'Idle')
  assert.equal(view(state, 1004).payload.recordedStatus, 'Success')
  assert.equal(Object.values(state.records)[0].status, 'Success')
  assert.equal(update(state, { sequence: 2, ts: 1005, observedAt: 1005, turnId: 'a' }).result, 'ignored')
  assert.equal(update(state, { sequence: 2, ts: 1005, observedAt: 1005, turnId: 'b' }).result, 'applied')
})
test('silence threshold, waiting and next event recovery preserve intent', () => {
  const state = reduce([{}])
  assert.equal(view(state, 1180).status, 'Thinking')
  assert.equal(view(state, 1180.001).status, 'Unknown')
  assert.equal(view(state, 1181).event, 'StateStale')
  assert.equal(view(state, 1181).stale, true)
  const fresh = update(state, { sequence: 2, ts: 1200, observedAt: 1200 }).state
  assert.equal(view(fresh, 1200).status, 'Thinking')
  for (const status of ['Waiting Input', 'Waiting Permission']) {
    const waiting = reduce([{ status, pose: 'asking' }])
    assert.equal(view(waiting, 5000).status, status)
    assert.equal(view(waiting, 5000).stale, false)
  }
})
test('future timestamps cannot manufacture work, completion or stale status', () => {
  for (const extra of [{}, { status: 'Success', pose: 'happy', event: 'Stop' }, { ts: 999 }]) {
    const state = reduce([extra])
    assert.equal(view(state, 900).status, 'Unknown')
    assert.equal(view(state, 900).event, 'NoSessions')
    assert.equal(view(state, 900).stale, false)
    assert.equal(Object.values(P.sessions(state, 900, scope))[0].event, 'StateUnconfirmed')
  }
})
test('priority respects permission, input, error, tool and thinking', () => {
  let state = {}
  for (const [index, status] of ['Thinking', 'Tool Running', 'Error', 'Waiting Input', 'Waiting Permission'].entries()) {
    state = update(state, { sessionId: String(index), status }).state
    assert.equal(view(state).status, status)
  }
  assert.equal(view(state).count, 5)
})
test('expired terminal acknowledgement cannot hide ongoing work', () => {
  const state = reduce([{ status: 'Error', pose: 'oops', event: 'Stop' }, { sessionId: 'ongoing', status: 'Tool Running', pose: 'running' }])
  assert.equal(view(state, 1001).status, 'Error')
  assert.equal(view(state, 1004).status, 'Tool Running')
  assert.equal(view(state, 1200).status, 'Unknown')
})
test('fresh completion takes precedence over old uncertain evidence', () => {
  const state = reduce([{}, { sessionId: 'new', status: 'Success', event: 'Stop', ts: 1300, observedAt: 1300 }])
  assert.equal(view(state, 1301).status, 'Success')
  assert.equal(view(state, 1305).status, 'Idle')
})
test('same session id remains separate across clients and sources', () => {
  const generic = { family: 'gpt', staleAfter: 180 }
  const state = reduce([{ family: 'gpt', source: 'codex', client: 'tui' }, { family: 'gpt', source: 'codex', client: 'desktop' }], generic)
  assert.equal(Object.keys(P.sessions(state, 1000, generic)).length, 2)
  const terminal = reduce([{ family: 'claude', source: 'claude-code', client: 'tui' }, { family: 'claude', source: 'claude-code', client: 'desktop', status: 'Success', event: 'Stop' }], claude)
  assert.equal(view(terminal, 1000, claude).status, 'Thinking')
})
test('unknown origins are diagnostics only and expire without being guessed', () => {
  const unknown = { family: 'claude', source: 'claude-code', client: 'unknown' }
  let state = reduce([unknown], claude)
  assert.equal(view(state, 1001, claude).payload.unattributed, 1)
  assert.equal(Object.keys(state.records).length, 0)
  assert.equal(view(state, 1300, claude).payload.unattributed, undefined)
  state = update(state, { ...unknown, client: 'tui', sequence: 2, ts: 1001, observedAt: 1001 }, claude).state
  assert.equal(view(state, 1002, claude).payload.unattributed, undefined)
})
test('ended unknown and delayed diagnostic cannot revive the warning', () => {
  const unknown = { family: 'claude', source: 'claude-code', client: 'unknown' }
  const state = reduce([{ ...unknown, sequence: 2 }, { ...unknown, sequence: 3, status: 'Offline', event: 'SessionEnd', ts: 1001, observedAt: 1001 }, { ...unknown, sequence: 1, ts: 999, observedAt: 1002 }], claude)
  assert.equal(view(state, 1002, claude).payload.unattributed, undefined)
})
test('process exit requires same observed producer and never follows silence', () => {
  const state = reduce([{}]), key = Object.keys(state.records)[0]
  assert.equal(P.processExited(state, key, 'wrong', 1001), state)
  assert.equal(P.processExited(state, key, 'process-a', 999), state)
  const exited = P.processExited(state, key, 'process-a', 1001)
  assert.equal(view(exited, 1002).status, 'Offline')
  assert.equal(view(exited, 1002).count, 0)
  assert.equal(view(state, 1002).status, 'Thinking')
})
test('producer restart accepts new sequence without accepting a retired producer', () => {
  let state = reduce([{ turnId: 'a', status: 'Success', event: 'Stop' }])
  state = update(state, { producerId: 'process-b', sequence: 1, turnId: 'a', ts: 1005, observedAt: 1005 }).state
  assert.equal(view(state, 1005).status, 'Thinking')
  assert.equal(update(state, { producerId: 'process-a', sequence: 100, turnId: 'a', ts: 1006, observedAt: 1006 }).result, 'ignored')
})
test('closed turns remain closed beyond a short recent-history window', () => {
  let state = {}
  for (let i = 0; i < 140; i++) state = update(state, { sequence: i + 1, turnId: String(i), status: 'Success', event: 'Stop', ts: 1000 + i, observedAt: 1000 + i }).state
  assert.equal(update(state, { sequence: 141, turnId: '0', ts: 1141, observedAt: 1141 }).result, 'ignored')
})
test('completed result is brief, independent of Offline and cannot come from timeout', () => {
  const state = reduce([{ status: 'Offline', event: 'SessionEnd', pose: 'sleeping', lastResult: { status: 'Success', pose: 'happy', event: 'Stop', ts: 999 } }])
  assert.equal(view(state).status, 'Offline')
  assert.equal(view(state).payload.lastResult.event, 'Stop')
  assert.equal(view(state, 1010).payload.lastResult, undefined)
  const invalid = reduce([{ lastResult: { status: 'Success', pose: 'happy', event: 'Timeout', ts: 999 } }])
  assert.equal(view(invalid).payload.lastResult, undefined)
})
test('stale snapshots strip delayed tool-animation hints', () => {
  const state = reduce([{ after: 'reading', afterTs: 999 }])
  const p = Object.values(P.sessions(state, 1200, scope))[0]
  assert.equal(p.event, 'StateStale')
  assert.equal(p.after, undefined)
  assert.equal(p.afterTs, undefined)
})
test('client registry can extend beyond the initial five descriptors', () => {
  const spec = { id: 'future-editor', family: 'future', source: 'future-engine', client: 'editor', title: 'Future' }
  P.specs.push(spec)
  try {
    const result = update({}, { family: 'future', source: 'future-engine', client: 'editor' }, { family: 'future', client: 'editor' })
    assert.equal(result.result, 'applied')
    assert.equal(P.specs.length, 6)
  } finally { P.specs.pop() }
})

const host = (pid, parent, executable, started = 100) => ({ pid, parent, executable, started })
test('five host presences use executable paths and desktop basename is insufficient', () => {
  const rows = [host(1, 0, '/sbin/launchd'), host(2, 1, '/bin/zsh'), host(10, 1, '/Applications/Claude.app/Contents/MacOS/Claude'), host(20, 1, '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'), host(30, 1, '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'), host(40, 2, '/opt/homebrew/bin/claude'), host(50, 2, '/opt/homebrew/bin/codex')]
  assert.deepEqual(Object.keys(P.hosts(rows)).sort(), P.specs.map(s => s.id).sort())
  assert.deepEqual(P.hosts([host(60, 1, '/tmp/Claude'), host(61, 1, '/tmp/ChatGPT'), host(62, 1, '/Applications/Other.app/Contents/MacOS/ChatGPT')]), {})
  // Presence is intentionally separate from session evidence, including ordinary desktop chat.
  assert.equal(view({}).event, 'NoSessions')
})
test('embedded or orphan CLI and CrossPet helpers cannot be terminal hosts', () => {
  for (const path of ['/Applications/ChatGPT.app/Contents/Resources/bin/codex', '/Applications/Claude.app/Contents/Resources/claude', '/Users/test/.codex/packages/app-server-daemon/releases/test/bin/codex', '/opt/homebrew/bin/claude']) assert.deepEqual(P.hosts([host(70, 1, path)]), {})
  const rows = [host(10, 1, '/Applications/Claude.app/Contents/MacOS/Claude'), host(20, 1, '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'), host(30, 1, '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'), host(40, 1, '/Applications/CrossPet.app/Contents/MacOS/CrossPet'), host(71, 20, '/bin/sh'), host(72, 71, '/opt/homebrew/bin/codex'), host(73, 10, '/opt/homebrew/bin/claude'), host(74, 30, '/opt/homebrew/bin/claude'), host(75, 40, '/opt/homebrew/bin/claude')]
  assert.equal(P.hosts(rows)['claude-tui'], undefined)
  assert.equal(P.hosts(rows)['codex-tui'], undefined)
})
test('ancestry cycles terminate and latest surviving instance defines presence', () => {
  assert.equal(P.hosts([host(80, 81, '/opt/homebrew/bin/codex'), host(81, 80, '/bin/sh')])['codex-tui'], 100)
  assert.equal(P.hosts([host(90, 2, '/opt/homebrew/bin/codex', 50), host(91, 2, '/opt/homebrew/bin/codex', 200)])['codex-tui'], 200)
})
test('appearance rules run only within CrossPet and do not synthesize work', () => {
  assert.equal(P.visible({ mode: 'followApp', master: true }), false)
  assert.equal(P.visible({ mode: 'followApp', master: true, hostStarted: 1 }), true)
  assert.equal(P.visible({ mode: 'followApp', master: false }), true)
  assert.equal(P.visible({ mode: 'always', master: true }), true)
  assert.equal(P.visible({ mode: 'onWork', master: true }), false)
})

test('onWork is driven by activity, uncertainty and explicit completion dwell', () => {
  const active = reduce([{}])
  assert.equal(P.visible({ mode: 'onWork', master: true, state: view(active, 1000), now: 1000 }), true)
  assert.equal(P.visible({ mode: 'onWork', master: true, state: view(active, 1200), now: 1200 }), true)
  assert.equal(P.visible({ mode: 'onWork', master: true, state: view({}), now: 1000, hostStarted: 10 }), false)
  const ended = reduce([{ status: 'Success', pose: 'happy', event: 'Stop' }])
  assert.equal(P.visible({ mode: 'onWork', master: true, state: view(ended, 1001), now: 1001 }), true)
  assert.equal(P.visible({ mode: 'onWork', master: true, state: view(ended, 1004), now: 1004 }), false)
  const exited = P.processExited(active, Object.keys(active.records)[0], 'process-a', 1001)
  assert.equal(P.visible({ mode: 'onWork', master: true, state: view(exited, 1002), now: 1002 }), false)
  assert.equal(P.visible({ mode: 'onWork', master: true, state: view(active, 900), now: 900 }), false)
})
test('foreign snapshot cannot discard retired-producer evidence', () => {
  let state = reduce([{}])
  state = update(state, { producerId: 'process-b', ts: 1001, observedAt: 1001 }).state
  state = update(state, { client: 'unknown', sessionId: 'foreign', ts: 1002, observedAt: 1002 }).state
  assert.equal(update(state, { producerId: 'process-a', ts: 1003, observedAt: 1003, sequence: 3 }).result, 'ignored')
})

test('new root turn retires unfinished predecessor before any late event', () => {
  let state = reduce([{ turnId: 'root-a' }])
  state = update(state, { turnId: 'root-b', sequence: 2, ts: 1001, observedAt: 1001 }).state
  assert.equal(update(state, { turnId: 'root-a', sequence: 3, ts: 1002, observedAt: 1002 }).result, 'ignored')
  assert.equal(view(state, 1002).payload.turnId, 'root-b')
})

test('unavailable clocks cannot report active or completed work', () => {
  const state = reduce([{}])
  for (const now of [NaN, Infinity, 0, -1]) assert.equal(view(state, now).event, 'NoSessions')
})
test('observed process exit closes its turn against delayed work', () => {
  let state = reduce([{ turnId: 'a' }])
  state = P.processExited(state, Object.keys(state.records)[0], 'process-a', 1001)
  assert.equal(update(state, { turnId: 'a', sequence: 2, ts: 1002, observedAt: 1002 }).result, 'ignored')
})
