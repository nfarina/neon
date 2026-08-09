import Testing
import Foundation
@testable import NeonShell

// The doze/idle state machine in VoiceSession.swift is the known-untested
// area behind the recurring "she wasn't dozing off, she was still
// listening" class of bugs. These tests characterize the arm/reset/cancel
// paths and the idle-timeout transitions as they exist today — they do not
// change or attempt to fix the behavior, including anything that looks
// suspicious. Every real-world timer VoiceSession schedules runs through
// Timer.scheduledTimer on the main thread; setUpShortVoiceSessionTimings()
// shortens the production values via the same env-var seam
// NEON_DEAD_TURN_SECS already used for manual repro, so these run in well
// under a second instead of the real 5-10s.

@Suite(.serialized)
struct VoiceSessionDozeTests {
    init() { setUpShortVoiceSessionTimings() }

    // MARK: - Turn watchdog: arm / reset / cancel

    @Test func armingTurnWatchdogSetsTurnOwed() async {
        let session = VoiceSession(engine: FakeVoiceEngine())
        #expect(!session.turnOwed)
        await MainActor.run { session.armTurnWatchdog() }
        // armTurnWatchdog dispatches its own scheduling onto the main queue.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.turnOwed)
    }

    @Test func answerStartedResetsTheWatchdog() async {
        let session = VoiceSession(engine: FakeVoiceEngine())
        await MainActor.run { session.armTurnWatchdog() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.turnOwed)
        session.pendingTurnText = "what's the weather"
        session.retriedTurn = true

        await MainActor.run { session.answerStarted() }

        #expect(!session.turnOwed)
        #expect(session.pendingTurnText.isEmpty)
        #expect(!session.retriedTurn)
    }

    @Test func answerStartedWithNothingArmedIsANoOp() async {
        // Cancel path with nothing to cancel — must not crash or leave
        // turnOwed in a surprising state.
        let session = VoiceSession(engine: FakeVoiceEngine())
        await MainActor.run { session.answerStarted() }
        #expect(!session.turnOwed)
    }

    // MARK: - Abandoned turns

    @Test func abandonedTurnRetriesOnceAndStaysArmed() async {
        // Simulate a turn the model took input for and then never answered:
        // ready, nothing playing, not thinking, and the server has been
        // quiet at least as long as the (shortened) dead-turn window.
        let session = VoiceSession(engine: FakeVoiceEngine())
        session.ready = true
        session.pendingTurnText = "what's the weather"
        session.lastServerAt = .distantPast

        await MainActor.run { session.checkAbandonedTurn() }
        // The retry re-arms via armTurnWatchdog(), which schedules itself
        // through DispatchQueue.main.async rather than arming inline.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(session.retriedTurn)
        #expect(session.turnOwed)  // re-armed for the retry
        #expect(!session.closed)   // first miss retries, it doesn't give up
    }

    @Test func checkAbandonedTurnDefersWhileTheModelIsStillWorking() async {
        // pendingPlaybacks > 0 means audio is still queued — this must not
        // be mistaken for an abandoned turn.
        let session = VoiceSession(engine: FakeVoiceEngine())
        session.ready = true
        session.pendingTurnText = "what's the weather"
        session.lastServerAt = .distantPast
        session.pendingPlaybacks = 1

        await MainActor.run { session.checkAbandonedTurn() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!session.retriedTurn)
        #expect(session.turnOwed)  // deferred, not abandoned — watchdog re-armed
    }

    @Test func checkAbandonedTurnDefersWhileThinking() async {
        let session = VoiceSession(engine: FakeVoiceEngine())
        session.ready = true
        session.pendingTurnText = "what's the weather"
        session.lastServerAt = .distantPast
        session.thinkingActive = true

        await MainActor.run { session.checkAbandonedTurn() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!session.retriedTurn)
        #expect(session.turnOwed)
    }

    // MARK: - Idle timeout -> doze

    @Test func idleTimeoutEntersDozeWhenTheRoomIsQuiet() async {
        let session = VoiceSession(engine: FakeVoiceEngine())
        var dozeEvents: [Bool] = []
        session.onDoze = { dozeEvents.append($0) }

        await MainActor.run { session.bumpIdle() }
        try? await Task.sleep(nanoseconds: 500_000_000)  // > NEON_IDLE_SECS

        #expect(session.dozing)
        #expect(dozeEvents == [true])
    }

