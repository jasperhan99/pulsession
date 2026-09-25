import Foundation

/// Where a session lives: which app or CLI started it, and so where it is read
/// from and how it is opened again.
enum SessionSource: String, CaseIterable, Codable, Sendable, Identifiable {
    /// PI-Desktop's own conversations, read from its database.
    case piDesktop
    /// Claude Code CLI transcripts under `~/.claude/projects`.
    case claudeCode
    /// Codex CLI rollouts under `~/.codex/sessions`.
    case codex

    var id: String { rawValue }

    /// Brand names, left as they are in every language.
    var displayName: String {
        switch self {
        case .piDesktop: "PI-Desktop"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The Pulse provider whose transcripts this source reads, where there is
    /// one. PI-Desktop is not a usage provider; it has no ring of its own.
    var provider: Provider? {
        switch self {
        case .piDesktop: nil
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }
}

/// What a session is doing, ordered by how much it wants a person.
///
/// **Only what was witnessed.** PI-Desktop records running and finished turns
/// in its database and approval requests in its permission log; the CLIs say
/// whether a turn is in flight (see `AgentActivity`). Nothing here is guessed
/// from a timer alone, except the dead-session grace `AgentActivity` already
/// applies — and a turn PI-Desktop still marks running after PI-Desktop itself
/// has gone is shown as interrupted, which is what PI-Desktop will record the
/// next time it starts.
enum SessionState: String, CaseIterable, Sendable {
    /// A tool call is waiting for someone to allow or deny it.
    case approval
    /// A turn is in flight.
    case running
    /// The agent asked a question and is waiting for an answer.
    case waitingInput
    /// The last turn ended in an error.
    case failed
    /// The last turn was stopped before it finished.
    case interrupted
    /// The last turn finished, recently.
    case done
    /// Nothing recent to report.
    case idle

    /// Whether the session is doing something, or waiting on a person, right
    /// now. These are the states that keep the rail open and count on it.
    var isActive: Bool {
        switch self {
        case .approval, .running, .waitingInput: true
        case .failed, .interrupted, .done, .idle: false
        }
    }

    /// Whether a person is being waited on, as opposed to the agent working.
    var needsAttention: Bool {
        self == .approval || self == .waitingInput
    }

    /// Sort order: whatever needs a person first, then work in flight, then
    /// outcomes, then the quiet.
    var urgency: Int {
        switch self {
        case .approval: 0
        case .waitingInput: 1
        case .running: 2
        case .failed: 3
        case .interrupted: 4
        case .done: 5
        case .idle: 6
        }
    }

    var label: String {
        switch self {
        case .approval: .localized("Waiting for approval")
        case .running: .localized("Running")
        case .waitingInput: .localized("Waiting for input")
        case .failed: .localized("Failed")
        case .interrupted: .localized("Interrupted")
        case .done: .localized("Finished")
        case .idle: .localized("Idle")
        }
    }

    /// How long a finished turn is still worth calling out. After this a
    /// session is simply idle — the outcome is old news, and a rail full of
    /// green ticks from this morning says nothing about now.
    static let outcomeWindow: TimeInterval = 30 * 60
}

/// One conversation, from whichever app or CLI holds it.
struct AgentSession: Identifiable, Sendable, Equatable {
    /// Unique across sources: the source's name and the session's own id.
    var id: String { "\(source.rawValue):\(nativeID)" }
    let source: SessionSource
    /// The id the source itself uses, which is what opening or resuming the
    /// session needs.
    let nativeID: String
    var title: String
    /// The project's short name — a folder name, or PI-Desktop's own project
    /// name. Nil for a session with no project; none is invented.
    var project: String?
    var projectPath: String?
    var state: SessionState
    /// When the turn in flight started, for an active session.
    var startedAt: Date?
    /// When anything last happened in the session.
    var updatedAt: Date
    /// When the last turn ended, if it has.
    var endedAt: Date?
    /// Opens the session in the desktop app that holds it — the Claude or
    /// Codex app — when there is one. See `DesktopAppLinks`.
    var appLink: URL?

    /// Most urgent first, then most recent.
    static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted {
            if $0.state.urgency != $1.state.urgency { return $0.state.urgency < $1.state.urgency }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// A shell line that picks the conversation up again, for the CLIs that
    /// have one. PI-Desktop sessions are opened in PI-Desktop instead.
    var resumeCommand: String? {
        let resume: String
        switch source {
        case .piDesktop: return nil
        case .claudeCode: resume = "claude --resume \(nativeID)"
        case .codex: resume = "codex resume \(nativeID)"
        }
        guard let projectPath, !projectPath.isEmpty else { return resume }
        return "cd \(Self.shellQuoted(projectPath)) && \(resume)"
    }

    /// Single-quoted for a POSIX shell, with any single quote inside closed,
    /// escaped and reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The last path component, for a project that is only known by its path.
    /// Both separators, because a path recorded on Windows can still end up in
    /// a transcript synced to this Mac.
    static func folderName(of path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last else { return nil }
        let name = String(last)
        return name.isEmpty || name == "." ? nil : name
    }
}
