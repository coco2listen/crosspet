import Cocoa
import WebKit

extension App {
    /// Exercises real NSPanel/WKWebView instances in a disposable home; this is not mouse-driven E2E.
    func startRuntimeProbe() {
        guard CommandLine.arguments.contains("--runtime-probe") else { return }
        let env = ProcessInfo.processInfo.environment
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        func isolatedPath(_ key: String, excluding: String) -> Bool {
            guard let path = env[key], path.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path != URL(fileURLWithPath: excluding).resolvingSymlinksInPath().path
        }
        guard let suite = env["CROSSPET_PREFERENCES_SUITE"], suite.hasPrefix("io.github.crosspet.test."),
              isolatedPath("CFFIXED_USER_HOME", excluding: realHome),
              isolatedPath("CROSSPET_DATA_DIR", excluding: realHome + "/Library/Application Support/CrossPet"),
              isolatedPath("CROSSPET_STATE_DIR", excluding: "/tmp/crosspet"),
              let output = env["CROSSPET_PROBE_OUTPUT"], output.hasPrefix("/") else {
            fputs("Runtime probe requires an isolated CFFIXED_USER_HOME, CROSSPET_DATA_DIR, CROSSPET_STATE_DIR, and absolute CROSSPET_PROBE_OUTPUT.\n", stderr)
            exit(2)
        }
        RuntimeProbe(app: owner, output: URL(fileURLWithPath: output)).start()
    }
}

private final class ProbeWeakView {
    weak var web: WKWebView?
    weak var panel: NSPanel?
    weak var drag: DragView?
    init(_ pet: App) { web = pet.web; panel = pet.panel; drag = pet.panel?.contentView?.subviews.first { $0 is DragView } as? DragView }
}

private final class RuntimeProbe {
    let app: App
    let output: URL
    let began = Date()
    var assertions: [[String: Any]] = []
    var stages: [[String: Any]] = []
    var finished = false
    let foregroundBefore = NSWorkspace.shared.frontmostApplication
    var restoring = false
    var saved: [(App, NSRect, Bool, Bool, [String: Any])] = []
    var ownerValues: [String: Any] = [:]
    /// "families" (3 pets) or "clients" (5 pets), chosen by the harness with CROSSPET_PROBE_MODE.
    let mode = ProcessInfo.processInfo.environment["CROSSPET_PROBE_MODE"] == "clients" ? "clients" : "families"
    var petCount: Int { mode == "clients" ? 5 : 3 }
    let keys = ["petMode", "origin", "size", "hidden", "enabled", "dock", "__runtimeProbeIdentity", "appearanceMode", "appearanceEnabled", "hideFullscreen", "skins", "showName", "auraMode", "powerSave", "codexResets"]

