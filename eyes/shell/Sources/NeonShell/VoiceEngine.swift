import Foundation

// Provider abstraction for realtime speech-to-speech engines. VoiceSession
// owns the transport and audio; an engine translates between the provider's
// wire protocol and these events. Wire schemas are validated by the probes
// in voice/ (gemini-live-audio-test.mjs, openai-realtime-test.mjs).

struct VoiceUsage {
    var audioIn = 0, audioOut = 0, textIn = 0, textOut = 0, cachedIn = 0
    mutating func add(_ o: VoiceUsage) {
        audioIn += o.audioIn; audioOut += o.audioOut
        textIn += o.textIn; textOut += o.textOut; cachedIn += o.cachedIn
    }
}

enum VoiceEvent {
    case ready
    case audio(Data)
    case inputText(String)
    case outputText(String)
    case interrupted
    case usage(VoiceUsage, cumulative: Bool)  // cumulative: replaces prior totals
    case toolCall(String)                     // function name
}

// Tools offered to every engine. go_to_sleep lets the model end the session
// itself; the shell closes the socket, so no tool response is ever sent.
let sleepToolName = "go_to_sleep"
let sleepToolDescription = """
    End the conversation and go back to sleep. Call this when the user says \
    goodbye, the conversation is clearly over, or you realize you were woken \
    by accident and the speech around you is not directed at you.
    """

protocol VoiceEngine {
    var name: String { get }
    var model: String { get }
    var sendSampleRate: Double { get }
    var keyName: String { get }
    func url(key: String) -> URL
    func headers(key: String) -> [String: String]
    /// Sent immediately after the socket opens.
    func openMessages(system: String) -> [[String: Any]]
    /// Sent when the engine reports `.ready`.
    func readyMessages(greeting: String) -> [[String: Any]]
    func audioMessage(_ base64: String) -> [String: Any]
    func parse(_ msg: [String: Any]) -> [VoiceEvent]
    /// Estimated cost in dollars for the given usage / elapsed session time.
    func cost(_ u: VoiceUsage, elapsed: TimeInterval) -> Double
}

// MARK: - Gemini Live

struct GeminiEngine: VoiceEngine {
    let name = "gemini"
    let model = "gemini-3.1-flash-live-preview"
    let sendSampleRate = 16000.0
    let keyName = "GEMINI_API_KEY"

    func url(key: String) -> URL {
        URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(key)")!
    }
    func headers(key: String) -> [String: String] { [:] }

    func openMessages(system: String) -> [[String: Any]] {
        [[
            "setup": [
                "model": "models/\(model)",
                "generationConfig": ["responseModalities": ["AUDIO"]],
                "systemInstruction": ["parts": [["text": system]]],
                "outputAudioTranscription": [String: String](),
                "inputAudioTranscription": [String: String](),
                "tools": [[
                    "functionDeclarations": [[
                        "name": sleepToolName,
                        "description": sleepToolDescription,
                    ]],
                ]],
            ],
        ]]
    }

    func readyMessages(greeting: String) -> [[String: Any]] {
        [[
            "clientContent": [
                "turns": [["role": "user", "parts": [["text": greeting]]]],
                "turnComplete": true,
            ],
        ]]
    }

    func audioMessage(_ base64: String) -> [String: Any] {
        ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": base64]]]
    }

    func parse(_ msg: [String: Any]) -> [VoiceEvent] {
        var events: [VoiceEvent] = []
        if msg["setupComplete"] != nil { events.append(.ready) }
        if let tc = msg["toolCall"] as? [String: Any],
           let calls = tc["functionCalls"] as? [[String: Any]] {
            for call in calls {
                if let name = call["name"] as? String { events.append(.toolCall(name)) }
            }
        }
        if let meta = msg["usageMetadata"] as? [String: Any] {
            var u = VoiceUsage()
            for (details, isInput) in [(meta["promptTokensDetails"], true), (meta["responseTokensDetails"], false)] {
                for d in details as? [[String: Any]] ?? [] {
                    let count = d["tokenCount"] as? Int ?? 0
                    let modality = d["modality"] as? String ?? ""
                    if modality == "AUDIO" { if isInput { u.audioIn += count } else { u.audioOut += count } }
                    else { if isInput { u.textIn += count } else { u.textOut += count } }
                }
            }
            events.append(.usage(u, cumulative: true))
        }
        if let sc = msg["serverContent"] as? [String: Any] {
            if sc["interrupted"] != nil { events.append(.interrupted) }
            if let turn = sc["modelTurn"] as? [String: Any],
               let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any],
                       let b64 = inline["data"] as? String,
                       let data = Data(base64Encoded: b64) {
                        events.append(.audio(data))
                    }
                }
            }
            if let tx = sc["inputTranscription"] as? [String: Any], let t = tx["text"] as? String {
                events.append(.inputText(t))
            }
            if let tx = sc["outputTranscription"] as? [String: Any], let t = tx["text"] as? String {
                events.append(.outputText(t))
            }
        }
        return events
    }

    func cost(_ u: VoiceUsage, elapsed: TimeInterval) -> Double {
        // gemini-3.1-flash-live-preview: audio $3/$12, text $0.75/$4.50 per 1M
        (Double(u.audioIn) * 3.00 + Double(u.audioOut) * 12.00
            + Double(u.textIn) * 0.75 + Double(u.textOut) * 4.50) / 1_000_000
    }
}

