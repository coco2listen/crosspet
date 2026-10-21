# 额度条样式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 「设置 → 额度」里可以把额度从文字换成进度条：单家每个额度一行（名字、条、剩余 %、短重置时间），合并显示时一家一行、每个额度一格短条。

**Architecture:** 排版规则全在网页层：新纯函数模块 `app/web/quota-bars.js` 把一个额度对象 `q` 变成若干「条行 / 文字行」；`quota-aggregate.js` 在合并显示时借用它画格子。数据来源（GPT 的 `codex-quota.js`、Claude 增强版 mod、两端的 Gemini 解析）在原有 `text`、`low` 之外多给一个 `bars` 数组；没有 `bars` 时按现有文字格式拆字兜底。两个外壳只存取设置 `quotaStyle` 并交给网页。

**Tech Stack:** 原生 JS（浏览器 + node:test）、TypeScript（Claude Code mod，node 24 直接剥类型运行测试）、Swift（macOS）、C#（Windows，LogicTests）。

**Spec:** `docs/superpowers/specs/2026-10-21-quota-bars-design.md`

## Global Constraints

- 默认样式是文字：`quotaStyle` 不是 `"bars"` 时，额度区和现在逐像素一致（反目标：默认样式下有任何变化）
- 条长 = 剩余比例；剩余 ≤ 10% 算快用完（和 `quota-aggregate.js` 的 `LOW_LEFT = 10` 一致），那一行条和百分比变红
- 额度条样式下 `#quota` 不加 `low` 类（不出现整块红底）
- 重置时间短写：24 小时内 `H:mm`（小时不补零，如 `3:40`），7 天内 `周一`…`周日`，再远 `M/D`（如 `10/26`）；按本机时区
- 过了重置时间的窗口：100%、不写时间、不红
- DeepSeek 等没有百分比的照旧文字；Codex 重置提醒行、峰谷时段照常追加
- 只在 dev 上做，`git add` 只加具体文件，提交末尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- 网页测试：`node --test tests/*.test.js tests/*.test.mjs`；Python：`python3 -m unittest discover -s tests -p "*_test.py"`；Windows：`cd tests/windows/LogicTests && ~/.dotnet/dotnet run`；Mac Gemini：`bash app/build.sh && sh tests/antigravity_quota_probe.sh`

## Review Focus

1. 用户的 Claude 增强版 mod 还是旧版（只有 `text`）：额度条照样画出来（拆字兜底）——Task 1 测试「没有 bars 时从文字拆」
2. 文字里有拆不动的段（余额「余额 ¥4.96」、以后的新写法）：那一段原样显示成文字，不丢——Task 1「拆不出来的段落保留成文字行」
3. 已经过了重置时间、还没新数据的窗口：显示 100%、不写时间、不变红——Task 1「过了重置时间算满」
4. 单家额度行很多（Gemini 三个窗口 + 重置提醒 + 峰谷条）撑破底栏：退回文字而不是把人物顶上去——Task 2 浏览器验证步骤
5. 正好 10% / 11% 的边界：10% 红、11% 不红——Task 1「10% 算快用完、11% 不算」

---

### Task 1: 纯函数 `quota-bars.js`

**Files:**
- Create: `app/web/quota-bars.js`
- Test: `tests/quota_bars.test.js`

