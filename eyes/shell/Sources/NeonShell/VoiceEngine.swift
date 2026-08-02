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
}

// Tools offered to the engines. go_to_sleep lets the model end the session
// itself (the shell closes the socket; no response sent). capture_image
// fetches one camera frame on demand — far cheaper than streaming.
let sleepToolName = "go_to_sleep"
let sleepToolDescription = """
    End the conversation and go back to sleep. Call this when the user says \
    goodbye, the conversation is clearly over, or you realize you were woken \
    by accident and the speech around you is not directed at you.
    """
let captureToolName = "capture_image"
let captureToolDescription = """
    Capture a fresh snapshot from your camera so you can see the kitchen \
    right now. Call this whenever looking would help — what someone is \
    holding, what's cooking, who's there.
    """
let emoteToolName = "emote"
let emoteEmotions = ["happy", "laugh", "surprised", "wink", "sad",
                     "confused", "eyeroll", "excited", "love"]
let emoteToolDescription = """
    Show a feeling with your eyes — they animate the emotion on screen. \
    Use this often, whenever it fits what you're saying or reacting to.
    """
// The kitchen timer: one at a time, and it rings on its own rather than
// through Neon. She sets it, reports on it, and can silence it — but she is
// not in the loop when it goes off.
let timerToolName = "set_timer"
let timerToolDescription = """
    Set the kitchen timer. There is only one, so this replaces any timer \
    already running. It rings by itself on screen when it's up — you are not \
    involved and shouldn't promise to tell them; just confirm it briefly \
    ("five minutes, going"). Label it for whatever it's for.
    """
let timerCheckToolName = "check_timer"
let timerCheckToolDescription = """
    How much time is left on the kitchen timer, or whether it's ringing now.
    """
let timerStopToolName = "stop_timer"
let timerStopToolDescription = """
    Stop the kitchen timer — silences it if it's ringing, cancels it if it's \
    still counting down. Call this whenever someone says to stop, cancel, or \
    turn it off while it's going, even if they don't use the word "timer".
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
    /// Wire message for one JPEG camera frame; nil if the engine takes no video.
    func videoMessage(_ base64: String) -> [String: Any]?
    /// Reply to a tool call; nil if the engine doesn't take tool responses.
    func toolResponseMessage(id: String?, name: String, result: String) -> [String: Any]?
}

extension VoiceEngine {
    func videoMessage(_ base64: String) -> [String: Any]? { nil }
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
    /// LOW keeps spoken replies snappy — HIGH added a multi-second pause to
    /// every turn; search grounding works at any level.
    var thinkingLevel: String? = "LOW"
    let voice = "Leda"
    let audioInRate = 3.00, audioOutRate = 12.00
    let sendSampleRate = 16000.0
    let keyName = "GEMINI_API_KEY"

    func url(key: String) -> URL {
        URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(key)")!
    }
    func headers(key: String) -> [String: String] { [:] }

    func openMessages(system: String) -> [[String: Any]] {
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
                    ["functionDeclarations": [
                        ["name": sleepToolName, "description": sleepToolDescription],
                        ["name": captureToolName, "description": captureToolDescription],
                        ["name": emoteToolName, "description": emoteToolDescription,
                         "parameters": [
                            "type": "OBJECT",
                            "properties": ["emotion": ["type": "STRING", "enum": emoteEmotions]],
                            "required": ["emotion"],
                         ]],
                        ["name": timerToolName, "description": timerToolDescription,
                         "parameters": [
                            "type": "OBJECT",
                            "properties": [
                                "label": ["type": "STRING",
                                          "description": "1-3 words, shown on screen — \"pasta\", \"tea\""],
                                "seconds": ["type": "NUMBER",
                                            "description": "How long from now, in seconds"],
                            ],
                            "required": ["label", "seconds"],
                         ]],
                        ["name": timerCheckToolName, "description": timerCheckToolDescription],
                        ["name": timerStopToolName, "description": timerStopToolDescription],
                    ]],
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
