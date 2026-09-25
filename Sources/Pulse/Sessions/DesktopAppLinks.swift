import AppKit
import Foundation

/// Links that open a Claude Code or Codex session in the desktop app that
/// holds it, rather than a resume command for a terminal.
///
/// Most of these sessions are not terminal sessions at all. Claude Code runs
/// inside the Claude app's Code tab (`"entrypoint":"claude-desktop"` on every
/// transcript record), and Codex inside the Codex app (`originator`
/// `codex_work_desktop` in the rollout's `session_meta`). Both apps register a
/// URL scheme that opens one session:
///
/// - **Claude**: `claude://code/continue?session=local_…`. The id is the app's
///   own, not the transcript's; the app keeps one JSON record per session under
///   `~/Library/Application Support/Claude/claude-code-sessions/`, whose
///   `cliSessionId` is the transcript's id and whose `sessionId` is the one the
///   link wants. Evidence: Claude 1.x `claudeURLHandler` — `/continue` accepts
///   `last` or `^local_[A-Za-z0-9-]{1,64}$` and routes to that session.
/// - **Codex**: `codex://threads/<id>`, where the thread id is the rollout's
///   `session_meta.payload.id`. Evidence: the Codex app's own links to a
///   thread, `codex://threads/${threadId}`.
///
/// A session neither app knows — Claude Code started in a terminal — has no
/// link, and its row falls back to copying the resume command.
enum DesktopAppLinks {
    static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    static let codexBundleIdentifier = "com.openai.codex"

    /// One Code session as the Claude app records it.
    struct ClaudeDesktopSession: Sendable, Equatable {
        /// The app's own id, `local_…` — what the link carries.
        let localID: String
        let title: String?
        let isArchived: Bool
    }

    /// The Claude app's Code sessions, keyed by the transcript's session id.
    ///
    /// Read-only, and only the three fields used: the records also carry the
    /// session's permission settings and tool grants, which are none of this
    /// app's business.
    static func claudeDesktopSessions(home: URL) -> [String: ClaudeDesktopSession] {
        let root = home.appending(path: "Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }

        var sessions: [String: ClaudeDesktopSession] = [:]
        for case let url as URL in walker {
            guard !Task.isCancelled else { break }
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("local_"),
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = record["cliSessionId"] as? String, !cli.isEmpty,
                  let local = record["sessionId"] as? String, isClaudeLocalID(local)
            else { continue }
            let title = (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[cli] = ClaudeDesktopSession(
                localID: local,
                title: title?.isEmpty == false ? title : nil,
                isArchived: record["isArchived"] as? Bool ?? false
            )
        }
        return sessions
    }

    /// The shape the Claude app itself accepts, checked here so a malformed
    /// record never becomes a link.
    static func isClaudeLocalID(_ id: String) -> Bool {
        id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
    }

    static func claudeLink(localID: String) -> URL? {
        guard isClaudeLocalID(localID) else { return nil }
        var parts = URLComponents()
        parts.scheme = "claude"
        parts.host = "code"
        parts.path = "/continue"
        parts.queryItems = [URLQueryItem(name: "session", value: localID)]
        return parts.url
    }

    static func codexLink(threadID: String) -> URL? {
        // A thread id is a UUID; anything else is not worth handing to a URL.
        guard UUID(uuidString: threadID) != nil else { return nil }
        return URL(string: "codex://threads/\(threadID.lowercased())")
    }

    /// Whether an app is installed, so a link is only offered where something
    /// will answer it.
    static func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// The desktop app's name for a menu item. Brand names, not translated.
    static func appName(for source: SessionSource) -> String {
        switch source {
        case .piDesktop: "PI-Desktop"
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }
}
