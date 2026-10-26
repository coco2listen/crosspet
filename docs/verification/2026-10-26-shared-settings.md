# macOS 共享设置核验（2026-10-26）

本轮在 `perf/macos-pet-renderers` 的既有历史上追加修复，不重复提交 #33 的前置功能。#33、#34 均未合并；维护者要求的最新 `dev` 重构拆分尚未完成，本轮不能作为已满足上游合并要求的声明。

## 实际结果

| 检查 | 本轮执行结果 |
|---|---|
| Foundation 配置迁移 | 33 项通过：明确 false、缺省、固定优先级、GPT 两开关、旧域及主域备份、幂等 |
| Node | 原套件 99 项通过；新增共享重置服务 JS 7 项通过 |
| Python | 执行 69 项：68 通过、1 跳过 |
| 原生逻辑探针 | FamilyState 86、缓存 17、出现策略 55 项通过；出现策略使用合成进程元数据 |
| 最终构建五宠窗口 | 两次独立进程启动，各 143 项通过；共享大小与独立坐标重启一致 |
| 最终构建三宠兼容 | 两次独立进程启动，各 125 项通过；共享大小与独立坐标重启一致 |
| 最终构建真实鼠标 | CGEvent 驱动物理指针，29 项通过：逐宠拖动、其他宠不移动、贴边、重启位置恢复 |
| 最终构建真实全屏 | TextEdit / Space 真实切换，13 项通过：隐藏、退出恢复、关闭隐藏选项后仍显示 |
| 构建与安装 | arm64 构建、签名严格核验、最终 diff 格式检查通过；安装后二进制与受测构建逐字节相同 |

窗口探针使用真实 NSPanel 和 WKWebView，在独立偏好域及运行目录内执行。通过两个真实设置页的 native bridge 修改共享设置，检查所有设置页和渲染器的 showName / aura / powerSave，以及共享大小、手动隐藏、五个扁平启用开关、客户端身份、禁用释放 / 重启用恢复。重置服务使用公开合成元数据验证唯一计时器、缓存命中后的调度与页面不另起轮询；额度失败节流和 DeepSeek 两种缓存键失效亦有断言。这些不是五个真实客户端并发任务的证明。

首轮设置 bridge 探针因 JS 最后返回不可序列化值报失败；修正测试返回值后，最终构建完整重跑通过。没有把首轮失败记为通过。

## Claude Desktop 的现场原因与安装核验

修复前实测 Claude 主进程可识别，桌宠窗口已创建但 alpha=0。旧 Claude Desktop 域保存 `hidden=true`，`enabled=true`，`hideFullscreen=false`，未设置 appearanceMode（实际 onWork）；followApp 保存在别的宠域。窗口部分超出屏幕但仍有可见交集，不是完全丢失在屏外，也不是渲染资源未创建。

新版安装后，迁移保留了手动隐藏，主域 appearanceMode=followApp、gptQuota=true、codexResets=true。定点解除共享 hidden 标志并正常重启 CrossPet 后，真实 Claude 宿主仍在，`CrossPet · claude-desktop` 窗口 alpha=1、onscreen=true；GPT 桌面也可见。GPT 终端原本禁用，重启后仍禁用且无对应渲染窗口。DSH 宿主未运行，其宠在 followApp 下保持 alpha=0。

未通过真实快捷键完成本次恢复；Cua 键盘尝试未改变隐藏标志，不据此声明快捷键实测通过。恢复没有清空配置、没有强制常驻、没有生成工作事件。Claude Code 工作来源和普通聊天的区分做了源码检查；未新发真实 Claude Code 会话。未读取聊天、密钥或登录凭据，未退出真实 Claude / Codex / DSH 客户端或任务。

旧 App 已通过系统废纸篓接口回收；新版位于 `/Applications/CrossPet.app`。原偏好域保留，`sharedSettingsBackupV1` 验证包含旧 Claude hidden=true 和 GPT 两个开启值。旧 appearance LaunchAgent 的文件与注册服务均已不存在。

最终原生二进制 SHA-256：`b557721631633cb8572169748081fa97ab36ffd8b2be6779a056fc3636d2ec8a`。

## 未验证范围

未退出真实 Claude 来验证真实宿主退出；该分支的可见性通过原生窗口探针注入宿主集合及纯策略探针验证。未做五个真实客户端并发、真实 AI 应用全屏例外、多显示器、小时级稳定性、Windows、Intel 构建或 GitHub CI 验证。本轮没有重新测量资源占用或声明性能收益。
