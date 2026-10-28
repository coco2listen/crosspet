import Cocoa
import WebKit

extension App {
    /// Opt-in test entry point. main.swift rejects non-isolated paths before creating this App.
    func startRuntimeProbe() {
        guard CommandLine.arguments.contains("--runtime-probe") else { return }
        ClientRuntimeProbe(app: self).start()
    }
}

private final class ClientRuntimeProbe {
    private let app: App
    private var checks: [String] = []
    private var failures: [String] = []
    private var rendererEvidence: [String: [String: Any]] = [:]
    private var failureEvidence: [[String: Any]] = []
    private let deadline = Date().addingTimeInterval(30)
    private var finished = false
    private var expectedSizes: [String: Double] = [:]
    private var expectedOutfits: [String: String] = [:]
    private var expectedOrigins: [String: [Double]] = [:]
    private var restoredPet: App?
    private weak var releasedWeb: WKWebView?

    init(app: App) { self.app = app }

    func start() {
        // Disable every service that can query real clients or the network before navigation finishes.
        for key in ["gptQuota", "agyQuota", "codexResets", "followApps", "followEvents", "eggs", "hideFullscreen", "edgeDock"] {
            appPreferences.set(false, forKey: key)
        }
        appPreferences.set("off", forKey: "hideHotkey")
        app.registerHotKey()
        appPreferences.set([:], forKey: "peakSkins")
        check(app.petMode == "single", "fresh preferences default to single mode")
        check(appPreferences.object(forKey: "petMode") == nil, "startup does not create a multi-pet preference")
        waitFor("single renderer ready", { self.app.ready && !self.app.characterIds.isEmpty }) { self.singleReady() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
            if !finished { failures.append("30-second runtime probe deadline"); finish() }
        }
    }

