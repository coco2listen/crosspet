// 沉默只说明状态失去确认，不代表任务完成；显式传入时间，供网页与原生 JS 引擎共用。
;(function (root) {
  const STALE_AFTER = 180
  const REST = new Set(['idle', 'sleeping', 'tired', 'hungry', 'happy', 'proud'])
  const END = new Set(['Stop', 'StopFailure', 'StopCancelled', 'Interrupt', 'SessionEnd', 'AfterAgent', 'turn/end'])

  function evaluate(snapshot, now, staleAfter = STALE_AFTER) {
    if (!snapshot || !snapshot.pose) return { kind: 'waiting', label: '等待会话事件', pose: 'idle', stale: false, remaining: null }
    const pose = snapshot.pose, event = snapshot.event || ''
    const result = (kind, label = '', stale = false, remaining = null) => ({ kind, label, pose: stale ? 'idle' : pose, stale, remaining })
    if (event === 'SessionEnd') return result('offline')
    if (pose === 'asking') return result('ask')  // 等用户答复可持续很久，沿用现有规则。
    if (END.has(event)) return result('done')
    if (REST.has(pose) || pose.startsWith('greet_') || pose.startsWith('fest_')) return result('idle')
    // 工具中途出错仍可能继续工作；只有结束事件才证明这一轮已结束。
    const ts = Number(snapshot.ts), clock = Number(now)
    const limit = Number.isFinite(staleAfter) && staleAfter > 0 ? staleAfter : STALE_AFTER
    if (!Number.isFinite(ts) || ts <= 0 || !Number.isFinite(clock) || ts > clock + 5) return result('unconfirmed', '状态待确认', true)
    // 系统时钟回拨 / 未来时间不能让陈旧事件永久免于确认。
    const age = Math.max(0, clock - ts)
    if (age >= limit) return result('unconfirmed', '状态待确认', true)
    return result('work', '', false, limit - age)
  }

  root.SessionStatus = { STALE_AFTER, evaluate }
  if (typeof module !== 'undefined') module.exports = root.SessionStatus
})(typeof window !== 'undefined' ? window : globalThis)
