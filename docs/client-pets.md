# 按客户端显示桌宠

多桌宠默认关闭。macOS 设置的「AI」页可开启；关闭后继续 dev 的单宠状态文件、菜单和跟随逻辑。沉默提示是独立的网页功能，不会伪造结束事件。

## 判断与系统接口

`app/web/client-policy.js` 的 ingest、aggregate、sessions、processExited、hosts、visible 均不读文件、不查进程，时间由调用方传入。Node 与 JavaScriptCore 共用测试样例。Mac 仅采集可执行文件路径、父进程和启动时间，读取快照并执行窗口操作。Windows 可直接复用模块，当前没有多窗口实现。

客户端注册表位于 ClientPolicy.specs，首批为 Claude 终端/桌面、Codex 终端/桌面和 DeepSeek Harness；可继续追加来源，不以五只为数量上限。unknown 只记诊断，不分配到已知端。Claude 宿主存在只证明程序开着，不证明存在 Code 会话。

## 文件和隔离

仅在数据目录的 `multi-pets-enabled` 标记存在时，接入层才额外发布 `families/<family>/` 的会话快照和 `clients/<family>-<client>-quota.json`。App 在显式切换模式时更新标记；关闭后不消费这些文件。原有状态格式与合法 AI 工作拉起机制保留，不安装后台 appearance LaunchAgent。

多宠路径复用 dev 的 session + turn gate，已知客户端使用各自的门禁/计数作用域，原宿主锁保护旧文件。hook 与 mod 是并行观测通道，分别排序，合并为一个会话；一个通道结束后，另一通道的旧工作不能恢复任务。来源、状态、额度均不借用另一端数据；缺少可靠额度显示待更新。Codex 本地服务查询无法证明桌面账号归属，因此不将其共享结果广播到多宠。

## 配置与回退

每宠保存 enabled、origin、dock、size、outfitV1、appearanceMode。衣服缺少动作时使用原角色图片。通用的额度开关、重置提醒、文字和省电设置继续共享。

迁移按键存在性处理，明确 false 和空服装不被覆盖。既有 sharedSettingsSchema=1 的主域保持原值；尚未迁移时，固定顺序为 codex-desktop、claude-desktop、codex-tui、claude-tui、dsh-desktop、旧 gpt/claude/deepseek 域、原主域。每宠自身已有配置优先，缺失才复制旧共享值。原域、迁移前备份和逐键来源保留，不猜测最后修改时间。

关闭多宠即可回到单宠。回退旧 App 时使用保留的原配置；不要在 App 运行时覆盖偏好域。无可靠 turnId 的 hook 遇到系统时钟回拨时，保守拒绝旁路更新，直到时间恢复；不把旧 prompt 猜成新任务。

## 验证边界

Node/Python、JavaScriptCore 样例、隔离偏好探针及原生窗口探针是不同证据。窗口探针使用合成事件和假宿主，不代表真实客户端任务通过。Windows 本机只能编译和运行兼容的逻辑测试，不能替代 Windows GUI 验证。
