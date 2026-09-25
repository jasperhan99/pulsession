import Foundation

/// Claude Code and Codex sessions, one per transcript file.
///
/// The turn's state is `AgentActivity`'s verdict — the same exact reading of
/// `stop_reason` and `task_started` / `task_complete` that turns the usage
/// ring — applied per file instead of per provider. Title and project come
/// from the head of the file, where both CLIs state the working directory and
/// the opening prompt; Claude Code's own name for a conversation
/// (`customTitle`, or its generated `summary`) wins over the prompt wherever
/// it appears.
///
/// Neither CLI records a pending approval or a question in a form that can be
/// told apart from a slow tool, so these sessions are never shown as waiting —
/// only running, or finished. Saying less is better than saying something
/// the transcript does not.
enum CLISessionReader {
    /// How far back a transcript is still worth listing.
    static let recentWindow: TimeInterval = 24 * 60 * 60
    /// How many sessions per CLI.
    static let limit = 20
    /// Enough of the head to reach the working directory and the opening
    /// prompt, which both CLIs write in the first few records.
    static let headLimit = 64 * 1024

    struct Metadata: Sendable, Equatable {
        var sessionID: String?
        var cwd: String?
        var prompt: String?
        /// A name the CLI gave the conversation, which outranks the prompt.
        var name: String?
        /// Claude Code: where the session runs — `cli`, or `claude-desktop`
        /// for the Claude app's Code tab.
        var entrypoint: String?
        /// Codex: which client wrote the rollout — `codex_cli_rs`, or
        /// `codex_work_desktop` for the Codex app.
        var originator: String?
    }

    /// What was read from a file the last time it was looked at, so an
    /// unchanged transcript is not re-read every scan.
    struct CachedMetadata: Sendable, Equatable {
        var modified: Date
        var metadata: Metadata
    }

    static func sessions(
        for source: SessionSource,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        now: Date = Date(),
        cache: [String: CachedMetadata],
        claudeDesktop: [String: DesktopAppLinks.ClaudeDesktopSession] = [:],
        codexAppInstalled: Bool = false
    ) -> (sessions: [AgentSession], cache: [String: CachedMetadata]) {
        guard let provider = source.provider else { return ([], cache) }

        let files = AgentActivity.transcripts(for: provider, home: home)
            .filter { now.timeIntervalSince($0.modified) <= recentWindow && isSessionFile($0.url, source: source) }
            .prefix(limit)

        var sessions: [AgentSession] = []
        var updated: [String: CachedMetadata] = [:]

        for file in files {
            guard !Task.isCancelled else { break }
            let key = file.url.path
            let metadata: Metadata
            if let cached = cache[key], cached.modified == file.modified {
                metadata = cached.metadata
            } else {
                metadata = self.metadata(of: file.url, source: source)
            }
            updated[key] = CachedMetadata(modified: file.modified, metadata: metadata)

            let verdict = AgentActivity.verdict(for: file.url, provider: provider)
            let state = self.state(for: verdict, modified: file.modified, now: now)
            let id = metadata.sessionID ?? sessionID(fromFileName: file.url, source: source)

            // Where it can be opened, and — for the Claude app — what the app
            // calls it and whether it has been archived there.
            var appLink: URL?
            var appTitle: String?
            switch source {
            case .claudeCode:
                if let desktop = claudeDesktop[id] {
                    // Archived in the Claude app is a choice already made about
                    // this session; showing it here would undo it.
                    if desktop.isArchived { continue }
                    appLink = DesktopAppLinks.claudeLink(localID: desktop.localID)
                    appTitle = desktop.title
                }
            case .codex:
                // The Codex app lists every rollout under ~/.codex, whichever
                // client wrote it, so any thread can be opened there.
                if codexAppInstalled { appLink = DesktopAppLinks.codexLink(threadID: id) }
            case .piDesktop:
                break
            }
            let title = appTitle ?? metadata.name ?? metadata.prompt ?? String.localized("Untitled session")

            sessions.append(AgentSession(
                source: source,
                nativeID: id,
                title: title,
                project: AgentSession.folderName(of: metadata.cwd)
                    ?? UsageLedgerReader.project(of: file.url, provider: provider)?.name,
                projectPath: metadata.cwd,
                state: state,
                startedAt: nil,
                updatedAt: file.modified,
                endedAt: state.isActive ? nil : file.modified,
                appLink: appLink
            ))
        }

        return (sessions, updated)
    }