// MARK: - OpenAI Realtime

struct OpenAIEngine: VoiceEngine {
    let name = "openai"
    let model = "gpt-realtime-2.1"
    let sendSampleRate = 24000.0
    let keyName = "OPENAI_API_KEY"

    func url(key: String) -> URL {
        URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!
    }
    func headers(key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)"]
    }

    func openMessages(system: String) -> [[String: Any]] {
        [[
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": system,
                "tools": [[
                    "type": "function",
                    "name": sleepToolName,
                    "description": sleepToolDescription,
                ]],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "turn_detection": ["type": "server_vad"],
                        "transcription": ["model": "whisper-1"],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "voice": "marin",
                    ],
                ],
            ],
        ]]
    }

    func readyMessages(greeting: String) -> [[String: Any]] {
        [
            [
                "type": "conversation.item.create",
                "item": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": greeting]],
                ],
            ],
            ["type": "response.create"],
        ]
    }

    func audioMessage(_ base64: String) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": base64]
    }

    func parse(_ msg: [String: Any]) -> [VoiceEvent] {
        switch msg["type"] as? String ?? "" {
        case "session.created":
            return [.ready]
        case "response.output_audio.delta":
            if let b64 = msg["delta"] as? String, let data = Data(base64Encoded: b64) {
                return [.audio(data)]
            }
        case "response.output_audio_transcript.delta":
            if let t = msg["delta"] as? String { return [.outputText(t)] }
        case "conversation.item.input_audio_transcription.completed":
            // (.delta also fires; using only .completed avoids duplicates)
            if let t = msg["transcript"] as? String { return [.inputText(t)] }
        case "input_audio_buffer.speech_started":
            return [.interrupted]
        case "response.output_item.done":
            if let item = msg["item"] as? [String: Any],
               item["type"] as? String == "function_call",
               let name = item["name"] as? String {
                return [.toolCall(name)]
            }
        case "response.done":
            if let resp = msg["response"] as? [String: Any],
               let usage = resp["usage"] as? [String: Any] {
                var u = VoiceUsage()
                if let inD = usage["input_token_details"] as? [String: Any] {
                    u.audioIn = inD["audio_tokens"] as? Int ?? 0
                    u.textIn = inD["text_tokens"] as? Int ?? 0
                    u.cachedIn = inD["cached_tokens"] as? Int ?? 0
                }
                if let outD = usage["output_token_details"] as? [String: Any] {
                    u.audioOut = outD["audio_tokens"] as? Int ?? 0
                    u.textOut = outD["text_tokens"] as? Int ?? 0
                }
                return [.usage(u, cumulative: false)]
            }
        case "error":
            NSLog("Neon voice: openai error: \(msg)")
        default:
            break
        }
        return []
    }

    func cost(_ u: VoiceUsage, elapsed: TimeInterval) -> Double {
        // Cached input is billed at $0.40/1M; audio rates dominate. Text at
        // the realtime text rates ($4/$16) as an estimate.
        let uncachedIn = max(0, u.audioIn - u.cachedIn)
        return (Double(uncachedIn) * 32.00 + Double(u.cachedIn) * 0.40
            + Double(u.audioOut) * 64.00
            + Double(u.textIn) * 4.00 + Double(u.textOut) * 16.00) / 1_000_000
    }
}

func makeEngine(_ name: String) -> VoiceEngine {
    switch name {
    case "openai": return OpenAIEngine()
    default: return GeminiEngine()
    }
}
