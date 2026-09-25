import AppKit
import Foundation
import Observation

/// Watches every session the readers can see and says what each is doing.
///
/// Its own clock, like `AgentActivityMonitor`, and for the same reason: a turn
/// starts and ends in seconds, and a spinner that lags it is a spinner that
/// lies. Everything read is local — a database opened read-only, the tails of
/// a few transcripts and one log — so two seconds costs next to nothing, and
/// nothing is read while the panel is off screen or the display asleep.
@MainActor
@Observable
final class SessionMonitor {
    let settings: SessionSettings

    /// Every session read, most urgent first. Hidden and archived ones are
    /// still here; `visible` leaves them out.
    private(set) var sessions: [AgentSession] = []
    /// PI-Desktop's schema version as read, nil when it has no database.
    private(set) var piSchemaVersion: Int?
    /// Whether PI-Desktop's control port is answering.
    private(set) var isControlReady = false
    /// When a session last finished a turn, for the ring's one-shot.
    private(set) var finishedAt: Date?
    /// The row whose resume command was just copied, for a moment.
    private(set) var copiedID: String?
    /// The row whose open was just asked for without the control port, so
    /// the card can say why PI-Desktop only came forward.
    private(set) var openedWithoutControl: String?

    /// Set by the store: true while the panel is hidden or the display asleep.
    var isPaused = false {
        didSet { if !isPaused && oldValue { sample() } }
    }

    private static let interval: TimeInterval = 2

    private var timer: Timer?
    private var scan: Task<Void, Never>?
    private var generation = 0
    /// When each session was first seen active, so a session whose source
    /// does not state its turn's start still shows how long it has run.
    private var firstSeenActive: [String: Date] = [:]
    private var cliCache: [SessionSource: [String: CLISessionReader.CachedMetadata]] = [:]
    private let control: PiDesktopControl
    private let home: URL

    init(
        settings: SessionSettings = SessionSettings(),
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        self.settings = settings
        self.home = home
        control = PiDesktopControl(home: home)
    }

    // MARK: - What the panel shows

    /// The sessions the panel lists: everything not hidden or archived.
    var visible: [AgentSession] {
        sessions.filter { !settings.isExcluded($0.id) }
    }

    var activeCount: Int { visible.filter(\.state.isActive).count }
    var isAnyRunning: Bool { visible.contains { $0.state == .running } }
    var needsAttention: Bool { visible.contains { $0.state.needsAttention } }

    /// Whether the rail should stay drawn out for the sessions' sake.
    var holdsRailOpen: Bool {
        settings.isEnabled && settings.keepsRailOpenWhileActive && activeCount > 0
    }

    /// Whether a turn finished just now — six seconds, as the usage rings'
    /// mark uses for the same event.
    func justFinished(within span: TimeInterval = 6, now: Date = Date()) -> Bool {
        guard let finishedAt else { return false }
        let age = now.timeIntervalSince(finishedAt)
        return age >= 0 && age <= span
    }

    /// When the turn in flight started, as stated or as first seen.
    func startedAt(_ session: AgentSession) -> Date? {
        session.startedAt ?? firstSeenActive[session.id]
    }

    // MARK: - Clock

    func start() {
        guard settings.isEnabled else { stop(); return }
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        scan?.cancel()
        scan = nil
    }

    /// Reads now rather than at the next tick — a click on the ring.
    func refreshNow() {
        guard timer != nil else { return }
        sample()
    }