    init(app: App, output: URL) { self.app = app; self.output = output }
    func later(_ seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }
    func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        assertions.append(["name": name, "passed": passed, "detail": detail])
    }
    func preference(_ pet: App, _ key: String) -> UserDefaults {
        ["enabled", "origin", "dock", "__runtimeProbeIdentity"].contains(key) ? pet.windowDefaults : pet.defaults
    }
    func start() {
        for key in keys { if let value = preference(app, key).object(forKey: key) { ownerValues[key] = value } }
        appPreferences.set(mode, forKey: "petMode")
        app.applyPetMode()
        later(110) { [self] in
            guard !finished else { return }
            check("bounded_runtime", false, "Timed out waiting for WebKit or probe callbacks")
            finish()
        }
        waitReady()
    }
    func waitReady() {
        guard !finished else { return }
        guard app.activePets.count == petCount, app.allPets.allSatisfy({ $0.ready }) else {
            later(0.25) { [self] in waitReady() }; return
        }
        // didFinish queues character initialization and image loads after ready becomes true.
        later(1) { [self] in prepare() }
    }
    func prepare() {
        for pet in app.allPets {
            var values: [String: Any] = [:]
            for key in keys {
                if preference(pet, key) === pet.defaults { if let value = ownerValues[key] { values[key] = value } }
                else if let value = preference(pet, key).object(forKey: key) { values[key] = value }
            }
            if pet === app { values = ownerValues }
            saved.append((pet, pet.panel.frame, pet.userHidden, pet.pauseRealEvents, values))
            pet.pauseRealEvents = true
            pet.defaults.set(false, forKey: "hideFullscreen")
            pet.hiddenForFullscreen = false
            pet.windowDefaults.set(true, forKey: "enabled")
        }
        appPreferences.set(mode, forKey: "petMode")
        app.applyPetMode()
        check("distinct_active_windows", Set(app.activePets.map { ObjectIdentifier($0.panel) }).count == petCount)
        check("distinct_active_webviews", Set(app.activePets.map { ObjectIdentifier($0.web) }).count == petCount)
        check("shared_active_preferences", Set(app.activePets.map { ObjectIdentifier($0.defaults) }).count == 1)
        check("distinct_window_preferences", Set(app.activePets.map { ObjectIdentifier($0.windowDefaults) }).count == petCount)
        snapshot("initial") { [self] pages in
            for page in pages {
                let family = page["family"] as? String ?? "single"
                let pet = page["pet"] as? String ?? family
                check("image_loaded_\(pet)", (page["imageLoaded"] as? Bool) == true)
                if family != "single" { check("fixed_identity_\(pet)", page["charId"] as? String == family && page["familyMode"] as? String == family) }
                else { check("legacy_page_available", page["familyMode"] is NSNull && !(page["charId"] as? String ?? "").isEmpty) }
            }
            sharedSettingsWindows()
        }
    }
    /// Two actual settings WKWebViews receive a change through the page's native bridge.
    func sharedSettingsWindows() {
        let first = app.activePets[0]
        let pets = [first, app.activePets.first { $0.family != first.family } ?? app.activePets[1]]
        guard pets.count == 2 else { check("two_settings_owners_available", false); finish(); return }
        for pet in pets { pet.openSettings() }
        waitSettings(pets[0]) { [self] in
            waitSettings(pets[1]) { [self] in
                let code = "(()=>{post({cmd:'set',key:'showName',value:false}); post({cmd:'set',key:'aura',value:'off'}); post({cmd:'set',key:'powerSave',value:true});return true})()"
                pets[0].settingsWeb?.evaluateJavaScript(code) { [self] _, error in
                    check("settings_bridge_write_succeeded", error == nil, error?.localizedDescription ?? "")
                    later(0.8) { [self] in
                        let group = DispatchGroup()
                        for pet in pets {
                            group.enter()
                            pet.settingsWeb?.evaluateJavaScript("JSON.stringify({showName:state.showName,aura:state.aura,powerSave:state.powerSave})") { [self] value, _ in
                                let row = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                                check("open_settings_synced_\(pet.petId!)", row?["showName"] as? Bool == false && row?["aura"] as? String == "off" && row?["powerSave"] as? Bool == true)
                                group.leave()
                            }
                        }
                        for pet in app.activePets {
                            group.enter()
                            pet.web.evaluateJavaScript("document.documentElement.classList.contains('no-name') && document.documentElement.classList.contains('aura-off') && powerSave") { [self] value, _ in
                                check("shared_behavior_applied_\(pet.petId!)", value as? Bool == true)
                                group.leave()
                            }
                        }
                        group.notify(queue: .main) { [self] in
                            for pet in pets { pet.settingsWindow?.close() }
                            sharedServices()
                        }
                    }
                }
            }
        }
    }
    /// Seed public reset metadata only; this exercises service ownership without a network request.
    func sharedServices() {
        check("quota_timer_owned_once", app.quotaTimer != nil && app.familyPets.allSatisfy { $0.quotaTimer == nil })
        let quotaPath = stateDir.appendingPathComponent("deepseek-quota.json").path
        for pet in app.allControllers { pet.stamps["deepseek-quota"] = Date(); pet.stamps[quotaPath] = Date() }
        app.applySharedSettings(key: "dsQuota")
        check("ds_quota_change_invalidates_all_cache_keys", app.allControllers.allSatisfy { $0.stamps["deepseek-quota"] == nil && $0.stamps[quotaPath] == nil })
        let oldQuota = app.defaults.object(forKey: "gptQuota")
        let oldLast = app.codexLast, oldPayload = app.codexPayload, oldLiveAt = app.codexLiveAt
        app.defaults.set(true, forKey: "gptQuota"); app.codexLast = nil; app.codexPayload = nil; app.codexLiveAt = Date()
        for pet in app.allControllers { pet.refreshCodexQuota(.now) }
        check("failed_quota_request_throttled_across_pages", !app.codexInFlight)
        if let oldQuota { app.defaults.set(oldQuota, forKey: "gptQuota") } else { app.defaults.removeObject(forKey: "gptQuota") }
        app.codexLast = oldLast; app.codexPayload = oldPayload; app.codexLiveAt = oldLiveAt
        app.defaults.set(true, forKey: "codexResets")
        app.resetJSON = "{}"
        app.resetFetchedAt = Date()
        app.resetNextPollAt = Date().addingTimeInterval(1800)
        app.updateSharedResets()
        check("shared_reset_timer_owned_once", app.resetTimer != nil && app.resetTask == nil && app.familyPets.allSatisfy { $0.resetTimer == nil && $0.resetTask == nil })
        app.updateSharedResets()
        check("shared_reset_cached_update_keeps_timer", app.resetTimer != nil && app.resetTask == nil)
        let group = DispatchGroup()
        for pet in app.activePets {
            group.enter()
            pet.web.evaluateJavaScript("resetsShared === true && (resetsTimer === null || !resetsTimer)") { [self] value, error in
                check("renderer_reset_polling_disabled_\(pet.petId!)", value as? Bool == true, error?.localizedDescription ?? "")
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            app.defaults.set(false, forKey: "codexResets"); app.updateSharedResets()
            check("shared_reset_disabled_stops_service", app.resetTimer == nil && app.resetTask == nil)
            app.resetJSON = nil; app.resetFetchedAt = .distantPast; app.resetNextPollAt = .distantPast
            claudeOutfits()
        }
    }
    /// Actual renderer image loading for both reusable Claude outfits, preserving fixed client identity.
    func claudeOutfits() {
        let pets = app.activePets.filter { $0.family == "claude" }
        guard let pet = pets.first else { lifecycleInitialDisabled(); return }
        let previous = pet.defaults.dictionary(forKey: "skins") as? [String: String] ?? [:]
        let expected = ["claude-hoodie", "claude-pajamas"]
        check("claude_outfits_available", pets.allSatisfy { Set($0.skinChoices["claude"]?.map(\.id) ?? []).isSuperset(of: expected) })
        var remaining = expected
        func next() {
            guard !remaining.isEmpty else {
                pet.defaults.set(previous, forKey: "skins"); app.applySharedSettings(key: "skins")
                later(0.5) { [self] in lifecycleInitialDisabled() }; return
            }
            let skin = remaining.removeFirst()
            pet.wear("claude", skin)
            later(0.5) { [self] in
                let group = DispatchGroup()
                for view in pets {
                    group.enter()
                    view.web.evaluateJavaScript("JSON.stringify({id:charId,client:familyClient,skin:manifest.characters.claude.skin,image:[...document.querySelectorAll('#body img')].find(i=>i.classList.contains('on'))?.src||'',loaded:[...document.querySelectorAll('#body img')].some(i=>i.classList.contains('on')&&i.complete&&i.naturalWidth>0)})") { [self] result, _ in
                        let row = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                        check("outfit_render_\(skin)_\(view.petId!)", row?["id"] as? String == "claude" && row?["skin"] as? String == skin && row?["loaded"] as? Bool == true && (row?["image"] as? String)?.contains("/characters/\(skin)/") == true && (view.client == nil || row?["client"] as? String == view.client))
                        group.leave()
                    }
                }
                group.notify(queue: .main) { next() }
            }
        }
        next()
    }
    func awaitReady(_ count: Int, until deadline: Date = Date().addingTimeInterval(12), _ done: @escaping () -> Void) {
        guard !finished else { return }
        if app.activePets.count == count && app.allPets.allSatisfy({ $0.ready }) {
            if !restoring {
                for pet in app.allPets {
                    pet.pauseRealEvents = true
                    pet.defaults.set(false, forKey: "hideFullscreen")
                    pet.hiddenForFullscreen = false
                }
            }
            later(0.6, done)
        } else if Date() < deadline {
            later(0.2) { [self] in awaitReady(count, until: deadline, done) }
        } else {
            check("recreated_windows_ready", false, "expected \(count) active and ready, got \(app.activePets.count)")
            finish()
        }
    }
    func awaitReleased(_ refs: [ProbeWeakView], until deadline: Date = Date().addingTimeInterval(5), _ done: @escaping (Bool) -> Void) {
        guard !finished else { return }
        if refs.allSatisfy({ $0.web == nil && $0.panel == nil && $0.drag == nil }) { done(true) }
        else if Date() < deadline { later(0.1) { [self] in awaitReleased(refs, until: deadline, done) } }
        else { done(false) }
    }
    func lifecycleInitialDisabled() {
        let original = app.activePets
        let weakViews = original.map(ProbeWeakView.init)
        let other = mode == "clients" ? "families" : "clients"
        let otherSpecs = mode == "clients" ? App.familySpecs : App.petSpecs
        let disabledID = otherSpecs[0].id
        let preferences = UserDefaults(suiteName: "\(preferenceDomain).pet.\(disabledID)")!
        let old = preferences.object(forKey: "enabled")
        preferences.set(false, forKey: "enabled")
        appPreferences.set(other, forKey: "petMode"); app.applyPetMode()
        check("initially_disabled_pet_has_no_renderer", app.familyPets.first { $0.petId == disabledID }.map { $0.panel == nil && $0.web == nil } == true)
        check("initially_disabled_not_in_loaded_windows", !app.allPets.contains { $0.petId == disabledID })
        check("mode_switch_releases_previous_panels", original.allSatisfy { $0.panel == nil && $0.web == nil })
        awaitReady(otherSpecs.count - 1) { [self] in
            awaitReleased(weakViews) { [self] released in
                check("mode_switch_old_webviews_deallocated", released)
                if let old { preferences.set(old, forKey: "enabled") } else { preferences.removeObject(forKey: "enabled") }
                appPreferences.set(mode, forKey: "petMode"); app.applyPetMode()
                awaitReady(petCount) { [self] in lifecycleSettingsDisable() }
            }
        }
    }
    func waitSettings(_ pet: App, until deadline: Date = Date().addingTimeInterval(8), _ done: @escaping () -> Void) {
        guard !finished, let page = pet.settingsWeb else { check("settings_window_available", false); finish(); return }
        page.evaluateJavaScript("typeof setState === 'function' && !!state") { [self] value, _ in
            if value as? Bool == true { done() }
            else if Date() < deadline { later(0.2) { [self] in waitSettings(pet, until: deadline, done) } }
            else { check("settings_page_ready", false); finish() }
        }
    }
    func lifecycleSettingsDisable() {
        let pet = app.activePets.first { !($0.skinChoices[$0.family ?? ""] ?? []).isEmpty } ?? app.activePets[0]
        let identity = ObjectIdentifier(pet)
        let family = pet.family!
        let skin = pet.skinChoices[family]?.first?.id
        check("lifecycle_skin_fixture_available", skin != nil)
        var skins = pet.defaults.dictionary(forKey: "skins") as? [String: String] ?? [:]
        if let skin { skins[family] = skin; pet.defaults.set(skins, forKey: "skins") }
        let origin = NSPoint(x: pet.panel.frame.minX + 7, y: pet.panel.frame.minY + 11)
        pet.panel.setFrameOrigin(origin); pet.windowDefaults.set([origin.x, origin.y], forKey: "origin")
        let dir = stateDir.appendingPathComponent("families/\(family)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("runtime-lifecycle-state.json")
        let source = ["claude": "claude-code", "gpt": "codex", "deepseek": "deepseek-harness"][family]!
        let row: [String: Any] = ["schema": 1, "family": family, "source": source, "client": pet.client ?? "desktop", "sessionId": "lifecycle-state",
            "model": "test", "status": "Thinking", "pose": "thinking", "event": "UserPromptSubmit", "sequence": 1,
            "ts": Date().timeIntervalSince1970, "observedAt": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: row) { try? data.write(to: file, options: .atomic) }
        routedFiles.append(file)
        pet.pauseRealEvents = false; pet.pollStates(); pet.pauseRealEvents = true
        pet.openSettings()
        waitSettings(pet) { [self] in
            let weakView = ProbeWeakView(pet)
            pet.windowDefaults.set(false, forKey: "enabled"); app.applyPetMode()
            check("disabled_pet_renderer_released", pet.panel == nil && pet.web == nil && !pet.ready)
            check("disabled_pet_settings_retained", pet.settingsWindow != nil && pet.settingsWeb != nil)
            check("disabled_pet_feedback_summary_safe", pet.runtimeSummary().contains("窗口未创建"))
            check("disabled_pet_display_summary_safe", !pet.displaysSummary().isEmpty)
            pet.handleSettings(["cmd": "set", "key": "size", "value": 1.1])
            check("settings_change_while_disabled_persisted", abs(pet.defaults.double(forKey: "size") - 1.1) < 0.001)
            later(0.3) { [self] in
                pet.settingsWeb?.evaluateJavaScript("state.size") { [self] value, _ in
                    check("settings_change_while_disabled_roundtrip", abs((value as? Double ?? 0) - 1.1) < 0.001)
                    awaitReleased([weakView]) { [self] released in
                        check("disabled_pet_webview_deallocated", released)
                        pet.windowDefaults.set(true, forKey: "enabled"); app.applyPetMode()
                        awaitReady(petCount) { [self] in
                            check("reenabled_reuses_controller", app.activePets.contains { ObjectIdentifier($0) == identity })
                            check("reenabled_position_preserved", pet.panel.frame.origin == origin)
                            check("reenabled_size_preserved", abs(pet.web.pageZoom - 1.1) < 0.001)
                            check("reenabled_skin_preference_preserved", pet.defaults.dictionary(forKey: "skins") as? [String: String] == skins)
                            pet.pauseRealEvents = false; pet.pollStates(); pet.pauseRealEvents = true
                            later(0.6) { [self] in
                                pet.web.evaluateJavaScript("JSON.stringify({badge:document.getElementById('familyStatus')?.textContent,skin:manifest.characters[charId]?.skin||'',loaded:[...document.querySelectorAll('#body img')].some(i=>i.classList.contains('on')&&i.complete&&i.naturalWidth>0)})") { [self] value, _ in
                                    let view = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                                    check("reenabled_state_replayed_to_new_webview", (view?["badge"] as? String)?.contains("Thinking") == true)
                                    check("reenabled_skin_rendered", view?["skin"] as? String == (skin ?? "") && view?["loaded"] as? Bool == true)
                                    pet.settingsWindow?.close()
                                    try? FileManager.default.removeItem(at: file); routedFiles.removeAll { $0 == file }
                                    pet.familyState = FamilyState(family: family, client: pet.client); pet.familyPayload = ""; pet.familySessionPayload = ""
                                    pet.js("setSessions(\(pet.quote(family)), {})")
                                    manipulateWindow()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func snapshot(_ stage: String, completion: @escaping ([[String: Any]]) -> Void) {
        let group = DispatchGroup()
        var pages: [[String: Any]] = []
        for pet in app.allPets {
            group.enter()
            let code = """
            JSON.stringify((()=>{const img=[...document.querySelectorAll('#body img')].filter(i=>i.classList.contains('on'))[0]; return {
              charId, pose, familyMode, familyClient, caption:document.getElementById('caption').textContent,
              imageLoaded:!!img&&img.complete&&img.naturalWidth>0,
              naturalWidth:img?.naturalWidth||0, image:img?.src||'', bodyClass:document.getElementById('body').className,
              badge:document.getElementById('familyStatus')?.textContent||'', pageHidden,
              bubble:document.getElementById('bubble').textContent, animationFrames:framesFor(pose).length
            }})())
            """
            pet.web.evaluateJavaScript(code) { [self] result, error in
                var page: [String: Any] = ["family": pet.family ?? "single", "pet": pet.petId ?? "single", "frame": rect(pet.panel.frame),
                    "alpha": pet.panel.alphaValue, "activeInMode": pet.activeInMode,
                    "pageZoom": pet.web.pageZoom, "preferenceSuite": pet.petId.map { "\(preferenceDomain).pet.\($0)" } ?? "standard"]
                if let text = result as? String, let data = text.data(using: .utf8),
                   let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    page.merge(state) { _, new in new }
                } else { page["error"] = error?.localizedDescription ?? "No JSON returned"; check("javascript_\(stage)_\(pet.family ?? "single")", false) }
                pages.append(page)
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            stages.append(["stage": stage, "elapsedSeconds": Date().timeIntervalSince(began), "pages": pages])
            if stage == "initial" {
                for pet in app.activePets {
                    pet.web.takeSnapshot(with: nil) { image, _ in
                        guard let image, let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
                        try? png.write(to: self.output.deletingLastPathComponent().appendingPathComponent("pet-\(pet.petId ?? "single").png"), options: .atomic)
                    }
                }
            }
            completion(pages)
        }
    }
    func rect(_ frame: NSRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height].map(Double.init) }
    func manipulateWindow() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let body = CGRect(x: 0, y: 69, width: 1512, height: 913), toolbar = CGRect(x: 0, y: 33, width: 1512, height: 68)
        let split = App.fullscreenWindowPieces([body, toolbar], screen: screen, topSlack: 48)
        check("fullscreen_split_toolbar_merged", split.contains(body.union(toolbar)))
        let tiled = [CGRect(x: 0, y: 0, width: 1512, height: 491), CGRect(x: 0, y: 491, width: 1512, height: 491)]
        check("fullscreen_tiled_documents_not_merged", App.fullscreenWindowPieces(tiled, screen: screen, topSlack: 48).count == 2)
        let rounded = CGRect(x: 0, y: -1, width: 1512, height: 984.5)
        check("fullscreen_rounding_preserved", App.fullscreenWindowPieces([rounded], screen: screen, topSlack: 48) == [rounded])
        let secondScreen = CGRect(x: 0, y: 982, width: 1512, height: 982)
        check("fullscreen_other_screen_not_merged", App.fullscreenWindowPieces([screen, secondScreen], screen: screen, topSlack: 48) == [screen])
        let gapToolbar = CGRect(x: 0, y: 0, width: 1512, height: 30)
        check("fullscreen_toolbar_gap_not_bridged", App.fullscreenWindowPieces([body, gapToolbar], screen: screen, topSlack: 48).count == 2)
        let appearancePet = app.activePets[0]
        appearancePet.defaults.set("followApp", forKey: "appearanceMode")
        app.refreshAppearance(hosts: [:])
        check("host_exit_hides_window", appearancePet.hiddenForAppearance && appearancePet.panel.alphaValue == 0)
        let hostId = appearancePet.client != nil ? appearancePet.petId! : appearancePet.family == "gpt" ? "codex-tui" : appearancePet.family == "claude" ? "claude-tui" : "dsh-desktop"
        app.refreshAppearance(hosts: [hostId: Date().timeIntervalSince1970])
        check("host_launch_reveals_window", !appearancePet.hiddenForAppearance && appearancePet.panel.alphaValue == 1)
        appearancePet.userHidden = true
        app.refreshAppearance(hosts: [:]); app.refreshAppearance(hosts: [hostId: Date().timeIntervalSince1970])
        check("host_restart_preserves_manual_hide", appearancePet.userHidden && appearancePet.panel.alphaValue == 0)
        appearancePet.userHidden = false
        app.defaults.set(false, forKey: "appearanceEnabled"); app.refreshAppearance(hosts: [:])
        check("appearance_master_disables_follow", !appearancePet.hiddenForAppearance)
        app.defaults.removeObject(forKey: "appearanceEnabled")
        appearancePet.defaults.removeObject(forKey: "appearanceMode"); app.refreshAppearance(hosts: [:])
        check("onwork_default_unchanged", appearancePet.appearanceMode == "onWork" && !appearancePet.hiddenForAppearance)

        let current = app.activePets
        let weakViews = current.map(ProbeWeakView.init)
        for pet in current { pet.windowDefaults.set(false, forKey: "enabled") }
        app.applyPetMode()
        check("all_disabled_menu_has_window", app.activePets.isEmpty && app.menuPet.panel != nil && app.menuPet.web != nil)
        check("all_disabled_only_one_fallback", app.allPets.count == 1 && app.allPets.first === app && app.panel.alphaValue == 0)
        check("all_disabled_pet_renderers_released", current.allSatisfy { $0.panel == nil && $0.web == nil })
        check("all_disabled_menu_builds", app.menuPet.buildMenu().numberOfItems > 0)
        awaitReleased(weakViews) { [self] released in
            check("all_disabled_webviews_deallocated", released)
            for pet in current { pet.windowDefaults.set(true, forKey: "enabled") }
            app.applyPetMode()
            awaitReady(petCount) { [self] in manipulateRecreatedWindow() }
        }
    }
    func manipulateRecreatedWindow() {
        let pet = app.activePets[0]
        let marker = UUID().uuidString
        pet.windowDefaults.set(marker, forKey: "__runtimeProbeIdentity")
        check("preference_write_isolated", app.allPets.filter { $0 !== pet }.allSatisfy { $0.windowDefaults.string(forKey: "__runtimeProbeIdentity") != marker })
        let suite = UserDefaults(suiteName: "\(preferenceDomain).pet.\(pet.petId!)")!
        check("preference_readback", suite.string(forKey: "__runtimeProbeIdentity") == marker)
        let moved = NSPoint(x: pet.panel.frame.minX + 13, y: pet.panel.frame.minY + 17)
        pet.panel.setFrameOrigin(moved)
        pet.windowDefaults.set([moved.x, moved.y], forKey: "origin")
        check("programmatic_position_persisted", suite.array(forKey: "origin") as? [Double] == [Double(moved.x), Double(moved.y)])
        pet.handleSettings(["cmd": "set", "key": "size", "value": 1.2])
        later(0.7) { [self] in
            check("programmatic_scale", abs(pet.web.pageZoom - 1.2) < 0.01 && abs(pet.panel.frame.width - pet.pageSize.width * 1.2) < 1)
            pet.setUserHidden(true)
            check("shared_manual_hide", app.activePets.allSatisfy { $0.userHidden && $0.panel.alphaValue == 0 } && app.defaults.bool(forKey: "hidden"))
            check("all_windows_shared_scale_applied", app.activePets.allSatisfy { abs($0.web.pageZoom - 1.2) < 0.01 })
            check("manual_hide_shared_preference", app.allControllers.allSatisfy { $0.defaults.bool(forKey: "hidden") })
            snapshot("programmatic_window_changes") { [self] _ in
                pet.setUserHidden(false)
                check("show_restored", pet.panel.alphaValue == 1)
                routedSessions()
            }
        }
    }
    var routedFiles: [URL] = []
    func routedSessions() {
        for pet in app.activePets {
            guard let family = pet.family else { continue }
            let source = ["claude": "claude-code", "gpt": "codex", "deepseek": "deepseek-harness"][family]!
            for client in family == "deepseek" ? ["desktop"] : ["tui", "desktop"] + (mode == "clients" ? ["unknown"] : []) {
                let dir = stateDir.appendingPathComponent("families/\(family)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("runtime-probe-\(source)-\(client).json")
                let snapshot: [String: Any] = ["schema": 1, "family": family, "source": source, "client": client,
                    "sessionId": "runtime-probe-shared-session", "model": family == "deepseek" ? "claude-model" : family,
                    "status": mode == "clients" && family == "claude" ? (client == "tui" ? "Thinking" : "Waiting Permission") : "Tool Running",
                    "pose": mode == "clients" && family == "claude" ? (client == "tui" ? "thinking" : "asking") : "running",
                    "event": mode == "clients" && family == "claude" ? (client == "tui" ? "PreInvocation" : "PermissionRequest") : "PreToolUse", "sequence": 1,
                    "ts": Date().timeIntervalSince1970, "observedAt": Date().timeIntervalSince1970]
                if let data = try? JSONSerialization.data(withJSONObject: snapshot) { try? data.write(to: file, options: .atomic) }
                routedFiles.append(file)
            }
            pet.pauseRealEvents = false
            pet.pollStates()
            pet.pauseRealEvents = true
        }
        later(1) { [self] in
            snapshot("simulated_five_clients_file_to_web") { [self] pages in
                for pet in app.activePets {
                    check("source_session_count_\(pet.petId!)", pet.familyState?.records.count == (mode == "clients" || pet.family == "deepseek" ? 1 : 2))
                    if mode == "clients" && pet.family != "deepseek" { check("unattributed_surfaced_\(pet.petId!)", pet.familyState?.unattributed.count == 1) }
                }
                for page in pages where page["family"] as? String != "single" {
                    let family = page["family"] as! String, pet = page["pet"] as! String
                    let isClaudeClient = mode == "clients" && family == "claude"
                    let expected = isClaudeClient ? (pet == "claude-tui" ? "Thinking" : "Waiting Permission") : "Tool Running"
                    check("simulated_route_\(pet)", page["charId"] as? String == family && (page["badge"] as? String)?.contains(expected) == true)
                    if mode == "clients" {
                        let client = pet.hasSuffix("tui") ? "tui" : "desktop"
                        check("fixed_client_label_\(pet)", page["familyClient"] as? String == client && (page["badge"] as? String)?.hasPrefix(client == "tui" ? "终端 · " : "桌面 · ") == true)
                        if isClaudeClient { check("different_claude_pose_\(pet)", page["pose"] as? String == (client == "tui" ? "thinking" : "asking")) }
                    }
                    if family != "deepseek" && mode == "families" { check("multi_session_animation_\(pet)", (page["pose"] as? String)?.hasPrefix("busy_") == true) }
                }
                for file in routedFiles { try? FileManager.default.removeItem(at: file) }
                routedFiles = []
                for pet in app.activePets { pet.familyState = FamilyState(family: pet.family!, client: pet.client); pet.familyPayload = ""; pet.familySessionPayload = ""; pet.js("setSessions(\(pet.quote(pet.family!)), {})") }
                interact()
            }
        }
    }
    func interact() {
        for pet in app.activePets {
            pet.js("setEggsEnabled(false); devShow(\(pet.quote(pet.family!)), 'idle', '', null, 15000); (()=>{const random=Math.random;try{Math.random=()=>0.99;handleClick('pat')}finally{Math.random=random}})()")
        }
        later(0.6) { [self] in
            snapshot("pat_function_call") { [self] pages in
                for page in pages where (page["family"] as? String) != "single" {
                    check("pat_\(page["pet"]!)", page["pose"] as? String == "pat" && page["imageLoaded"] as? Bool == true)
                }
                for pet in app.activePets { pet.js("handleClick('poke')") }
                later(0.6) { [self] in
                    snapshot("poke_function_call") { [self] pages in
                        for page in pages where (page["family"] as? String) != "single" {
                            check("poke_\(page["pet"]!)", (page["pose"] as? String) != "pat" && page["imageLoaded"] as? Bool == true)
                        }
                        heartbeat()
                    }
                }
            }
        }
    }
    /// A heartbeat seen by one pet's owner must show in every pet's settings, and old per-pet values merge by newest.
    func heartbeat() {
        let now = Date().timeIntervalSince1970
        appPreferences.removeObject(forKey: "seen")
        let legacy = UserDefaults(suiteName: "\(preferenceDomain).pet.deepseek")!
        legacy.set(["claude": now - 500, "gpt": now - 50], forKey: "seen")
        UserDefaults(suiteName: "\(preferenceDomain).pet.claude")?.set(["gpt": now - 900], forKey: "seen")
        app.migrateSeen()
        check("seen_migrated_newest_wins", abs((app.lastSeen["gpt"] ?? 0) - (now - 50)) < 1 && abs((app.lastSeen["claude"] ?? 0) - (now - 500)) < 1)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? "\(now - 3)".write(to: stateDir.appendingPathComponent("seen-claude"), atomically: true, encoding: .utf8)
        let legacyTimestamp = " \n\"\(now - 2)\"\n "
        try? legacyTimestamp.write(to: stateDir.appendingPathComponent("seen-claude-mod"), atomically: true, encoding: .utf8)
        check("heartbeat_parses_plain", App.heartbeatTimestamp(" \n\(now)\n ") == now)
        check("heartbeat_parses_legacy_quoted", App.heartbeatTimestamp(legacyTimestamp) == now - 2)
        check("heartbeat_rejects_invalid", ["invalid", "nan", "inf", "0", "-1"].allSatisfy { App.heartbeatTimestamp($0) == nil })
        Shared.integrated = ["claude-hooks", "claude-mod"]
        app.refreshSeen()
        for pet in app.familyPets {
            let list = pet.settingsState()["integrations"] as? [[String: Any]]
            let age = list?.first { $0["id"] as? String == "claude-hooks" }?["lastSeen"] as? Double
            check("settings_heartbeat_visible_\(pet.petId!)", age != nil && age! < 10)
            let modAge = list?.first { $0["id"] as? String == "claude-mod" }?["lastSeen"] as? Double
            check("settings_mod_heartbeat_visible_\(pet.petId!)", modAge != nil && modAge! < 10)
        }
        Shared.integrated = nil
        changeMode()
    }
    func changeMode() {
        appPreferences.set("single", forKey: "petMode")
        app.applyPetMode()
        waitSingleReady()
    }
    func waitSingleReady() {
        guard !finished else { return }
        guard app.ready else { later(0.25) { [self] in waitSingleReady() }; return }
        later(0.6) { [self] in inspectSingleMode() }
    }
    func inspectSingleMode() {
        check("legacy_mode_active", app.activePets.count == 1 && app.activePets.first === app)
        check("legacy_full_character_catalog", Set(["claude", "gpt", "deepseek"]).isSubset(of: Set(app.characterIds)))
        snapshot("single_mode") { [self] pages in
            let single = pages.first { $0["family"] as? String == "single" }
            check("legacy_page_available", single?["familyMode"] is NSNull && !(single?["charId"] as? String ?? "").isEmpty)
            check("legacy_image_loaded", single?["imageLoaded"] as? Bool == true)
            renderCatalog { [self] in crossSwitch() }
        }
    }
    /// Every selectable character and every skin must load its idle image in the legacy single-pet page.
    func renderCatalog(_ done: @escaping () -> Void) {
        var queue: [(id: String, skin: String)] = []
        for id in app.characterIds { queue.append((id, "")); for skin in app.skinChoices[id] ?? [] { queue.append((id, skin.id)) } }
        func next() {
            guard !queue.isEmpty else { app.wear(app.characterIds[0], ""); done(); return }
            let item = queue.removeFirst()
            app.wear(item.id, item.skin)
            app.switchTo(item.id)
            later(0.7) { [self] in
                app.web.evaluateJavaScript("JSON.stringify({charId, ok: (()=>{const i=[...document.querySelectorAll('#body img')].find(i=>i.classList.contains('on'));return !!i&&i.complete&&i.naturalWidth>0})()})") { [self] result, _ in
                    let row = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    check("character_renders_\(item.id)\(item.skin.isEmpty ? "" : "_" + item.skin)", row?["charId"] as? String == item.id && row?["ok"] as? Bool == true)
                    next()
                }
            }
        }
        next()
    }
    func crossSwitch() {
        let previous = app.allPets
        let weakViews = previous.map(ProbeWeakView.init)
        let other = mode == "clients" ? "families" : "clients", otherCount = mode == "clients" ? 3 : 5
        appPreferences.set(other, forKey: "petMode"); app.applyPetMode()
        awaitReady(otherCount) { [self] in
            check("cross_mode_\(other)_active", app.activePets.count == otherCount && app.activePets.allSatisfy { $0.ready && $0.petId != nil })
            check("cross_mode_windows_distinct", Set(app.activePets.map { ObjectIdentifier($0.panel) }).count == otherCount)
            check("cross_mode_old_pets_inactive", previous.allSatisfy { !$0.activeInMode && $0.panel == nil && $0.web == nil })
            awaitReleased(weakViews) { [self] released in
                check("cross_mode_old_webviews_deallocated", released)
                finishInspect()
            }
        }
    }
    func finishInspect() {
        snapshot("cross_mode_checked") { [self] _ in
            appPreferences.set(mode, forKey: "petMode"); app.applyPetMode()
            awaitReady(petCount) { [self] in
                check("group_mode_restored", app.activePets.count == petCount && app.activePets.allSatisfy { $0.family != nil })
                snapshot("family_mode_restored") { [self] _ in
                    inspectClientMenu()
                    restore { [self] in
                        snapshot("preferences_restored") { [self] _ in
                            later(max(0, 20 - Date().timeIntervalSince(began))) { [self] in finish() }
                        }
                    }
                }
            }
        }
    }
    func inspectClientMenu() {
        let menu = app.menuPet.buildMenu()
        let switches = menu.items.first { $0.title == "桌宠" }?.submenu
        check("client_menu_five_flat_switches", switches?.numberOfItems == 5 && switches!.items.allSatisfy { $0.submenu == nil && $0.action == #selector(App.toggleClientPet(_:)) })
        check("mode_menu_removed", !menu.items.contains { $0.title == "桌宠模式" })
        let clientPrefs = UserDefaults(suiteName: "\(preferenceDomain).pet.claude-tui")!
        let oldEnabled = clientPrefs.object(forKey: "enabled")
        let enabled = oldEnabled as? Bool ?? true
        let item = NSMenuItem(); item.representedObject = "claude-tui"
        app.toggleClientPet(item)
        check("switch_enters_clients_and_toggles", app.petMode == "clients" && clientPrefs.bool(forKey: "enabled") == !enabled)
        if let oldEnabled { clientPrefs.set(oldEnabled, forKey: "enabled") } else { clientPrefs.removeObject(forKey: "enabled") }
        let fallback = NSMenuItem(); fallback.representedObject = "single"
        app.changePetMode(fallback)
        check("single_menu_fallback", app.petMode == "single" && app.activePets.count == 1)
        appPreferences.set(mode, forKey: "petMode"); app.applyPetMode()
    }
    func restorePreferenceValues() {
        for (pet, _, _, _, values) in saved {
            pet.scaleTimer?.invalidate()
            for key in keys { if let value = values[key] { preference(pet, key).set(value, forKey: key) } else { preference(pet, key).removeObject(forKey: key) } }
        }
        for key in keys {
            if let value = ownerValues[key] { preference(app, key).set(value, forKey: key) }
            else { preference(app, key).removeObject(forKey: key) }
        }
    }
    func restore(_ done: @escaping () -> Void) {
        restoring = true
        restorePreferenceValues()
        app.applyPetMode()
        awaitReady(petCount) { [self] in
            for (pet, frame, hidden, pause, values) in saved {
                pet.userHidden = hidden; pet.pauseRealEvents = pause; pet.shownScale = 0
                pet.applyScale(pet.petScale, anchor: .corner)
                pet.panel.setFrame(frame, display: true)
                if let origin = values["origin"] { pet.windowDefaults.set(origin, forKey: "origin") } else { pet.windowDefaults.removeObject(forKey: "origin") }
                if let stored = values["hidden"] { pet.defaults.set(stored, forKey: "hidden") } else { pet.defaults.removeObject(forKey: "hidden") }
                pet.js("devRelease(); setEggsEnabled(\(pet.eggsEnabled))")
            }
            check("window_frames_restored", saved.allSatisfy { $0.0.panel?.frame == $0.1 })
            check("appearance_preferences_restored", saved.allSatisfy { entry in
                let (pet, _, _, _, values) = entry
                return keys.allSatisfy { key in
                    let current = preference(pet, key).object(forKey: key)
                    if current == nil && values[key] == nil { return true }
                    return (current as? NSObject)?.isEqual(values[key]) == true
                }
            })
            done()
        }
    }
    func finish() {
        guard !finished else { return }
        finished = true
        for file in routedFiles { try? FileManager.default.removeItem(at: file) }
        if stages.last?["stage"] as? String != "preferences_restored", !saved.isEmpty { restorePreferenceValues() }
        foregroundBefore?.activate(options: [])
        let failed = assertions.filter { $0["passed"] as? Bool != true }.count
        let result: [String: Any] = ["kind": "programmatic_NSPanel_WKWebView_probe", "passed": failed == 0,
            "elapsedSeconds": Date().timeIntervalSince(began), "assertions": assertions, "stages": stages,
            "limitations": ["No physical mouse dragging or clicking", "No real AI client execution", "Persistence readback is in-process; process-restart coverage is separate"]]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        } catch { fputs("Runtime probe output failed: \(error.localizedDescription)\n", stderr); exit(2) }
        exit(failed == 0 ? 0 : 1)
    }
}
