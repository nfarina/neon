import Foundation

// Features you can turn on and off. Neon's core — the eyes, the voice, waking,
// remembering, seeing — is not a plugin and never asks permission to exist. A
// plugin is a capability somebody might reasonably not want: a calendar she can
// read, a timer, a way to hand work to Claude Code.
//
// The unit of a plugin is *what reaches the model*: a set of tool declarations,
// a paragraph of system prompt explaining when to use them, and optionally a
// macOS permission that has to be granted before any of it works. Turning a
// plugin off doesn't disable a code path — it removes the tools from the
// session setup entirely, so the model never learns the capability exists. That
// is the only kind of "off" a language model respects.
//
// State lives in ~/.config/neon/plugins.json, outside the repo, so a fresh
// clone starts at the defaults rather than inheriting this house's choices.

// MARK: - Tool declarations

/// One parameter of a tool. Deliberately flat and small: every tool Neon has
/// ever needed takes a handful of strings and numbers, and a general JSON
/// Schema encoder would be more machinery than the problem deserves. If a tool
/// ever needs nesting, this is the place to grow — not the call sites.
struct ToolParam {
    enum Kind: String { case string, number, boolean }

    let name: String
    let kind: Kind
    let description: String?
    /// Allowed values, for closed sets like the emote list.
    let options: [String]?
    let required: Bool

    init(_ name: String, _ kind: Kind, _ description: String? = nil,
         options: [String]? = nil, required: Bool = true) {
        self.name = name
        self.kind = kind
        self.description = description
        self.options = options
        self.required = required
    }
}

/// A tool as the plugin describes it, before any provider's wire format gets
/// involved. Engines translate; plugins never see Gemini's uppercase types or
/// OpenAI's wrapper object.
struct ToolSpec {
    let name: String
    let description: String
    var params: [ToolParam] = []

    /// Gemini's `functionDeclarations` entry (OBJECT/STRING/NUMBER, uppercase).
    var geminiDeclaration: [String: Any] {
        var decl: [String: Any] = ["name": name, "description": description]
        guard !params.isEmpty else { return decl }
        var properties: [String: Any] = [:]
        for p in params {
            var prop: [String: Any] = ["type": p.kind.rawValue.uppercased()]
            if let d = p.description { prop["description"] = d }
            if let o = p.options { prop["enum"] = o }
            properties[p.name] = prop
        }
        decl["parameters"] = [
            "type": "OBJECT",
            "properties": properties,
            "required": params.filter(\.required).map(\.name),
        ]
        return decl
    }

    /// OpenAI Realtime's `tools` entry (lowercase JSON Schema types).
    var openAIDeclaration: [String: Any] {
        var decl: [String: Any] = [
            "type": "function", "name": name, "description": description,
        ]
        guard !params.isEmpty else { return decl }
        var properties: [String: Any] = [:]
        for p in params {
            var prop: [String: Any] = ["type": p.kind.rawValue]
            if let d = p.description { prop["description"] = d }
            if let o = p.options { prop["enum"] = o }
            properties[p.name] = prop
        }
        decl["parameters"] = [
            "type": "object",
            "properties": properties,
            "required": params.filter(\.required).map(\.name),
        ]
        return decl
    }
}

// MARK: - Permissions

/// A macOS privacy grant a plugin depends on. TCC attaches the grant to the
/// signed app, not to the moment of asking, so this only ever has three
/// answers and the interesting one is `.notDetermined` — the only state where
/// asking raises a dialog rather than silently failing.
enum PluginPermission: String {
    case calendar

    enum Status: String { case granted, denied, notDetermined }

    var status: Status {
        switch self {
        case .calendar: return CalendarBridge.permissionStatus
        }
    }

    /// Human-readable, for the settings panel when the answer was no. macOS
    /// will not re-prompt after a denial, so the only honest thing to say is
    /// where the switch lives.
    var settingsHint: String {
        switch self {
        case .calendar:
            return "Turned down. Grant Neon under System Settings › Privacy & Security › Calendars."
        }
    }

