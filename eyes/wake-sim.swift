// Simulation of WakeWordListener's baseline/common-prefix wake logic with a
// fake clock. Mirrors the real implementation (keep in sync by hand).
import Foundation

let nameWords: Set<String> = ["neon", "neons", "neo", "nion", "nian", "neyon", "leon", "nia"]
let heyWords: Set<String> = ["hey", "hay", "hi", "ok", "okay"]
let fusedWords: Set<String> = ["henon", "heynon", "hanon", "heneon", "haynon"]
let utteranceGap = 0.7
let trailingSilence = 0.85

func tokenize(_ text: String) -> [String] {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))
    return text.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
}

func heySummons(in words: [String], from start: Int) -> Int? {
    for i in start..<max(start, words.count) {
        if fusedWords.contains(words[i]) { return i + 1 }
        if heyWords.contains(words[i]), let end = nameEnd(in: words, from: i) { return end }
    }
    return nil
}

func nameEnd(in words: [String], from start: Int) -> Int? {
    guard start < words.count else { return nil }
    let w0 = words[start]
    if nameWords.contains(w0) || fusedWords.contains(w0) || w0.hasPrefix("neon") { return start + 1 }
    if w0 == "knee", start + 1 < words.count, words[start + 1] == "on" { return start + 2 }
    if heyWords.contains(w0), start + 1 < words.count {
        if let end = nameEnd(in: words, from: start + 1) { return end }
    }
    return nil
}

func commonPrefix(_ a: [String], _ b: [String]) -> Int {
    var i = 0
    while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
    return i
}

final class Sim {
    var lastPartialAt = -1e9
    var baseline: [String] = []
    var latestWords: [String] = []
    var pending = false
    var pendingNameEnd: Int?
    var fired: String?

    func partial(_ text: String, at now: Double) {
        let words = tokenize(text)
        if now - lastPartialAt > utteranceGap { baseline = latestWords }
        lastPartialAt = now
        latestWords = words
        guard !pending else { return }
        let cut = commonPrefix(baseline, words)
        if let end = nameEnd(in: words, from: cut) ?? heySummons(in: words, from: cut) {
            pending = true
            pendingNameEnd = end
        }
    }

    func tick(at now: Double) {
        guard pending, now - lastPartialAt > trailingSilence else { return }
        evaluate()
    }

    func evaluate() {
        pending = false
        let cut = commonPrefix(baseline, latestWords)
        var matched = nameEnd(in: latestWords, from: cut)
            ?? heySummons(in: latestWords, from: cut)
        if matched == nil, let seen = pendingNameEnd {
            for i in max(0, seen - 5)..<min(latestWords.count, seen + 3) {
                if let e = nameEnd(in: latestWords, from: i) { matched = e; break }
            }
        }
        pendingNameEnd = nil
        if let end = matched {
            let cmd = latestWords.dropFirst(end).joined(separator: " ")
            fired = cmd.isEmpty ? "(greeting)" : cmd
        } else {
            baseline = latestWords
        }
    }
}

func run(_ label: String, _ events: [(Double, String)], expect: String?) {
    let s = Sim()
    var t = 0.0
    for (at, text) in events {
        while t < at { t += 0.15; s.tick(at: t) }
        s.partial(text, at: at)
    }
    while t < (events.last!.0 + 3) && s.fired == nil { t += 0.15; s.tick(at: t) }
    let ok = s.fired == expect
    print("\(ok ? "PASS" : "FAIL") \(label): fired=\(s.fired ?? "nil") expected=\(expect ?? "nil")")
}

// name alone -> greeting
run("bare name", [(1.0, "Neon")], expect: "(greeting)")
// name + command in growing partials
run("name+command", [(1.0, "Neon"), (1.3, "Neon what"), (1.6, "Neon what year"), (1.9, "Neon what year is it")],
    expect: "what year is it")
// hey neon still works
run("hey neon", [(1.0, "Hey"), (1.2, "Hey Neon"), (1.5, "Hey Neon set a timer")], expect: "set a timer")
// fused token
run("fused henon", [(1.0, "Henon")], expect: "(greeting)")
// mid-sentence mention must NOT fire
run("mid-sentence", [(1.0, "I"), (1.2, "I love"), (1.4, "I love neon"), (1.6, "I love neon lights")], expect: nil)
// mention later, then real wake after silence in the same recognition session
run("wake after chatter",
    [(1.0, "we should buy a lamp"), (3.0, "we should buy a lamp neon"), (3.3, "we should buy a lamp neon hello there")],
    expect: "hello there")
// second utterance is unrelated -> no fire
run("chatter then chatter", [(1.0, "pass the salt"), (3.0, "pass the salt thank you")], expect: nil)
// slow deliberate "hey ... neon" across a gap
run("hey pause neon", [(1.0, "Hey"), (2.2, "Hey Neon")], expect: "(greeting)")
// THE KITCHEN BUG: recognizer REVISES junk into the wake sentence instead of appending
run("revision replaces junk",
    [(1.0, "no"), (4.0, "Neon"), (4.3, "Neon what's up")], expect: "what's up")
// revision that rewrites mid-utterance after the name was spotted
run("late revision", [(1.0, "Neon set a"), (1.3, "Neon set a timer"), (1.6, "Neon set a timer for ten minutes")],
    expect: "set a timer for ten minutes")
// apostrophes survive tokenizing
run("apostrophe", [(1.0, "Neon what's the weather")], expect: "what's the weather")
// "Nia" nickname wakes too
run("nia nickname", [(1.0, "Nia what time is it")], expect: "what time is it")
// "hey neon" mid-utterance is a deliberate summons — wakes anywhere
run("hey neon mid-utterance",
    [(1.0, "so anyway"), (1.3, "so anyway hey neon"), (1.6, "so anyway hey neon what's cooking")],
    expect: "what's cooking")
// but a bare mid-utterance name still does NOT wake
run("bare name mid-utterance stays quiet",
    [(1.0, "I"), (1.2, "I think neon"), (1.4, "I think neon signs are cool")], expect: nil)
// LONG QUESTION: recognizer revises words BEFORE the name mid-capture,
// shifting the common-prefix boundary — the stored name position recovers it
run("baseline revised during long question",
    [(1.0, "lets see"), (3.0, "lets see neon what is"), (3.4, "lets see neon what is the largest"),
     (3.8, "let us see neon what is the largest planet")],
    expect: "what is the largest planet")
