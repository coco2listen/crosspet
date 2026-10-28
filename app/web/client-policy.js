// Platform-independent client routing. Inputs contain metadata only; this module has no I/O or clock.
;(function (root) {
  'use strict'
  const specs = [
    { id: 'claude-tui', family: 'claude', source: 'claude-code', client: 'tui', title: 'Claude 娘 · 终端' },
    { id: 'claude-desktop', family: 'claude', source: 'claude-code', client: 'desktop', title: 'Claude 娘 · 桌面' },
    { id: 'codex-tui', family: 'gpt', source: 'codex', client: 'tui', title: 'GPT 白龙娘 · 终端' },
    { id: 'codex-desktop', family: 'gpt', source: 'codex', client: 'desktop', title: 'GPT 白龙娘 · 桌面' },
    { id: 'dsh-desktop', family: 'deepseek', source: 'deepseek-harness', client: 'desktop', title: 'DeepSeek 娘 · 桌面' },
  ]
  const priority = { Offline: 0, Idle: 1, Success: 2, Thinking: 3, 'Tool Running': 4, Error: 5, 'Waiting Input': 6, 'Waiting Permission': 7 }
  const successEvents = ['Stop', 'AfterAgent', 'turn/end']
  const ended = ['Stop', 'StopFailure', 'StopCancelled', 'Interrupt', 'AfterAgent', 'turn/end', 'SessionEnd']
  const has = (o, key) => Object.prototype.hasOwnProperty.call(o, key)
  const object = x => x !== null && typeof x === 'object' && !Array.isArray(x)
  const finiteTime = x => typeof x === 'number' && Number.isFinite(x) && x > 0
  const keyOf = s => JSON.stringify([s.source, s.client, s.sessionId])
  const originKey = s => JSON.stringify([s.source, s.sessionId])
  const limit = scope => finiteTime(scope && scope.staleAfter) ? scope.staleAfter : 180
  const terminal = s => s.status === 'Offline' || (ended.includes(s.event) && ['Success', 'Error', 'Idle'].includes(s.status))
  const waiting = s => s.status === 'Waiting Input' || s.status === 'Waiting Permission'
  const unconfirmed = (s, now, scope) => !terminal(s) && s.status !== 'Idle' && !waiting(s) && now - s.observedAt > limit(scope)
  const future = (s, now) => s.observedAt > now || s.ts > now
  const validResult = r => object(r) && finiteTime(r.ts) && ['Success', 'Error'].includes(r.status) && (r.status === 'Success' ? successEvents : ended).includes(r.event) && typeof r.pose === 'string'
  const recentResult = (r, now) => validResult(r) && now >= r.ts && now - r.ts < 10

  function valid(s, scope) {
    return object(s) && object(scope) && s.schema === 1 && s.family === scope.family &&
      specs.some(d => d.source === s.source && d.family === s.family && (s.client === 'unknown' || d.client === s.client)) &&
      typeof s.sessionId === 'string' && s.sessionId.length > 0 && typeof s.model === 'string' &&
      has(priority, s.status) && typeof s.pose === 'string' && typeof s.event === 'string' &&
      finiteTime(s.ts) && finiteTime(s.observedAt) &&
      (scope.now === undefined || (finiteTime(scope.now) && s.ts <= scope.now && s.observedAt <= scope.now)) &&
      (s.sequence === undefined || (Number.isSafeInteger(s.sequence) && s.sequence >= 0)) &&
      (s.producerId === undefined || typeof s.producerId === 'string') &&
      (s.turnId === undefined || typeof s.turnId === 'string') &&
      ['eventId', 'tool', 'after'].every(k => s[k] === undefined || typeof s[k] === 'string') &&
      (s.afterTs === undefined || finiteTime(s.afterTs)) &&
      (s.pid === undefined || (Number.isInteger(s.pid) && s.pid > 1)) &&
      (s.status !== 'Success' || successEvents.includes(s.event))
  }
  function follows(next, previous) {
    if (next.ts < previous.ts || next.observedAt < previous.observedAt) return false
    if (next.producerId === previous.producerId && Number.isSafeInteger(next.sequence) && Number.isSafeInteger(previous.sequence)) return next.sequence > previous.sequence
    return next.observedAt > previous.observedAt || next.ts > previous.ts
  }
  function copySnapshot(s) {
    const out = {}
    for (const k of ['schema', 'family', 'source', 'client', 'sessionId', 'model', 'status', 'pose', 'event', 'ts', 'observedAt', 'turnId', 'eventId', 'sequence', 'pid', 'producerId', 'tool', 'after', 'afterTs']) {
      if (s[k] !== undefined) out[k] = s[k]
    }
    if (validResult(s.lastResult)) out.lastResult = { status: s.lastResult.status, pose: s.lastResult.pose, event: s.lastResult.event, ts: s.lastResult.ts }
    return out
  }

  const channelOf = s => s.producerId === 'hook' ? 'hook' : typeof s.producerId === 'string' && s.producerId.startsWith('claude-mod-') ? 'mod' : 'plugin'
  const turnToken = s => s.turnId ? JSON.stringify([s.producerId || '', s.turnId]) : null
  const followsVisible = (next, previous) => next.observedAt > previous.observedAt || (next.observedAt === previous.observedAt && next.ts >= previous.ts)

  function ingest(previous, snapshot, scope) {
    const state = object(previous) ? previous : {}
    if (!valid(snapshot, scope)) return { state, result: 'invalid' }
    const next = copySnapshot(snapshot), key = keyOf(next), origin = originKey(next)
    const records = { ...(state.records || {}) }, unknown = { ...(state.unknown || {}) }, known = { ...(state.known || {}) }, closed = { ...(state.closed || {}) }
    // Identity diagnostics never route an unknown session into a known client's renderer.
    if (next.client === 'unknown') {
      if (!unknown[key] || follows(next, unknown[key])) unknown[key] = next
    } else {
      const clients = known[origin] || []
      if (!clients.includes(next.client)) known[origin] = [...clients, next.client]
    }
    const updated = { ...state, records, unknown, known, closed }
    if (scope.client != null && next.client !== scope.client) return { state: updated, result: 'ignored' }
    // Hooks and the mod are concurrent observers, not successive incarnations of one
    // process. Keep ordering/restart evidence per channel while exposing one session.
    const channel = channelOf(next), channelKey = JSON.stringify([key, channel])
    const channels = { ...(state.channels || {}) }, starts = { ...(state.starts || {}) }
    const epochs = { ...(state.epochs || {}) }, endedAt = { ...(state.endedAt || {}) }
    const retired = { ...(state.retired || {}) }, domains = { ...(state.domains || {}) }, channelDomains = { ...(state.channelDomains || {}) }
    Object.assign(updated, { channels, starts, epochs, endedAt, retired, domains, channelDomains })
    const before = channels[channelKey]
    const prompt = ['UserPromptSubmit', 'BeforeAgent', 'turn/start'].includes(next.event)
    const newTurn = before && before.turnId && next.turnId && next.turnId !== before.turnId
    // Sequence counters survive wall-clock corrections. Only a provably newer
    // prompt/turn can establish a corrected time domain; old work cannot do it.
    const newerSequence = before && next.producerId === before.producerId && Number.isSafeInteger(next.sequence) && Number.isSafeInteger(before.sequence) && next.sequence > before.sequence
    const recovery = newerSequence && !terminal(next) && (prompt || newTurn) && (next.ts < before.ts || next.observedAt < before.observedAt)
    if (before && !follows(next, before) && !recovery) return { state: updated, result: 'ignored' }
    if ((retired[channelKey] || []).includes(next.producerId)) return { state: updated, result: 'ignored' }
    const restart = before && next.producerId !== before.producerId
    if (restart) retired[channelKey] = [...(retired[channelKey] || []), before.producerId].filter(x => x != null)
    const token = turnToken(next)
    if (token && (closed[channelKey] || []).includes(token) && next.status !== 'Offline') return { state: updated, result: 'ignored' }
    const changed = before && !restart && before.turnId && next.turnId && before.turnId !== next.turnId
    const begins = prompt || changed || (restart && channel === 'plugin')
    if (changed) {
      const previousToken = turnToken(before)
      if (previousToken && !(closed[channelKey] || []).includes(previousToken)) closed[channelKey] = [...(closed[channelKey] || []), previousToken]
    }
    let recoveredDomain = false
    if (recovery && (channelDomains[channelKey] || 0) >= (domains[key] || 0)) {
      domains[key] = (domains[key] || 0) + 1
      epochs[key] = next.observedAt
      delete endedAt[key]
      recoveredDomain = true
    }
    // Other channels keep their old domain until they supply their own fresh
    // boundary. Their old high wall-clock values cannot override recovered work.
    if ((channelDomains[channelKey] || 0) < (domains[key] || 0) && !begins) return { state: updated, result: 'ignored' }
    const channelWasCurrent = (channelDomains[channelKey] || 0) >= (domains[key] || 0)
    if (begins || !(channelKey in channelDomains)) channelDomains[channelKey] = domains[key] || 0
    const ownStart = begins || !before ? next.observedAt : starts[channelKey]
    // A second observer's prompt joins the current epoch. A channel that already
    // joined it can begin the next one. Turn IDs remain local to their producer.
    if (!epochs[key] || (begins && before && channelWasCurrent && (starts[channelKey] || 0) >= epochs[key])) epochs[key] = next.observedAt
    channels[channelKey] = next
    // First seeing a worker after another observer ended is not a new-turn proof.
    // Keep it behind the end boundary until its own prompt/turn transition arrives.
    starts[channelKey] = !before && !begins && !terminal(next) && endedAt[key]
      ? Math.min(ownStart, endedAt[key]) : ownStart
    // Remember the other observer's terminal evidence even if its old work arrives
    // later. Only a proven fresh prompt/turn can open work after that boundary.
    if (terminal(next) && token && !(closed[channelKey] || []).includes(token)) closed[channelKey] = [...(closed[channelKey] || []), token]
    if (ownStart < (epochs[key] || 0) || (!begins && !terminal(next) && !before && endedAt[key]) || (!begins && next.status !== 'Offline' && ownStart <= (endedAt[key] || 0))) return { state: updated, result: 'ignored' }
    if (terminal(next)) endedAt[key] = Math.max(endedAt[key] || 0, next.observedAt)
    const visibleBefore = records[key]
    if (visibleBefore && !recoveredDomain && !recovery && !followsVisible(next, visibleBefore)) return { state: updated, result: 'ignored' }
    records[key] = next
    return { state: updated, result: 'applied', snapshot: next }
  }

  function payload(s, now, scope) {
    const out = { pose: s.pose, event: s.event, ts: s.ts, status: s.status, source: s.source, client: s.client, sessionId: s.sessionId, model: s.model, stale: false }
    for (const k of ['turnId', 'tool', 'after', 'afterTs']) if (s[k] !== undefined) out[k] = s[k]
    if (recentResult(s.lastResult, now)) out.lastResult = { ...s.lastResult }
    if (future(s, now) || unconfirmed(s, now, scope)) {
      out.recordedStatus = s.status
      out.recordedEvent = s.event
      out.status = 'Unknown'; out.pose = 'sleeping'; out.event = future(s, now) ? 'StateUnconfirmed' : 'StateStale'
      out.stale = !future(s, now)
      delete out.after; delete out.afterTs
    }
    return out
  }
  function sessions(state, now, scope) {
    const out = {}
    for (const [key, s] of Object.entries((state || {}).records || {})) out[key] = payload(s, now, scope)
    return out
  }
  function unattributed(state, now, scope) {
    return Object.values(state.unknown || {}).filter(s => !future(s, now) && !terminal(s) && now - s.observedAt <= limit(scope) && ((state.known || {})[originKey(s)] || []).length !== 1).length
  }
  function aggregate(state, now, scope) {
    state = state || {}
    const records = Object.values(state.records || {})
    if (!finiteTime(now)) {
      const p = { status: 'Unknown', pose: 'sleeping', event: 'NoSessions', ts: 0, stale: false, confidence: 'unknown' }
      return { status: p.status, pose: p.pose, event: p.event, ts: p.ts, stale: p.stale, count: 0, payload: p }
    }
    const settled = s => ['Success', 'Error'].includes(s.status) && terminal(s) && now - s.observedAt >= 4
    const status = s => future(s, now) || unconfirmed(s, now, scope) ? 'Unknown' : settled(s) ? 'Idle' : s.status
    const uncertain = records.filter(s => !future(s, now) && unconfirmed(s, now, scope))
    const latestUncertain = uncertain.reduce((t, s) => Math.max(t, s.observedAt), 0)
    const current = records.filter(s => !future(s, now) && !unconfirmed(s, now, scope) && s.status !== 'Offline' && (waiting(s) || now - s.observedAt <= limit(scope) || s.observedAt > latestUncertain))
    const candidates = current.length ? current : uncertain.length ? uncertain : records.filter(s => !future(s, now))
    const rank = s => has(priority, status(s)) ? priority[status(s)] : 0
    const ordered = candidates.slice().sort((a, b) => rank(a) - rank(b) || a.observedAt - b.observedAt || (keyOf(a) < keyOf(b) ? -1 : keyOf(a) > keyOf(b) ? 1 : 0))
    const selected = ordered[ordered.length - 1]
    const count = records.filter(s => s.status !== 'Offline' && !future(s, now)).length
    const unknown = unattributed(state, now, scope)
    if (!selected) {
      const p = { status: 'Unknown', pose: 'sleeping', event: 'NoSessions', ts: 0, stale: false, confidence: 'unknown' }
      if (unknown) p.unattributed = unknown
      return { status: p.status, pose: p.pose, event: p.event, ts: p.ts, stale: p.stale, count, payload: p }
    }
    const p = payload(selected, now, scope)
    if (settled(selected)) { p.recordedStatus = selected.status; p.status = 'Idle'; p.pose = 'idle'; p.stale = false }
    const results = records.map(s => s.lastResult).filter(r => recentResult(r, now)).sort((a, b) => b.ts - a.ts)
    if (results.length) p.lastResult = { ...results[0] }
    p.confidence = p.stale ? 'stale' : 'event'
    if (unknown) p.unattributed = unknown
    return { status: p.status, pose: p.pose, event: p.event, ts: p.ts, stale: p.stale, count, payload: p }
  }
  function processExited(state, key, producerId, now) {
    const previous = (state || {}).records && state.records[key]
    if (!previous || previous.producerId !== producerId || !previous.pid || previous.status === 'Offline' || !finiteTime(now) || now < previous.observedAt) return state
    const closed = { ...(state.closed || {}) }, channelKey = JSON.stringify([key, channelOf(previous)]), token = turnToken(previous)
    if (token && !(closed[channelKey] || []).includes(token)) closed[channelKey] = [...(closed[channelKey] || []), token]
    return { ...state, closed, endedAt: { ...(state.endedAt || {}), [key]: now }, records: { ...state.records, [key]: { ...previous, status: 'Offline', pose: 'sleeping', event: 'ProcessExit', ts: now, observedAt: now } } }
  }

  function hosts(processes) {
    const rows = Array.isArray(processes) ? processes.filter(p => object(p) && Number.isInteger(p.pid) && typeof p.executable === 'string' && finiteTime(p.started)) : []
    const byPID = new Map(rows.map(p => [p.pid, p])), found = {}
    const desktop = [
      ['/Claude.app/Contents/MacOS/Claude', 'claude-desktop'],
      ['/ChatGPT.app/Contents/MacOS/ChatGPT', 'codex-desktop'],
      ['/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness', 'dsh-desktop'],
    ]
    const embeddedPaths = ['/Claude.app/', '/ChatGPT.app/', '/DeepSeek Harness.app/', '/CrossPet.app/', '/app-server-daemon/']
    for (const process of rows) {
      const path = process.executable, name = path.slice(path.lastIndexOf('/') + 1)
      let id = desktop.find(([suffix]) => path.endsWith(suffix))
      id = id && id[1]
      if ((name === 'claude' || name === 'codex') && process.parent > 1) {
        let cursor = process, embedded = false
        const visited = new Set()
        while (cursor && !visited.has(cursor.pid)) {
          visited.add(cursor.pid)
          if (embeddedPaths.some(part => cursor.executable.includes(part))) { embedded = true; break }
          cursor = byPID.get(cursor.parent)
        }
        if (!embedded) id = name === 'claude' ? 'claude-tui' : 'codex-tui'
      }
      if (id) found[id] = Math.max(found[id] || 0, process.started)
    }
    // A desktop host proves presence only. It never creates a Code session or a working state.
    return found
  }
  function visible({ mode, master, hostStarted, state, now }) {
    if (master === false || mode === 'always') return true
    if (mode === 'followApp') return finiteTime(hostStarted)
    // onWork consumes the aggregate at this same explicit clock tick. Host presence alone is
    // insufficient: ordinary desktop chat is not evidence of a Code task.
    if (!object(state) || !finiteTime(now) || state.event === 'NoSessions' || state.status === 'Offline') return false
    if (!finiteTime(state.ts) || state.ts > now) return false
    if (['Thinking', 'Tool Running', 'Waiting Input', 'Waiting Permission'].includes(state.status)) return true
    if (state.status === 'Unknown') return state.event === 'StateStale' && state.count > 0
    if (['Success', 'Error'].includes(state.status) && ended.includes(state.event)) return now - state.ts < 4
    return state.status === 'Error' && !ended.includes(state.event)
  }
  root.ClientPolicy = { specs, ingest, aggregate, sessions, processExited, hosts, visible }
  if (typeof module !== 'undefined') module.exports = root.ClientPolicy
})(typeof window !== 'undefined' ? window : globalThis)