    private func check(_ condition: @autoclosure () -> Bool, _ label: String, actual: [String: Any]? = nil) {
        checks.append(label)
        if !condition() {
            failures.append(label)
            if let actual { failureEvidence.append(["check": label, "actual": actual]) }
        }
    }
    private func waitFor(_ label: String, _ predicate: @escaping () -> Bool, _ done: @escaping () -> Void) {
        guard !finished else { return }
        if predicate() { done(); return }
        guard Date() < deadline else { failures.append(label + " timed out"); finish(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in waitFor(label, predicate, done) }
    }
    private func inspect(_ pet: App, _ code: String, _ done: @escaping ([String: Any]) -> Void) {
        guard !finished, let web = pet.web else { failures.append("missing renderer during JavaScript inspection"); finish(); return }
        web.evaluateJavaScript(code) { [self, weak pet, weak web] value, error in
            guard !finished else { return }
            guard let pet, let web, pet.web === web, error == nil, let text = value as? String,
                  let data = text.data(using: .utf8), let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failures.append("renderer inspection failed: \(error?.localizedDescription ?? "invalid JSON or replaced renderer")")
                finish(); return
            }
            rendererEvidence[pet.petId ?? "single"] = answer
            done(answer)
        }
    }
    private var rendererState: String {
        "JSON.stringify({id:charId,powerSave,noName:document.documentElement.classList.contains('no-name'),skin:char()?.skin||'',badge:document.getElementById('familyStatus')?.textContent||'',switching:characterTarget!==null||characterTimer!==null})"
    }
    private func waitForRenderer(_ pet: App, _ label: String, _ predicate: @escaping ([String: Any]) -> Bool, _ done: @escaping ([String: Any]) -> Void) {
        let phaseDeadline = min(deadline, Date().addingTimeInterval(5))
        func sample() {
            guard !finished else { return }
            inspect(pet, rendererState) { [self] actual in
                if predicate(actual) { done(actual); return }
                if Date() >= phaseDeadline {
                    check(false, label + " timed out waiting for rendered state", actual: actual)
                    finish(); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sample() }
            }
        }
        sample()
    }
    private func singleReady() {
        check(app.allPets.count == 1, "single mode has exactly one window")
        check(app.familyPets.isEmpty, "single mode does not allocate client controllers")
        check(!FileManager.default.fileExists(atPath: app.root.appendingPathComponent("multi-pets-enabled").path), "single mode does not enable producer sidecar output")
        check(!app.buildMenu().items.contains { $0.title == "桌宠" }, "single mode retains original menu")
        let specs = App.petSpecs
        check(!specs.isEmpty, "shared client registry loaded")
        for (index, spec) in specs.enumerated() {
            let prefs = UserDefaults(suiteName: "\(preferenceDomain).pet.\(spec.id)")!
            let size = 0.7 + Double(index % 8) * 0.1
            let origin = [80.0 + Double(index) * 36, 120.0 + Double(index) * 28]
            var outfit = app.skinChoices[spec.family]?.first?.id ?? ""
            if spec.id == "claude-tui" { outfit = "claude-hoodie" }
            if spec.id == "claude-desktop" { outfit = "claude-pajamas" }
            if spec.id == "codex-desktop" { outfit = "" } // Explicit original outfit must beat shared skins.
            prefs.set(size, forKey: "size"); prefs.set(origin, forKey: "origin")
            prefs.set(outfit, forKey: "outfitV1"); prefs.set(true, forKey: "enabled")
            prefs.set("always", forKey: "appearanceMode") // Prevent live process scans in this probe.
            expectedSizes[spec.id] = size; expectedOrigins[spec.id] = origin; expectedOutfits[spec.id] = outfit
        }
        appPreferences.set("clients", forKey: "petMode")
        app.applyPetMode()
        waitFor("client renderers ready", { self.app.activePets.count == specs.count && self.app.activePets.allSatisfy { $0.ready } }) { self.clientsReady() }
    }
    private func clientsReady() {
        check(app.web == nil && app.panel == nil, "single renderer released when entering clients mode")
        check(Set(app.activePets.compactMap(\.petId)) == Set(App.petIds), "client registry maps to independent windows")
        check(FileManager.default.fileExists(atPath: app.root.appendingPathComponent("multi-pets-enabled").path), "explicit clients mode enables producer output")
        check(app.resetTask == nil && app.resetTimer == nil && !app.codexInFlight && !app.agyInFlight, "probe starts no global quota requests or reset polling")
        for pet in app.activePets {
            guard let id = pet.petId else { continue }
            check(abs(Double(pet.petScale) - (expectedSizes[id] ?? 0)) < 0.001, "\(id) independent scale")
            check(pet.windowDefaults.string(forKey: "outfitV1") == expectedOutfits[id], "\(id) independent outfit preference")
            check(pet.selectedSkins[pet.family ?? ""] == expectedOutfits[id], "\(id) selected outfit respects local value")
            check(pet.panel.title.contains(id), "\(id) native window identity")
            check(pet.windowDefaults.array(forKey: "origin") as? [Double] == expectedOrigins[id], "\(id) independent persisted position")
            check(pet.coordinator === app && pet.timer == nil && pet.quotaTimer == nil, "\(id) reuses process services")
            check(pet.familyState?.aggregate().event == "NoSessions", "\(id) empty host is waiting for session evidence")
        }
        check(app.activePets.first { $0.petId == "claude-tui" }?.skinChoices["claude"]?.contains { $0.id == "claude-hoodie" } == true, "Claude hoodie remains available")
        check(app.activePets.first { $0.petId == "claude-desktop" }?.skinChoices["claude"]?.contains { $0.id == "claude-pajamas" } == true, "Claude pajamas remain available")
        appPreferences.set(false, forKey: "showName"); app.applySharedSettings(key: "showName")
        appPreferences.set(true, forKey: "powerSave"); app.applySharedSettings(key: "powerSave")
        appPreferences.set(false, forKey: "textLinked"); appPreferences.set(1.1, forKey: "textSize")
        app.applySharedSettings(key: "textLinked")
        inspectClients(app.activePets, index: 0) { self.syntheticState() }
    }
    private func inspectClients(_ pets: [App], index: Int, done: @escaping () -> Void) {
        guard index < pets.count else { done(); return }
        let pet = pets[index], id = pet.petId ?? "?"
        waitForRenderer(pet, "\(id) initial identity and outfit", { [self] actual in
            actual["id"] as? String == pet.family && actual["skin"] as? String == expectedOutfits[id] && actual["switching"] as? Bool == false
        }) { [self] result in
            check(result["id"] as? String == pet.family, "\(id) renderer keeps its own character identity", actual: result)
            check(result["powerSave"] as? Bool == true, "\(id) receives shared power-save update", actual: result)
            check(result["noName"] as? Bool == true && pet.defaults.object(forKey: "showName") as? Bool == false, "\(id) explicit false shared setting reaches renderer", actual: result)
            check(result["skin"] as? String == expectedOutfits[id], "\(id) renderer uses its own outfit", actual: result)
            check((result["badge"] as? String)?.contains("等待会话事件") == true, "\(id) displays waiting-for-session label", actual: result)
            inspectClients(pets, index: index + 1, done: done)
        }
    }
    private func syntheticState() {
        let now = Date().timeIntervalSince1970
        let targets = app.activePets
        // Changing shared text size legitimately moves each footer anchor; recreation must restore
        // the latest saved location rather than the position from before that intentional resize.
        for pet in targets {
            if let id = pet.petId, let origin = pet.windowDefaults.array(forKey: "origin") as? [Double] { expectedOrigins[id] = origin }
        }
        for (index, pet) in targets.enumerated() {
            guard let family = pet.family, let client = pet.client, let spec = App.petSpecs.first(where: { $0.id == pet.petId }) else { continue }
            let source = family == "claude" ? "claude-code" : family == "gpt" ? "codex" : "deepseek-harness"
            let row: [String: Any] = ["schema": 1, "family": family, "source": source, "client": client,
                "sessionId": "same-synthetic-session", "model": "probe-model", "status": index % 2 == 0 ? "Thinking" : "Tool Running",
                "pose": index % 2 == 0 ? "thinking" : "reading", "event": index % 2 == 0 ? "PreInvocation" : "PreToolUse",
                "ts": now, "observedAt": now, "sequence": 1, "producerId": "synthetic-\(spec.id)", "turnId": "synthetic-turn"]
            if let data = try? JSONSerialization.data(withJSONObject: row) {
                check(pet.familyState?.ingest(data) == true, "\(spec.id) accepts its own synthetic session")
                for other in targets where other !== pet && other.family == family {
                    check(other.familyState?.ingest(data) == false, "\(spec.id) synthetic event cannot enter another client")
                }
            }
            pet.pollFamilyStates()
        }
        for pet in targets { check(pet.familyState?.records.count == 1, "\(pet.petId ?? "?") has only its own client task") }
        guard let tui = targets.first(where: { $0.petId == "claude-tui" }), let desk = targets.first(where: { $0.petId == "claude-desktop" }) else { failures.append("Claude pair missing"); finish(); return }
        inspect(tui, "JSON.stringify({badge:document.getElementById('familyStatus')?.textContent||'',id:charId})") { [self] result in
            check((result["badge"] as? String)?.contains("终端") == true, "terminal label renders on terminal Claude")
            inspect(desk, "JSON.stringify({badge:document.getElementById('familyStatus')?.textContent||'',id:charId})") { [self] desktop in
                check((desktop["badge"] as? String)?.contains("桌面") == true, "desktop label renders on desktop Claude")
                appearance(tui)
            }
        }
    }
    private func appearance(_ pet: App) {
        pet.windowDefaults.set("followApp", forKey: "appearanceMode")
        app.refreshAppearance(hosts: [:])
        check(pet.hiddenForAppearance, "followApp hides when synthetic host is absent")
        app.setUserHidden(true)
        app.refreshAppearance(hosts: [pet.petId!: 100])
        check(!pet.hiddenForAppearance && pet.userHidden && pet.panel.alphaValue == 0, "host presence preserves explicit user-hidden choice")
        app.setUserHidden(false)
        app.refreshAppearance(hosts: [pet.petId!: 100])
        check(!pet.hiddenForAppearance && !pet.userHidden, "followApp returns when synthetic host exists")
        pet.windowDefaults.set("always", forKey: "appearanceMode")
        app.refreshAppearance(hosts: [:])
        check(!pet.hiddenForAppearance, "explicit always ignores absent host")
        if ProcessInfo.processInfo.environment["CROSSPET_PROBE_FEATURE_ONLY"] == "1" { finish(); return }
        releaseAndRestore(pet)
    }
    private func releaseAndRestore(_ pet: App) {
        restoredPet = pet
        releasedWeb = pet.web
        for controller in app.familyPets { controller.windowDefaults.set(false, forKey: "enabled") }
        app.applyPetMode()
        check(app.allControllers.allSatisfy { $0.panel == nil && $0.web == nil && !$0.ready }, "all disabled pets retain no window or hidden WebView")
        check(app.activePets.isEmpty, "all disabled pets have no active renderer")
        check(app.familyPets.allSatisfy { $0.windowDefaults.object(forKey: "enabled") as? Bool == false }, "explicit false enablement survives mode application")
        check(releasedWeb?.navigationDelegate == nil, "released renderer has no navigation delegate")
        check(app.resetTask == nil && app.resetTimer == nil, "all disabled pets stop reset services")
        pet.windowDefaults.set(true, forKey: "enabled")
        app.applyPetMode()
        waitFor("re-enabled renderer ready", { pet.ready && pet.web != nil }) { [self] in
            check(pet.web !== releasedWeb, "re-enable allocates a fresh renderer")
            check(app.activePets.count == 1, "re-enable creates only the selected client")
            check(abs(Double(pet.petScale) - (expectedSizes[pet.petId!] ?? 0)) < 0.001, "re-enable restores independent size")
            check(pet.windowDefaults.string(forKey: "outfitV1") == expectedOutfits[pet.petId!], "re-enable restores independent outfit")
            check(pet.familyState?.records.count == 1, "re-enable preserves task state")
            check(pet.windowDefaults.array(forKey: "origin") as? [Double] == expectedOrigins[pet.petId!], "re-enable restores independent position")
            waitForRenderer(pet, "recreated renderer identity, outfit and task", { [self] actual in
                actual["id"] as? String == pet.family && actual["skin"] as? String == expectedOutfits[pet.petId!] &&
                    actual["switching"] as? Bool == false && (actual["badge"] as? String)?.contains("思考中") == true
            }) { [self] result in
                check(result["skin"] as? String == expectedOutfits[pet.petId!], "recreated renderer restores outfit", actual: result)
                check(result["powerSave"] as? Bool == true && result["noName"] as? Bool == true, "recreated renderer restores shared settings", actual: result)
                check((result["badge"] as? String)?.contains("思考中") == true, "recreated renderer restores its task status", actual: result)
                releasedWeb = nil
                appPreferences.set("single", forKey: "petMode")
                app.applyPetMode()
                waitFor("single renderer restored", { self.app.ready && self.app.web != nil }) { self.finishSingle() }
            }
        }
    }
    private func finishSingle() {
        check(app.activePets.count == 1 && app.familyPets.allSatisfy { $0.web == nil }, "returning to single releases all client renderers")
        check(!FileManager.default.fileExists(atPath: app.root.appendingPathComponent("multi-pets-enabled").path), "returning to single disables producer output")
        check(appPreferences.object(forKey: "showName") as? Bool == false, "shared explicit false survives mode round trip")
        finish()
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        app.timer?.invalidate(); app.quotaTimer?.invalidate()
        let report: [String: Any] = ["ok": failures.isEmpty, "checks": checks, "failures": failures,
            "kind": "native-window-probe-with-synthetic-events", "realClientOperations": false,
            "rendererEvidence": rendererEvidence, "failureEvidence": failureEvidence]
        if let output = ProcessInfo.processInfo.environment["CROSSPET_PROBE_OUTPUT"],
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print("Client runtime probe: \(checks.count) checks, \(failures.count) failures (synthetic events; no real client tasks)")
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        if !failureEvidence.isEmpty, let data = try? JSONSerialization.data(withJSONObject: failureEvidence, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { fputs("ACTUAL: \(text)\n", stderr) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
