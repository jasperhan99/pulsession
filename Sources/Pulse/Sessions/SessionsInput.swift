import AppKit
import SwiftUI

/// Where the sessions card's rows are, in the panel's top-left coordinates —
/// the space `FloatingPanel` measures its events in, and the one
/// `BotMarkView.panelSpace` names on the SwiftUI side.
///
/// Written by the rows as they are laid out, read by the window when a press
/// arrives. Deliberately not observable: nothing is drawn from it.
@MainActor
final class SessionCardHitMap {
    private var rows: [String: CGRect] = [:]

    func set(_ frame: CGRect?, for id: String) {
        rows[id] = frame
    }

    func clear() {
        rows.removeAll()
    }

    /// The row under a point. Rows never overlap, so there is at most one.
    func row(at point: CGPoint?) -> String? {
        guard let point else { return nil }
        return rows.first { $0.value.contains(point) }?.key
    }
}

/// Publishes a row's frame in the panel's space as it lays out and moves, and
/// withdraws it when the row goes.
struct RowFrameReporter: View {
    let id: String
    let hitMap: SessionCardHitMap

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BotMarkView.panelSpace))
            Color.clear
                .onAppear { hitMap.set(frame, for: id) }
                .onChange(of: frame) { _, frame in hitMap.set(frame, for: id) }
                .onDisappear { hitMap.set(nil, for: id) }
        }
    }
}

extension PanelHitArea {
    /// Whether a point is on the ring at `index` of a rail holding `count`
    /// rings. The same geometry as `slot(at:…)`, for a ring that is not an
    /// account's.
    static func isOnRing(
        at point: CGPoint,
        index: Int,
        count: Int,
        edge: PanelEdge,
        railTop: CGFloat,
        railLeading: CGFloat,
        docked: Bool
    ) -> Bool {
        let size = DockLayout.size(for: count, on: edge.axis, docked: docked)
        let rail = rail(edge: edge, railSize: size, railTop: railTop, railLeading: railLeading)
        guard rail.contains(point) else { return false }

        let radius = DockLayout.ringDiameter / 2 * 1.08
        let across = DockLayout.ringCentreAcross(on: edge.axis)
        let along = DockLayout.firstRingAlong(docked: docked, on: edge.axis)
            + CGFloat(index) * DockLayout.ringStep(on: edge.axis)
        let centre = edge.isVertical
            ? CGPoint(x: rail.minX + across, y: rail.minY + along)
            : CGPoint(x: rail.minX + along, y: rail.minY + across)
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        return dx * dx + dy * dy <= radius * radius
    }
}

/// A menu item that runs a closure, so a menu built for one row can carry
/// that row's actions without a target object per row.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}

/// The menu a secondary click on a session row puts up.
@MainActor
enum SessionRowMenu {
    static func make(for id: String, monitor: SessionMonitor) -> NSMenu? {
        guard let session = monitor.session(withID: id) else { return nil }
        let menu = NSMenu()

        switch session.source {
        case .piDesktop:
            menu.addItem(ClosureMenuItem(String.localized("Open in PI-Desktop")) { monitor.open(id) })
        case .claudeCode, .codex:
            if session.appLink != nil {
                let app = DesktopAppLinks.appName(for: session.source)
                menu.addItem(ClosureMenuItem(String.localized("Open in \(app)")) { monitor.open(id) })
            }
            menu.addItem(ClosureMenuItem(String.localized("Copy resume command")) { monitor.copyResumeCommand(id) })
            if let path = session.projectPath {
                menu.addItem(ClosureMenuItem(String.localized("Show project in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String.localized("Hide until its next turn ends")) { monitor.hide(id) })
        menu.addItem(ClosureMenuItem(String.localized("Archive in Pulsession")) { monitor.archive(id) })
        menu.addItem(.separator())
        if let openSettings {
            menu.addItem(ClosureMenuItem(String.localized("Hidden and archived sessions…"), handler: openSettings))
        }
        return menu
    }

    /// Opens Settings on the sessions pane. Set by the app delegate, which
    /// owns the settings window; a URL round trip through `pulsession://`
    /// would do nothing in a loose `swift run` build, which registers no
    /// scheme.
    static var openSettings: (() -> Void)?
}
