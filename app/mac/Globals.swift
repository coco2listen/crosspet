// CrossPet：跨 AI 桌宠。透明无边框、永远在最上层、可拖动的小窗。
//
// 目录约定
//   ~/Library/Application Support/CrossPet/   运行目录（每次启动从 App 包里同步 web/ 和内置角色）
//       web/            画面（index.html + effects.js）
//       characters/     角色：<id>/character.json + 各姿态立绘（idle.webp、thinking-2.webp、idle-blink.webp …）
//                       自己加的角色放这里不会被覆盖
//       crosspet-hook.py  钩子脚本（Claude Code / Codex / Gemini CLI 用）
//   /tmp/crosspet/      各 AI 接入写的状态：<id>-state.json、<id>-quota.json
//
// 交互：单击 = 摸摸头；拖动 = 移动；右键 = 菜单（戳一下 / 彩蛋 / 换角色 / 改名 / 设置 / 退出）
import Carbon
import Cocoa
import ServiceManagement
import WebKit

// A separate preference domain is required for tests: CFFIXED_USER_HOME alone does
// not isolate cfprefsd's per-user application domains.
let preferenceDomain = ProcessInfo.processInfo.environment["CROSSPET_PREFERENCES_SUITE"] ?? "io.github.crosspet"
let appPreferences = ProcessInfo.processInfo.environment["CROSSPET_PREFERENCES_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? UserDefaults.standard
let stateDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSPET_STATE_DIR"] ?? "/tmp/crosspet", isDirectory: true)

/// Install status, plugin versions and the config watcher describe the machine, not one pet, so every pet window reads the same copy.
enum Shared {
    static var integrated: [String]?
    static var pluginStatus = "[]"
    static var configStamp: Date?
    static var healTimes: [Date] = []
    static var healPending: DispatchWorkItem?
}