    @Test func recentVoiceActivityPostponesDoze() async {
        // lastVoiceAt within the last 1.5s (noteVoiceActivity's effect) must
        // keep re-arming the idle timer instead of dozing off underneath
        // someone still talking.
        let session = VoiceSession(engine: FakeVoiceEngine())
        session.lastVoiceAt = Date()  // "someone is mid-sentence"
        var dozeEvents: [Bool] = []
        session.onDoze = { dozeEvents.append($0) }

        await MainActor.run { session.bumpIdle() }
        // Long enough to clear NEON_IDLE_SECS several times over, but the
        // 1.5s voice-recency gate in bumpIdle's guard should keep deferring.
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(!session.dozing)
        #expect(dozeEvents.isEmpty)
    }

    @Test func bumpIdleWhileDozingWakesHerBackUp() async {
        // The reset path: activity arriving mid-doze should exit doze
        // immediately, not merely postpone the next one.
        let session = VoiceSession(engine: FakeVoiceEngine())
        var dozeEvents: [Bool] = []
        session.onDoze = { dozeEvents.append($0) }
        await MainActor.run { session.enterDoze() }
        #expect(session.dozing)

        await MainActor.run { session.bumpIdle() }
        // bumpIdle's exitDoze runs inside its own DispatchQueue.main.async
        // block rather than inline, so give it a beat to actually run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(!session.dozing)
        #expect(dozeEvents == [true, false])
    }

    // MARK: - enterDoze / exitDoze guards

    @Test func enterDozeIsANoOpWhileThinking() async {
        // This is the exact shape of bug Nick diagnosed by hand (2026-08-03,
        // see the comment above VoiceSession.idleSeconds): a thought part
        // must not let the idle clock doze her off mid-reasoning.
        let session = VoiceSession(engine: FakeVoiceEngine())
        session.thinkingActive = true
        var dozeEvents: [Bool] = []
        session.onDoze = { dozeEvents.append($0) }

        await MainActor.run { session.enterDoze() }

        #expect(!session.dozing)
        #expect(dozeEvents.isEmpty)
    }

    @Test func enterDozeIsANoOpWhenAlreadyClosedOrSleepRequested() async {
        let closedSession = VoiceSession(engine: FakeVoiceEngine())
        closedSession.closed = true
        await MainActor.run { closedSession.enterDoze() }
        #expect(!closedSession.dozing)

        let sleepingSession = VoiceSession(engine: FakeVoiceEngine())
        sleepingSession.sleepRequested = true
        await MainActor.run { sleepingSession.enterDoze() }
        #expect(!sleepingSession.dozing)
    }

    @Test func exitDozeIsANoOpWhenNotDozing() async {
        let session = VoiceSession(engine: FakeVoiceEngine())
        var dozeEvents: [Bool] = []
        session.onDoze = { dozeEvents.append($0) }

        await MainActor.run { session.exitDoze() }

        #expect(!session.dozing)
        #expect(dozeEvents.isEmpty)  // no spurious onDoze(false) with nothing to exit
    }

    // MARK: - Doze window vs. an owed answer

    @Test func dozeWindowDoesNotCloseTheSessionWhileATurnIsOwed() async {
        // A slow reply can outlast the whole doze window (the comment in
        // enterDoze cites up to 8.3s measured against a 5s+5.2s close).
        // Closing here would cut off a reply that was simply running late,
        // so the doze poll must keep waiting rather than hang up.
        //
        // turnOwed is simulated with a long dummy timer rather than
        // armTurnWatchdog() itself: that timer is real, and at the shortened
        // NEON_DEAD_TURN_SECS it would fire checkAbandonedTurn() mid-test —
        // which, on a session that was never marked `ready`, clears the
        // watchdog without re-arming it and would make this test exercise
        // (and fight) a second state machine instead of isolating this one
        // guard.
        let session = VoiceSession(engine: FakeVoiceEngine())
        await MainActor.run {
            session.enterDoze()
            session.turnWatchdog = Timer.scheduledTimer(withTimeInterval: 999, repeats: false) { _ in }
        }
        #expect(session.turnOwed)

        // Wait past NEON_DOZE_WINDOW_SECS plus a couple of the doze timer's
        // 0.2s polls.
        try? await Task.sleep(nanoseconds: 700_000_000)

        #expect(session.dozing)   // still dozing, not woken
        #expect(!session.closed)  // and, importantly, not hung up on
    }
}
