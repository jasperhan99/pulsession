import Foundation
import SQLite3

/// PI-Desktop's sessions, read from the files PI-Desktop itself keeps.
///
/// PI-Desktop has no API an outside process can ask without it being started
/// specially (see `PiDesktopControl`), but everything the monitor needs except
/// a pending approval is already on disk:
///
/// - `~/.pi-desktop/pi.sqlite` — `sessions` (title, project, timestamps) and
///   `turns`, one row per turn with `status` `running` / `completed` /
///   `failed` / `aborted`. A unique index allows one running turn per session,
///   and PI-Desktop rewrites leftover `running` rows to `aborted` when it
///   starts, so a running row is a turn in flight — as long as PI-Desktop is.
/// - `~/.pi-desktop/logs/app/permission.log` — one JSON line per approval
///   `permission.requested`, and `permission.resolved` when it is answered.
///
/// **Read-only, always.** The database belongs to a running app; it is opened
/// with `SQLITE_OPEN_READONLY` through `AgentSQLite` and never written. The
/// schema is PI-Desktop's own and can change with any update: a query that no
/// longer prepares yields no rows rather than an error, and `schemaVersion`
/// is reported so Settings can say the format is not the one this was built
/// against. Evidence: PI-Desktop 0.15.7, `PRAGMA user_version` 19.
enum PiDesktopSessionReader {
    /// The schema this reader was written against.
    static let knownSchemaVersion = 19
    /// How many sessions to read. The panel card shows far fewer; the rest
    /// only feed Settings' hidden and archived lists.
    static let sessionLimit = 60
    /// PI-Desktop's bundle identifier, to tell whether it is running.
    static let bundleIdentifier = "net.aiuo.pi-desktop"
    /// An approval asked for longer ago than this, and never answered, is
    /// taken as one that timed out rather than one still on screen — the log
    /// has requests with no resolution line at all.
    static let approvalLifetime: TimeInterval = 15 * 60

    struct Snapshot: Sendable, Equatable {
        var sessions: [AgentSession] = []
        /// Nil when there is no database at all — PI-Desktop not installed or
        /// never run.
        var schemaVersion: Int?
    }

    static func dataDirectory(home: URL) -> URL {
        home.appending(path: ".pi-desktop")
    }

