import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { apply } from '../integrations/deepseek/dsh-plugin-crosspet/lib/index.js';
import { register } from '../integrations/claude-code/mod/hooks/register.ts';
const run = promisify(execFile);
const wait = ms => new Promise(r => setTimeout(r, ms));
async function snapshots(dir, family) {
  const path = join(dir, 'families', family);
  return Promise.all((await readdir(path)).filter(n => n.endsWith('.json')).map(async n => JSON.parse(await readFile(join(path, n), 'utf8'))));
}

test('DSH sessions stay DeepSeek across model changes; only completed is success', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'crosspet-family-dsh-'));
  const handlers = {};
  const ctx = { on(n, f) { (handlers[n] ??= []).push(f); }, inject() {}, effect() {}, credentials: {}, logger: { warn() {} } };
  apply(ctx, { stateDir: dir, autostart: false });
  const fire = async (sid, type, model, data = {}, meta = {}) => {
    const session = { id: sid, header: {}, requestContext: () => ({ model, provider: 'custom' }) };
    for (const fn of handlers['session/event']) fn(session, { type, data, ...meta });
    await wait(80);
  };
  await fire('a', 'turn/start', 'gpt-6');
  await fire('b', 'tool/call', 'claude-sonnet', { name: 'read', arguments: { private: 'HIDDEN' } });
  let records = await snapshots(dir, 'deepseek');
  assert.equal(records.length, 2);
  assert.ok(records.every(r => r.family === 'deepseek' && r.source === 'deepseek-harness' && r.pid === process.pid));
  assert.deepEqual(records.map(r => r.status).sort(), ['Thinking', 'Tool Running']);
  assert.ok(!JSON.stringify(records).includes('HIDDEN'));
  await fire('a', 'turn/end', 'gpt-6', { reason: { kind: 'blocked' } });
  await fire('b', 'turn/end', 'claude-sonnet', { reason: { kind: 'completed' } });
  records = await snapshots(dir, 'deepseek');
  assert.equal(records.find(r => r.sessionId === 'a').status, 'Idle');
  assert.equal(records.find(r => r.sessionId === 'b').status, 'Success');
  await fire('seq', 'turn/start', 'gpt', {}, { seq: 5, time: Date.now() + 9999999 });
  await fire('seq', 'turn/end', 'gpt', { reason: { kind: 'completed' } }, { seq: 6, time: Date.now() });
  await fire('seq', 'tool/call', 'gpt', { name: 'read' }, { seq: 5, time: Date.now() });
  await fire('seq', 'turn/end', 'gpt', { reason: { kind: 'error' } }, { seq: 6, time: Date.now() });
  records = await snapshots(dir, 'deepseek');
  assert.equal(records.find(r => r.sessionId === 'seq').status, 'Success');
  assert.equal(records.find(r => r.sessionId === 'seq').sourceSequence, 6);

  await fire('big', 'turn/start', 'claude', { turn: 7 });
  for (let i = 0; i < 8; i++) await fire('big', 'tool/call', 'claude', { name: 'Read' });
  const child = { id: 'child', header: { origin: 'subagent', parentSession: 'big' }, requestContext: () => ({ model: 'gpt' }) };
  for (const fn of handlers['session/event']) fn(child, { type: 'turn/start', data: {}, time: Date.now() });
  await wait(80);
  records = await snapshots(dir, 'deepseek');
  assert.equal(records.find(r => r.sessionId === 'big').pose, 'delegating');
  assert.ok(!records.some(r => r.sessionId === 'child'));
  await fire('big', 'turn/end', 'claude', { reason: { kind: 'completed' } });
  for (const fn of handlers['session/event']) fn(child, { type: 'turn/end', data: { reason: { kind: 'completed' } }, time: Date.now() });
  await wait(80);
  records = await snapshots(dir, 'deepseek');
  assert.equal(records.find(r => r.sessionId === 'big').pose, 'proud');
  assert.equal(records.find(r => r.sessionId === 'big').turnId, '7');
  assert.equal(records.find(r => r.sessionId === 'big').lastResult.pose, 'proud');
  await fire('big', 'turn/start', 'gpt', { turn: 8 });
  records = await snapshots(dir, 'deepseek');
  assert.equal(records.find(r => r.sessionId === 'big').status, 'Thinking');
  assert.equal(records.find(r => r.sessionId === 'big').lastResult.status, 'Success');
});

