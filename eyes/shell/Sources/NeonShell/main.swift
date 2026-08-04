import AppKit
import WebKit

// Neon kiosk shell: a borderless fullscreen window hosting the eyes web page,
// plus the wake-word listener. Ctrl-Opt-Cmd-Q quits (Esc under NEON_DEV=1);
// W triggers a wake for testing.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var wakeListener: WakeWordListener?
    private var owwListener: OpenWakeListener?
    private var voiceSession: VoiceSession?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var debugVisible = false
    private var statsTimer: Timer?
    private var micTimer: Timer?
    private let settings = SettingsBridge()
    private let display = DisplayKeeper()
    private var wakeHeard = ""  // latest wake-listener transcript, for the overlay
    private var providerName = ProcessInfo.processInfo.environment["NEON_PROVIDER"]
        ?? UserDefaults.standard.string(forKey: "neon.voiceProvider") ?? "gemini"

    /// When a trained Neon wake model is present, the openWakeWord path owns
    /// waking (it opens the session mid-phrase, so connect overlaps speech).
    /// SFSpeech then only feeds transcripts, the overlay, and voice-activity —
    /// NEON_SFWAKE=1 re-arms it for debugging. Models ship in the bundle, so
    /// this is normally true; it stays a check so a build without them still
    /// wakes rather than going deaf.
    private let sfSpeechWakes: Bool = {
        if ProcessInfo.processInfo.environment["NEON_SFWAKE"] == "1" { return true }
        guard let dir = OpenWakeListener.modelDir else { return true }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasNeonModel = files.contains {
            $0.hasSuffix(".onnx") && $0.lowercased().contains("neon")
        }
        return !hasNeonModel
    }()

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NSScreen.main else { fatalError("no screen") }

        // The settings panel is the first thing that talks *back* to the shell,
        // so the page gets a message handler as well as evaluateJavaScript.
        let config = WKWebViewConfiguration()
        config.userContentController.add(settings, name: SettingsBridge.handlerName)
        webView = WKWebView(frame: screen.frame, configuration: config)
        webView.isInspectable = true  // allow Safari Web Inspector while developing
        installSettingsBridge()

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.backgroundColor = .black
        window.contentView = webView

        loadEyes()

        window.makeKeyAndOrderFront(nil)
        Kiosk.apply()
        NSApp.activate(ignoringOtherApps: true)

        display.start()
        // Yield the screen while macOS asks about location, and take it back
        // the moment the question is answered.
        LocationProvider.shared.onAwaitingPermission = { [weak self] waiting in
            self?.awaitingPermission(waiting, reason: "location permission dialog")
        }
        LocationProvider.shared.start()
        // Calendars is *not* asked for at launch. It belongs to a plugin, and
        // a plugin asks when somebody turns it on in settings — standing at
        // the machine, having just clicked Allow, which is the only moment a
        // TCC dialog can actually be answered. (The step-aside plumbing is
        // still wired up here, because the prompt lands behind the kiosk
        // window wherever it is raised from.)
        CalendarBridge.onAwaitingPermission = { [weak self] waiting in
            self?.awaitingPermission(waiting, reason: "calendar permission dialog")
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
        // Deafness needs catching sooner than the 20 s idle sweep.
        micTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkMicrophone()
        }
        installExitHandlers()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.noteActivity()
            if Kiosk.isQuitChord(event) {
                NSApp.terminate(nil)
                return nil
            }
            if Kiosk.isStepAsideChord(event) {
                self?.stepAside(for: 45, reason: "make way for a system dialog")
                return nil
            }
            if Kiosk.isSettingsChord(event) {
                self?.settings.toggle()
                return nil
            }
            // With the panel up the page owns the keyboard — the single-letter
            // shortcuts below would otherwise fire while someone is typing
            // their household into a text box, and "d" would toggle the debug
            // overlay mid-word. Esc closes; everything else goes through.
            if self?.settings.isOpen == true {
                if event.type == .keyDown, event.keyCode == 53 {
                    self?.settings.close()
                    return nil
                }
                return event
            }
            if event.type == .keyUp {
                if event.keyCode == 48 { self?.showLegend(false); return nil }
                return event
            }
            switch event.keyCode {
            case 49:  // space — silence a ringing timer, from across the room
                if self?.dismissAlarmIfRinging() == true { return nil }
                return event
            case 53:  // esc — quits only in dev; in kiosk mode it does nothing,
                      // since a stray Esc is exactly how a guest lands on the desktop
                if !Kiosk.enabled { NSApp.terminate(nil) }
                return nil
            case 13:  // w — manual wake, for testing without the mic
                self?.logEvent("wake", "manual (W)")
                self?.triggerWake()
                return nil
            case 1:   // s — sleep now, exactly as the sleep tool does
                self?.sleepNow()
                return nil
            case 2:   // d — toggle the debug overlay
                self?.toggleDebugOverlay()
                return nil
            case 37:  // l — toggle the event log sidebar
                self?.toggleEventLog()
                return nil
            case 14:  // e — cycle voice engine (takes effect next session)
                self?.cycleEngine()
                return nil
            case 17:  // t — ghost mode: transparent background over the desktop
                self?.toggleTransparency()
                return nil
            case 35:  // p — cycle state previews (awake/hearing/thinking/speaking)
                self?.webView.evaluateJavaScript("window.neon && neon.previewNext()")
                return nil
            case 7:   // x — cycle emote animations
                self?.webView.evaluateJavaScript("window.neon && neon.emoteNext()")
                return nil
            case 48:  // tab (hold) — keyboard shortcut legend
                if !event.isARepeat { self?.showLegend(true) }
                return nil
            case 43:  // , — settings, the Mac-standard key for it
                self?.settings.toggle()
                return nil
            default:
                return event
            }
        }

        // A click anywhere silences a ringing timer — the cursor is only
        // visible for exactly that reason (see updateCursor).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.dismissAlarmIfRinging() == true ? nil : event
        }

        NSLog("Neon: SFSpeech wake triggers \(sfSpeechWakes ? "armed" : "off (custom wake model owns waking)")")
        let listener = WakeWordListener()
        listener.onWake = { [weak self] command, prelude in
            guard let self, self.sfSpeechWakes else { return }
            self.logEvent("wake", "SFSpeech: \(command ?? "(name only)")")
            self.triggerWake(command: command, prelude: prelude)
        }
        listener.onNameHeard = { [weak self] in
            // Pre-wake: eyes open and listen while the speaker finishes.
            guard let self, self.voiceSession == nil, !self.settings.isOpen else { return }
            self.noteActivity()
            self.webView.evaluateJavaScript("window.neon && neon.wake()")
        }
        listener.onWakeAborted = { [weak self] in
            guard let self, self.voiceSession == nil else { return }
            self.webView.evaluateJavaScript("window.neon && neon.sleep()")
        }
        listener.onTranscript = { [weak self] text in
            self?.wakeHeard = text
            // A partial arriving means someone is talking — listening cue,
            // and evidence against idle/doze hangup (works at a distance
            // where the session's mic-energy gate misses).
            self?.voiceSession?.noteVoiceActivity()
            self?.webView.evaluateJavaScript("window.neon && neon.hearing(0.55)")
        }
        listener.start()
        wakeListener = listener

        // openWakeWord runs alongside the SFSpeech matcher: it spots its
        // phrase mid-stream with no silence bookkeeping. On detection the
        // session opens with ring audio from just before the phrase, so the
        // model hears the summons and whatever follows it live.
        let oww = OpenWakeListener()
        oww.onDetect = { [weak self] name in
            guard let self else { return }
            let score = self.owwListener?.lastScore ?? 0
            guard self.voiceSession == nil else {
                self.logEvent("wake", String(format: "%@ %.2f — ignored, session live",
                                             name, score))
                return
            }
            NSLog("Neon: openWakeWord detection (\(name))")
            self.logEvent("wake", String(format: "%@ %.2f", name, score))
            self.triggerWake(preludeFrom: Date().addingTimeInterval(-2.0))
        }
        // Scores that nearly fired. Reading these from the kitchen is how you
        // learn whether the threshold or the model is what's missing you.
        oww.onNearMiss = { [weak self] score in
            self?.logEvent("wake", String(format: "near miss %.2f (threshold %.2f)",
                                          score, OpenWakeListener.threshold))
        }
        oww.start()
        owwListener = oww

        // Neon's hands. Completions push into the announce channel below; the
        // list pushes to the left edge of the page.
        TaskStore.shared.onFinished = { [weak self] task in
            self?.announce(task)
        }
        TaskStore.shared.onChanged = { [weak self] tasks in
            self?.pushTasks(tasks)
        }
        pushTasks(TaskStore.shared.tasks)

        // The kitchen timer rings on its own — no session, no announcement.
        // The shell's job is to make it impossible to miss and trivial to
        // silence: the cursor comes back so it can be clicked, and space
        // works from across the counter.
        KitchenTimer.shared.onChanged = { [weak self] t in
            self?.pushTimer(t)
        }
        KitchenTimer.shared.onRingChanged = { [weak self] ringing in
            guard let self else { return }
            self.logEvent(ringing ? "timer" : "timer",
                          ringing ? "ringing" : "silenced")
            self.noteActivity()
            self.updateCursor()
        }
        pushTimer(KitchenTimer.shared)

        // Anything that finished while she was shut down — a crash, a rebuild
        // mid-task — is still news when she comes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            // Only recent news. Anything older than an hour is marked spoken
            // without saying it — waking the kitchen to recite yesterday's
            // results would be worse than losing them.
            let unspoken = TaskStore.shared.tasks.filter { !$0.isActive && !$0.announced }
            let cutoff = Date().addingTimeInterval(-3600)
            for stale in unspoken where (stale.finishedAt ?? .distantPast) < cutoff {
                TaskStore.shared.markAnnounced(id: stale.id)
            }
            let fresh = unspoken.filter { ($0.finishedAt ?? .distantPast) >= cutoff }
            guard !fresh.isEmpty else { return }
            self.pendingAnnouncements.append(contentsOf: fresh)
            self.flushAnnouncements()
        }

        // First line of the log, once the page exists to receive it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.logEvent("session", "Neon up · \(self.providerName) · wake: \(self.wakeStatus())")
        }

        // Debug hook: NEON_AUTOWAKE=1 starts a voice session shortly after
        // launch, so the full audio path is testable without speaking.
        if ProcessInfo.processInfo.environment["NEON_AUTOWAKE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.triggerWake()
            }
        }
    }

    // ==================================================== settings
    // Comma opens the panel (Cmd-, too, out of habit). While it is up Neon is
    // asleep and stays asleep: the session closes, wakes are ignored, and the
    // cursor comes back because there is now something to click.
    //
    // The wake *listeners* keep running rather than being stopped. OpenWake
    // has no stop — it is designed to run for months — and the deafness
    // watchdog exists precisely to restart a listener that went quiet, so
    // stopping one deliberately would have the watchdog fighting to bring it
    // back. Gating the detections is the honest equivalent and can't leave her
    // deaf afterwards.

    private func installSettingsBridge() {
        settings.evaluate = { [weak self] js in
            self?.webView.evaluateJavaScript(js)
        }
        settings.log = { [weak self] kind, text in
            self?.logEvent(kind, text)
        }
        settings.onNeedsScreen = { [weak self] reason in
            self?.stepAside(for: 90, reason: reason)
        }
        settings.onOpenChanged = { [weak self] open in
            guard let self else { return }
            self.noteActivity()
            if open {
                // Nobody wants to be overheard by the thing whose settings
                // they are reading.
                self.voiceSession?.close(reason: "manual")
                self.webView.evaluateJavaScript("window.neon && neon.sleep()")
            } else {
                // Anything that finished while the panel was up is still news.
                self.flushAnnouncements()
            }
            self.updateCursor()
        }
        Updater.shared.onNeedsScreen = { [weak self] reason in
            self?.stepAside(for: 120, reason: reason)
        }
        Updater.shared.log = { [weak self] kind, text in
            self?.logEvent(kind, text)
        }
        // When it is safe for Neon to vanish for a few seconds and come back.
        // Deep sleep is the load-bearing condition — it means ten minutes with
        // nobody speaking to her — and the rest are the ways somebody can be
        // waiting on her without having said anything recently.
        Updater.shared.isQuiet = { [weak self] in
            guard let self else { return false }
            return self.deepAsleep
                && self.voiceSession == nil
                && !self.settings.isOpen
                && !KitchenTimer.shared.isActive
                && self.pendingAnnouncements.isEmpty
        }
    }

    // ==================================================== deep sleep
    // After a long stretch with nobody talking to her, the eyes fade to an
    // ember and the backlight goes down with them — a bright rectangle in a
    // dark kitchen at 2am is just light pollution, and the panel runs 24/7.
    //
    // Ambient kitchen conversation deliberately does not count as activity:
    // wake-listener transcripts fire for any speech in the room, and dinner
    // three meters away should not light the display back up. Only being
    // spoken to (a wake), a live session, or the keyboard counts.

    private let deepSleepAfter = ProcessInfo.processInfo.environment["NEON_DEEPSLEEP_SECS"]
        .flatMap(Double.init) ?? 600
    private let deepBrightness = ProcessInfo.processInfo.environment["NEON_DEEP_BRIGHTNESS"]
        .flatMap(Float.init) ?? 0.03
    private var lastActivity = Date()
    private var deepAsleep = false
    private var idleTimer: Timer?

    private func noteActivity() {
        lastActivity = Date()
        guard deepAsleep else { return }
        deepAsleep = false
        display.restore(over: 0.4)
        logEvent("wake", "deep sleep lifted")
        webView.evaluateJavaScript("window.neon && neon.deepSleep(false)")
    }

    /// The wake listener going deaf is the worst failure this thing has,
    /// because it is invisible: she simply never answers again. Nothing
    /// reports it, so it has to be inferred from silence at the microphone.
    private func checkMicrophone() {
        guard let oww = owwListener, oww.modelName != nil,
              let quiet = oww.secondsSinceAudio, quiet > 6 else { return }
        logEvent("error", String(format: "microphone silent for %.0fs — reattaching", quiet))
        NSLog("Neon: wake listener deaf for \(Int(quiet))s; reattaching tap")
        oww.reattach()
    }

    private func checkIdle() {
        checkMicrophone()
        TaskStore.shared.prune()
        // A downloaded update waits here for the room to empty. Runs before
        // the deep-sleep guard below, since deep sleep is precisely the state
        // it is waiting for.
        Updater.shared.installIfQuiet()
        // A running timer keeps the panel lit: it is a countdown someone is
        // watching, and an ember-dim clock is useless.
        //
        // A background task does not. Nothing about it is on screen worth
        // staying bright for — it announces itself when it lands, which wakes
        // her anyway — and a research task running at 2am should not hold the
        // kitchen display up all night.
        guard !KitchenTimer.shared.isActive else { return }
        // Somebody is standing at the machine reading the panel.
        guard !settings.isOpen else { return }
        guard !deepAsleep, voiceSession == nil,
              Date().timeIntervalSince(lastActivity) > deepSleepAfter else { return }
        deepAsleep = true
        NSLog("Neon: deep sleep after \(Int(deepSleepAfter))s idle")
        logEvent("sleep", "deep sleep after \(Int(deepSleepAfter))s idle")
        display.dim(to: deepBrightness, over: 6)
        // With the backlight at a few percent there is little left for the
        // render to do; without it the pixels have to carry the whole fade.
        let render = display.controlsBacklight ? 0.45 : 0.12
        webView.evaluateJavaScript("window.neon && neon.deepSleep(true, \(render))")
    }

    func applicationDidBecomeActive(_ note: Notification) {
        // Reapplying the lockdown while stepped aside would immediately undo
        // the whole point of stepping aside.
        if !steppedAside { Kiosk.apply() }
        updateCursor()
    }

    // ==================================================== step aside
    // The kiosk options that keep a guest from escaping — no process
    // switching, no app hiding, a window above the menu bar — also make macOS
    // permission prompts unanswerable: the dialog is behind Neon and the ways
    // to get past her are switched off. Location authorization hit this
    // immediately. So there is a deliberate way to yield the screen without
    // quitting, on a chord (Ctrl-Opt-Cmd-H) and automatically whenever
    // something is known to be waiting on a click.

    private var steppedAside = false
    private var stepAsideTimer: Timer?

    /// macOS queues TCC prompts one at a time, and on a first run both location
    /// and calendars are unanswered. Taking the screen back the moment the
    /// first one is dealt with would drop the kiosk straight on top of the
    /// second, which is the exact failure this machinery exists to avoid — so
    /// count the outstanding ones and only step back at zero.
    private var permissionWaits = 0

    private func awaitingPermission(_ waiting: Bool, reason: String) {
        if waiting {
            permissionWaits += 1
            stepAside(for: 90, reason: reason)
        } else {
            permissionWaits = max(0, permissionWaits - 1)
            if permissionWaits == 0 { stepBack() }
        }
    }

    func stepAside(for seconds: TimeInterval, reason: String) {
        stepAsideTimer?.invalidate()
        if !steppedAside {
            steppedAside = true
            logEvent("session", "stepping aside — \(reason)")
            NSApp.presentationOptions = []
            window.level = .normal
            window.orderBack(nil)
            NSApp.hide(nil)
        }
        // Always come back on its own. A kitchen display that stayed hidden
        // because nobody answered a dialog would just look broken.
        stepAsideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.stepBack()
        }
    }

    func stepBack() {
        guard steppedAside else { return }
        stepAsideTimer?.invalidate()
        stepAsideTimer = nil
        steppedAside = false
        logEvent("session", "back to kiosk")
        NSApp.unhide(nil)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Kiosk.apply()
        updateCursor()
    }

    func applicationDidResignActive(_ note: Notification) {
        updateCursor()
    }

    func applicationWillTerminate(_ note: Notification) {
        setCursorHidden(false)
        display.restoreImmediately()
    }

    // The page's `cursor: none` only holds while the pointer is over web
    // content; the native arrow still reappears on any movement, and an arrow
    // parked in the middle of the kitchen display is exactly the sort of
    // "this is a computer" detail the eyes are trying to make you forget.
    // Hidden only while Neon is frontmost and opaque: in ghost mode the point
    // is to work with what's underneath, which needs a pointer.
    private var cursorHidden = false

    private func updateCursor() {
        // A ringing timer is the one moment the cursor earns its place: Nick
        // asked to be able to click the alarm off, which needs something to
        // click with.
        setCursorHidden(NSApp.isActive && !transparentMode
                        && !KitchenTimer.shared.ringing && !settings.isOpen)
    }

    /// NSCursor.hide/unhide are a balanced pair — an unmatched hide leaves the
    /// cursor invisible system-wide until this process dies.
    private func setCursorHidden(_ hide: Bool) {
        guard hide != cursorHidden else { return }
        cursorHidden = hide
        if hide { NSCursor.hide() } else { NSCursor.unhide() }
    }

    /// The debug workflow runs the binary straight from a shell, so Ctrl-C is
    /// a normal exit — and it must not leave the panel dimmed. Dispatch
    /// sources deliver on the main queue, unlike a raw signal handler.
    private var signalSources: [DispatchSourceSignal] = []
    private func installExitHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.display.restoreImmediately()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // ==================================================== announce channel
    // A task finished and Neon has to say so. She is usually asleep when that
    // happens — she sleeps after 5 s of silence — so this is the piece that
    // decides *how* she gets to speak, not just that she should.
    //
    // Nick's call, 2026-08-02: anything may wake the room, deep sleep
    // included. If that turns out to be annoying at 3am, gate it here.

    /// Announcements that couldn't be delivered yet — a task that finished in
    /// the moment between `go_to_sleep` and the socket actually closing used to
    /// be dropped in silence, marked announced, and never spoken.
    private var pendingAnnouncements: [NeonTask] = []

    private func announce(_ task: NeonTask) {
        logEvent("task", "\(task.id) \(task.status.rawValue) — announcing")
        // Mid-conversation: slip it in as a turn she can work into what she's
        // already saying. inject() reports whether the session could take it.
        if let session = voiceSession, session.inject(task.completionNote) {
            TaskStore.shared.markAnnounced(id: task.id)
            return
        }
        pendingAnnouncements.append(task)
        // With no session at all, deliver now; otherwise the closing session
        // hands over in onClosed. Starting one on top of a session that is
        // still shutting down would be refused.
        if voiceSession == nil { flushAnnouncements() }
        else { logEvent("task", "holding \(task.id) until the session closes") }
    }

    /// Wake and say everything that's been waiting. Several results arriving
    /// together become one wake rather than a queue of them.
    private func flushAnnouncements() {
        // Held, not dropped: `markAnnounced` happens below, so a result that
        // lands while the panel is up is still news when it closes.
        guard !pendingAnnouncements.isEmpty, voiceSession == nil,
              !settings.isOpen else { return }
        let held = pendingAnnouncements
        pendingAnnouncements = []
        for task in held { TaskStore.shared.markAnnounced(id: task.id) }
        let note = held.map(\.completionNote).joined(separator: " ")
        logEvent("task", "waking to announce \(held.count) result(s)")
        triggerWake(command: note)
    }

    private func pushTasks(_ tasks: [NeonTask]) {
        let rows: [[String: Any]] = tasks.filter(\.onScreen).map { t in
            var row: [String: Any] = [
                "id": t.id, "title": t.title, "status": t.status.rawValue,
            ]
            if let d = t.detail { row["detail"] = d }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.neon && neon.tasks(\(json))")
    }

    /// Who does the wake utterance sound like? Uses whatever audio the wake
    /// carried — the flushed utterance, or the ring back to the detection.
    private func speakerHint(prelude: Data?, from: Date?) -> String? {
        guard VoiceID.shared.isAvailable, !VoiceID.shared.profiles.isEmpty else { return nil }
        let pcm = prelude ?? AudioRing.shared.audio(since: from ?? Date().addingTimeInterval(-3))
        guard pcm.count > 16000 else { return nil }   // under half a second
        let samples: [Float] = pcm.withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Float($0) }
        }
        guard let who = VoiceID.shared.describe(samples) else { return nil }
        lastWho = "\(who.phrase ?? "no match") · \(who.detail)"
        logEvent("who", "voice: \(lastWho)")
        return who.phrase
    }

    /// Latest identity judgment, for the debug overlay — the event log scrolls,
    /// and "who does she think this is right now" is a standing question.
    private var lastWho = ""

    private func pushTimer(_ t: KitchenTimer) {
        var obj: [String: Any] = ["ringing": t.ringing, "label": t.label]
        if t.dueAt != nil { obj["remaining"] = Int(t.remaining) }
        obj["active"] = t.isActive
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.neon && neon.timer(\(json))")
    }

    /// Space, or a click anywhere, silences a ringing timer. Returns true if
    /// it consumed the event — while nothing is ringing, both keep their
    /// normal meaning.
    @discardableResult
    private func dismissAlarmIfRinging() -> Bool {
        guard KitchenTimer.shared.ringing else { return false }
        KitchenTimer.shared.stop()
        return true
    }

    private func triggerWake(command: String? = nil, prelude: Data? = nil,
                             preludeFrom: Date? = nil) {
        // One gate for every path in: the wake word, the W key, an
        // announcement landing. Settings is a modal moment.
        guard !settings.isOpen else {
            logEvent("wake", "ignored — settings is open")
            return
        }
        noteActivity()
        webView.evaluateJavaScript("window.neon && neon.wake()")
        startVoiceSession(command: command, prelude: prelude, preludeFrom: preludeFrom)
    }

    private func toggleDebugOverlay() {
        debugVisible.toggle()
        webView.evaluateJavaScript("window.neon && neon.debug(\(debugVisible))")
        statsTimer?.invalidate()
        statsTimer = nil
        if debugVisible {
            pushStats()
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.pushStats()
            }
        }
    }

    private var transparentMode = false
    private var eventLogVisible = false

    // ==================================================== event log
    // A running trace of the conversation's machinery — sessions, transcripts
    // both ways, tool calls, sleeps — rendered down the right edge. Events are
    // pushed whether or not the panel is showing, so L reveals the history.

    private func logEvent(_ kind: String, _ text: String) {
        // evaluateJavaScript takes source, not arguments: both strings go
        // through JSON encoding so quotes and newlines can't break out.
        webView.evaluateJavaScript(
            "window.neon && neon.event(\(Self.jsString(kind)), \(Self.jsString(text)))")
    }

    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())  // unwrap the array
    }

    private func toggleEventLog() {
        eventLogVisible.toggle()
        webView.evaluateJavaScript("window.neon && neon.events(\(eventLogVisible))")
    }

    /// S, and anything else that means "that's enough for now": the eyes shut
    /// at once, the way they do when the model calls the sleep tool. The slow
    /// dozing-off animation stays reserved for silence running out.
    private func sleepNow() {
        logEvent("sleep", "manual sleep (S)")
        if let session = voiceSession {
            // onClosed treats "manual" like "tool" — immediate close.
            session.close(reason: "manual")
        } else {
            webView.evaluateJavaScript("window.neon && neon.sleep()")
        }
    }

    private func showLegend(_ show: Bool) {
        webView.evaluateJavaScript("window.neon && neon.legend(\(show))")
    }

    private func toggleTransparency() {
        transparentMode.toggle()
        window.isOpaque = !transparentMode
        window.backgroundColor = transparentMode ? .clear : .black
        window.hasShadow = false
        // WKWebView has no public drawsBackground on macOS; KVC is the
        // long-standing way to make it composite transparently.
        webView.setValue(!transparentMode, forKey: "drawsBackground")
        webView.evaluateJavaScript("window.neon && neon.transparent(\(transparentMode))")
        updateCursor()   // ghost mode needs a pointer for what's underneath
    }

    private func cycleEngine() {
        let idx = engineNames.firstIndex(of: providerName) ?? 0
        providerName = engineNames[(idx + 1) % engineNames.count]
        UserDefaults.standard.set(providerName, forKey: "neon.voiceProvider")
        NSLog("Neon: voice engine -> \(providerName) (next session)")
        logEvent("session", "engine → \(providerName) (next session)")
        pushStats()
    }

    /// Which path is actually armed to wake her, plus the last openWakeWord
    /// hit — the answer to "is my trained model live?".
    private func wakeStatus() -> String {
        var parts: [String] = []
        if let model = owwListener?.modelName {
            parts.append(String(format: "%@ ≥%.2f", model, OpenWakeListener.threshold))
            if let at = owwListener?.lastDetectAt, let score = owwListener?.lastScore {
                parts.append(String(format: "last %.2f, %ds ago", score,
                                    Int(Date().timeIntervalSince(at))))
            }
        } else {
            parts.append("no wake model")
        }
        parts.append(sfSpeechWakes ? "+ SFSpeech" : "SFSpeech off")
        return parts.joined(separator: " · ")
    }

    private func pushStats() {
        var pairs: [[String]]
        if let session = voiceSession {
            pairs = session.statsPairs()
        } else {
            pairs = [
                ["engine", "\(providerName) (idle)"],
                ["state", "wake listener"],
                ["wake", wakeStatus()],
                ["mic", owwListener?.secondsSinceAudio.map {
                    String(format: "%.1fs since audio", $0) } ?? "not attached"],
                ["here", LocationProvider.shared.status()],
                ["lifetime", String(format: "$%.3f", UsageStore.shared.total)],
                ["mac hears", String(wakeHeard.suffix(70))],
            ]
        }
        if !lastWho.isEmpty { pairs.append(["who", lastWho]) }
        if let data = try? JSONSerialization.data(withJSONObject: pairs) {
            let json = String(decoding: data, as: UTF8.self)
            webView.evaluateJavaScript("window.neon && neon.stats(\(json))")
        }
    }

    private func startVoiceSession(command: String? = nil, prelude: Data? = nil,
                                   preludeFrom: Date? = nil) {
        guard voiceSession == nil else {
            // This used to return in silence, which is indistinguishable from
            // the wake never arriving.
            logEvent("error", "wake ignored — a session is already open")
            return
        }
        NSLog("Neon: starting voice session")
        // ~28 ms, against a socket connect of roughly a second — cheap enough
        // to resolve before the session opens rather than a turn late.
        let hint = speakerHint(prelude: prelude, from: preludeFrom)
        // The wake listener keeps running through the session — AudioHub fans
        // the mic out to both, and echo cancellation keeps Neon's own voice
        // out of it. No recognition-restart dead zone at session end, so she
        // hears her name any time, including mid-doze.
        webView.evaluateJavaScript("window.neon && neon.hold(true)")
        let session = VoiceSession(engine: makeEngine(providerName),
                                   firstUtterance: command, preludeAudio: prelude,
                                   preludeFrom: preludeFrom, speakerHint: hint)
        session.onAmplitude = { [weak self] amp in
            self?.webView.evaluateJavaScript("window.neon && neon.speaking(\(amp))")
        }
        session.onThinking = { [weak self] on in
            self?.webView.evaluateJavaScript("window.neon && neon.thinking(\(on))")
        }
        session.onDoze = { [weak self] dozing in
            self?.webView.evaluateJavaScript("window.neon && neon.\(dozing ? "doze" : "wake")()")
        }
        session.onCapture = { [weak self] in
            self?.webView.evaluateJavaScript("window.neon && neon.capture()")
        }
        session.onEmote = { [weak self] emotion in
            let safe = emotion.filter { $0.isLetter }
            self?.webView.evaluateJavaScript("window.neon && neon.emote('\(safe)')")
        }
        session.onEvent = { [weak self] kind, text in
            if kind == "who" { self?.lastWho = text }
            self?.logEvent(kind, text)
        }
        session.onClosed = { [weak self] reason in
            guard let self else { return }
            NSLog("Neon: voice session ended (\(reason))")
            self.voiceSession = nil
            self.noteActivity()   // the idle clock starts when the talking stops
            self.webView.evaluateJavaScript("window.neon && neon.hold(false)")
            if reason == "tool" || reason == "manual" {
                // She put herself to sleep (or S did) — eyes close right away;
                // the slow dozing-off animation is reserved for idle silence.
                self.webView.evaluateJavaScript("window.neon && neon.sleep()")
            }
            // A result that landed while she was closing gets said now. The
            // pause lets the goodbye finish and the eyes shut, so waking again
            // reads as a new thought rather than a stutter.
            if !self.pendingAnnouncements.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.flushAnnouncements()
                }
            }
        }
        voiceSession = session
        session.start()
    }

    private func loadEyes() {
        // Bundled resource first (production: inside Neon.app)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        // Dev fallback: walk up from cwd looking for the web page
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<5 {
            for rel in ["web/index.html", "eyes/web/index.html"] {
                let candidate = dir.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) {
                    webView.loadFileURL(candidate, allowingReadAccessTo: candidate.deletingLastPathComponent())
                    return
                }
            }
            dir.deleteLastPathComponent()
        }
        webView.loadHTMLString("<body style='background:#000;color:#fff'><h1>index.html not found</h1></body>", baseURL: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Offline pipeline check: NEON_OWW_TEST=file.wav runs the wake models over
// a 16 kHz mono WAV and prints scores, no app launch.
if let wav = ProcessInfo.processInfo.environment["NEON_OWW_TEST"] {
    OpenWakeListener.offlineTest(wavPath: wav)
    exit(0)
}

// Task runner check: NEON_TASK_TEST="title=instructions" runs one task to
// completion and prints what Neon would have been told, no app launch.
if let spec = ProcessInfo.processInfo.environment["NEON_TASK_TEST"] {
    let parts = spec.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else { print("format: title=instructions"); exit(1) }
    var done = false
    TaskStore.shared.onChanged = { tasks in
        if let t = tasks.last, t.isActive, let d = t.detail { print("  … \(d)") }
    }
    TaskStore.shared.onFinished = { task in
        print("\n\(task.status.rawValue) in \(Int(Date().timeIntervalSince(task.createdAt)))s")
        print("she would say → \(task.detail ?? "(nothing)")")
        print("\nannounce note → \(task.completionNote)")
        done = true
    }
    switch TaskRunner.shared.start(title: String(parts[0]),
                                   instructions: String(parts[1]),
                                   requester: "sounds like Nick") {
    case .success(let t): print("started \(t.id) — \(TaskRunner.home.path)/tasks/\(t.id)")
    case .failure(let r): print("refused: \(r.reason)"); exit(1)
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    exit(0)
}

// What the settings panel would be handed, without a window or a microphone:
// NEON_SETTINGS_TEST=1. Prints the state object, the tool surface each engine
// would be sent, and which plugins are on — the quickest way to confirm that
// switching something off really does remove it from the session rather than
// merely refusing it later.
if ProcessInfo.processInfo.environment["NEON_SETTINGS_TEST"] == "1" {
    let state = SettingsBridge().stateObject()
    if let data = try? JSONSerialization.data(withJSONObject: state,
                                              options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    let registry = PluginRegistry.shared
    print("\nplugins:")
    for p in registry.all {
        let on = registry.isEnabled(p.id)
        let why = on && !p.isUsable ? " (on, but permission missing)" : ""
        print("  \(on ? "●" : "○") \(p.id)\(why)")
    }
    let tools = coreTools + registry.activeTools
    print("\ntools this session would declare (\(tools.count)):")
    for t in tools {
        let params = t.params.map { $0.name + ($0.required ? "" : "?") }.joined(separator: ", ")
        print("  \(t.name)(\(params))")
    }
    exit(0)
}

// Pipeline check with no enrollment: NEON_FACEID_TEST=1
if ProcessInfo.processInfo.environment["NEON_FACEID_TEST"] != nil {
    Enrollment.faceCheck()
    exit(0)
}

// One sitting per person, both modalities: NEON_ENROL=Sam
if let name = ProcessInfo.processInfo.environment["NEON_ENROL"] {
    Enrollment.run(name: name)
    exit(0)
}

// Voice enrollment from files, for the offline harness:
// NEON_VOICEID_ENROL="Nick=a.wav,b.wav"
if let spec = ProcessInfo.processInfo.environment["NEON_VOICEID_ENROL"] {
    let parts = spec.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else { print("format: Name=clip1.wav,clip2.wav"); exit(1) }
    let name = String(parts[0])
    let vectors = parts[1].split(separator: ",")
        .compactMap { WavFile.samples(at: String($0)) }
        .compactMap { VoiceID.shared.embed($0) }
    guard !vectors.isEmpty else { print("no usable clips"); exit(1) }
    var mean = [Float](repeating: 0, count: vectors[0].count)
    for v in vectors { for i in v.indices { mean[i] += v[i] } }
    let norm = (mean.reduce(0) { $0 + $1 * $1 }).squareRoot()
    if norm > 0 { for i in mean.indices { mean[i] /= norm } }
    PersonStore.shared.setVoice(mean, for: name)
    print("enrolled \(name) from \(vectors.count) clip(s)")
    exit(0)
}

// Separability check: NEON_VOICEID_TEST=dir scores every WAV in a directory
// against every enrolled voice. Run this BEFORE building anything on top of
// speaker ID — twins are the case that decides what's possible.
if let dir = ProcessInfo.processInfo.environment["NEON_VOICEID_TEST"] {
    VoiceID.voiceMatrix(dir: dir)
    exit(0)
}

// The family's real schedule is in iCloud, not the Google calendar the task
// agent can reach, so tasks read it by re-running this binary:
// NEON_CALENDAR_DAYS=7 prints the next week as JSON, NEON_CALENDAR_LIST=1
// prints just the calendar names. Run from a task, the process tree is
// Neon -> zsh -> claude -> here, so the Calendars grant already belongs to
// Neon.app and no second prompt appears.
if let days = ProcessInfo.processInfo.environment["NEON_CALENDAR_DAYS"] {
    CalendarBridge.dump(days: Int(days) ?? 7)
}
// What the *model* is handed, which is not the JSON above: NEON_CALENDAR_SAY=2
// prints the day-grouped text `check_calendar` returns. Worth looking at with
// real events in it — this is the thing that gets read aloud, and an all-day
// event landing under the wrong heading is invisible in JSON and obvious here.
if let spec = ProcessInfo.processInfo.environment["NEON_CALENDAR_SAY"] {
    let plugin = CalendarPlugin.shared
    let context = PluginContext(requester: nil) { kind, text in print("[\(kind)] \(text)") }
    let done = DispatchSemaphore(value: 0)
    // A number is a day count; anything else is a search.
    if let days = Double(spec) {
        plugin.handle(tool: "check_calendar", args: ["days": days], context: context) {
            print($0); done.signal()
        }
    } else {
        plugin.handle(tool: "search_calendar", args: ["query": spec], context: context) {
            print($0); done.signal()
        }
    }
    done.wait()
    exit(0)
}
if ProcessInfo.processInfo.environment["NEON_CALENDAR_LIST"] == "1" {
    CalendarBridge.listCalendars()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
