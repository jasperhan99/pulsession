import Foundation
import Observation

/// A session the reader has taken off the panel. It stays in Settings, where
/// it can be put back; the conversation itself is never touched.
struct SessionVisibilityEntry: Codable, Sendable, Equatable, Identifiable {
    /// `AgentSession.id`: source and native id together.
    let id: String
    /// Remembered so Settings can name a session that has since dropped out
    /// of what the readers list.
    var title: String
    var project: String?
    var source: SessionSource?
    /// When it was taken off. A hidden session comes back when a turn ends
    /// after this.
    var at: Date
}

/// The session monitor's own settings.
///
/// Kept apart from `AppSettings` on purpose: that class is upstream Pulse's,
/// and everything this fork adds lives where a merge from upstream will not
/// run into it. The one thing the panel's geometry needs — whether the rail
/// carries a sessions ring — reaches `AppSettings.extraRailSlots` through
/// `onRailChange`.
@MainActor
@Observable
final class SessionSettings {
    /// Whether the rail carries the sessions ring and the monitor reads
    /// anything at all.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.isEnabled)
            onRailChange?()
        }
    }

    /// Which apps and CLIs are read.
    var sources: Set<SessionSource> {
        didSet {
            guard sources != oldValue else { return }
            defaults.set(sources.map(\.rawValue).sorted(), forKey: Key.sources)
        }
    }

    /// Keep the rail drawn out, rather than wound down to its sliver, while
    /// a session is working or waiting on a person.
    var keepsRailOpenWhileActive: Bool {
        didSet {
            guard keepsRailOpenWhileActive != oldValue else { return }
            defaults.set(keepsRailOpenWhileActive, forKey: Key.keepsRailOpen)
        }
    }

    /// Use PI-Desktop's control port whenever it is serving one, to open a
    /// session by id and to read pending approvals exactly. Using it never
    /// starts it; see `PiDesktopLauncher.relaunchWithControl`.
    var usesPiDesktopControl: Bool {
        didSet {
            guard usesPiDesktopControl != oldValue else { return }
            defaults.set(usesPiDesktopControl, forKey: Key.usesControl)
        }
    }

    /// The animated mark in the sessions ring instead of its symbol, as the
    /// usage rings offer per account. Off by default, as there.
    var showsBotMark: Bool {
        didSet {
            guard showsBotMark != oldValue else { return }
            defaults.set(showsBotMark, forKey: Key.botMark)
        }
    }

    private(set) var hidden: [SessionVisibilityEntry] {
        didSet { save(hidden, forKey: Key.hidden) }
    }
    private(set) var archived: [SessionVisibilityEntry] {
        didSet { save(archived, forKey: Key.archived) }
    }

    /// Called when `isEnabled` changes, which adds or removes a ring.
    var onRailChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        let stored = (defaults.array(forKey: Key.sources) as? [String])?.compactMap(SessionSource.init(rawValue:))
        sources = stored.map(Set.init) ?? Set(SessionSource.allCases)
        keepsRailOpenWhileActive = defaults.object(forKey: Key.keepsRailOpen) as? Bool ?? true
        usesPiDesktopControl = defaults.object(forKey: Key.usesControl) as? Bool ?? true
        showsBotMark = defaults.object(forKey: Key.botMark) as? Bool ?? false
        hidden = Self.load(forKey: Key.hidden, from: defaults)
        archived = Self.load(forKey: Key.archived, from: defaults)
    }

    func reads(_ source: SessionSource) -> Bool { sources.contains(source) }

    func setReads(_ reads: Bool, _ source: SessionSource) {
        if reads { sources.insert(source) } else { sources.remove(source) }
    }

    /// Whether the panel leaves this session out.
    func isExcluded(_ id: String) -> Bool {
        hidden.contains { $0.id == id } || archived.contains { $0.id == id }
    }

    func hide(_ session: AgentSession, at date: Date = Date()) {
        put(session, in: \.hidden, at: date)
    }

    func archive(_ session: AgentSession, at date: Date = Date()) {
        put(session, in: \.archived, at: date)
    }

    func restore(_ id: String) {
        hidden.removeAll { $0.id == id }
        archived.removeAll { $0.id == id }
    }

    /// Brings back hidden sessions whose next turn has ended. Called by the
    /// monitor with the ids it saw end a turn.
    func unhide(_ ids: Set<String>) {
        guard hidden.contains(where: { ids.contains($0.id) }) else { return }
        hidden.removeAll { ids.contains($0.id) }
    }

    /// One list or the other, never both: moving a session between them
    /// replaces its entry.
    private func put(_ session: AgentSession, in list: ReferenceWritableKeyPath<SessionSettings, [SessionVisibilityEntry]>, at date: Date) {
        restore(session.id)
        self[keyPath: list].append(SessionVisibilityEntry(
            id: session.id,
            title: session.title,
            project: session.project,
            source: session.source,
            at: date
        ))
        // A list that only grows is a preference file that only grows. The
        // oldest entries go first; they are the ones least likely to matter.
        if self[keyPath: list].count > Self.listLimit {
            self[keyPath: list].removeFirst(self[keyPath: list].count - Self.listLimit)
        }
    }

    static let listLimit = 200

    private func save(_ entries: [SessionVisibilityEntry], forKey key: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(forKey key: String, from defaults: UserDefaults) -> [SessionVisibilityEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([SessionVisibilityEntry].self, from: data)
        else { return [] }
        return entries
    }

    private enum Key {
        static let isEnabled = "sessions.enabled"
        static let sources = "sessions.sources"
        static let keepsRailOpen = "sessions.keepsRailOpenWhileActive"
        static let usesControl = "sessions.usesPiDesktopControl"
        static let botMark = "sessions.showsBotMark"
        static let hidden = "sessions.hidden"
        static let archived = "sessions.archived"
    }
}
