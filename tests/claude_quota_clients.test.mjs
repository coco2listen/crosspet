import { test } from 'node:test';
import assert from 'node:assert/strict';

let fixtureId = 0;
async function fixture(environment = {}) {
  const { register } = await import(`../integrations/claude-code/mod/hooks/register.ts?quota-test=${++fixtureId}`);
  const handlers = {}, files = new Map(), moves = [], commands = [], directories = new Set();
  const control = { mkdirExit: 0, moveExit: 0, onMove: null };
  register((name, fn) => { handlers[name] = fn; });
  const root = '/test-state';
  directories.add(root);
  const $ = {
    env: { get: async name => ({ CROSSPET_STATE_DIR: root, ...environment })[name] },
    fs: {
      write: async (path, text) => {
        if (path.includes('/clients/')) assert.ok(directories.has(`${root}/clients`), 'clients directory must exist before Engine fs.write');
        files.set(path, text);
      },
      read: async path => { if (!files.has(path)) throw new Error('not found'); return files.get(path); },
      exists: async () => true,
    },
    session: { id: async () => 'quota-session', usage: async () => ({ rateLimits: [] }) },
    process: { run: async args => {
      commands.push([...args]);
      if (args[0] === '/bin/mkdir') {
        assert.deepEqual(args, ['/bin/mkdir', '-p', `${root}/clients`]);
        if (control.mkdirExit === 0) directories.add(args[2]);
        return { exitCode: control.mkdirExit };
      }
      assert.equal(args[0], '/bin/mv');
      assert.equal(args[1], '-f');
      assert.ok(files.has(args[2]));
      moves.push(args);
      if (control.onMove) await control.onMove(args);
      if (control.moveExit !== 0) return { exitCode: control.moveExit };
      files.set(args[3], files.get(args[2])); files.delete(args[2]);
      return { exitCode: 0 };
    } },
  };
  const measure = async (limits, env = environment) => {
    $.env.get = async name => ({ CROSSPET_STATE_DIR: root, ...env })[name];
    await handlers['session.measure']($, { rateLimits: limits }, async () => ({}));
  };
  const read = file => JSON.parse(files.get(`${root}/${file}`));
  return { handlers, $, files, moves, commands, directories, control, measure, read };
}
const fiveHour = percentUsed => [{ kind: 'five_hour', percentUsed }];

