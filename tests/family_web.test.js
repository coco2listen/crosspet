const {test} = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const page = fs.readFileSync('app/web/index.html', 'utf8')
function fn(name, next) { return page.slice(page.indexOf(`function ${name}(`), page.indexOf(next, page.indexOf(`function ${name}(`))) }
const activity = fn('aiActivity', '// 抱怨一句')
function context(overrides) {
  const ctx = {familyMode:'claude',charId:'claude',charState:{claude:{pose:'thinking',status:'Thinking',event:'PreInvocation',ts:Date.now()/1000-600}},pose:'idle',STUCK_AFTER:180000,NOT_WORKING:new Set(['idle','sleeping','asking','happy','proud','oops','surprised']),...overrides}
  vm.createContext(ctx); vm.runInContext(activity, ctx); return ctx
}
test('a quiet active family task remains active after interaction restores from an idle pose', () => {
  const ctx=context(); assert.equal(vm.runInContext('aiActivity()',ctx),'work')
  for (const status of ['Waiting Input','Waiting Permission']) {ctx.charState.claude.status=status; assert.equal(vm.runInContext('aiActivity()',ctx),'asking')}
})
test('completed and offline snapshots do not resume work; intermediate tool errors do', () => {
  const ctx=context()
  for (const status of ['Idle','Offline','Success']) {ctx.charState.claude.status=status; assert.equal(vm.runInContext('aiActivity()',ctx),null)}
  ctx.charState.claude.status='Error';ctx.charState.claude.event='PostToolUse';assert.equal(vm.runInContext('aiActivity()',ctx),'work')
  ctx.charState.claude.event='Stop';assert.equal(vm.runInContext('aiActivity()',ctx),null)
})
test('legacy quiet-event fallback is retained', () => {
  const ctx=context({familyMode:null,pose:'thinking'});assert.equal(vm.runInContext('aiActivity()',ctx),null)
  ctx.charState.claude.ts=Date.now()/1000;assert.equal(vm.runInContext('aiActivity()',ctx),'work')
})
test('family session cards retain long-running tasks and user waits', () => {
  const ctx={familyMode:'gpt',SESSION_DONE_SHOW:4,STUCK_AFTER:180000};vm.createContext(ctx)
  vm.runInContext(fn('sessionKind','// 当前角色要演的会话'),ctx)
  const old={pose:'asking',status:'Waiting Input',ts:1};ctx.entry=old
  assert.equal(vm.runInContext('sessionKind(entry,10000)',ctx),'ask')
  old.status='Tool Running';old.pose='running';assert.equal(vm.runInContext('sessionKind(entry,10000)',ctx),'work')
  old.status='Offline';old.lastResult={status:'Success',ts:9999};assert.equal(vm.runInContext('sessionKind(entry,10000)',ctx),'done');delete old.lastResult
  old.status='Success';assert.equal(vm.runInContext('sessionKind(entry,10000)',ctx),null)
})

test('unconfirmed session does not keep a busy card or resume thinking', () => {
  const ctx=context({charState:{claude:{status:'Unknown',pose:'sleeping',event:'StateStale',stale:true}}})
  assert.equal(vm.runInContext('aiActivity()',ctx),null)
  vm.runInContext(fn('sessionKind','// 当前角色要演的会话'),ctx)
  ctx.entry={status:'Unknown',pose:'sleeping',event:'StateStale',stale:true,ts:1}
  assert.equal(vm.runInContext('sessionKind(entry,10000)',ctx),null)
})

test('unconfirmed badge describes uncertainty and identifies the count as sessions', () => {
  const badge={parentNode:true,textContent:'',title:''}
  const ctx={familyMode:'claude',seenFamilyResult:0,$:()=>badge,applyCharState:()=>{},Date}
  vm.createContext(ctx);vm.runInContext(fn('applyFamilyState','function applyCharState'),ctx)
  ctx.state={status:'Unknown',pose:'sleeping',event:'StateStale',stale:true,unattributed:2}
  vm.runInContext("applyFamilyState('claude',state)",ctx)
  assert.equal(badge.textContent,'状态待确认 · 2 个会话来源未识别')
})

test('stale event clears pending thinking timer and does not re-arm tool completion animation', () => {
  const shown=[],scheduled=[],cleared=[]
  const ctx={charId:'claude',charState:{},standsIn:()=>false,egg:null,multi:null,shakingUntil:0,
    thinkTimer:123,lastTrouble:{},seenTool:{},watchStuck:()=>{},Date,
    clearTimeout:t=>cleared.push(t),setTimeout:f=>scheduled.push(f),show:p=>shown.push(p)}
  vm.createContext(ctx);vm.runInContext(fn('applyCharState','// ---- 额度里的'),ctx)
  ctx.state={status:'Unknown',pose:'sleeping',event:'StateStale',stale:true,ts:1}
  vm.runInContext("applyCharState('claude',state)",ctx)
  assert.deepEqual(cleared,[123]);assert.deepEqual(scheduled,[]);assert.deepEqual(shown,['sleeping'])
})

test('every explicit terminal error stops busy cards after its acknowledgement', () => {
  const ctx=context({SESSION_DONE_SHOW:4});vm.runInContext(fn('sessionKind','// 当前角色要演的会话'),ctx)
  for (const event of ['Stop','StopFailure','AfterAgent','turn/end']) {
    ctx.entry={status:'Error',pose:'oops',event,ts:1000};ctx.charState.claude=ctx.entry
    assert.equal(vm.runInContext('sessionKind(entry,1001)',ctx),'error')
    assert.equal(vm.runInContext('sessionKind(entry,1005)',ctx),null)
    assert.equal(vm.runInContext('aiActivity()',ctx),null)
  }
})
