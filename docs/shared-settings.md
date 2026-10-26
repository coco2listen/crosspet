# macOS 共享设置

所有窗口的用户设置使用主域 `io.github.crosspet`。每宠域只继续写 `enabled`、`origin`、`dock`；旧用户设置留在原域，供旧版本回退。固定 `family/client/petId` 由控制器决定，不从共享角色选择读取。

## 一次性迁移

`sharedSettingsSchema = 1` 表示迁移完成。迁移前将主域及八个旧宠域保存到主域的 `sharedSettingsBackupV1`，记录 `sharedSettingsSourcesV1` 供定位每个键的来源；旧域不删。

对每个已列入迁移的键，按以下顺序选择**第一个实际存在的值**：

1. `codex-desktop`
2. `claude-desktop`
3. `codex-tui`、`claude-tui`、`dsh-desktop`
4. 旧三宠 `gpt`、`claude`、`deepseek`
5. 原主域；仍未设置时使用程序默认值。

这是无修改时间记录情况下的固定冲突规则，不声称能判断哪个值最后修改。明确 `false` 会覆盖低优先级的 `true`，不做布尔 OR；字典也按同一来源整体选取。GPT 桌面优先，保留现场已开启的 `gptQuota`、`codexResets`。后续改动只写共享域，不再用旧域覆盖。

手动隐藏也成为全局设置，并按上述规则保留已有隐藏选择。恢复显示请单击菜单栏爪印；该明确操作会解除全局隐藏。迁移不会靠删除隐藏标志、伪造任务或强制常驻恢复 Claude 宠。单窗位置与贴边仍独立。

回退时退出新版并恢复旧 App，旧宠域仍可直接使用。若还需要恢复原单宠主域，可从 `sharedSettingsBackupV1["io.github.crosspet"]` 导出原始主域后恢复；先另存当前备份。不要在 CrossPet 运行时覆盖配置。

## 同步与服务

设置写入后按变更键向所有渲染器应用；禁用宠不创建 WebView，重新启用时读取同一设置。已开的设置页一起刷新；共享角色选择只决定设置页编辑对象，不改变五客户端身份。

Codex / Gemini 额度由主控制器查询并广播缓存；Codex 重置提醒由主控制器保留单个请求和计时器，macOS 各页面不另启联网轮询。Windows 网页的原轮询路径保留。额度查询只复用既有接口，本轮没有读取聊天或登录凭据。

跟随应用在 CrossPet 运行期间扫描可执行文件及父进程，不读取命令参数。保存配置会撤销旧 `io.github.crosspet.appearance` LaunchAgent，不再安装后台监视器。CrossPet 退出后的工作启动仍由原有钩子负责。