test('Claude mod writes independent atomic family snapshots without Node API in mod', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'crosspet-family-mod-'));
  const handlers = {};
  register((n, fn) => { handlers[n] = fn; });
  let sid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  const $ = { env: { get: async n => n === 'CROSSPET_STATE_DIR' ? dir : undefined },
    fs: { write: async (p, s) => { await mkdir(dirname(p), { recursive: true }); await writeFile(p, s); }, read: async p => readFile(p, 'utf8') },
    session: { id: async () => sid }, process: { run: async args => { await run(args[0], args.slice(1)); return { exitCode: 0 }; } } };
  await handlers['tool.call']($, { tool: 'Read' }, async () => ({ isError: false }));
  const heartbeat = await readFile(join(dir, 'seen-claude-mod'), 'utf8');
  assert.match(heartbeat, /^\d+$/);
  assert.ok(Math.abs(Number(heartbeat) - Date.now() / 1000) < 10);
  let records = await snapshots(dir, 'claude');
  assert.equal(records[0].status, 'Thinking');
  assert.equal(records[0].sequence, 2);
  assert.equal(records[0].source, 'claude-code');
  sid = 'other-session';
  await handlers['turn.complete']($, { reason: 'answer' }, async () => ({}));
  records = await snapshots(dir, 'claude');
  assert.equal(records.length, 2);
  assert.equal(records.find(r => r.sessionId === sid).status, 'Success');
  await handlers['classic.Notification']($, { notification_type: 'elicitation_dialog' }, async () => ({}));
  records = await snapshots(dir, 'claude');
  assert.equal(records.find(r => r.sessionId === sid).status, 'Waiting Input');
  await handlers['classic.Notification']($, { notification_type: 'permission_prompt' }, async () => ({}));
  records = await snapshots(dir, 'claude');
  assert.equal(records.find(r => r.sessionId === sid).status, 'Waiting Permission');
  await handlers['session.compact']($, { trigger: 'manual' }, async () => ({}));
  records = await snapshots(dir, 'claude');
  assert.equal(records.find(r => r.sessionId === sid).status, 'Idle');

  // A tool finishing after an explicit Stop must not revive the completed turn.
  sid = 'late-session';
  await handlers['prompt.submit']($, {}, async () => ({}));
  let release, entered;
  const started = new Promise(r => { entered = r; });
  const late = handlers['tool.call']($, { tool: 'Read' }, async () => {
    entered(); return new Promise(r => { release = r; });
  });
  await started;
  await handlers['turn.complete']($, { reason: 'answer' }, async () => ({}));
  release({ isError: false }); await late;
  records = await snapshots(dir, 'claude');
  assert.equal(records.find(r => r.sessionId === 'late-session').status, 'Success');

  // Nor may a previous generation's completion replace a new prompt.
  await handlers['prompt.submit']($, {}, async () => ({}));
  const startedAgain = new Promise(r => { entered = r; });
  const older = handlers['tool.call']($, { tool: 'Read' }, async () => {
    entered(); return new Promise(r => { release = r; });
  });
  await startedAgain;
  await handlers['prompt.submit']($, {}, async () => ({}));
  release({ isError: false }); await older;
  records = await snapshots(dir, 'claude');
  assert.equal(records.find(r => r.sessionId === 'late-session').event, 'UserPromptSubmit');

  // Tool counts belong to the session, even when the SDK shares one mod instance.
  sid = 'big-session';
  await handlers['prompt.submit']($, {}, async () => ({}));
  for (let i = 0; i < 8; i++) await handlers['tool.call']($, { tool: 'Read' }, async () => ({ isError: false }));
  sid = 'small-session';
  await handlers['prompt.submit']($, {}, async () => ({}));
  await handlers['turn.complete']($, { reason: 'answer' }, async () => ({}));
  sid = 'big-session';
  await handlers['turn.complete']($, { reason: 'answer' }, async () => ({}));
  records = await snapshots(dir, 'claude');
  assert.equal(records.find(r => r.sessionId === 'small-session').pose, 'happy');
  assert.equal(records.find(r => r.sessionId === 'big-session').pose, 'proud');
  assert.equal(records.find(r => r.sessionId === 'big-session').lastResult.pose, 'proud');
});