    static func read(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        now: Date = Date(),
        isAppRunning: Bool,
        liveApprovals: Set<String>? = nil
    ) -> Snapshot {
        let directory = dataDirectory(home: home)
        let database = directory.appending(path: "pi.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return Snapshot() }

        let pending = liveApprovals.map { ids in ids.reduce(into: [String: PendingApproval]()) { $0[$1] = PendingApproval(turnID: nil, at: now) } }
            ?? pendingApprovals(in: directory.appending(path: "logs/app/permission.log"), now: now)

        let result: Snapshot? = AgentSQLite.read(at: database) { db in
            var snapshot = Snapshot(schemaVersion: schemaVersion(of: db))
            AgentSQLite.each(db, sql: query) { row in
                if let session = session(from: row, now: now, isAppRunning: isAppRunning, pending: pending) {
                    snapshot.sessions.append(session)
                }
            }
            return snapshot
        }
        return result ?? Snapshot()
    }

    /// The newest turn per session rides along through a correlated subquery,
    /// which `idx_turns_session (session_id, started_at DESC)` answers without
    /// a scan.
    static let query = """
        SELECT s.id, s.title, s.updated_at, p.name, p.path,
               t.id, t.status, t.started_at, t.ended_at
        FROM sessions s
        LEFT JOIN projects p ON p.id = s.project_id
        LEFT JOIN turns t ON t.id = (
            SELECT id FROM turns WHERE session_id = s.id ORDER BY started_at DESC LIMIT 1
        )
        WHERE s.deleted_at IS NULL
        ORDER BY s.updated_at DESC
        LIMIT \(sessionLimit)
        """

    private static func schemaVersion(of db: OpaquePointer) -> Int? {
        var version: Int?
        AgentSQLite.each(db, sql: "PRAGMA user_version") { row in
            version = Int(sqlite3_column_int64(row, 0))
        }
        return version
    }

    private static func session(
        from row: OpaquePointer,
        now: Date,
        isAppRunning: Bool,
        pending: [String: PendingApproval]
    ) -> AgentSession? {
        guard let id = AgentSQLite.text(row, column: 0), !id.isEmpty else { return nil }
        let title = AgentSQLite.text(row, column: 1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let updatedAt = date(row, column: 2) ?? now
        let projectName = AgentSQLite.text(row, column: 3)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectPath = AgentSQLite.text(row, column: 4)
        let turnID = AgentSQLite.text(row, column: 5)
        let status = AgentSQLite.text(row, column: 6)
        let startedAt = date(row, column: 7)
        let endedAt = date(row, column: 8)

        let state = self.state(
            status: status,
            turnID: turnID,
            startedAt: startedAt,
            endedAt: endedAt,
            approval: pending[id],
            isAppRunning: isAppRunning,
            now: now
        )

        return AgentSession(
            source: .piDesktop,
            nativeID: id,
            title: title.isEmpty ? String.localized("Untitled session") : title,
            project: (projectName?.isEmpty == false ? projectName : nil) ?? AgentSession.folderName(of: projectPath),
            projectPath: projectPath,
            state: state,
            startedAt: state.isActive ? startedAt : nil,
            updatedAt: max(updatedAt, endedAt ?? .distantPast, startedAt ?? .distantPast),
            endedAt: endedAt
        )
    }

    /// Internal so the mapping can be tested without a database.
    static func state(
        status: String?,
        turnID: String?,
        startedAt: Date?,
        endedAt: Date?,
        approval: PendingApproval?,
        isAppRunning: Bool,
        now: Date
    ) -> SessionState {
        switch status {
        case "running":
            // PI-Desktop gone with a turn still marked running: it died or was
            // quit mid-turn, and will record exactly this when it next starts.
            guard isAppRunning else { return .interrupted }
            if let approval, approval.turnID == nil || approval.turnID == turnID {
                return .approval
            }
            return .running
        case nil:
            return .idle
        default:
            break
        }

        let outcome: SessionState = switch status {
        case "completed": .done
        case "failed", "error": .failed
        case "aborted", "interrupted", "canceled", "cancelled": .interrupted
        default: .done
        }
        let ended = endedAt ?? startedAt ?? .distantPast
        return now.timeIntervalSince(ended) <= SessionState.outcomeWindow ? outcome : .idle
    }

    private static func date(_ row: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
        let millis = sqlite3_column_int64(row, column)
        guard millis > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    // MARK: - Approvals

    struct PendingApproval: Sendable, Equatable {
        /// The turn the request belongs to, so a request left over from an
        /// earlier turn cannot mark a later one as waiting.
        var turnID: String?
        var at: Date
    }

    /// Requests without a resolution, by session. Reads only the log's tail:
    /// an unanswered request that has scrolled out of it is long past
    /// `approvalLifetime` anyway.
    static func pendingApprovals(in log: URL, now: Date, limit: Int = 256 * 1024) -> [String: PendingApproval] {
        pendingApprovals(lines: tail(of: log, limit: limit), now: now)
    }

    /// Internal so the parsing can be tested on lines built by hand.
    static func pendingApprovals(lines: [Data], now: Date) -> [String: PendingApproval] {
        var requests: [String: (session: String, approval: PendingApproval)] = [:]
        var resolved: Set<String> = []

        for line in lines {
            guard
                let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let event = record["event"] as? String
            else { continue }
            let data = record["data"] as? [String: Any]

            switch event {
            case "permission.requested":
                guard
                    let request = record["requestId"] as? String ?? data?["requestId"] as? String,
                    let session = record["sessionId"] as? String ?? data?["sessionId"] as? String
                else { continue }
                let at = (record["ts"] as? String).flatMap(isoDate) ?? now
                requests[request] = (session, PendingApproval(turnID: record["turnId"] as? String, at: at))
            case "permission.resolved":
                if let request = data?["requestId"] as? String ?? record["requestId"] as? String {
                    resolved.insert(request)
                }
            default:
                continue
            }
        }

        var pending: [String: PendingApproval] = [:]
        for (request, entry) in requests where !resolved.contains(request) {
            guard now.timeIntervalSince(entry.approval.at) <= approvalLifetime else { continue }
            // The newest unanswered request per session is the one on screen.
            if let existing = pending[entry.session], existing.at > entry.approval.at { continue }
            pending[entry.session] = entry.approval
        }
        return pending
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// The last stretch of a file, in whole lines.
    static func tail(of url: URL, limit: Int) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
