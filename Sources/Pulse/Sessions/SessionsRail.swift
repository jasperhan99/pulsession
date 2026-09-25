import SwiftUI

/// What the rail needs to draw the sessions ring. Built by the panel from the
/// monitor, so the rail itself never reads the monitor.
struct SessionsRailItem: Equatable {
    /// The ring's slot id. Cannot collide with an account's, which is a
    /// provider's raw value with an optional `#…` or `@…` suffix.
    static let slotID = "pulsession.sessions"

    /// The visible sessions' states, most urgent first. One segment each, up
    /// to `SessionsRingView.maximumSegments`.
    var states: [SessionState]
    var activeCount: Int
    var isAnyRunning: Bool
    var needsAttention: Bool
    var showsBotMark: Bool
    var botEvent: BotMarkEvent?

    var hasSessions: Bool { !states.isEmpty }
}

/// Colour on the sessions ring and card, in the panel's own vocabulary.
///
/// White is what Pulse uses for "working" — its activity mark — so a running
/// session is white here too. Amber and red keep the meanings they have on the
/// usage rings: something to look at, and something wrong. Green is the one
/// reading Pulse gives when all is well.
enum SessionTint {
    static func color(for state: SessionState) -> Color {
        switch state {
        case .approval, .waitingInput: .pulseCaution
        case .running: .primary.opacity(0.92)
        case .failed: .pulseWarning
        case .interrupted: .primary.opacity(0.4)
        case .done: .pulseGood
        case .idle: .primary.opacity(0.22)
        }
    }

    /// The body colour of the sessions ring's animated mark. Not a provider's
    /// brand — the ring belongs to no provider — so a colour of its own, light
    /// enough to read on the disc behind it.
    static let botBody = Color(red: 0.60, green: 0.66, blue: 1.00)
}

/// The sessions ring and its label, laid out exactly as a usage ring's item
/// is so the rail's budgets and hit testing hold for it unchanged.
struct SessionsDockItem: View {
    let item: SessionsRailItem
    let isSelected: Bool
    /// False while the rail is collapsed; an invisible ring must not open a
    /// card. See `UsageDockItem.isInteractive`.
    let isInteractive: Bool
    var showsLabel: Bool = true
    var animatesActivity: Bool = true
    let botPersona: BotMarkPersona
    let botGaze: BotMarkGaze
    let pointer: CGPoint?
    let isQuiet: Bool
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: DockLayout.ringToTextSpacing) {
            if DockLayout.labelLeads { label }
            ring
            if !DockLayout.labelLeads { label }
        }
        .contentShape(.rect)
        .background {
            if isInteractive { PointerEntryReporter(onEnter: onEnter) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String.localized("Sessions"))
        .accessibilityValue(String.localized("\(String(item.activeCount)) active"))
    }

    private var ring: some View {
        SessionsRingView(
            item: item,
            diameter: DockLayout.ringDiameter,
            lineWidth: DockLayout.ringLineWidth,
            animatesActivity: animatesActivity,
            highlight: isSelected,
            botPersona: botPersona,
            botGaze: botGaze,
            botPointer: pointer,
            botQuiet: isQuiet
        )
        .scaleEffect(isSelected ? 1.06 : 1)
    }

    /// How many sessions are working or waiting — a count, never a
    /// percentage: there is no allowance here to measure against.
    @ViewBuilder
    private var label: some View {
        if showsLabel {
            Text(verbatim: String(item.activeCount))
                .font(.system(size: DockLayout.percentFontSize, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(
                    item.needsAttention ? Color.pulseCaution
                        : .primary.opacity(item.activeCount == 0 ? 0.4 : 1)
                )
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: item.activeCount)
        }
    }
}

/// A ring whose segments are sessions: one arc per visible session, coloured
/// by what it is doing, with Pulse's travelling white mark while any of them
/// is running.
struct SessionsRingView: View {
    let item: SessionsRailItem
    let diameter: CGFloat
    let lineWidth: CGFloat
    var animatesActivity: Bool = true
    var highlight: Bool = false
    var botPersona: BotMarkPersona = .calm
    var botGaze: BotMarkGaze = .ahead
    var botPointer: CGPoint?
    var botQuiet = false

