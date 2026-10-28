const {test}=require('node:test')
const assert=require('node:assert/strict'), fs=require('node:fs'), vm=require('node:vm')
const page=fs.readFileSync('app/web/index.html','utf8')
const code=page.slice(page.indexOf('function setClientQuota('),page.indexOf('function applyFamilyState('))
const sources={claude:'claude-code',gpt:'codex',deepseek:'deepseek-harness'}
function view(family, client) {
 const values={}, context={familyMode:family,familyClient:client,setQuota:(id,q)=>values[id]=q}
 vm.createContext(context); vm.runInContext(code,context)
 return {values,send(envelope,origin=client,id=family) {Object.assign(context,{envelope,origin,id});vm.runInContext('setClientQuota(id,origin,envelope)',context)}}
}
const envelope=(family,client,text)=>({schema:1,family,source:sources[family],client,quota:{text,low:false,bars:[{label:'5小时',left:.5}]}})
for(const family of Object.keys(sources)) {
 test(`${family}: client quota never falls back to shared or opposite-client data`,()=>{
  const tui=view(family,'tui'),desk=view(family,'desktop')
  tui.send(envelope(family,'tui','15%'));desk.send(envelope(family,'desktop','65%'))
  assert.equal(tui.values[family].text,'15%');assert.equal(desk.values[family].text,'65%')
  for(const value of [null,{text:'99%'},envelope(family,'tui','99%'),{...envelope(family,'desktop','99%'),source:'other'}]) {
   desk.send(value);assert.equal(desk.values[family].unavailable,true)
  }
  desk.send(envelope(family,'tui','99%'),'tui')
  assert.equal(desk.values[family].unavailable,true)
  assert.equal(desk.values[`${family}-tui`].text,'99%')
  assert.equal(tui.values[family].text,'15%')
 })
 test(`${family}: structured quota bars survive and empty measurements clear only their own client`,()=>{
  const a=view(family,'tui'),b=view(family,'desktop')
  a.send(envelope(family,'tui','15%'));b.send(envelope(family,'desktop','65%'))
  assert.equal(a.values[family].bars[0].left,.5)
  a.send({...envelope(family,'tui',''),quota:null})
  assert.equal(a.values[family].unavailable,true);assert.equal(b.values[family].text,'65%')
 })
}
test('unknown identity is never displayed as an attributed quota',()=>{
 const viewA=view('claude','desktop');viewA.send(envelope('claude','unknown','99%'),'unknown');assert.equal(Object.keys(viewA.values).length,0)
})
