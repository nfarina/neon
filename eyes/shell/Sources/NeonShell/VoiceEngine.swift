import Foundation

// Provider abstraction for realtime speech-to-speech engines. VoiceSession
// owns the transport and audio; an engine translates between the provider's
// wire protocol and these events. Wire schemas are validated by the probes
// in voice/ (gemini-live-audio-test.mjs, openai-realtime-test.mjs).

struct VoiceUsage {
    var audioIn = 0, audioOut = 0, textIn = 0, textOut = 0, cachedIn = 0, imageIn = 0
    mutating func add(_ o: VoiceUsage) {
        audioIn += o.audioIn; audioOut += o.audioOut
        textIn += o.textIn; textOut += o.textOut
        cachedIn += o.cachedIn; imageIn += o.imageIn
    }
}

enum VoiceEvent {
    case ready
    case audio(Data)
    case inputText(String)
    case outputText(String)
    case interrupted
    case usage(VoiceUsage, cumulative: Bool)  // cumulative: replaces prior totals
    case toolCall(name: String, id: String?, args: [String: Any])
    case thinking                             // a thought part arrived; model is reasoning

    /// Is this the server *working on a reply*, as opposed to bookkeeping?
    ///
    /// The idle timer uses this to tell "she's mid-thought, wait" apart from
    /// "the socket is merely alive". Gemini sends a sessionResumptionUpdate
    /// about twice a second for as long as we stream mic audio, so treating
    /// every inbound frame as activity means the server is never quiet
    /// (measured: 86 messages, longest gap 1.02s — voice/gemini-idle-chatter-test.mjs).
    var isServerWorking: Bool {
        switch self {
        case .audio, .inputText, .outputText, .thinking, .toolCall, .interrupted: true
        case .ready, .usage: false
        }
    }
}

// Core tools — Neon herself, not features. Ending the conversation, looking
// through the camera, showing a feeling, and remembering are the things that
// make her her; none of them is switchable, and none belongs to a plugin.
// Everything else the model can call comes from PluginRegistry (Plugins.swift).
//
// go_to_sleep lets the model end the session itself (the shell closes the
// socket; no response sent). capture_image fetches one camera frame on demand
// — far cheaper than streaming.
let sleepToolName = "go_to_sleep"
let captureToolName = "capture_image"
let emoteToolName = "emote"
let rememberToolName = "remember"
let recallToolName = "recall"

let emoteEmotions = ["happy", "laugh", "surprised", "wink", "sad",
                     "confused", "eyeroll", "excited", "love"]

let coreTools: [ToolSpec] = [
    ToolSpec(
        name: sleepToolName,
        description: """
            End the conversation and go back to sleep. Call this when the user says \
            goodbye, the conversation is clearly over, or you realize you were woken \
            by accident and the speech around you is not directed at you.
            """),
    ToolSpec(
        name: captureToolName,
        description: """
            Capture a fresh snapshot from your camera so you can see the kitchen \
            right now. Call this whenever looking would help — what someone is \
            holding, what's cooking, who's there.
            """),
    ToolSpec(
        name: emoteToolName,
        description: """
            Show a feeling with your eyes — they animate the emotion on screen. \
            Use this often, whenever it fits what you're saying or reacting to.
            """,
        params: [ToolParam("emotion", .string, options: emoteEmotions)]),
    // Memory. Deliberately two tools rather than one magic one: what she
    // chooses to write down is a judgment call, and making it explicit means
    // the store stays small enough to stay useful.
    ToolSpec(
        name: rememberToolName,
        description: """
            Save something worth knowing later — a preference, a plan, a fact about \
            someone, how they like something done. Write it as a short standalone \
            sentence that will still make sense in a month ("Alex's tennis lesson \
            moved to Thursdays", not "it moved"). Don't save passing chatter, \
            anything you were told to forget, or things you can look up. You don't \
            need permission and shouldn't announce it — just remember and carry on.
            """,
        params: [ToolParam("fact", .string,
                           "One standalone sentence, understandable with no other context")]),
    ToolSpec(
        name: recallToolName,
        description: """
            Look through what you remember. Use it when someone refers to something \
            from before, asks what you know about a person or plan, or when an \
            answer would be better if you checked first. Query with the words you'd \
            expect the memory to contain.
            """,
        params: [ToolParam("query", .string,
                           "Words you'd expect in the memory — a name, a topic")]),
]

protocol VoiceEngine {
    var name: String { get }
    var model: String { get }
    var sendSampleRate: Double { get }
    var keyName: String { get }
    func url(key: String) -> URL
    func headers(key: String) -> [String: String]
    /// Sent immediately after the socket opens. `tools` is the whole surface
    /// for this session — core plus whatever plugins are switched on — so a
    /// disabled feature isn't merely refused, it is never mentioned.
    func openMessages(system: String, tools: [ToolSpec]) -> [[String: Any]]
    /// Sent when the engine reports `.ready`.
    func readyMessages(greeting: String) -> [[String: Any]]
    func audioMessage(_ base64: String) -> [String: Any]
    func parse(_ msg: [String: Any]) -> [VoiceEvent]
    /// Estimated cost in dollars for the given usage / elapsed session time.
    func cost(_ u: VoiceUsage, elapsed: TimeInterval) -> Double
    /// Wire message for one JPEG camera frame; nil if the engine takes no video.
    func videoMessage(_ base64: String) -> [String: Any]?
    /// A JPEG delivered as its own completed user turn, which is the only
    /// ordering that gets the image into context *before* the model answers
    /// (see voice/gemini-image-order-test.mjs). nil if unsupported.
    func imageTurnMessage(_ base64: String, text: String) -> [String: Any]?
    /// Reply to a tool call; nil if the engine doesn't take tool responses.
    func toolResponseMessage(id: String?, name: String, result: String) -> [String: Any]?
}