**Interfaces:**
- Produces（`window.QuotaBars`，node 下 `module.exports`）：
  - `shortWhen(resetSec: number, nowSec: number): string` —— 规则见 Global Constraints
  - `of(q: {text?, low?, bars?, note?} | null, nowSec: number): { rows: Row[], note: string | null } | null`
    - `Row = { kind: 'bar', label: string, pct: number, low: boolean, when: string | null } | { kind: 'text', text: string, low: boolean }`
    - 有 `q.bars`（`[{ label, left: 0–1, reset?: Unix 秒 }]`）就用它；否则把 `q.text` 按 `/\s*｜\s*/` 拆段，每段用正则 `/^(.+?) 剩余 (\d+)%(?: · (\S+) 重置)?(.*)$/` 认：认出来是条行（`when` 用文字里原样的时间，比如 `3:40`、`10/26`），尾巴里的「· HH:MM 的数据」去掉开头的「· 」放进 `note`；认不出是文字行（`low` 取 `q.low`）
    - `q.note` 存在时优先当 `note`
    - 没有 `q` 或没有任何行 → `null`
    - `pct = Math.max(0, Math.min(100, Math.round(left * 100)))`；`reset` 已过（`reset <= nowSec`）→ `pct = 100, when = null, low = false`；否则 `low = pct <= 10`，`when = reset ? shortWhen(reset, nowSec) : null`
  - `render(el: HTMLElement, result): void` —— 把 `of()` 的结果画进 `el`：每个条行一个 `div.qbar`，里面依次 `span.ql`（名字）、`span.qtrack > i`（`style.width = pct + '%'`）、`span.qp`（`pct%`）、`span.qt`（`when`，没有就空）；`low` 时 `div.qbar` 加 `low`。文字行 `div`（`low` 时加 `low` 类）。有 `note` 时最后加 `div.qnote`

- [ ] **Step 1: 写失败测试** `tests/quota_bars.test.js`（文件开头 `process.env.TZ = 'Asia/Shanghai'`，`const B = require('../app/web/quota-bars.js')`，`const bj = s => Date.parse(s + ':00+08:00') / 1000`，`now = bj('2026-10-21T10:00')`，那天是周三）

```js
test('重置时间短写：24 小时内、7 天内、更远', () => {
  assert.equal(B.shortWhen(now + 5.6 * 3600, now), '15:36')      // 当天
  assert.equal(B.shortWhen(bj('2026-10-22T03:40'), now), '3:40')  // 不补零
  assert.equal(B.shortWhen(bj('2026-10-26T08:00'), now), '周一')
  assert.equal(B.shortWhen(bj('2026-11-02T08:00'), now), '11/2')
})
test('有 bars 时按 bars 画', () => {
  const r = B.of({ text: 'x', bars: [{ label: '5小时', left: 0.91, reset: now + 3600 }, { label: '本周', left: 0.59 }] }, now)
  assert.deepEqual(r.rows, [
    { kind: 'bar', label: '5小时', pct: 91, low: false, when: '11:00' },
    { kind: 'bar', label: '本周', pct: 59, low: false, when: null }])
})
test('10% 算快用完、11% 不算', () => { /* left 0.10 → low true；0.11 → low false */ })
test('过了重置时间算满', () => { /* left 0.05, reset now-60 → pct 100, when null, low false */ })
test('没有 bars 时从文字拆（旧版 mod）', () => {
  const r = B.of({ text: '5小时 剩余 91% ｜ 本周 剩余 59% · 10/26 重置', low: false }, now)
  assert.deepEqual(r.rows.map(x => [x.label, x.pct, x.when]), [['5小时', 91, null], ['本周', 59, '10/26']])
})
test('拆字：「· 15:20 的数据」进 note', () => { /* text '5小时 剩余 40% · 15:20 的数据' → note '15:20 的数据' */ })
test('拆不出来的段落保留成文字行', () => {
  const r = B.of({ text: '余额 ¥4.96', low: true }, now)
  assert.deepEqual(r.rows, [{ kind: 'text', text: '余额 ¥4.96', low: true }])
})
test('没有额度 → null', () => { assert.equal(B.of(null, now), null); assert.equal(B.of({ text: '' }, now), null) })
```

- [ ] **Step 2:** `node --test tests/quota_bars.test.js` → FAIL（找不到模块）
- [ ] **Step 3:** 实现 `app/web/quota-bars.js`，写法照 `peak-hours.js`（IIFE、`root.QuotaBars = api`、`module.exports`），`render` 只在浏览器里用
- [ ] **Step 4:** `node --test tests/quota_bars.test.js` → 全 PASS
- [ ] **Step 5:** 提交 `app/web/quota-bars.js tests/quota_bars.test.js`

