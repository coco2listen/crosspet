# macOS 多桌宠：实现与验收边界

本功能支持同一进程中的独立客户端桌宠，并保留单桌宠回退。真实客户端验收边界见 [CLIENT-VERIFICATION.md](CLIENT-VERIFICATION.md)。

## 使用

菜单栏爪印右键 →「桌宠」只有五个带勾选的开关：Claude 娘·终端、Claude 娘·桌面、GPT 白龙娘·终端、
GPT 白龙娘·桌面、DeepSeek 娘·桌面；点击直接切换对应 `enabled`，同时进入 `petMode=clients`。
不再显示「桌宠模式」三选一，也不再为每只宠增加“显示并置前 / 隐藏 / 设置”子菜单。
「原有单桌宠」作为独立回退入口保留；单只宠的隐藏、设置、大小等仍从宠物自己的右键菜单操作。
五只全关时仅保留一个隐藏的菜单窗口，仍可从爪印重新开启。

内部继续支持 `single` 原有单桌宠、`families` 三家族、`clients` 五客户端。
升级不重写已有 `petMode`；原有三宠用户可继续使用，`families` 代码和配置保留，但不再提供主菜单入口。
新配置的原默认规则也保留：没有角色配置时为三宠，已有角色配置时保留单宠。
每只宠有独立偏好域 `io.github.crosspet.pet.<petId>`（首次从家族域/应用域复制外观，之后独立），
独立启用、隐藏、位置、缩放、皮肤、贴边、全屏规则；窗口在同一进程内，素材只读共享。
快捷键由同一应用管理，多宠模式同时切换当前启用桌宠的可见性。

默认 `onWork` 下，AI 未启动或未接入时也保留已打开的角色窗口。没有任何会话事件时显示「等待会话事件」
（内部状态 `Unknown`，不是 Offline）；只有真实 SessionEnd 或已观察到生产者进程退出才显示 Offline。
已接入会话长时间沉默显示「状态待确认」，不将沉默当作成功或离线。出现方式决定窗口可见性，不改写工作状态。

单宠模式继续读取原状态文件、按模型和前台应用切角色；角色、皮肤、节日动作、额度显示和互动代码继续复用。

## 出现方式

在每只宠的「设置」页选择，主菜单不增加此设置。`appearanceMode` 保存在各宠偏好域；单宠保存在应用域。
全局 `appearanceEnabled` 保存在应用域，默认 `true`；关闭后停用新增自动出现规则，恢复原窗口可见行为。
原「AI 开始工作时自动出现」开关仍由 `ai-autostart-off` 控制，独立生效，不改名、不迁移。

| 模式 | 行为 |
|---|---|
| `onWork`（默认） | 保持现状：工作事件钩子按原规则拉起 App；宿主关闭不自动收起，退出靠手动。默认不安装后台监视器。 |
| `followApp` | 绑定宿主存在时出现，进程退出后收起；监听 NSWorkspace 启停通知并检查进程，每 3 秒补查。扫描失败不当作宿主退出，沉默不算退出。 |
| `always` | 无需宿主，自动保持 App 运行；单只宠的隐藏、禁用和全屏规则仍生效。 |

宿主绑定为 Claude.app、ChatGPT.app、DeepSeek Harness.app 的实际可执行路径；Codex Desktop 不只按 bundle id 判断。
终端宠检查独立 `claude` / `codex` 进程及祖先，排除 Desktop 内嵌 CLI、CrossPet helper、app-server-daemon 和 PPID 1 后台孤儿。
旧三宠按家族合并对应宿主，单宠可跟随任一受支持宿主。进程检查只读 PID、父 PID、可执行路径、启动时间，不读聊天或凭据。

从菜单手动「退出」继续写 `user-quit`：`followApp` 不被当时已打开的宿主立即拉起，宿主重开后才允许；
`always` 在本次开机期间保持退出。重启电脑使旧退出标记失效，手动打开 App 也会清除标记。
手动隐藏不因宿主跟随而被取消。

只有当前模式中至少一只启用宠选择 `followApp` 或 `always`，且总开关开启时，才安装可选 LaunchAgent：
`~/Library/LaunchAgents/io.github.crosspet.appearance.plist`，运行当前 App 可执行文件的 `--appearance-watch`。
配置快照为 `~/Library/Application Support/CrossPet/appearance.json`，包含总开关和当前宠的模式/启用状态。
原 `user-quit`、`ai-autostart-off` 同在此数据目录；`pet.pid` 仍在 `/tmp/crosspet`。
测试可用 `CROSSPET_DATA_DIR`、`CROSSPET_STATE_DIR` 覆盖路径，隔离测试不安装 LaunchAgent。

切回全部 `onWork`、关闭总开关，或禁用全部需要监视的宠，会卸载该 LaunchAgent。
卸载或移动 App 前，先在设置关闭「启用自动出现规则（全部桌宠）」，确认上述 plist 已移除，再退出 App、将 App 移到废纸篓。
若 App 已无法打开，先执行 `launchctl bootout gui/$(id -u)/io.github.crosspet.appearance` 停止监视器，
再把该 plist 移到废纸篓，最后移动 App。移除 App 本身不等于卸载 LaunchAgent。

## 接入

App 的「设置 → 接入 AI」沿用原接入工具。Claude 标准 Hooks 与增强 mod 二选一；
Codex 必须在真实客户端中通过正常 `/hooks` 信任。DSH 插件需要重新启动 Harness 才会装载新代码。
具体版本、实测范围和限制见 `CLIENT-VERIFICATION.md`。

不要将普通 Claude 聊天页等同于 Claude Code 工作会话；本改造消费的是 Code 工作事件。
每个客户端仅支持它实际发出的事件。Codex 关闭终端不保证立即发出 SessionEnd，无法据此假定即时离线。

