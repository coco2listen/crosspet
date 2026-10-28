import Foundation
import JavaScriptCore

/// Runs the same IO-free module as Node and the future Windows adapter.
enum ClientPolicyBridge {
    static let context: JSContext = {
        let context = JSContext()!
        let sourceURL = ProcessInfo.processInfo.environment["CROSSPET_POLICY_PATH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL!.appendingPathComponent("web/client-policy.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return context }
        context.evaluateScript(source, withSourceURL: sourceURL)
        return context
    }()
    static func call(_ name: String, _ args: [Any]) -> Any? {
        context.exception = nil
        let value = context.objectForKeyedSubscript("ClientPolicy")?.invokeMethod(name, withArguments: args)
        guard context.exception == nil else { return nil }
        return value?.toObject()
    }
    static var specs: [(id: String, family: String, client: String?, title: String)] {
        let rows = context.objectForKeyedSubscript("ClientPolicy")?.forProperty("specs")?.toArray() as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let family = row["family"] as? String, let title = row["title"] as? String else { return nil }
            return (id, family, row["client"] as? String, title)
        }
    }
}