    @State private var spinning = false
    @State private var calling = false

    /// Past this many the arcs are too short to read as separate sessions.
    static let maximumSegments = 12

    /// Same proportions as `UsageRingView`, so the two kinds of ring sit on
    /// the rail as one family.
    private static let centreGap: CGFloat = 4
    private static let iconScale: CGFloat = 0.62
    private static let botScale: CGFloat = 1.4
    private static let busySweep: CGFloat = 0.22
    private static let busyPeriod: TimeInterval = 1.0
    private static let haloRadius: CGFloat = 10

    private var centreDiameter: CGFloat {
        max(diameter - (lineWidth + Self.centreGap) * 2, 0)
    }

    private var busyDiameter: CGFloat {
        max(diameter - lineWidth * 1.5 - Self.centreGap, 0)
    }

    private var segments: [SessionState] {
        Array(item.states.prefix(Self.maximumSegments))
    }

    /// The halo: amber while something waits on a person, otherwise the
    /// colour of the most urgent session, as a usage ring glows its arc's.
    private var haloColour: Color {
        segments.first.map(SessionTint.color(for:)) ?? .primary
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: lineWidth)

            segmentArcs
                .rotationEffect(.degrees(-90))
                .shadow(color: haloColour.opacity(highlight ? 0.42 : 0), radius: Self.haloRadius)
                .animation(.easeOut(duration: 0.35), value: segments)

            centre

            if item.isAnyRunning && !item.showsBotMark && animatesActivity {
                Circle()
                    .trim(from: 0, to: Self.busySweep)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: max(lineWidth * 0.5, 1.5), lineCap: .round))
                    .frame(width: busyDiameter, height: busyDiameter)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    // Core Animation, and reset on the way out — see
                    // `UsageRingView`'s activity mark for why both matter.
                    .animation(.linear(duration: Self.busyPeriod).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }
                    .transition(.opacity)
            }
        }
        .frame(width: diameter, height: diameter)
        // A slow amber breath outside the ring while a session waits on a
        // person: the one state worth pulling an eye across the screen for.
        .overlay {
            if item.needsAttention && animatesActivity {
                Circle()
                    .stroke(Color.pulseCaution, lineWidth: max(lineWidth * 0.5, 1.5))
                    .frame(width: diameter + lineWidth * 2, height: diameter + lineWidth * 2)
                    .opacity(calling ? 0.85 : 0.1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: calling)
                    .onAppear { calling = true }
                    .onDisappear { calling = false }
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var segmentArcs: some View {
        let count = segments.count
        // A gap between arcs only when there is more than one to separate.
        let gap: CGFloat = count > 1 ? 0.035 : 0
        ZStack {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, state in
                let start = CGFloat(index) / CGFloat(count) + gap / 2
                let end = CGFloat(index + 1) / CGFloat(count) - gap / 2
                Circle()
                    .trim(from: start, to: max(end, start))
                    .stroke(
                        SessionTint.color(for: state),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: count == 1 ? .round : .butt)
                    )
            }
        }
    }

    @ViewBuilder
    private var centre: some View {
        if item.showsBotMark {
            BotMarkView(
                mood: BotMarkMood.resolve(
                    isBusy: item.isAnyRunning,
                    isRefreshing: false,
                    isSpent: false,
                    hasReading: item.hasSessions
                ),
                persona: botPersona,
                bodyShape: .default,
                gaze: botGaze,
                event: item.botEvent,
                pointer: botPointer,
                isPointedAt: highlight,
                isQuiet: botQuiet,
                tint: SessionTint.botBody,
                eyeTint: BotMarkTint.eyes(on: SessionTint.botBody),
                size: centreDiameter * Self.botScale
            )
        } else {
            Image(systemName: "text.bubble")
                .resizable()
                .scaledToFit()
                .frame(width: centreDiameter * Self.iconScale, height: centreDiameter * Self.iconScale)
                .foregroundStyle(.primary.opacity(item.hasSessions ? 1 : 0.35))
        }
    }
}
