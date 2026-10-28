const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path')
const { STALE_AFTER, evaluate } = require('../app/web/session-status.js')
const now = 1000
const work = (ts = now, extra = {}) => ({ pose: 'thinking', event: 'BeforeModel', ts, ...extra })

test('180 秒边界：只在达到门槛时显示待确认，不伪造终止事件', () => {
  assert.equal(STALE_AFTER, 180)
  assert.equal(evaluate(work(now - 179.999), now).kind, 'work')
  assert.deepEqual(evaluate(work(now - 180), now), { kind: 'unconfirmed', label: '状态待确认', pose: 'idle', stale: true, remaining: null })
})
test('无会话证据必须明确等待，不能声称离线', () => {
  assert.equal(evaluate(null, now).label, '等待会话事件')
  assert.equal(evaluate({}, now).kind, 'waiting')
})
test('沉默提示不改写输入，恢复事件可再次显示工作', () => {
  const old = Object.freeze(work(now - 181))
  assert.equal(evaluate(old, now).stale, true)
  assert.equal(old.event, 'BeforeModel')
  assert.equal(old.pose, 'thinking')
  assert.equal(evaluate(work(now), now).kind, 'work')
})
test('asking 保留已有等待用户规则', () => {
  assert.equal(evaluate(work(1, { pose: 'asking', event: 'Notification' }), now).kind, 'ask')
})
test('完成、打断、关闭事件不因沉默变成未知', () => {
  for (const event of ['Stop', 'StopFailure', 'StopCancelled', 'Interrupt', 'AfterAgent', 'turn/end']) {
    assert.equal(evaluate(work(1, { pose: 'oops', event }), now).kind, 'done', event)
  }
  assert.equal(evaluate(work(1, { pose: 'sleeping', event: 'SessionEnd' }), now).kind, 'offline')
})
test('工具中途错误没有结束证据时仍会变为待确认', () => {
  assert.equal(evaluate(work(1, { pose: 'oops', event: 'PostToolUse' }), now).stale, true)
})
test('已处于待机和日常动作不额外产生任务提示', () => {
  for (const pose of ['idle', 'sleeping', 'tired', 'hungry', 'happy', 'proud', 'greet_morning', 'fest_christmas']) {
    assert.equal(evaluate(work(1, { pose }), now).label, '', pose)
  }
})
test('无效时间与过远未来时间不冒充可靠工作证据', () => {
  for (const ts of [undefined, NaN, Infinity, -1, 0, now + 60]) {
    assert.equal(evaluate({ ...work(), ts }, now).kind, 'unconfirmed', String(ts))
  }
  assert.equal(evaluate(work(now), NaN).kind, 'unconfirmed')
})
test('容忍很小的时钟偏差，但剩余时间不超过门槛', () => {
  assert.equal(evaluate(work(now + 1), now).remaining, 180)
})
test('门槛可显式注入，非法门槛回退至 180 秒', () => {
  assert.equal(evaluate(work(now - 20), now, 10).stale, true)
  assert.equal(evaluate(work(now - 20), now, NaN).stale, false)
})
test('模块无需 DOM、Node 或外部时钟，可用于 JavaScriptCore', () => {
  const sandbox = {}
  vm.createContext(sandbox)
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../app/web/session-status.js'), 'utf8'), sandbox)
  assert.equal(sandbox.SessionStatus.evaluate(work(now - 180), now).label, '状态待确认')
})
