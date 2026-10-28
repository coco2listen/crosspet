import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { clientOf as claudeClient, register } from '../integrations/claude-code/mod/hooks/register.ts'
import { clientOf as dshClient, apply } from '../integrations/deepseek/dsh-plugin-crosspet/lib/index.js'

test('Claude 只认明确的 Code 入口', () => {
  for (const [entry, expected] of [['cli', 'tui'], ['sdk-cli', 'tui'], ['claude-desktop', 'desktop'], ['', 'unknown'], ['desktop', 'unknown'], [undefined, 'unknown']])
    assert.equal(claudeClient(entry).client, expected)
})
test('DSH 非桌面包不冒充桌面；可执行路径允许空格', () => {
  assert.equal(dshClient('/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness').client, 'desktop')
  assert.equal(dshClient('/usr/local/bin/node').client, 'unknown')
})
test('mod 保留额度 bars，状态与会话附加相同来源；不增加旁路文件', async () => {
  const files = new Map(), handlers = {}
  const $ = { env: { get: async key => ({ CROSSPET_STATE_DIR: '/fake-state', CLAUDE_CODE_ENTRYPOINT: 'claude-desktop', HOME: '/fake-home' })[key] },
    fs: { write: async (path, value) => files.set(path, value), read: async path => files.get(path) ?? '{}', exists: async () => true },
    session: { id: async () => 's1' } }
  register((event, callback) => { handlers[event] = callback })
  await handlers['tool.call']($, { tool: 'Read' }, async () => ({}))
  const state = JSON.parse(files.get('/fake-state/claude-state.json'))
  assert.equal(state.client, 'desktop'); assert.equal(state.host, 'claude'); assert.equal(state.session, 's1')
  const card = JSON.parse(files.get('/fake-state/claude-sessions.json')).s1
  assert.equal(card.clientReason, state.clientReason)
  await handlers['session.measure']($, { rateLimits: [{ kind: 'five_hour', percentUsed: 10 }] }, async () => ({}))
  const quota = JSON.parse(files.get('/fake-state/claude-quota.json'))
  assert.equal(quota.client, 'desktop'); assert.deepEqual(quota.bars, [{ label: '5小时', left: 0.9 }])
  assert.ok([...files.keys()].every(path => !path.includes('/clients/') && !path.includes('/families/')))
})
test('DSH 会话保留实际模型路由，附加证据来源', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'crosspet-source-'))
  try {
    const handlers = {}
    const ctx = { on: (name, callback) => { (handlers[name] ||= []).push(callback) }, effect() {}, inject() { throw Error('fake') }, credentials: { resolve: async () => { throw Error('fake') } }, logger: { warn() {} } }
    apply(ctx, { stateDir: folder, dataDir: folder, autostart: false })
    const session = { id: 's1', header: {}, requestContext: () => ({ provider: 'example', model: 'claude-test' }) }
    for (const callback of handlers['session/event']) await callback(session, { type: 'turn/start', data: {} })
    await new Promise(resolve => setTimeout(resolve, 300))
    const card = JSON.parse(await readFile(join(folder, 'claude-sessions.json'), 'utf8')).s1
    assert.equal(card.host, 'deepseek'); assert.equal(card.session, 's1'); assert.equal(card.client, 'unknown')
    const host = JSON.parse(await readFile(join(folder, 'deepseek-host.json'), 'utf8'))
    assert.equal(host.character, 'claude')
  } finally { await rm(folder, { recursive: true, force: true }) }
})
