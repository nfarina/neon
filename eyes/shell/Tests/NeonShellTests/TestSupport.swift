import Foundation
@testable import NeonShell

// Shared fixtures for the VoiceSession and MemoryStore tests. Kept in one
// file since both are small and neither is worth its own target.

/// A VoiceEngine that speaks no real wire protocol — just enough to satisfy
/// VoiceSession's init and the handful of calls the doze/idle state machine
/// makes along the way (readyMessages during a retried turn, cost during
/// close). No network, no real provider.
struct FakeVoiceEngine: VoiceEngine {
    var name = "fake"
    var model = "fake-model"
    var sendSampleRate = 16000.0
    var keyName = "FAKE_API_KEY"

    func url(key: String) -> URL { URL(string: "wss://example.invalid/fake")! }
    func headers(key: String) -> [String: String] { [:] }
    func openMessages(system: String, tools: [ToolSpec]) -> [[String: Any]] { [] }
    func readyMessages(greeting: String) -> [[String: Any]] { [["greeting": greeting]] }
    func audioMessage(_ base64: String) -> [String: Any] { [:] }
    func parse(_ msg: [String: Any]) -> [VoiceEvent] { [] }
    func cost(_ u: VoiceUsage, elapsed: TimeInterval) -> Double { 0 }
}

/// VoiceSession reads its doze/idle timing constants once, lazily, into
/// process-lifetime `static let`s (see VoiceSession.swift) — the same
/// escape hatch `NEON_DEAD_TURN_SECS` already used for manual repro before
/// this test target existed. Because they're memoized, only the *first*
/// evaluation in the process matters, so every test that touches timing
/// calls this with the same values before constructing a VoiceSession —
/// it doesn't matter which test gets there first, or whether Swift Testing
/// runs them in parallel.
///
/// Deliberately not exercised here: the doze window actually elapsing with
/// no turn owed, and a second abandoned-turn check giving up. Both end in
/// VoiceSession.close(), which calls UsageStore.shared.record(...) and
/// writes to the real ~/.config/neon/usage.json on whatever machine runs
/// the suite — not something a unit test should be mutating. Everything
/// upstream of that call is covered directly instead.
func setUpShortVoiceSessionTimings() {
    setenv("NEON_IDLE_SECS", "0.15", 1)
    setenv("NEON_DOZE_WINDOW_SECS", "0.3", 1)
    setenv("NEON_DEAD_TURN_SECS", "0.2", 1)
}
