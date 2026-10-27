const {test}=require('node:test')
const assert=require('node:assert/strict')
const fs=require('node:fs'),vm=require('node:vm')
const page=fs.readFileSync('app/web/index.html','utf8')
const code=page.slice(page.indexOf('function setClientQuota('),page.indexOf('function applyFamilyState('))
function view(client) { const values={};const ctx={familyMode:'claude',familyClient:client,setQuota:(id,q)=>values[id]=q};vm.createContext(ctx);vm.runInContext(code,ctx);return {values,send(envelope,clientArg=client) { ctx.envelope=envelope;ctx.clientArg=clientArg;vm.runInContext("setClientQuota('claude',clientArg,envelope)",ctx) }} }
const envelope=(client,text)=>({schema:1,family:'claude',source:'claude-code',client,quota:{text,low:false}})
test('different client accounts render their own quota numbers',()=>{
 const tui=view('tui'),desktop=view('desktop');tui.send(envelope('tui','15%'));desktop.send(envelope('desktop','65%'))
 assert.equal(tui.values.claude.text,'15%');assert.equal(desktop.values.claude.text,'65%')
})
test('shared legacy, missing and mismatched sources never masquerade as a client quota',()=>{
 const desktop=view('desktop')
 for(const e of [null,{text:'99%'},envelope('tui','99%'),{...envelope('desktop','99%'),source:'other'}, {...envelope('desktop','99%'),quota:null}]) {
  desktop.send(e);assert.equal(desktop.values.claude.unavailable,true);assert.equal(desktop.values.claude.text,'桌面额度待更新')
 }
 desktop.send(envelope('tui','99%'),'tui');assert.equal(desktop.values.claude.text,'桌面额度待更新')
})
test('clearing one client quota leaves the other view intact',()=>{
 const tui=view('tui'),desktop=view('desktop');tui.send(envelope('tui','15%'));desktop.send(envelope('desktop','65%'))
 tui.send({...envelope('tui',''),quota:null});assert.equal(tui.values.claude.unavailable,true);assert.equal(desktop.values.claude.text,'65%')
})

test('other families retain both attributed Claude quotas for aggregate rows',()=>{
 const values={},ctx={familyMode:'gpt',familyClient:'desktop',setQuota:(id,q)=>values[id]=q}
 vm.createContext(ctx);vm.runInContext(code,ctx)
 for(const [client,text] of [['tui','15%'],['desktop','65%']]) {ctx.e=envelope(client,text);ctx.client=client;vm.runInContext("setClientQuota('claude',client,e)",ctx)}
 assert.equal(values['claude-tui'].text,'15%');assert.equal(values['claude-desktop'].text,'65%');assert.equal(values.claude,undefined)
})
test('aggregate rows label terminal and desktop separately instead of a shared Claude row',()=>{
 const model=require('../app/web/quota-aggregate.js'), rendered=[]
 const ctx={familyMode:'gpt',familyClient:'desktop',charId:'gpt',quotaAggregate:true,egg:null,
  manifest:{characters:{gpt:{name:'GPT'},claude:{name:'Claude'}}},
  quota:{'claude-tui':{text:'15%'},'claude-desktop':{text:'65%'},claude:{text:'SHARED 99%'}},
  $:()=>({style:{}}),QuotaAggregate:{...model,render:(_,rows)=>rendered.push(...rows)},appendResetNotice:()=>{},appendPeakBar:()=>{}}
 vm.createContext(ctx);vm.runInContext(page.slice(page.indexOf('function renderQuota('),page.indexOf('// 临时动作（打招呼')),ctx)
 vm.runInContext('renderQuota()',ctx)
 assert.deepEqual(new Set(rendered.map(r=>r.name)),new Set(['终端 Claude','桌面 Claude']))
 assert.ok(!JSON.stringify(rendered).includes('99%'))
})
