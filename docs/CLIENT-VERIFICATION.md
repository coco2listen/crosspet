# 五客户端接口与真实验证记录

日期：2026-10-24，Apple Silicon macOS。此文区分真实客户端执行、静态接口审计和模拟测试；三者不能互相替代。

## 当前验收边界

| 客户端 | 本机版本/定位 | 接口证据 | 真实任务执行 |
|---|---|---|---|
| Claude Code TUI | `2.1.308`，`/opt/homebrew/bin/claude` | 标准 hooks；新增 family 快照 | 已执行真实交互 TUI 和 `--print`，均用 Bash 执行 `pwd` 后回复 `OK`；收到 Idle → Thinking → Tool Running → Thinking → Success → Offline |
| Claude Desktop 中的 Code | `Claude.app 3.6556.2` | 原项目共用 hooks / mod；mod 已做兼容 SDK 的测试替身验证 | **未通过真实桌面任务验收**；没有本次桌面 Code 会话产生的事件证据 |
| Codex TUI | `codex-cli 0.164.0`，`/opt/homebrew/bin/codex` | 已正常打开 `/hooks` 信任本次精确 hook 定义，没有使用 bypass 参数 | 已执行真实交互 TUI，shell `pwd` 后回复 `OK`；收到 Idle → Thinking → Tool Running → Thinking → Success；正常 `/exit` 后本次观察期没有收到 SessionEnd |
| Codex Desktop / Work | 本机实际运行时在 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` | 与 CLI 同 hooks 协议；已定位实际运行进程 | **未通过真实桌面任务验收**；本次不能把 TUI 事件当作 Desktop 事件 |
| DeepSeek Harness Desktop | `0.2.1-rc.3` | 从已安装 `app.asar` 核实 `@deepseek-ai/dsh-session` 和 `dsh-subagent` 发布的真实事件实现 | **未执行真实 Harness 模型任务**；插件测试中发送的事件是测试替身，不能算真实 DSH E2E |

本次桌面自动化工具曾返回 `Computer Use was not approved to use CrossPet`。没有绕过该访问检查；真实鼠标操作、三个桌面客户端的任务输入与最终显示仍需补验。未声称客户端缺失、未登录或已完整接入，因为没有实际证据支持这些说法。

## 已执行的真实链路

1. Claude 标准 hooks：独立 `--settings`，`--setting-sources ''`，只启用 Bash，正常可信目录确认；没有改动用户 hooks 配置。`work/e2e/claude/` 是非交互结果；`work/e2e/claude-tui/` 是真实交互 TUI 结果。
2. Codex：`--no-daemon --no-alt-screen -s read-only -a on-request`，用 `-c hooks.<event>=...` 注入本次会话配置；启动正常 `/hooks` 审查、信任 12 个自有 hook，再执行固定测试任务。没有使用 `--dangerously-bypass-hook-trust` 或关闭执行保护。
3. 并发链路：Claude `--print` 与 Codex 交互 TUI 同时执行 `pwd` 加 `sleep 8`，向 `work/e2e/live/state` 写元数据；应用主进程同时运行。真实页面回传保存在 `work/e2e/live/render.jsonl`，事件观察记录在 `state/observed.jsonl`。两个客户端输出与测试任务均不含用户既有聊天。
4. 配置恢复：Codex 两次信任前均备份 `config.toml`，确认没有期间并发配置改动后按测试前字节恢复并核对 SHA-256。Claude 可信测试目录条目及浏览器默认选项已恢复，保留其他项目和正常 CLI 更新的计数/缓存。私有配置备份在恢复后已删除，没有提交或打包。
5. 此处的 `CROSSPET_CLIENT=tui` 是测试调用明确提供的来源标签，不是已验证的自动客户端识别能力。默认 `unknown` 会如实保留未知来源；不能用模型名、前台窗口或文件时间猜测端来源。

## 官方 Codex hooks 限制

[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks) 已实际查阅：非托管 hook 必须按精确定义审查信任；`PermissionRequest` 和 `SessionEnd` 均有正式接口。切走会话或取消订阅不等于立即结束，无订阅且空闲的会话可能 30 分钟后才结束。部分托管工具不走本地工具 hooks，不能保证每种工具和提问均有事件。因此缺少输入事件时不声称 Waiting Input，静默时只标状态待确认，不推断 Success 或 Offline。

Codex 本次正常 `/exit` 未观察到 SessionEnd，即使文档描述正常关闭支持该事件，也不能标记本机该分支实测通过。钩子进程的父进程可能是瞬态 shell，当前 Python 接入不把它当客户端存活 PID；因此 TUI 异常关闭缺少显式结束事件时只会变 stale。没有通过轮询聊天记录或读取凭据补造离线状态。

## Harness 本机源代码核实

已安装 `app.asar` 的 `/dsh/node_modules/@deepseek-ai/dsh-session/lib/types/known-event-types.js` 包含 `turn/start`、`step/start`、`tool/call`、`tool/result`、`approval/asked`、`approval/decided`、`compaction/start`、`compaction/end`、`turn/end`。事件具有 `seq` 和毫秒 `time`；会话头存在 `parentSession`。`dsh-session` 的 repair 实现使用 `data.turn` 关闭明确轮次。

`@deepseek-ai/dsh-subagent/lib/index.js` 的全局生命周期回调仅收到子任务 identity 信息，父 Agent 是作用域 dispatch carrier，不能假设回调第二参数就是父会话。family 插件只在已经观察到父会话且真实子会话头明确给出 `parentSession` 时，将子会话 `turn/start/end` 路由为父会话的委派/恢复思考动作；子任务完成不等于父任务完成。父轮次已结束后不允许迟到子任务重新激活它。

DSH 无论 `model` 为 Claude 或 GPT，family 始终是 `deepseek`；旧模型切换状态文件照旧供单桌宠模式使用。完成 `reason.kind=completed` 才是 Success，blocked/aborted 不当作成功；工具达到原门槛时保留 `proud`。余额查询原实现未删除；本次没有读取用户 Key 或调用真实余额查询，余额功能只做既有测试回归。

## 新协议与仍受限项

family 文件按 `source + client + sessionId` 独立，模型仅为属性。原角色状态文件继续保留；family 从自身同来源文件恢复模型属性和快速工具 `after/afterTs`，不从可能被其他模型宿主覆盖的 legacy 文件导入动画。

`lastResult={status,pose,event,ts}` 只由明确的 Stop / turn/end 成功或失败产生，后续快照保留最多 10 秒，供紧跟 SessionEnd 时显示完成通知；当前会话仍可同时真实显示 Offline。工具中间失败不会制造终结结果。Claude mod 增加每会话本地 generation 和 closed fence（不是伪造 provider 轮次 ID），阻止 await 后的迟到工具/压缩回写；原有大活计数也按会话隔离。

尚未验证：五客户端真实并发、Desktop 端自动身份识别、TUI 异常退出即时 Offline、全部八状态的真实触发、真实 DSH 切模型/余额、真实鼠标拖动贴边、小时级稳定性。相关模拟和程序化窗口检查不能替代这些验收项。


## 2026-10-24 续：五客户端独立方案（feat/macos-five-client-pets）的验证记录

方案已获用户批准。以下区分三类证据，互不替代。

**身份识别（真实宿主证据）**
- Claude Desktop：本会话（Claude Desktop 的 Code）的真实钩子事件快照为 `client=desktop`、`clientReason=entrypoint:claude-desktop`（环境变量 `CLAUDE_CODE_ENTRYPOINT`）。
- Codex（终端二进制）：真实 `codex exec` 会话触发已信任钩子，快照为 `client=tui`、`ancestor:codex-outside-ChatGPT.app`。该次祖先链中 codex 进程命令行是裸名 `codex`。
- **未验证**：Claude 终端交互 TUI 的 `CLAUDE_CODE_ENTRYPOINT=cli`（按已知取值实现，未在本次独立抓取）；Codex 交互式 TUI（本次 pty 驱动未能提交提示，且 5h 额度提示不足 10%，已停止消耗）；**Codex Desktop**（`ChatGPT.app` 祖先规则按进程表实现并有 shim 单测，没有真实桌面任务事件）；DSH 真实任务（固定 desktop）。
- Codex 钩子：只改了脚本内容，hooks.json 命令字符串未变，不触发重新信任（本机已用已信任钩子实际运行验证）。

**自动化（真实 App 进程，模拟/受控输入，不等于真实客户端）**
- `tests/macos_runtime_probe.sh`（`CROSSPET_PROBE_MODE=families|clients`）：真实 NSPanel/WKWebView，三宠 56 项、五宠 72 项，两次进程启动，含模式来回切换、全角色/皮肤渲染、心跳跨宠可见与旧域合并。
- `tests/clients_e2e.py`：真实钩子子进程 → 真实 App → 页面徽标：五端各自路由、同名会话、权限优先、重复事件、完成→待机、错误、DSH 用 Claude 模型不串宠、SessionEnd 才 Offline、未识别来源提示、SIGKILL 重启恢复。24 项。
- `tests/mouse_e2e.swift`：Accessibility 授权的 CGEvent 真实光标拖动、位置各自持久化、右边缘贴边、重启恢复（五宠 29 项、三宠 19 项）。会移动用户光标约 40 秒。
- `tests/fullscreen_e2e.swift`：TextEdit 真实全屏/退出：默认隐藏、退出恢复、关闭“全屏时隐藏”后保留（单显示器）。AI 应用全屏例外未测。
- 偶发：两次完整运行中各出现一次不稳定（一次 families 探针的初始位置断言、一次鼠标拖动），重跑通过，原因未查明；全屏测试若前台 App（如终端）自己全屏，宠会按既有规则隐藏。

**仍未验证**：五个真实客户端同时执行同一批任务；Claude Desktop 增强 mod 在新会话中加载新版代码后的 `client` 值（已运行的会话仍在用旧 mod，产生 `unknown`，会显示“N 个来源未识别”，重开会话后消失）；Codex Desktop / DSH 真实任务；小时级稳定性仅做了 60 分钟隔离合成事件（见交付报告）；Space 切换、多显示器；Windows 代码未改动也未实测。