### Task 2: 单家显示接上额度条 + 设置开关（网页层）

**Files:**
- Modify: `app/web/index.html`（`<script src="quota-bars.js">` 跟在 `quota-aggregate.js` 后面；CSS 在 `#quota .notice` 附近；`renderQuota` 约 624–646 行；外壳调用说明注释约 203 行）
- Modify: `app/web/settings.html`（「额度」卡片，峰谷那一项下面）

**Interfaces:**
- Consumes: `QuotaBars.of`、`QuotaBars.render`
- Produces: 外壳调用 `setQuotaStyle(s: 'text' | 'bars')`（不认识的值当 `'text'`）；设置页发 `{ cmd: 'set', key: 'quotaStyle', value: 'text' | 'bars' }`，状态里读 `s.quotaStyle`

- [ ] **Step 1:** `index.html`：`let quotaStyle = 'text'`；`function setQuotaStyle(s)` 设值后 `renderQuota()`
- [ ] **Step 2:** `renderQuota` 非合并分支：`quotaStyle === 'bars'` 且 `QuotaBars.of(q, Date.now()/1000)` 不是 null 时，用 `QuotaBars.render`，`el.className = 'bars'`（不加 `low`）；然后照旧 `appendResetNotice`、`appendPeakBar`。之后若 `$('foot').offsetHeight > 62 * Math.max(1, k) + 0.5`（和 `appendPeakBar` 同一个预算）就按文字样式重画这一次（不改 `quotaStyle`）
- [ ] **Step 3:** CSS：`.qbar` 一行 flex、`align-items:center`、`gap: calc(4px * var(--k))`；`.ql` 不折行；`.qtrack` `flex:1`、高 `calc(5px * var(--k))`、圆角、底色 `#e4dcd6`，里面 `i` 蓝 `#4f7fd8`；`.qp` 粗体右对齐；`.qt` 小一号（`calc(8.5px * var(--k))`）、颜色 `#a8958a`；`.qbar.low .qtrack i` 和 `.qbar.low .qp` 用 `#c0392b`；`.qnote` 小字浅色；`#quota.bars` 左对齐、宽度占满 `max-width`
- [ ] **Step 4:** `settings.html`：在「额度栏显示峰谷时段」上方加一项「额度显示样式」，说明「额度条：每个额度一条，后面是重置时间；DeepSeek 余额照旧是文字」，控件 `<div class="seg" id="quotaStyle" data-key="quotaStyle"><button data-v="text">文字</button><button data-v="bars">额度条</button></div>`，高亮和点击照 `peakStyle` 的两行写法
- [ ] **Step 5: 浏览器验证**（`cd ~/Projects/crosspet && python3 -m http.server 8793 --bind 127.0.0.1` 后台跑，打开 `http://127.0.0.1:8793/app/web/index.html`，控制台 `init({characters:{claude:{...poses:{idle:['/characters/claude/idle.webp']}}, gemini:{...}}})`、`setCharacter`、`setQuota`、`setQuotaStyle('bars')`）：
  - Claude 两行条带时间；`setQuotaStyle('text')` 后和改动前一样
  - 快用完那行变红、整块不变红底
  - 造一个 `{text:'a 剩余 5% ｜ b 剩余 50% ｜ c 剩余 60% ｜ d 剩余 70% ｜ e 剩余 80%'}` 撑破预算 → 自动显示成文字
  - 截图存证
- [ ] **Step 6:** `node --test tests/*.test.js tests/*.test.mjs` 全 PASS；提交 `app/web/index.html app/web/settings.html`

### Task 3: 合并显示的格子条

**Files:**
- Modify: `app/web/quota-aggregate.js`
- Modify: `app/web/index.html`（合并分支传样式；格子条 CSS）
- Test: `tests/quota_aggregate.test.js`

