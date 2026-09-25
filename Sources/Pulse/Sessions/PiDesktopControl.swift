import AppKit
import Foundation

/// PI-Desktop's local control port: the one way to open a session by its id,
/// and the only exact source for "this turn is waiting for approval".
///
/// PI-Desktop has no URL scheme and ignores what a second launch passes it.
/// Started with `PI_DESKTOP_MCP_CONTROL=1` in its environment, it serves MCP
/// over streamable HTTP on `127.0.0.1` (port 37123 unless
/// `PI_DESKTOP_MCP_PORT` says otherwise), with a bearer token, and writes
/// where to find it to `~/.pi-desktop/mcp-control.json`. Nothing here starts
/// that server; `PiDesktopLauncher` relaunches PI-Desktop with it on, and only
/// when the person asks from Settings.
///
/// **Loopback only, and the token never leaves this Mac.** The connection file
/// is PI-Desktop's own (mode 0600); its URL is refused unless the host is a
/// loopback address, and the session this talks through bypasses any proxy
/// Pulse is configured with — a local token sent through a proxy is a token
/// handed to the proxy.
///
/// Evidence: PI-Desktop 0.15.7, `McpControlServer` — JSON replies (no SSE),
/// `Mcp-Session-Id` from `initialize`, tools `pi_desktop_invoke` with
/// operations `session/open` and `agent/getStatus`.
actor PiDesktopControl {
    struct Connection: Decodable, Sendable, Equatable {
        let active: Bool
        let url: String
        let token: String
        let pid: Int?
    }

    enum ControlError: Error, Equatable {
        case unavailable
        case refused(String)
    }

    static let protocolVersion = "2025-06-18"

    private let home: URL
    private let session: URLSession
    private var connection: Connection?
    private var mcpSession: String?
    private var nextID = 1

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// The connection PI-Desktop advertises, if it is serving one right now.
    static func advertisedConnection(home: URL) -> Connection? {
        let file = PiDesktopSessionReader.dataDirectory(home: home).appending(path: "mcp-control.json")
        guard
            let data = try? Data(contentsOf: file),
            let connection = try? JSONDecoder().decode(Connection.self, from: data),
            connection.active,
            let url = URL(string: connection.url),
            let host = url.host?.lowercased(),
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
            !connection.token.isEmpty
        else { return nil }
        // A file left `active` by a PI-Desktop that crashed is not a server.
        if let pid = connection.pid, pid > 0, kill(pid_t(pid), 0) != 0, errno == ESRCH { return nil }
        return connection
    }

    /// Whether the control port answers. Cheap when it already has.
    func isAvailable() async -> Bool {
        guard let advertised = Self.advertisedConnection(home: home) else {
            reset()
            return false
        }
        if advertised != connection { reset(); connection = advertised }
        if mcpSession != nil { return true }
        return (try? await initialize()) != nil
    }

    func openSession(_ id: String) async throws {
        _ = try await invoke(operation: "session/open", args: [id])
    }

    /// Which of these sessions have a tool call waiting on a person, by
    /// PI-Desktop's own count. Nil when the port cannot be asked, so the
    /// caller falls back to the permission log.
    func sessionsAwaitingApproval(among ids: [String]) async -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        guard await isAvailable() else { return nil }
        var waiting: Set<String> = []
        for id in ids.prefix(8) {
            guard let result = try? await invoke(operation: "agent/getStatus", args: [id]) else { return nil }
            if Self.pendingConfirmations(in: result) > 0 { waiting.insert(id) }
        }
        return waiting
    }

    /// `agent/getStatus` has answered both `{status: {...}}` and the bare
    /// status object; the count is looked for in either.
    static func pendingConfirmations(in value: Any?) -> Int {
        guard let object = value as? [String: Any] else { return 0 }
        if let count = object["pendingToolConfirmations"] as? Int { return count }
        if let count = (object["pendingToolConfirmations"] as? NSNumber)?.intValue { return count }
        return pendingConfirmations(in: object["status"])
    }

    // MARK: - Protocol

    private func reset() {
        connection = nil
        mcpSession = nil
    }

    private func initialize() async throws {
        guard connection != nil else { throw ControlError.unavailable }
        let (_, response) = try await post([
            "jsonrpc": "2.0",
            "id": takeID(),
            "method": "initialize",
            "params": [
                "protocolVersion": Self.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Pulsession", "version": Self.appVersion]
            ]
        ], session: nil)
        guard let id = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !id.isEmpty else {
            throw ControlError.refused("no session")
        }
        mcpSession = id
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: id)
    }

    /// Calls a reviewed PI-Desktop operation and returns its `result`.
    private func invoke(operation: String, args: [Any], retrying: Bool = true) async throws -> Any? {
        guard await isAvailable(), let mcpSession else { throw ControlError.unavailable }
        let (body, response) = try await post([
            "jsonrpc": "2.0",
            "id": takeID(),
            "method": "tools/call",
            "params": [
                "name": "pi_desktop_invoke",
                "arguments": ["operation": operation, "args": args]
            ]
        ], session: mcpSession)

        // PI-Desktop forgets sessions when it restarts, and keeps only a few.
        if response.statusCode == 404 || response.statusCode == 400, retrying {
            self.mcpSession = nil
            return try await invoke(operation: operation, args: args, retrying: false)
        }
        guard (200..<300).contains(response.statusCode),
              let result = body?["result"] as? [String: Any]
        else { throw ControlError.refused("HTTP \(response.statusCode)") }
        if result["isError"] as? Bool == true { throw ControlError.refused(operation) }
        let structured = result["structuredContent"] as? [String: Any]
        return structured?["result"]
    }

    private func post(_ message: [String: Any], session mcpSession: String?) async throws -> ([String: Any]?, HTTPURLResponse) {
        guard let connection, let url = URL(string: connection.url) else { throw ControlError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let mcpSession {
            request.setValue(mcpSession, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ControlError.unavailable }
        return (Self.decode(data, contentType: http.value(forHTTPHeaderField: "Content-Type")), http)
    }

    /// A JSON body, or — should a later PI-Desktop start answering in the
    /// streamable-HTTP event form — the last `data:` line of one.
    static func decode(_ data: Data, contentType: String?) -> [String: Any]? {
        if contentType?.contains("text/event-stream") == true, let text = String(data: data, encoding: .utf8) {
            let payload = text.split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .last
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            return payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Finds, brings forward and — when asked — relaunches PI-Desktop.
@MainActor
enum PiDesktopLauncher {
    static let controlEnvironment = ["PI_DESKTOP_MCP_CONTROL": "1"]

    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: PiDesktopSessionReader.bundleIdentifier)
    }

    static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: PiDesktopSessionReader.bundleIdentifier)
            .first { !$0.isTerminated }
    }

    static var isRunning: Bool { runningApplication != nil }

    /// Brings PI-Desktop forward, starting it if it is not running.
    ///
    /// Through `openApplication` rather than `NSRunningApplication.activate`:
    /// Pulse is an accessory app that is almost never active itself, and
    /// macOS 14's cooperative activation lets an inactive app's request to
    /// hand focus over go unanswered.
    static func bringForward() {
        guard let url = applicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// Quits PI-Desktop if it is running and starts it again with its control
    /// port on. Returns whether the new instance started.
    ///
    /// Only ever from a button the person pressed in Settings, after being
    /// told what it does: quitting stops any turn in flight.
    static func relaunchWithControl() async -> Bool {
        guard let url = applicationURL else { return false }

        if let running = runningApplication {
            running.terminate()
            for _ in 0..<50 where !running.isTerminated {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard running.isTerminated else { return false }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.environment = controlEnvironment
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
