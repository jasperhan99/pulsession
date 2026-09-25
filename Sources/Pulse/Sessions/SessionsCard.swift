import SwiftUI

/// Budgets for the sessions card, derived from `DetailCardLayout` so the card
/// fits the panel the usage card already sized — never larger than
/// `DetailCardLayout.maximumHeight`, which is what the window was built for.
enum SessionCardLayout {
    /// A row: its title line, the state line under it, and the padding round
    /// both. Rounded up from the fonts' rendered heights, as every budget on
    /// the panel is (see `DockLayout.percentTextHeight`).
    static var rowHeight: CGFloat {
        DetailCardLayout.rowTextLineHeight + 2 * PanelMetrics.scale
            + DetailCardLayout.footnoteHeight + 10 * PanelMetrics.scale
    }
    static var rowSpacing: CGFloat { 2 * PanelMetrics.scale }
    static var markSize: CGFloat { 14 * PanelMetrics.scale }
    static var badgeFontSize: CGFloat { 10 * PanelMetrics.scale }

    /// Everything on the card that is not a row.
    private static var fixedHeight: CGFloat {
        DetailCardLayout.padding * 2
            + DetailCardLayout.headerHeight
            + DetailCardLayout.contentSpacing * 2
            + DetailCardLayout.footnoteHeight
    }

    /// How many rows fit in the height the panel already has room for.
    static var maximumRows: Int {
        let room = DetailCardLayout.maximumHeight - fixedHeight
        return max(1, Int((room + rowSpacing) / (rowHeight + rowSpacing)))
    }
}