**Interfaces:**
- Consumes: `QuotaBars.of`（在 `quota-aggregate.js` 里取 `root.QuotaBars`，node 下 `require('./quota-bars.js')`）
- Produces: `rows(quota, own, all, nameOf, style = 'text', nowSec = Date.now() / 1000)`；`style === 'bars'` 时每格是 `{ bar: pct, low }`（条行）或现有的 `parts` 数组（文字行，用 `compact(text, low)`）。`render` 遇到 `{ bar }` 格子画 `span.qtrack > i` + `span.qp`，`low` 时格子加 `low` 类；其余逻辑（列数、最后一格跨列、`tight`、名字截短）不变

- [ ] **Step 1: 失败测试**（加在 `tests/quota_aggregate.test.js`）

```js
test('额度条样式：一家一行，每个额度一格短条，不带时间和窗口名', () => {
  const r = rows({ claude: { text: '5小时 剩余 91% ｜ 本周 剩余 59% · 10/26 重置' }, deepseek: { text: '余额 ¥4.96', low: true } },
    'claude', ['claude', 'deepseek'], id => id, 'bars', now)
  assert.deepEqual(r[0].cells, [{ bar: 91, low: false }, { bar: 59, low: false }])
  assert.deepEqual(r[1].cells, [[{ text: '余额 ¥4.96', low: true }]])
})
test('不传样式时和以前完全一样', () => { /* 现有某个用例去掉第 5、6 个参数，结果不变 */ })
```

- [ ] **Step 2:** `node --test tests/quota_aggregate.test.js` → 新用例 FAIL
- [ ] **Step 3:** 实现 `rows` 的样式参数和 `render` 的格子条；`index.html` 合并分支调用 `QuotaAggregate.rows(quota, charId, ids, nameOf, quotaStyle)`；CSS `#quota .qc .qtrack` 宽 `calc(34px * var(--k))`、`.qc.low` 变红
- [ ] **Step 4:** 测试全 PASS；浏览器里 `setQuotaAggregate(true)` 四家（Claude、GPT、Gemini、DeepSeek）看格子条，和文字样式一样高，截图
- [ ] **Step 5:** 提交 `app/web/quota-aggregate.js app/web/index.html tests/quota_aggregate.test.js`

### Task 4: GPT 和 Claude 的数据带上 `bars`

**Files:**
- Modify: `app/web/codex-quota.js`（`view`）、`tests/codex_quota_view.test.js`
- Modify: `integrations/claude-code/mod/hooks/register.ts`（`quotaOf` 改成 `export function quotaOf`）
- Create: `tests/claude_mod_quota.test.mjs`

**Interfaces:**
- Produces: 两边返回的对象多 `bars: [{ label, left, reset? }]`（`left = (100 - used) / 100`，`reset` Unix 秒，没有就不写）；`view` 在 `source === 'stale'` 时另给 `note: 'HH:MM 的数据'`（和 `text` 末尾那段相同）。`text`、`low` 一个字不变

- [ ] **Step 1:** 失败测试：`codex_quota_view.test.js` 加「view 带 bars（5小时 left 0.6 reset、本周 left 0.9）」「stale 时带 note」；`claude_mod_quota.test.mjs` 用 `import { quotaOf } from '../integrations/claude-code/mod/hooks/register.ts'`（node 24 直接剥类型），断言 `quotaOf([{ kind:'five_hour', percentUsed: 9, resetsAt: '2026-10-21T05:00:00Z' }, { kind:'seven_day', percentUsed: 41 }]).bars` 等于 `[{ label:'5小时', left:0.91, reset: 1792558800 }, { label:'本周', left:0.59 }]`，且 `text` 和改之前一致
- [ ] **Step 2:** 跑这两个测试 → FAIL
- [ ] **Step 3:** 实现（只加字段，不改 `text` 的拼法）。若 `import` 因 `claude-code` 类型模块报错，把 `import type` 保持为纯类型导入即可被剥掉；不要为测试改 mod 的运行时行为
- [ ] **Step 4:** 两个测试 PASS，`node --test tests/*.test.js tests/*.test.mjs` 全 PASS
- [ ] **Step 5:** 提交 `app/web/codex-quota.js tests/codex_quota_view.test.js integrations/claude-code/mod/hooks/register.ts tests/claude_mod_quota.test.mjs`