    /// Raise the system dialog. The completion fires on the main queue.
    /// Callers are responsible for yielding the screen first — a TCC prompt
    /// behind the kiosk window is a prompt nobody can answer.
    func request(_ done: @escaping (Bool) -> Void) {
        switch self {
        case .calendar: CalendarBridge.requestAccess(done)
        }
    }
}

// MARK: - The plugin itself

/// What a tool call gets besides its arguments.
struct PluginContext {
    /// Who Neon thinks is talking ("sounds like Nick"), when there is a guess.
    let requester: String?
    /// Write a line into the on-screen event log.
    let trace: (String, String) -> Void
}

/// Handlers reply through a callback rather than returning, so a plugin that
/// needs to go away and do something (a network call, a permission round trip)
/// doesn't have to block the session's message loop to do it.
typealias PluginReply = (String) -> Void

protocol NeonPlugin: AnyObject {
    /// Stable key for plugins.json. Renaming one silently resets it to the
    /// default, so don't.
    var id: String { get }
    /// Title in the settings panel.
    var title: String { get }
    /// One line under the title. Written for the person deciding whether to
    /// turn it on, not for the model.
    var blurb: String { get }
    /// Whether a fresh install has it on.
    var defaultEnabled: Bool { get }
    /// The grant this needs before its tools do anything useful.
    var permission: PluginPermission? { get }
    /// Tools offered to the model while enabled.
    var tools: [ToolSpec] { get }
    /// Appended to the system prompt while enabled. Nil for plugins whose
    /// tool descriptions say everything worth saying.
    var promptFragment: String? { get }

    func handle(tool: String, args: [String: Any], context: PluginContext,
                reply: @escaping PluginReply)
}

extension NeonPlugin {
    var permission: PluginPermission? { nil }
    var promptFragment: String? { nil }
    var defaultEnabled: Bool { false }

    /// True when the plugin has everything it needs to actually work. An
    /// enabled plugin whose permission was denied is still listed and still
    /// switched on — the settings panel says why it isn't doing anything —
    /// but its tools stay out of the session, because a tool that can only
    /// fail is worse than an absent one.
    var isUsable: Bool {
        guard let permission else { return true }
        return permission.status == .granted
    }
}

// MARK: - Registry

final class PluginRegistry {
    static let shared = PluginRegistry()

    /// Registration order is display order in settings.
    let all: [NeonPlugin] = [
        TimerPlugin.shared,
        CalendarPlugin.shared,
        TasksPlugin.shared,
    ]

    private var enabled: [String: Bool] = [:]
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/plugins.json")

    /// Fires whenever a plugin is switched on or off, so the shell can refresh
    /// the settings panel and anything else watching.
    var onChanged: () -> Void = { }

    private init() {
        if let data = try? Data(contentsOf: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool] {
            enabled = obj
        }
    }

    func plugin(id: String) -> NeonPlugin? {
        all.first { $0.id == id }
    }

    func isEnabled(_ id: String) -> Bool {
        enabled[id] ?? plugin(id: id)?.defaultEnabled ?? false
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard plugin(id: id) != nil else { return }
        enabled[id] = on
        save()
        onChanged()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: enabled,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path)
        }
    }

    /// Plugins that are switched on *and* able to work — what a new session
    /// actually gets.
    var active: [NeonPlugin] {
        all.filter { isEnabled($0.id) && $0.isUsable }
    }

    var activeTools: [ToolSpec] {
        active.flatMap(\.tools)
    }

    var activePromptFragments: [String] {
        active.compactMap(\.promptFragment)
    }

    /// Which plugin owns a tool name, among the active ones. An enabled-but-
    /// unusable plugin deliberately doesn't match: its tools were never
    /// declared, so a call bearing one is a model hallucination, not a
    /// dispatch.
    func owner(ofTool name: String) -> NeonPlugin? {
        active.first { $0.tools.contains { $0.name == name } }
    }
}
