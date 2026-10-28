# dev 拆分验证：客户端多桌宠

基线：origin/dev `0a3bce0887d2bb516778f14b33fe41bdfc6c8566`。来源 PR #35，沉默提示 PR #36。旧 #33/#34 均未合并，保留历史，不直接按 main 基线合入。

## C：功能验证

- Node：`node --test --test-reporter=tap tests/*.test.js tests/*.test.mjs tests/page_switch_test.cjs tests/ui_ownership_test.cjs`，213/213；页面与归属场景运行真实网页脚本的假 DOM/时钟，不是原生实测。
- Python：`python3 -m unittest discover -s tests -p '*_test.py'`，129项，127通过、2个Windows专用项跳过。覆盖dev turn gate、来源unknown、跨端同sid/turn、旁路关闭、迟到事件和时钟回拨。
- 原生纯逻辑：偏好迁移53/53；Node/JavaScriptCore共享样例2项一致。
- 原生窗口：`CROSSPET_PROBE_FEATURE_ONLY=1 ... tests/client_runtime_probe.sh`，93/93。使用独立preferences/home/data/state、合成事件和假宿主；覆盖默认single、五客户端独立窗口、大小/位置/衣服、通用设置同步、端标签及出现规则。此模式不验证D的禁用资源释放。
- 构建：Mac arm64+x86_64通用包；Windows完整打包和LogicTests 83项通过。FollowRoutingTests仅编译通过，在macOS运行因缺少mono失败；Windows GUI未验证。

首次窗口探针9项失败来自过早检查：WK didFinish不表示330ms换角已完成。修正为轮询真实charId/skin/characterTarget/characterTimer后，93项通过。首次Node整合失败来自抽取函数沙盒缺少family上下文，补齐后完整重跑通过。

## 边界

本轮没有真实客户端任务、真实鼠标/全屏、多显示器或小时级稳定性验证。不读取聊天、密钥或登录凭据，不终止Claude、Codex、DSH任务。所有窗口和偏好探针为隔离实例；不将旧报告作为本轮测试结果。

Codex服务查询缺少可靠客户端账号归属时，多宠不复用共享读数，显示待更新。无可靠turnId的hook遇到时钟回拨时保持保守。Windows多窗口等待后续接入。