### Task 5: Gemini（两端）带上 `bars`

**Files:**
- Modify: `app/mac/App+Quota.swift`（`antigravitySummary`、`antigravityQuota` 返回的字典）
- Modify: `app/windows/src/AntigravityQuota.Parse.cs`（`ParseSummary`、`ParseStatus`）
- Test: `tests/antigravity_quota_probe.sh`、`tests/windows/LogicTests/Program.cs`

**Interfaces:**
- Produces: 字典多 `"bars"`：每行 `["label": 行名（和文字里同一个名字）, "left": 0–1, "reset": Unix 秒（Int，没有就不写这个键）]`，顺序和文字一致

- [ ] **Step 1:** 失败测试：probe 脚本加 `check "汇总：bars 和文字一一对应" summary-two-windows 'len(q["bars"]) == 3 and q["bars"][0]["label"] == "Gemini 今日" and abs(q["bars"][0]["left"] - 0.4) < 1e-6 and "reset" in q["bars"][0]'` 和 `check "用户状态：bars 两行" two-pools-with-unavailable '[b["label"] for b in q["bars"]] == ["Gemini", "Claude/GPT"]'`；LogicTests 的 `Agy` 旁边加同样两条（取 `q["bars"]` 为 `List<Dictionary<string, object>>`）
- [ ] **Step 2:** `bash app/build.sh && sh tests/antigravity_quota_probe.sh` 新两条 FAIL；LogicTests 新两条 FAIL
- [ ] **Step 3:** 实现；Windows 的 `DateTime` 先 `ToUniversalTime()` 再 `new DateTimeOffset(...).ToUnixTimeSeconds()`；Swift 用 `Int(d.timeIntervalSince1970)`
- [ ] **Step 4:** 两边测试全 PASS；`~/.dotnet/dotnet build app/windows/CrossPet.csproj -c Release` 无错误
- [ ] **Step 5:** 提交 `app/mac/App+Quota.swift app/windows/src/AntigravityQuota.Parse.cs tests/antigravity_quota_probe.sh tests/windows/LogicTests/Program.cs`

### Task 6: 外壳存设置、文档、Mac 实测

**Files:**
- Modify Mac：`app/mac/App+Dock.swift`（`peakStyle` 旁加 `var quotaStyle: String`，只认 `"bars"`，其余 `"text"`）、`App+Integrations.swift`（`case "quotaStyle"`）、`App+Settings.swift`（状态字典加 `"quotaStyle"`）、`App+Update.swift`（启动 js 串加 `setQuotaStyle(...)`）、`App+Feedback.swift`（「额度样式 \(quotaStyle)」）
- Modify Windows：`Pet.Dock.cs`、`Pet.Integrations.cs`（状态和 `case "quotaStyle"`）、`Pet.cs`（启动脚本）、`Pet.Feedback.cs`，照 1.3.7 `peakStyle` 的同一套写法
- Modify：`CHANGELOG.md`「未发布」加一条新增；`README.md`「看着额度」那段加一句「设置里可以换成额度条」

- [ ] **Step 1:** 两端照 `peakStyle` 改；`bash app/build.sh` 成功；`~/.dotnet/dotnet build app/windows/CrossPet.csproj -c Release` 成功；LogicTests 全通过
- [ ] **Step 2:** 全部测试（Global Constraints 里四条命令）通过
- [ ] **Step 3:** Mac 实测：装到 `~/Applications/CrossPet.app` 重启；设置里切「额度条」→ Claude / GPT（有额度时）显示条，切回「文字」恢复；重开 App 设置还在；打开「合并显示各家额度」看格子条。截图给 loki
- [ ] **Step 4:** 提交（只列改过的具体文件）
