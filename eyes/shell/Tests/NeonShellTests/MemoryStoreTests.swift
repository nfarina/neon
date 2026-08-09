import Testing
import Foundation
@testable import NeonShell

// MemoryStore.salience/tokens/similarity are pure functions of their
// arguments (and, for salience, the current time) — no store state, no disk
// I/O — so they're covered directly rather than through MemoryStore.shared,
// which persists to the real ~/.config/neon/memories.jsonl a unit test has
// no business touching.

@Suite
struct MemoryStoreSalienceTests {
    @Test func freshMemoryScoresNearFullRecency() {
        let fresh = Memory(id: "m1", text: "test", at: Date(), uses: 0)
        // ageDays ~ 0, so recency = 1/(1 + 0/30) ~ 1.0.
        #expect(abs(MemoryStore.salience(fresh) - 1.0) < 0.01)
    }

    @Test func aMonthOldMemoryIsHalfWeight() {
        // The decay comment is explicit about this: "half-weight at a month".
        let monthOld = Memory(id: "m1", text: "test", at: Date().addingTimeInterval(-30 * 86400), uses: 0)
        #expect(abs(MemoryStore.salience(monthOld) - 0.5) < 0.01)
    }

    @Test func salienceDecaysMonotonicallyWithAge() {
        let newer = Memory(id: "m1", text: "test", at: Date().addingTimeInterval(-1 * 86400), uses: 0)
        let older = Memory(id: "m2", text: "test", at: Date().addingTimeInterval(-60 * 86400), uses: 0)
        #expect(MemoryStore.salience(newer) > MemoryStore.salience(older))
    }

    @Test func moreUsesRaisesSalienceAtEqualAge() {
        let at = Date().addingTimeInterval(-10 * 86400)
        let rarelyUsed = Memory(id: "m1", text: "test", at: at, uses: 0)
        let oftenUsed = Memory(id: "m2", text: "test", at: at, uses: 10)
        // 0.15 per use, per the salience formula.
        #expect(abs((MemoryStore.salience(oftenUsed) - MemoryStore.salience(rarelyUsed)) - 1.5) < 0.01)
    }

    @Test func heavyUseCanOutweighBeingOlder() {
        // digest() ranks purely on salience, so a well-worn old memory should
        // still be able to beat a fresh but never-recalled one.
        let oldButUseful = Memory(id: "m1", text: "test",
                                   at: Date().addingTimeInterval(-90 * 86400), uses: 20)
        let freshButUnused = Memory(id: "m2", text: "test", at: Date(), uses: 0)
        #expect(MemoryStore.salience(oldButUseful) > MemoryStore.salience(freshButUnused))
    }
}

@Suite
struct MemoryStoreTokenizingTests {
    @Test func stopwordsAndShortWordsAreDropped() {
        let tokens = MemoryStore.tokens("the plan is to go")
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("is"))
        #expect(!tokens.contains("to"))
        #expect(!tokens.contains("go"))  // 2 chars, filtered regardless of stopword list
        #expect(tokens.contains("plan"))
    }

    @Test func allStopwordsYieldsNoTokens() {
        #expect(MemoryStore.tokens("to my we").isEmpty)
    }

    @Test func longPluralsAreStemmedSoSearchesMatchTheSingular() {
        // The comment on tokens() gives this exact example: "lessons" should
        // hit a memory that says "lesson".
        #expect(MemoryStore.tokens("lessons") == ["lesson"])
    }

    @Test func shortWordsEndingInSAreNotStemmed() {
        // The stemming guard is `count > 4` — a short word ending in "s"
        // keeps its "s" rather than losing a real letter.
        #expect(MemoryStore.tokens("bus") == ["bus"])
    }

    @Test func caseIsNormalized() {
        #expect(MemoryStore.tokens("Tennis") == MemoryStore.tokens("tennis"))
    }
}

@Suite
struct MemoryStoreSimilarityTests {
    @Test func identicalTextIsFullySimilar() {
        #expect(MemoryStore.similarity("Alex's tennis lesson", "Alex's tennis lesson") == 1.0)
    }

    @Test func unrelatedTextHasNoSimilarity() {
        #expect(MemoryStore.similarity("the tennis lesson moved", "grocery list for dinner") == 0.0)
    }

    @Test func aRewordedRestatementClearsTheRememberDedupThreshold() {
        // remember() merges instead of duplicating above 0.6 — this is the
        // case it exists for: the same fact, said slightly differently.
        let similarity = MemoryStore.similarity(
            "Alex's tennis lesson moved to Thursdays",
            "Alex's tennis lesson is now on Thursdays")
        #expect(similarity > 0.6)
    }

    @Test func aDifferentFactAboutTheSameTopicStaysBelowTheThreshold() {
        let similarity = MemoryStore.similarity(
            "Alex's tennis lesson moved to Thursdays",
            "Alex hates the smell of tennis balls")
        #expect(similarity < 0.6)
    }
}