    @discardableResult
    func sample() -> Task<Void, Never>? {
        guard scan == nil, timer != nil, !isPaused, settings.isEnabled else { return scan }
        let generation = self.generation
        let sources = settings.sources
        let usesControl = settings.usesPiDesktopControl
        let isPiRunning = PiDesktopLauncher.isRunning
        let codexAppInstalled = DesktopAppLinks.isInstalled(DesktopAppLinks.codexBundleIdentifier)
        let cliCache = self.cliCache
        let control = self.control
        let home = self.home

        scan = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.read(
                sources: sources,
                usesControl: usesControl,
                isPiRunning: isPiRunning,
                codexAppInstalled: codexAppInstalled,
                cliCache: cliCache,
                control: control,
                home: home
            )
            await self?.record(result, generation: generation)
        }
        return scan
    }

    struct ScanResult: Sendable {
        var sessions: [AgentSession] = []
        var piSchemaVersion: Int?
        var isControlReady = false
        var cliCache: [SessionSource: [String: CLISessionReader.CachedMetadata]] = [:]
    }

    nonisolated private static func read(
        sources: Set<SessionSource>,
        usesControl: Bool,
        isPiRunning: Bool,
        codexAppInstalled: Bool,
        cliCache: [SessionSource: [String: CLISessionReader.CachedMetadata]],
        control: PiDesktopControl,
        home: URL
    ) async -> ScanResult {
        var result = ScanResult()
        let now = Date()

        if sources.contains(.piDesktop) {
            var snapshot = PiDesktopSessionReader.read(home: home, now: now, isAppRunning: isPiRunning)
            result.piSchemaVersion = snapshot.schemaVersion

            // The log is the fallback; the control port, where it answers, is
            // PI-Desktop's own count and replaces it.
            if usesControl, isPiRunning, await control.isAvailable() {
                result.isControlReady = true
                let inFlight = snapshot.sessions
                    .filter { $0.state == .running || $0.state == .approval }
                    .map(\.nativeID)
                if let waiting = await control.sessionsAwaitingApproval(among: inFlight) {
                    snapshot = PiDesktopSessionReader.read(
                        home: home, now: now, isAppRunning: isPiRunning, liveApprovals: waiting
                    )
                }
            }
            result.sessions += snapshot.sessions
        }

        // A few dozen small records; read fresh each scan so a session opened,
        // renamed or archived in the Claude app is reflected at once.
        let claudeDesktop = sources.contains(.claudeCode)
            ? DesktopAppLinks.claudeDesktopSessions(home: home) : [:]

        for source in [SessionSource.claudeCode, .codex] where sources.contains(source) {
            guard !Task.isCancelled else { break }
            let read = CLISessionReader.sessions(
                for: source, home: home, now: now, cache: cliCache[source] ?? [:],
                claudeDesktop: claudeDesktop, codexAppInstalled: codexAppInstalled
            )
            result.sessions += read.sessions
            result.cliCache[source] = read.cache
        }

        result.sessions = AgentSession.sorted(result.sessions)
        return result
    }

    private func record(_ result: ScanResult, generation: Int) {
        guard generation == self.generation, timer != nil else { return }
        scan = nil

        let now = Date()
        let previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ended: Set<String> = []

        for session in result.sessions {
            let was = previous[session.id]?.state.isActive ?? false
            if session.state.isActive {
                if !was || firstSeenActive[session.id] == nil { firstSeenActive[session.id] = now }
            } else {
                firstSeenActive[session.id] = nil
                // A transition this monitor saw, not an old outcome read on
                // the first scan: only that is worth a celebration.
                if was { ended.insert(session.id) }
            }
        }
        if !ended.isEmpty, ended.contains(where: { !settings.isExcluded($0) }) { finishedAt = now }

        // "Hidden until its next turn ends": a turn witnessed ending, or — for
        // PI-Desktop, whose database dates every turn — one that ended after
        // the session was hidden.
        let hiddenAt = Dictionary(settings.hidden.map { ($0.id, $0.at) }, uniquingKeysWith: { first, _ in first })
        var comeBack = ended.filter { hiddenAt[$0] != nil }
        for session in result.sessions where session.source == .piDesktop {
            if let at = hiddenAt[session.id], let endedAt = session.endedAt, endedAt > at { comeBack.insert(session.id) }
        }
        settings.unhide(comeBack)

        if result.sessions != sessions { sessions = result.sessions }
        if result.piSchemaVersion != piSchemaVersion { piSchemaVersion = result.piSchemaVersion }
        if result.isControlReady != isControlReady { isControlReady = result.isControlReady }
        cliCache = result.cliCache
    }

    // MARK: - Actions

    func session(withID id: String) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// Opens a session where it lives: PI-Desktop at that conversation when
    /// its control port is on, PI-Desktop brought forward when it is not; the
    /// Claude or Codex app at that session when one holds it; and for a
    /// terminal session the command that resumes it, on the clipboard.
    func open(_ id: String) {
        guard let session = session(withID: id) else { return }
        switch session.source {
        case .piDesktop:
            guard settings.usesPiDesktopControl, isControlReady else {
                PiDesktopLauncher.bringForward()
                flash(\.openedWithoutControl, id)
                return
            }
            let control = self.control
            let nativeID = session.nativeID
            Task {
                try? await control.openSession(nativeID)
                PiDesktopLauncher.bringForward()
            }
        case .claudeCode, .codex:
            if let link = session.appLink {
                NSWorkspace.shared.open(link)
            } else {
                copyResumeCommand(id)
            }
        }
    }

    func copyResumeCommand(_ id: String) {
        guard let command = session(withID: id)?.resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        flash(\.copiedID, id)
    }

    func hide(_ id: String) {
        guard let session = session(withID: id) else { return }
        settings.hide(session)
    }

    func archive(_ id: String) {
        guard let session = session(withID: id) else { return }
        settings.archive(session)
    }

    private var flashTask: Task<Void, Never>?

    /// Marks a row for a moment and then clears it.
    private func flash(_ property: ReferenceWritableKeyPath<SessionMonitor, String?>, _ id: String) {
        copiedID = nil
        openedWithoutControl = nil
        self[keyPath: property] = id
        // The explanation is a sentence to read; the tick is a glance.
        let seconds = property == \SessionMonitor.openedWithoutControl ? 4.0 : 1.6
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
            self?.openedWithoutControl = nil
        }
    }
}