    /// Internal so the rule can be tested against verdicts built by hand.
    static func state(for verdict: AgentActivity.Verdict, modified: Date, now: Date) -> SessionState {
        let recent = now.timeIntervalSince(modified) <= SessionState.outcomeWindow
        switch verdict {
        case .working(let wait, let at):
            if now.timeIntervalSince(at ?? modified) <= wait.grace { return .running }
            // A turn that never finished and has gone quiet past its grace:
            // the CLI died or was closed mid-turn.
            return recent ? .interrupted : .idle
        case .finished:
            return recent ? .done : .idle
        case .unknown:
            return now.timeIntervalSince(modified) <= AgentActivity.unknownFormatWindow ? .running : .idle
        }
    }

    /// Transcripts that are conversations of their own. Claude Code writes a
    /// subagent's records into a file of its own beside the session's, and
    /// listing those would show one conversation several times over.
    static func isSessionFile(_ url: URL, source: SessionSource) -> Bool {
        guard source == .claudeCode else { return true }
        if url.pathComponents.contains("subagents") { return false }
        return !url.lastPathComponent.hasPrefix("agent-")
    }

    /// Both CLIs put the session's id in the file name: Claude Code as the
    /// whole name, Codex as the last thirty-six characters of
    /// `rollout-<timestamp>-<uuid>.jsonl`.
    static func sessionID(fromFileName url: URL, source: SessionSource) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard source == .codex, stem.count > 36 else { return stem }
        return String(stem.suffix(36))
    }

    // MARK: - Metadata

    static func metadata(of url: URL, source: SessionSource) -> Metadata {
        var metadata = parse(lines: head(of: url), source: source)
        // A rename is written whenever it happens, so it is looked for at the
        // end too; the last one wins.
        if source == .claudeCode, let name = parse(lines: AgentActivity.tail(of: url), source: source).name {
            metadata.name = name
        }
        return metadata
    }

    /// Internal so the parsing can be driven with transcripts built by hand.
    static func parse(lines: [Data], source: SessionSource) -> Metadata {
        var metadata = Metadata()
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch source {
            case .claudeCode: readClaudeCode(record, into: &metadata)
            case .codex: readCodex(record, into: &metadata)
            case .piDesktop: return metadata
            }
        }
        return metadata
    }

    private static func readClaudeCode(_ record: [String: Any], into metadata: inout Metadata) {
        if metadata.cwd == nil, let cwd = record["cwd"] as? String, !cwd.isEmpty { metadata.cwd = cwd }
        if metadata.sessionID == nil, let id = record["sessionId"] as? String, !id.isEmpty { metadata.sessionID = id }
        if metadata.entrypoint == nil, let entry = record["entrypoint"] as? String, !entry.isEmpty { metadata.entrypoint = entry }

        if let custom = record["customTitle"] as? String, let title = UsageLedgerReader.title(from: custom) {
            metadata.name = title
            return
        }

        switch record["type"] as? String {
        case "summary":
            if metadata.name == nil, let summary = record["summary"] as? String,
               let title = UsageLedgerReader.title(from: summary) {
                metadata.name = title
            }
        case "user":
            guard metadata.prompt == nil,
                  record["isSidechain"] as? Bool != true,
                  record["isMeta"] as? Bool != true,
                  let message = record["message"] as? [String: Any],
                  let text = UsageLedgerReader.text(in: message["content"]),
                  let title = UsageLedgerReader.title(from: text)
            else { return }
            metadata.prompt = title
        default:
            return
        }
    }

    private static func readCodex(_ record: [String: Any], into metadata: inout Metadata) {
        guard let payload = record["payload"] as? [String: Any] else { return }

        if record["type"] as? String == "session_meta" {
            if metadata.sessionID == nil, let id = payload["id"] as? String, !id.isEmpty { metadata.sessionID = id }
            if metadata.cwd == nil, let cwd = payload["cwd"] as? String, !cwd.isEmpty { metadata.cwd = cwd }
            if metadata.originator == nil, let origin = payload["originator"] as? String, !origin.isEmpty { metadata.originator = origin }
            return
        }
        if metadata.cwd == nil, let cwd = payload["cwd"] as? String, !cwd.isEmpty { metadata.cwd = cwd }

        guard metadata.prompt == nil else { return }
        // Codex writes the prompt twice: as the model sees it (a message whose
        // first user item is often the environment envelope, which `title`
        // refuses) and as the user typed it.
        let text: String? = switch payload["type"] as? String {
        case "user_message": payload["message"] as? String
        case "message" where payload["role"] as? String == "user": UsageLedgerReader.text(in: payload["content"])
        default: nil
        }
        if let text, let title = UsageLedgerReader.title(from: text) { metadata.prompt = title }
    }

    private static func head(of url: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headLimit), !data.isEmpty else { return [] }
        var lines = data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        // The last line is only half a line unless the whole file fitted.
        if data.count == headLimit, !lines.isEmpty { lines.removeLast() }
        return lines
    }
}