test('Claude usage and measurements preserve independent desktop and terminal quotas', async () => {
  const f = await fixture({ CLAUDE_CODE_ENTRYPOINT: 'cli' });
  f.$.session.usage = async () => ({ rateLimits: fiveHour(5) });
  await f.handlers['session.start'](f.$, {}, async () => ({}));
  assert.equal(f.read('clients/claude-tui-quota.json').quota.text, '5小时 剩余 95%');
  await f.measure(fiveHour(80), { CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' });
  assert.deepEqual(f.read('clients/claude-desktop-quota.json'), {
    schema: 1, family: 'claude', source: 'claude-code', client: 'desktop', quota: { text: '5小时 剩余 20%', low: false },
  });
  assert.equal(f.read('clients/claude-tui-quota.json').quota.text, '5小时 剩余 95%');
  assert.deepEqual(f.read('claude-quota.json'), f.read('clients/claude-desktop-quota.json').quota);
  assert.ok(f.moves.some(args => args[3].endsWith('/clients/claude-tui-quota.json')));
  assert.ok(f.moves.some(args => args[3].endsWith('/clients/claude-desktop-quota.json')));
  assert.ok([...f.files.keys()].every(path => !path.endsWith('.tmp')));
});

test('explicit empty measurements clear only that client quota and preserve the other client', async () => {
  const f = await fixture();
  await f.measure(fiveHour(10), { CLAUDE_CODE_ENTRYPOINT: 'cli' });
  await f.measure(fiveHour(90), { CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' });
  await f.measure([], { CLAUDE_CODE_ENTRYPOINT: 'cli' });
  assert.equal(f.read('clients/claude-tui-quota.json').quota, null);
  assert.equal(f.read('clients/claude-desktop-quota.json').quota.text, '5小时 剩余 10%');
  assert.equal(f.read('claude-quota.json'), null);
  await f.measure([{ kind: 'unrecognised', percentUsed: 90 }], { CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' });
  assert.equal(f.read('clients/claude-desktop-quota.json').quota, null);
});

test('unknown origins stay unknown while the established explicit override remains supported', async () => {
  const f = await fixture();
  await f.measure(fiveHour(20), { CLAUDE_CODE_ENTRYPOINT: 'unrecognised' });
  assert.equal(f.read('clients/claude-unknown-quota.json').client, 'unknown');
  assert.equal(f.files.has('/test-state/clients/claude-desktop-quota.json'), false);
  assert.equal(f.files.has('/test-state/clients/claude-tui-quota.json'), false);
  await f.measure(fiveHour(30), { CROSSPET_CLIENT: 'desktop', CLAUDE_CODE_ENTRYPOINT: 'cli' });
  assert.equal(f.read('clients/claude-desktop-quota.json').client, 'desktop');
  await f.measure(fiveHour(40), { CROSSPET_CLIENT: 'invalid', CLAUDE_CODE_ENTRYPOINT: 'sdk-cli' });
  assert.equal(f.read('clients/claude-tui-quota.json').client, 'tui');
});

test('Windows keeps legacy quota output without invoking the macOS rename command', async () => {
  const f = await fixture({ LOCALAPPDATA: 'C:\\Users\\test\\AppData\\Local', CLAUDE_CODE_ENTRYPOINT: 'cli' });
  await f.measure(fiveHour(25));
  assert.equal(f.read('claude-quota.json').text, '5小时 剩余 75%');
  assert.equal(f.moves.length, 0);
  assert.equal(f.commands.length, 0);
  assert.ok([...f.files.keys()].every(path => !path.includes('/clients/')));
});


test('new client quota directory is explicitly created before writing any temporary snapshot', async () => {
  const f = await fixture({ CLAUDE_CODE_ENTRYPOINT: 'cli' });
  assert.equal(f.directories.has('/test-state/clients'), false);
  await f.measure(fiveHour(15));
  assert.deepEqual(f.commands[0], ['/bin/mkdir', '-p', '/test-state/clients']);
  assert.equal(f.directories.has('/test-state/clients'), true);
  assert.equal(f.read('clients/claude-tui-quota.json').quota.text, '5小时 剩余 85%');
});

test('mkdir and rename failures do not publish incomplete quotas or poison later measurements', async () => {
  const f = await fixture({ CLAUDE_CODE_ENTRYPOINT: 'cli' });
  f.control.mkdirExit = 1;
  await f.measure(fiveHour(10));
  assert.equal(f.files.has('/test-state/clients/claude-tui-quota.json'), false);
  assert.equal(f.moves.length, 0);
  f.control.mkdirExit = 0;
  await f.measure(fiveHour(20));
  assert.equal(f.read('clients/claude-tui-quota.json').quota.text, '5小时 剩余 80%');
  f.control.moveExit = 1;
  await f.measure(fiveHour(30));
  assert.equal(f.read('clients/claude-tui-quota.json').quota.text, '5小时 剩余 80%');
  f.control.moveExit = 0;
  await f.measure(fiveHour(40));
  assert.equal(f.read('clients/claude-tui-quota.json').quota.text, '5小时 剩余 60%');
});

test('overlapping measurements for the same client serialize their atomic renames', async () => {
  const f = await fixture({ CLAUDE_CODE_ENTRYPOINT: 'cli' });
  let release, started;
  const firstMoveStarted = new Promise(resolve => { started = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  let count = 0;
  f.control.onMove = async () => { if (++count === 1) { started(); await gate; } };
  const first = f.measure(fiveHour(10));
  await firstMoveStarted;
  const second = f.measure(fiveHour(80));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.moves.length, 1, 'second move must wait while first move is pending');
  release(); await Promise.all([first, second]);
  assert.equal(f.moves.length, 2);
  assert.equal(f.read('clients/claude-tui-quota.json').quota.text, '5小时 剩余 20%');
});