extension VoiceEngine {
    func videoMessage(_ base64: String) -> [String: Any]? { nil }
    func imageTurnMessage(_ base64: String, text: String) -> [String: Any]? { nil }
    func toolResponseMessage(id: String?, name: String, result: String) -> [String: Any]? { nil }
}

// MARK: - Gemini Live

struct GeminiEngine: VoiceEngine {
    var name = "gemini"
    var model = "gemini-3.1-flash-live-preview"
    // Pricing per 1M tokens; both native-audio models share audio rates.
    var textInRate = 0.75, textOutRate = 4.50
    /// Thinking level for Gemini 3.x; nil for 2.5, which uses a different
    /// (budget-based) schema. Validated by voice/gemini-config-test.mjs.
    /// HIGH added a multi-second pause to every turn and was backed out to
    /// LOW; MEDIUM is the middle setting Nick chose once the conversation had
    /// more to reason about (memory, tools). Search grounding works at any
    /// level. If first-turn latency creeps back up, this is the first dial.
    var thinkingLevel: String? = "MEDIUM"
    let voice = "Leda"
    let audioInRate = 3.00, audioOutRate = 12.00
    let sendSampleRate = 16000.0
    let keyName = "GEMINI_API_KEY"

    func url(key: String) -> URL {
        URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(key)")!
    }
    func headers(key: String) -> [String: String] { [:] }

    func openMessages(system: String, tools: [ToolSpec]) -> [[String: Any]] {
        var generationConfig: [String: Any] = [
            "responseModalities": ["AUDIO"],
            "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
        ]
        if let thinkingLevel {
            // includeThoughts streams thought-summary parts, which drive the
            // eyes' "thinking" indicator (validated by gemini-thinking-test.mjs).
            generationConfig["thinkingConfig"] =
                ["thinkingLevel": thinkingLevel, "includeThoughts": true]
        }
        return [[
            "setup": [
                "model": "models/\(model)",
                "generationConfig": generationConfig,
                "systemInstruction": ["parts": [["text": system]]],
                "outputAudioTranscription": [String: String](),
                "inputAudioTranscription": [String: String](),
                "tools": [
                    ["googleSearch": [String: String]()],
                    ["functionDeclarations": tools.map(\.geminiDeclaration)],
                ],
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

    func imageTurnMessage(_ base64: String, text: String) -> [String: Any]? {
        ["clientContent": [
            "turns": [["role": "user", "parts": [
                ["inlineData": ["mimeType": "image/jpeg", "data": base64]],
                ["text": text],
            ]]],
            "turnComplete": true,
        ]]
    }

    func audioMessage(_ base64: String) -> [String: Any] {
        ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": base64]]]
    }

    func videoMessage(_ base64: String) -> [String: Any]? {
        ["realtimeInput": ["video": ["mimeType": "image/jpeg", "data": base64]]]
    }

    func toolResponseMessage(id: String?, name: String, result: String) -> [String: Any]? {
        var response: [String: Any] = ["name": name, "response": ["result": result]]
        if let id { response["id"] = id }
        return ["toolResponse": ["functionResponses": [response]]]
    }

    func parse(_ msg: [String: Any]) -> [VoiceEvent] {
        var events: [VoiceEvent] = []
        if msg["setupComplete"] != nil { events.append(.ready) }
        if let tc = msg["toolCall"] as? [String: Any],
           let calls = tc["functionCalls"] as? [[String: Any]] {
            for call in calls {
                if let name = call["name"] as? String {
                    events.append(.toolCall(name: name, id: call["id"] as? String,
                                            args: call["args"] as? [String: Any] ?? [:]))
                }
            }
        }
        if let meta = msg["usageMetadata"] as? [String: Any] {
            var u = VoiceUsage()
            for (details, isInput) in [(meta["promptTokensDetails"], true), (meta["responseTokensDetails"], false)] {
                for d in details as? [[String: Any]] ?? [] {
                    let count = d["tokenCount"] as? Int ?? 0
                    let modality = d["modality"] as? String ?? ""
                    if modality == "AUDIO" { if isInput { u.audioIn += count } else { u.audioOut += count } }
                    else if modality == "IMAGE" || modality == "VIDEO" { u.imageIn += count }
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
                    if part["thought"] as? Bool == true {
                        events.append(.thinking)
                    } else if let inline = part["inlineData"] as? [String: Any],
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
        // Live API prices image/video input at the audio rate.
        (Double(u.audioIn + u.imageIn) * audioInRate + Double(u.audioOut) * audioOutRate
            + Double(u.textIn) * textInRate + Double(u.textOut) * textOutRate) / 1_000_000
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

    func openMessages(system: String, tools: [ToolSpec]) -> [[String: Any]] {
        [[
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": system,
                "tools": tools.map(\.openAIDeclaration),
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
                let args = (item["arguments"] as? String)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                return [.toolCall(name: name, id: item["call_id"] as? String, args: args ?? [:])]
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

/// Engine names in E-key cycle order.
let engineNames = ["gemini", "gemini25", "openai"]

func makeEngine(_ name: String) -> VoiceEngine {
    switch name {
    case "openai": return OpenAIEngine()
    case "gemini25":
        // GA native-audio model — same audio rates as 3.1, cheaper text.
        // A/B candidate for less tool-call verbalization than the preview.
        return GeminiEngine(name: "gemini25", model: "gemini-2.5-flash-native-audio-latest",
                            textInRate: 0.50, textOutRate: 2.00, thinkingLevel: nil)
    default: return GeminiEngine()
    }
}