多宠按宿主绑定：`claude-code → claude`，`codex → gpt`，`deepseek-harness → deepseek`。
DSH 内使用 Claude/GPT 模型只更新 DeepSeek 的会话属性。
前端类型 `tui` / `desktop` 只来自宿主的明确证据，认不出就记 `unknown`，不按模型名、前台 App 或“不是终端”去猜：

| 客户端 | 证据 | 位置 |
|---|---|---|
| Claude Code | 环境变量 `CLAUDE_CODE_ENTRYPOINT`：`claude-desktop`→desktop，`cli`/`sdk-cli`→tui，其余 unknown | hook 与 mod 同一规则 |
| Codex | 钩子祖先进程里的 `codex` 可执行文件：在 `ChatGPT.app` 内→desktop；其他位置→tui；找不到→unknown | `crosspet-hook.py`（hooks.json 命令不变，无需重新信任） |
| DeepSeek Harness | 只有桌面版，source 固定 desktop | 插件 |

`CROSSPET_CLIENT=tui|desktop` 仍可显式覆盖（测试用）。快照带 `clientReason` 说明依据。五宠模式下 `unknown` 来源的会话
不会被塞进任何一只宠，而是在对应家族的徽标上提示「N 个会话来源未识别」。三宠模式仍接收全部来源。

## 协议与状态

原 `<character>-state/sessions/quota.json` 完整保留。新增文件位于：
`/tmp/crosspet/families/<family>/<source>-<client>-<session-key>.json`。
不同生产者每会话原子替换，字段包含 schema、family、source、client、sessionId、model、status、pose、event、
ts、observedAt、sequence、可用的 turnId / producerId / pid。
Claude mod 在受限 VM 通过 SDK 写入并原子重命名；文件键编码允许与通用 Hooks 不同，消费以字段复合身份为准。

Swift 按 source + client + sessionId 隔离，拒绝错误家族、重复与旧事件，已结束轮次的迟到工具不会重启任务。
聚合优先级：Waiting Permission、Waiting Input、Error、Tool Running、Thinking、Success、Idle、Offline。
终结结果展示四秒后聚合回待机，记录仍保留；显式完成才能得到 Success。
短暂 Stop 后立即 SessionEnd 的结果在 lastResult 中保留十秒，只用于完成通知，不篡改当前 Offline。
可信的长期生产者 PID 明确不存在时才能认定进程退出；瞬态 Hook 的父 shell PID 不作为宿主存活证据。

## 设置页与接入心跳

接入安装状态、插件版本、各 AI 最近消息时间（`seen`，存放在应用域）属于整台机器，所有宠的设置页读取同一份并同时刷新。
升级时一次性取各旧域（家族/五宠域）中最新的 `seen` 合并，旧键保留。任务状态、位置、皮肤等仍各自独立。
增强 mod 新写 `seen-claude-mod` 使用无引号数字；Swift 与接入工具兼容旧版带引号的时间戳和首尾空白。
保留“还没收到过它的消息”提示，只有没有可用记录时才显示；不会用模拟事件替代真实接入验收。

## 配置与可逆性

单宠原配置域 `io.github.crosspet` 不迁走；新增家族域为
`io.github.crosspet.pet.claude`、`io.github.crosspet.pet.gpt`、`io.github.crosspet.pet.deepseek`。
首次创建时复制外观设置，之后各自独立；原单宠位置、角色和设置保留。切回单宠不删除三宠/五宠配置。
五宠域为 `io.github.crosspet.pet.{claude-tui,claude-desktop,codex-tui,codex-desktop,dsh-desktop}`。
更新已安装插件前在数据目录 `integration-backups` 保存旧代码，写入失败回滚。
接入工具修改外部配置前沿用原备份机制。撤销仅删除 CrossPet 自己的接入项。

## 测试隔离

`CFFIXED_USER_HOME` 单独使用不足以隔离 macOS cfprefsd。
自动化窗口探针必须同时设置独立 `CROSSPET_PREFERENCES_SUITE=io.github.crosspet.test.<name>`，
以及独立绝对 `CROSSPET_DATA_DIR`、`CROSSPET_STATE_DIR`、`CROSSPET_PROBE_OUTPUT`，再传 `--runtime-probe`。
`CROSSPET_RENDER_TRACE` 为显式开启的隔离测试元数据，不写对话、工具参数或凭据。
程序化 NSPanel/WKWebView 验证与真实鼠标操作分开报告。

## 2026-10-25 状态刷新修复

来源提示仅统计近期未终结且无唯一 client 证据的会话，历史/离线/已解析记录不再累计。
旧活动超过 180 秒且没有结束证据时，展示 Unknown /“状态待确认”，不继续 busy/Thinking 动画，不推断成功或离线；旧活动不盖住较新的完成。
无 provider turn_id 的通用钩子使用本地持久关闭围栏，Stop 后的迟到子任务/工具不再重新激活，明确新输入才重开。
缺少结束事件时无法立即确认任务已完成；180 秒后仅显示“状态待确认”。明确新输入之后才到达、又缺少轮次身份的旧事件仍无法可靠归属。

## 渲染资源与文件缓存

只为当前模式下已启用的宠创建窗口和 WebView。禁用或切换模式时释放宠物渲染资源；重新启用恢复位置、大小、皮肤及当前状态。独立打开的设置等窗口可以保留。

有效但属于其他客户端、重复或过期的状态文件也缓存 mtime，避免每 0.3 秒重复读取与解析；损坏或未写完的 JSON 继续重试。状态刷新间隔和过期规则不变。