/// The card that opens beside the sessions ring: every visible session, most
/// urgent first, each saying what it is doing and for how long.
///
/// **No controls of its own.** Presses on this panel belong to the window
/// (`FloatingPanel.sendEvent`); SwiftUI's own input is not reliable on a
/// non-key accessory panel (Docs/ui/input.md). So the rows only publish where
/// they are, through `SessionCardHitMap`, and the window turns a click or a
/// secondary click on one into an action.
struct SessionsCard: View {
    var usesGlass: Bool = false
    let sessions: [AgentSession]
    let totalCount: Int
    let monitor: SessionMonitor
    let edge: PanelEdge
    let pointerCenter: CGFloat
    /// The pointer in panel coordinates, for the row under it to light up.
    let pointer: CGPoint?
    let hitMap: SessionCardHitMap
    var animatesActivity: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DetailCardLayout.contentSpacing) {
            header

            if sessions.isEmpty {
                Text(totalCount > 0
                     ? String.localized("All sessions are hidden or archived")
                     : String.localized("No sessions in the last day"))
                    .font(.system(size: DetailCardLayout.messageFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: SessionCardLayout.rowSpacing) {
                        ForEach(shown) { session in
                            SessionRow(
                                session: session,
                                startedAt: monitor.startedAt(session),
                                now: context.date,
                                isHovered: hitMap.row(at: pointer) == session.id,
                                isCopied: monitor.copiedID == session.id,
                                animatesActivity: animatesActivity
                            )
                            .background(RowFrameReporter(id: session.id, hitMap: hitMap))
                        }
                    }
                }
            }

            Text(footnote)
                .font(.system(size: DetailCardLayout.footnoteFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(.primary.opacity(0.4))
                .lineLimit(1)
        }
        .padding(DetailCardLayout.padding)
        .frame(width: DetailCardLayout.width, alignment: .leading)
        .padding(Self.pointerSide(for: edge), DetailCardLayout.pointerWidth)
        .mask { bubble }
        .background(PanelSurface(shape: bubble, usesGlass: usesGlass))
        .onDisappear { hitMap.clear() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String.localized("Sessions"))
    }

    private var shown: [AgentSession] {
        Array(sessions.prefix(SessionCardLayout.maximumRows))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .resizable()
                .scaledToFit()
                .frame(width: DetailCardLayout.headerIconSize, height: DetailCardLayout.headerIconSize)
            Text(localized: "Sessions")
                .lineLimit(1)
                .font(.system(size: DetailCardLayout.titleFontSize, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            let active = sessions.filter(\.state.isActive).count
            if active > 0 {
                Text(localized: "\(String(active)) active")
                    .font(.system(size: DetailCardLayout.rowFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line, always — it is budgeted as one. What was just done, when
    /// something was; otherwise how many did not fit, or how to use the rows.
    private var footnote: String {
        if let id = monitor.openedWithoutControl, sessions.contains(where: { $0.id == id }) {
            return String.localized("Turn on PI-Desktop control in Settings to open the session itself")
        }
        if monitor.copiedID != nil {
            return String.localized("Resume command copied")
        }
        let hiddenCount = sessions.count - shown.count
        if hiddenCount > 0 {
            return String.localized("\(String(hiddenCount)) more in Settings")
        }
        return String.localized("Click to open · Right-click for more")
    }

    private var bubble: UsageBubbleShape {
        UsageBubbleShape(
            edge: edge,
            pointerCenter: pointerCenter,
            cornerRadius: DetailCardLayout.cornerRadius,
            pointerWidth: DetailCardLayout.pointerWidth,
            pointerHeight: DetailCardLayout.pointerHeight
        )
    }

    private static func pointerSide(for edge: PanelEdge) -> Edge.Set {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        }
    }
}

/// One session: what it is, what it is doing, and for how long.
private struct SessionRow: View {
    let session: AgentSession
    let startedAt: Date?
    let now: Date
    let isHovered: Bool
    let isCopied: Bool
    let animatesActivity: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 9 * PanelMetrics.scale) {
            SessionStateMark(state: session.state, animatesActivity: animatesActivity)
                .frame(width: SessionCardLayout.markSize, height: SessionCardLayout.markSize)

            VStack(alignment: .leading, spacing: 2 * PanelMetrics.scale) {
                HStack(spacing: 5 * PanelMetrics.scale) {
                    if let project = session.project {
                        Text(verbatim: project)
                            .font(.system(size: SessionCardLayout.badgeFontSize, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 5 * PanelMetrics.scale)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.12)))
                            // Capped, and the first to give way: the title is
                            // what tells two sessions of one project apart.
                            .frame(maxWidth: DetailCardLayout.width * 0.38, alignment: .leading)
                    }
                    Text(verbatim: session.title)
                        .font(.system(size: DetailCardLayout.rowFontSize, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }

                HStack(spacing: 4 * PanelMetrics.scale) {
                    Text(isCopied ? String.localized("Copied") : session.state.label)
                        .foregroundStyle(isCopied ? Color.pulseGood : SessionTint.color(for: session.state))
                    Text(verbatim: "·").foregroundStyle(.primary.opacity(0.3))
                    Text(verbatim: session.source.displayName).foregroundStyle(.primary.opacity(0.45))
                }
                .font(.system(size: DetailCardLayout.footnoteFontSize, weight: .regular, design: .rounded))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(verbatim: timeText)
                .font(.system(size: DetailCardLayout.footnoteFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(.primary.opacity(0.5))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(2)
        }
        .padding(.horizontal, 7 * PanelMetrics.scale)
        .frame(height: SessionCardLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9 * PanelMetrics.scale, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var timeText: String {
        if session.state.isActive, let startedAt {
            return SessionTime.clock(now.timeIntervalSince(startedAt))
        }
        return SessionTime.ago(from: session.updatedAt, now: now)
    }

    private var accessibilityText: String {
        let place = session.project.map { "\($0), " } ?? ""
        return "\(place)\(session.title), \(session.state.label), \(timeText)"
    }
}

/// The small mark before each row, drawn from the same pieces as the rings.
struct SessionStateMark: View {
    let state: SessionState
    var animatesActivity: Bool = true

    @State private var spinning = false
    @State private var breathing = false

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let line = max(size * 0.16, 1.5)
            ZStack {
                switch state {
                case .running:
                    Circle().stroke(Color.primary.opacity(0.18), lineWidth: line)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(
                            animatesActivity ? .linear(duration: 1).repeatForever(autoreverses: false) : nil,
                            value: spinning
                        )
                        .onAppear { spinning = animatesActivity }
                        .onDisappear { spinning = false }
                case .approval, .waitingInput:
                    Circle().stroke(Color.pulseCaution, lineWidth: line)
                    Circle()
                        .fill(Color.pulseCaution)
                        .frame(width: size * 0.36, height: size * 0.36)
                        .opacity(breathing ? 1 : 0.35)
                        .animation(
                            animatesActivity ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil,
                            value: breathing
                        )
                        .onAppear { breathing = animatesActivity }
                        .onDisappear { breathing = false }
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.8, weight: .bold))
                        .foregroundStyle(Color.pulseGood)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.75, weight: .bold))
                        .foregroundStyle(Color.pulseWarning)
                case .interrupted:
                    RoundedRectangle(cornerRadius: size * 0.12)
                        .stroke(Color.primary.opacity(0.45), lineWidth: line)
                        .frame(width: size * 0.62, height: size * 0.62)
                case .idle:
                    Circle()
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: size * 0.4, height: size * 0.4)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// How long ago, and how long for, in the panel's own locale.
enum SessionTime {
    /// "04:12", or "1:04:12" past the hour.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func ago(from date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String.localized("just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizationSource.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
