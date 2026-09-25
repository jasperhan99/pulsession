import Foundation
import SQLite3
import Testing
@testable import Pulse

/// Pulsession's session monitor: PI-Desktop's database and permission log,
/// the CLIs' transcripts, and the rules that turn them into states.
///
/// Everything here is built by hand in a temporary home — no test reads the
/// user's own `~/.pi-desktop`, `~/.claude` or `~/.codex`.
@Suite("Session monitor")
struct SessionMonitorTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func millis(_ secondsAgo: TimeInterval) -> Int64 {
        Int64((now.timeIntervalSince1970 - secondsAgo) * 1000)
    }

    // MARK: - PI-Desktop database

    @Test("PI-Desktop sessions come from the database with their newest turn")
    func piDesktopSessions() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makePiDatabase(in: home, statements: [
            "INSERT INTO projects VALUES (1, '/Users/me/Code/my-app', 'my-app', 0, 0, 0)",
            "INSERT INTO sessions (id, title, project_id, created_at, updated_at) VALUES ('run', 'Fix login', 1, 0, \(Self.millis(5)))",
            "INSERT INTO sessions (id, title, project_id, created_at, updated_at) VALUES ('done', 'Write tests', NULL, 0, \(Self.millis(60)))",
            "INSERT INTO sessions (id, title, project_id, created_at, updated_at) VALUES ('old', '', NULL, 0, \(Self.millis(7200)))",
            "INSERT INTO sessions (id, title, project_id, created_at, updated_at, deleted_at) VALUES ('gone', 'Deleted', NULL, 0, \(Self.millis(1)), 1)",
            "INSERT INTO turns (id, session_id, status, started_at, ended_at) VALUES ('t0', 'run', 'completed', \(Self.millis(600)), \(Self.millis(590)))",
            "INSERT INTO turns (id, session_id, status, started_at) VALUES ('t1', 'run', 'running', \(Self.millis(30)))",
            "INSERT INTO turns (id, session_id, status, started_at, ended_at) VALUES ('t2', 'done', 'completed', \(Self.millis(120)), \(Self.millis(60)))",
            "INSERT INTO turns (id, session_id, status, error_code, started_at, ended_at) VALUES ('t3', 'old', 'failed', 'X', \(Self.millis(7300)), \(Self.millis(7200)))",
        ])

        let snapshot = PiDesktopSessionReader.read(home: home, now: Self.now, isAppRunning: true)
        #expect(snapshot.schemaVersion == PiDesktopSessionReader.knownSchemaVersion)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.nativeID, $0) })
        #expect(byID["gone"] == nil)

        let running = try #require(byID["run"])
        #expect(running.state == .running)
        #expect(running.project == "my-app")
        #expect(running.projectPath == "/Users/me/Code/my-app")
        #expect(running.startedAt.map { abs($0.timeIntervalSince(Self.now) + 30) < 0.01 } == true)

        #expect(byID["done"]?.state == .done)
        #expect(byID["done"]?.project == nil)
        // A failure from two hours ago is old news.
        #expect(byID["old"]?.state == .idle)
        #expect(byID["old"]?.title.isEmpty == false)
    }

    @Test("A turn still marked running after PI-Desktop has gone is interrupted")
    func runningWithoutApp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makePiDatabase(in: home, statements: [
            "INSERT INTO sessions (id, title, created_at, updated_at) VALUES ('s', 'Title', 0, \(Self.millis(5)))",
            "INSERT INTO turns (id, session_id, status, started_at) VALUES ('t', 's', 'running', \(Self.millis(30)))",
        ])
        let snapshot = PiDesktopSessionReader.read(home: home, now: Self.now, isAppRunning: false)
        #expect(snapshot.sessions.first?.state == .interrupted)
    }

    @Test("An unanswered permission request for the running turn is an approval")
    func approvalFromLog() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makePiDatabase(in: home, statements: [
            "INSERT INTO sessions (id, title, created_at, updated_at) VALUES ('s', 'Title', 0, \(Self.millis(5)))",
            "INSERT INTO turns (id, session_id, status, started_at) VALUES ('t', 's', 'running', \(Self.millis(30)))",
        ])
        let log = home.appending(path: ".pi-desktop/logs/app/permission.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-10))
        try Data("""
            {"ts":"\(stamp)","event":"permission.requested","requestId":"r1","sessionId":"s","turnId":"t","data":{"toolName":"Bash"}}

            """.utf8).write(to: log)

        let snapshot = PiDesktopSessionReader.read(home: home, now: Self.now, isAppRunning: true)
        #expect(snapshot.sessions.first?.state == .approval)

        // The control port's answer replaces the log's.
        let live = PiDesktopSessionReader.read(home: home, now: Self.now, isAppRunning: true, liveApprovals: [])
        #expect(live.sessions.first?.state == .running)
    }

    @Test("Resolved, stale and other-turn requests are not pending")
    func pendingApprovalRules() {
        let recent = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-60))
        let stale = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3600))
        let lines = [
            #"{"ts":"\#(recent)","event":"permission.requested","requestId":"a","sessionId":"s1","turnId":"t1"}"#,
            #"{"ts":"\#(recent)","event":"permission.resolved","data":{"requestId":"a","decision":"allow-once"}}"#,
            #"{"ts":"\#(stale)","event":"permission.requested","requestId":"b","sessionId":"s2","turnId":"t2"}"#,
            #"{"ts":"\#(recent)","event":"permission.requested","requestId":"c","sessionId":"s3","turnId":"t3"}"#,
            "not json",
        ].map { Data($0.utf8) }

        let pending = PiDesktopSessionReader.pendingApprovals(lines: lines, now: Self.now)
        #expect(pending["s1"] == nil)
        #expect(pending["s2"] == nil)
        #expect(pending["s3"]?.turnID == "t3")

        // A request left over from an earlier turn does not mark a later one.
        let state = PiDesktopSessionReader.state(
            status: "running", turnID: "t4", startedAt: Self.now, endedAt: nil,
            approval: pending["s3"], isAppRunning: true, now: Self.now
        )
        #expect(state == .running)
    }

    @Test("Turn statuses map to states, and old outcomes go quiet")
    func statusMapping() {
        func state(_ status: String?, endedAgo: TimeInterval = 60) -> SessionState {
            PiDesktopSessionReader.state(
                status: status, turnID: "t", startedAt: nil,
                endedAt: Self.now.addingTimeInterval(-endedAgo),
                approval: nil, isAppRunning: true, now: Self.now
            )
        }
        #expect(state("completed") == .done)
        #expect(state("failed") == .failed)
        #expect(state("aborted") == .interrupted)
        #expect(state("interrupted") == .interrupted)
        #expect(state(nil) == .idle)
        #expect(state("completed", endedAgo: SessionState.outcomeWindow + 1) == .idle)
    }

    // MARK: - CLI transcripts

    @Test("Claude Code: working directory, id, and the name outranking the prompt")
    func claudeCodeMetadata() {
        let lines = [
            #"{"type":"user","sessionId":"abc","cwd":"/Users/me/Code/api","isMeta":true,"message":{"content":"<command-name>init</command-name>"}}"#,
            #"{"type":"user","sessionId":"abc","cwd":"/Users/me/Code/api","message":{"content":"Run the integration tests"}}"#,
            #"{"type":"user","isSidechain":true,"message":{"content":"subagent prompt"}}"#,
        ].map { Data($0.utf8) }
        var metadata = CLISessionReader.parse(lines: lines, source: .claudeCode)
        #expect(metadata.sessionID == "abc")
        #expect(metadata.cwd == "/Users/me/Code/api")
        #expect(metadata.prompt == "Run the integration tests")
        #expect(metadata.name == nil)

        metadata = CLISessionReader.parse(
            lines: lines + [Data(#"{"type":"custom-title","customTitle":"API tests"}"#.utf8)],
            source: .claudeCode
        )
        #expect(metadata.name == "API tests")
    }

    @Test("Codex: the session header, and the prompt as typed rather than the envelope")
    func codexMetadata() {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"0199-codex","cwd":"/Users/me/notes"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>…</environment_context>"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Summarize findings"}}"#,
        ].map { Data($0.utf8) }
        let metadata = CLISessionReader.parse(lines: lines, source: .codex)
        #expect(metadata.sessionID == "0199-codex")
        #expect(metadata.cwd == "/Users/me/notes")
        #expect(metadata.prompt == "Summarize findings")
    }

    @Test("Verdicts become session states")
    func cliStates() {
        let recent = Self.now.addingTimeInterval(-60)
        let old = Self.now.addingTimeInterval(-(SessionState.outcomeWindow + 60))
        #expect(CLISessionReader.state(for: .working(.model, at: recent), modified: recent, now: Self.now) == .running)
        #expect(CLISessionReader.state(for: .working(.model, at: Self.now.addingTimeInterval(-600)), modified: recent, now: Self.now) == .interrupted)
        #expect(CLISessionReader.state(for: .finished, modified: recent, now: Self.now) == .done)
        #expect(CLISessionReader.state(for: .finished, modified: old, now: Self.now) == .idle)
        #expect(CLISessionReader.state(for: .unknown, modified: old, now: Self.now) == .idle)
    }

    @Test("Session files and ids")
    func sessionFiles() {
        let codex = URL(fileURLWithPath: "/x/rollout-2026-09-25T10-00-00-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl")
        #expect(CLISessionReader.sessionID(fromFileName: codex, source: .codex) == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
        let claude = URL(fileURLWithPath: "/x/-Users-me-api/5f1e.jsonl")
        #expect(CLISessionReader.sessionID(fromFileName: claude, source: .claudeCode) == "5f1e")
        #expect(!CLISessionReader.isSessionFile(URL(fileURLWithPath: "/x/p/s/subagents/a.jsonl"), source: .claudeCode))
        #expect(!CLISessionReader.isSessionFile(URL(fileURLWithPath: "/x/p/agent-1.jsonl"), source: .claudeCode))
        #expect(CLISessionReader.isSessionFile(claude, source: .claudeCode))
    }

    @Test("Where a CLI session runs is read from its transcript")
    func origins() {
        let claude = CLISessionReader.parse(
            lines: [Data(#"{"type":"user","sessionId":"s","entrypoint":"claude-desktop","message":{"content":"hi there"}}"#.utf8)],
            source: .claudeCode
        )
        #expect(claude.entrypoint == "claude-desktop")
        let codex = CLISessionReader.parse(
            lines: [Data(#"{"type":"session_meta","payload":{"id":"x","originator":"codex_work_desktop"}}"#.utf8)],
            source: .codex
        )
        #expect(codex.originator == "codex_work_desktop")
    }

    @Test("The Claude app's session records map transcript ids to its own")
    func claudeDesktopIndex() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: "Library/Application Support/Claude/claude-code-sessions/a/b")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_1234-abcd","cliSessionId":"cb073919-0000-4000-8000-000000000001","title":"Fix login","isArchived":false,"permissionMode":"ask"}"#.utf8)
            .write(to: folder.appending(path: "local_1234-abcd.json"))
        try Data(#"{"sessionId":"not-local","cliSessionId":"cb073919-0000-4000-8000-000000000002"}"#.utf8)
            .write(to: folder.appending(path: "local_bad.json"))

        let index = DesktopAppLinks.claudeDesktopSessions(home: home)
        #expect(index.count == 1)
        let session = try #require(index["cb073919-0000-4000-8000-000000000001"])
        #expect(session.localID == "local_1234-abcd")
        #expect(session.title == "Fix login")
        #expect(DesktopAppLinks.claudeLink(localID: session.localID)?.absoluteString
                == "claude://code/continue?session=local_1234-abcd")
        #expect(DesktopAppLinks.claudeLink(localID: "local_../x") == nil)
    }

    @Test("Codex threads open by their id, and only a UUID becomes a link")
    func codexLinks() {
        #expect(DesktopAppLinks.codexLink(threadID: "0199A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B")?.absoluteString
                == "codex://threads/0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
        #expect(DesktopAppLinks.codexLink(threadID: "../settings") == nil)
    }

    @Test("A Claude session gets the app's link and title; one archived there is left out")
    func claudeSessionsFromDesktop() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appending(path: ".claude/projects/-Users-me-api")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let kept = "cb073919-0000-4000-8000-000000000001"
        let archived = "cb073919-0000-4000-8000-000000000002"
        let terminal = "cb073919-0000-4000-8000-000000000003"
        for id in [kept, archived, terminal] {
            let file = project.appending(path: "\(id).jsonl")
            try Data("{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/Users/me/api\",\"message\":{\"content\":\"prompt \(id)\"}}\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Self.now.addingTimeInterval(-60)], ofItemAtPath: file.path)
        }
        let desktop: [String: DesktopAppLinks.ClaudeDesktopSession] = [
            kept: .init(localID: "local_kept", title: "Named in Claude", isArchived: false),
            archived: .init(localID: "local_gone", title: nil, isArchived: true),
        ]
        let read = CLISessionReader.sessions(for: .claudeCode, home: home, now: Self.now, cache: [:], claudeDesktop: desktop)
        let byID = Dictionary(uniqueKeysWithValues: read.sessions.map { ($0.nativeID, $0) })
        #expect(byID[archived] == nil)
        #expect(byID[kept]?.title == "Named in Claude")
        #expect(byID[kept]?.appLink?.absoluteString == "claude://code/continue?session=local_kept")
        // Started in a terminal: no app holds it, so its row copies the command.
        #expect(byID[terminal]?.appLink == nil)
        #expect(byID[terminal]?.resumeCommand?.hasSuffix("claude --resume \(terminal)") == true)
    }

    // MARK: - Model

    @Test("Resume commands quote the project path for the shell")
    func resumeCommand() {
        let session = AgentSession(
            source: .claudeCode, nativeID: "abc", title: "t", project: "it's",
            projectPath: "/Users/me/it's here", state: .done, updatedAt: Self.now
        )
        #expect(session.resumeCommand == #"cd '/Users/me/it'\''s here' && claude --resume abc"#)
        #expect(AgentSession.folderName(of: #"C:\work\api\"#) == "api")
        #expect(AgentSession.folderName(of: "/") == nil)
    }

    @Test("Most urgent first, then most recent")
    func ordering() {
        func session(_ id: String, _ state: SessionState, _ ago: TimeInterval) -> AgentSession {
            AgentSession(source: .piDesktop, nativeID: id, title: id, state: state, updatedAt: Self.now.addingTimeInterval(-ago))
        }
        let sorted = AgentSession.sorted([
            session("idle", .idle, 1), session("run-old", .running, 100),
            session("approval", .approval, 500), session("run-new", .running, 10),
        ])
        #expect(sorted.map(\.nativeID) == ["approval", "run-new", "run-old", "idle"])
    }

    // MARK: - Visibility

    @Test("Hidden and archived are exclusive, and a hidden session comes back")
    @MainActor
    func visibility() throws {
        let suite = "SessionMonitorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SessionSettings(defaults: defaults)
        let session = AgentSession(source: .codex, nativeID: "x", title: "T", state: .running, updatedAt: Self.now)

        settings.hide(session, at: Self.now)
        #expect(settings.isExcluded(session.id))
        settings.archive(session, at: Self.now)
        #expect(settings.hidden.isEmpty)
        #expect(settings.archived.map(\.id) == [session.id])

        settings.restore(session.id)
        #expect(!settings.isExcluded(session.id))

        settings.hide(session, at: Self.now)
        settings.unhide([session.id])
        #expect(settings.hidden.isEmpty)

        // Persisted.
        settings.archive(session, at: Self.now)
        #expect(SessionSettings(defaults: defaults).archived.map(\.id) == [session.id])
    }

    // MARK: - Control port

    @Test("Pending confirmations are read from either status shape")
    func pendingConfirmations() {
        #expect(PiDesktopControl.pendingConfirmations(in: ["isRunning": true, "pendingToolConfirmations": 2]) == 2)
        #expect(PiDesktopControl.pendingConfirmations(in: ["status": ["pendingToolConfirmations": 1]]) == 1)
        #expect(PiDesktopControl.pendingConfirmations(in: nil) == 0)
        let event = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8)
        #expect(PiDesktopControl.decode(event, contentType: "text/event-stream")?["id"] as? Int == 1)
    }

    @Test("Only a loopback, active connection file is trusted")
    func connectionFile() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: ".pi-desktop/mcp-control.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data(#"{"active":true,"url":"http://127.0.0.1:37123/mcp","token":"abc"}"#.utf8).write(to: file)
        #expect(PiDesktopControl.advertisedConnection(home: home)?.url == "http://127.0.0.1:37123/mcp")

        try Data(#"{"active":true,"url":"http://example.com:37123/mcp","token":"abc"}"#.utf8).write(to: file)
        #expect(PiDesktopControl.advertisedConnection(home: home) == nil)

        try Data(#"{"active":false,"url":"http://127.0.0.1:37123/mcp","token":"abc"}"#.utf8).write(to: file)
        #expect(PiDesktopControl.advertisedConnection(home: home) == nil)
    }

    // MARK: - Helpers

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "session-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// The tables and columns the reader asks for, as PI-Desktop 0.15.7
    /// declares them (schema 19), trimmed of columns it does not read.
    private func makePiDatabase(in home: URL, statements: [String]) throws {
        let directory = home.appending(path: ".pi-desktop")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.appending(path: "pi.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = [
            "PRAGMA user_version = 19",
            "CREATE TABLE projects (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, last_opened_at INTEGER NOT NULL)",
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', project_id INTEGER REFERENCES projects(id), source TEXT, deleted_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
            "CREATE TABLE turns (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'running', error_code TEXT, started_at INTEGER NOT NULL, ended_at INTEGER)",
            "CREATE INDEX idx_turns_session ON turns(session_id, started_at DESC)",
        ]
        for sql in schema + statements {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
    }
}
