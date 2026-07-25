import SwiftUI
import AppKit

// MARK: - Tile Action

enum TileAction: Hashable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case centered, restoreOriginal, minimize
    case fill, fillRight, leftAndRight, quarters
}

extension TileAction {
    /// Tooltip text. Only the window-action row carries one: the geometry
    /// buttons draw exactly what they do, while "restore" and "minimize" are
    /// not something a shape can spell out.
    var tooltip: String? {
        switch self {
        case .centered:        return NSLocalizedString("tile.centered", comment: "")
        case .restoreOriginal: return NSLocalizedString("tile.restore", comment: "")
        case .minimize:        return NSLocalizedString("tile.minimize", comment: "")
        default:               return nil
        }
    }

    /// The SF Symbol drawn inside the mini-screen outline. Only Restore uses one:
    /// a hand-drawn counter-clockwise arc at 44×30 reads ambiguously (it looks
    /// like a clockwise "reload"), so that one glyph borrows Apple's, while the
    /// outline around it stays hand-drawn like every other icon.
    var symbolName: String? {
        switch self {
        case .restoreOriginal: return "arrow.counterclockwise"
        default:               return nil
        }
    }
}

// MARK: - TilingPanel

final class TilingPanel: NSPanel {

    var onAction: ((TileAction) -> Void)?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    /// - Parameter canRestore: whether the clicked window has a frame AnyDrag can
    ///   put it back to. False disables the Restore button — the state is read
    ///   once when the panel is built, which is fine because the panel is
    ///   short-lived (it closes on the next click or when the modifier is let go).
    init(canRestore: Bool) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        animationBehavior = .utilityWindow

        let panelView = TilingPanelView(canRestore: canRestore) { [weak self] action in
            self?.onAction?(action)
            self?.dismiss()
        }
        let hosting = NSHostingView(rootView: panelView)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    func show(at screenPoint: NSPoint) {
        let origin = NSPoint(
            x: screenPoint.x - frame.width / 2,
            y: screenPoint.y - frame.height / 2
        )
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.frame.contains(NSEvent.mouseLocation) else { return }
            self.dismiss()
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss() }
        }
    }

    func dismiss() {
        orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    override var canBecomeKey: Bool { false }
}

// MARK: - TilingPanelView

struct TilingPanelView: View {
    let canRestore: Bool
    let onAction: (TileAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(NSLocalizedString("Move & Resize", comment: ""))
            tileRow([.leftHalf, .rightHalf, .topHalf, .bottomHalf])
            Spacer().frame(height: 6)
            tileRow([.topLeft, .topRight, .bottomLeft, .bottomRight])
            Spacer().frame(height: 6)
            // Window actions. Three buttons in a four-column row: the empty
            // slot is deliberate — it holds the column width so these line up
            // with the rows above, and leaves room for a future action.
            tileRow([.centered, .restoreOriginal, .minimize])

            Divider().padding(.vertical, 8)

            sectionHeader(NSLocalizedString("Fill & Arrange", comment: ""))
            tileRow([.fill, .leftAndRight, .fillRight, .quarters])

//            Divider().padding(.vertical, 8)
//
//            menuRow(icon: "macwindow.on.rectangle", title: NSLocalizedString("Full Screen", comment: ""), showChevron: true)
//
//            if NSScreen.screens.count > 1,
//               let other = NSScreen.screens.first(where: { $0 != NSScreen.main }) {
//                menuRow(icon: "display", title: String(format: NSLocalizedString("Move to %@", comment: ""), other.localizedName))
//            }
        }
        .padding(12)
        .frame(width: 264)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.bottom, 8)
    }

    /// A row of tile buttons, padded out to `columns` slots so a short row still
    /// lines its buttons up with the full rows above it. The filler is an
    /// invisible, non-hit-testing spacer — not a disabled button, so there is
    /// nothing there to hover or click.
    @ViewBuilder
    private func tileRow(_ actions: [TileAction], columns: Int = 4) -> some View {
        HStack(spacing: 4) {
            ForEach(actions, id: \.self) { action in
                TileButton(action: action, isEnabled: isEnabled(action)) { onAction(action) }
            }
            ForEach(0..<max(0, columns - actions.count), id: \.self) { _ in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Restore is the only action that can be unavailable: AnyDrag has to have
    /// moved the window at least once to know what to put it back to.
    private func isEnabled(_ action: TileAction) -> Bool {
        action == .restoreOriginal ? canRestore : true
    }

    @ViewBuilder
    private func menuRow(icon: String, title: String, showChevron: Bool = false) -> some View {
        MenuRowButton {
            // TODO: implement
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - MenuRowButton

private struct MenuRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) { label() }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .onHover { isHovered = $0 }
    }
}

// MARK: - TileButton

private struct TileButton: View {
    let action: TileAction
    var isEnabled: Bool = true
    let onTap: () -> Void
    @State private var isHovered = false

    /// A disabled Restore button explains itself instead of leaving the user
    /// wondering why it won't click.
    private var helpText: String? {
        if action == .restoreOriginal, !isEnabled {
            return NSLocalizedString("tile.restore.unavailable", comment: "")
        }
        return action.tooltip
    }

    var body: some View {
        if let helpText {
            cell.help(helpText)
        } else {
            cell
        }
    }

    private var cell: some View {
        // The frame and padding live INSIDE the button's label, with a
        // `contentShape` matching the highlight: the whole visible cell
        // hit-tests, not just the opaque icon in the middle of it.
        Button(action: onTap) {
            TileIconView(action: action, isHovered: isHovered)
                .frame(width: 44, height: 30)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.accentColor : .clear)
        )
        // Never highlight what can't be clicked.
        .onHover { isHovered = isEnabled && $0 }
    }
}

// MARK: - TileIconView

private struct TileIconView: View {
    let action: TileAction
    let isHovered: Bool

    var body: some View {
        canvas
            // Actions whose meaning is an arrow get Apple's glyph centered in
            // the (hand-drawn) screen outline. The outline is inset evenly, so
            // the view's center is the outline's center.
            .overlay {
                if let symbol = action.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.white : Color(nsColor: .labelColor))
                }
            }
    }

    private var canvas: some View {
        Canvas { context, size in
            let screenRect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 1)
            let cr: CGFloat = 4    // screen corner radius
            let ir: CGFloat = 2    // block corner radius
            let pad: CGFloat = 3   // padding between screen border and blocks
            let gap: CGFloat = 2   // gap between blocks

            // Inner content area (where blocks are drawn)
            let content = screenRect.insetBy(dx: pad, dy: pad)

            let fill: Color = isHovered ? .white : Color(nsColor: .labelColor)
            let dim: Color = isHovered ? .white.opacity(0.35) : Color(nsColor: .secondaryLabelColor).opacity(0.3)
            let border: Color = isHovered ? .white.opacity(0.6) : Color(nsColor: .separatorColor)

            // Screen outline
            context.stroke(Path(roundedRect: screenRect, cornerRadius: cr),
                           with: .color(border), lineWidth: 1.2)

            switch action {
            // MARK: Move & Resize
            case .leftHalf:
                fillRect(context, CGRect(x: content.minX, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height),
                     color: fill, cr: ir)

            case .rightHalf:
                fillRect(context, CGRect(x: content.midX + gap / 2, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height),
                     color: fill, cr: ir)

            case .topHalf:
                fillRect(context, CGRect(x: content.minX, y: content.minY,
                     width: content.width, height: content.height / 2 - gap / 2),
                     color: fill, cr: ir)

            case .bottomHalf:
                fillRect(context, CGRect(x: content.minX, y: content.midY + gap / 2,
                     width: content.width, height: content.height / 2 - gap / 2),
                     color: fill, cr: ir)

            case .topLeft:
                fillRect(context, CGRect(x: content.minX, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height / 2 - gap / 2),
                     color: fill, cr: ir)

            case .topRight:
                fillRect(context, CGRect(x: content.midX + gap / 2, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height / 2 - gap / 2),
                     color: fill, cr: ir)

            case .bottomLeft:
                fillRect(context, CGRect(x: content.minX, y: content.midY + gap / 2,
                     width: content.width / 2 - gap / 2, height: content.height / 2 - gap / 2),
                     color: fill, cr: ir)

            case .bottomRight:
                fillRect(context, CGRect(x: content.midX + gap / 2, y: content.midY + gap / 2,
                     width: content.width / 2 - gap / 2, height: content.height / 2 - gap / 2),
                     color: fill, cr: ir)

            // MARK: Window actions
            case .centered:
                // Drawn at a fixed 75% regardless of the user's centered-size
                // setting: 5% steps are invisible at this size, and a block at
                // the 85% default leaves so little margin it reads as "fill".
                let cw = content.width * 0.75
                let ch = content.height * 0.75
                fillRect(context, CGRect(x: content.midX - cw / 2, y: content.midY - ch / 2,
                     width: cw, height: ch),
                     color: fill, cr: ir)

            case .minimize:
                // A window shrinking away downwards: a block up top with a
                // short arrow under it. Hand-drawn on purpose — the SF Symbol
                // "arrow into a line" glyph reads as *download*, not minimize.
                let bw = content.width * 0.56
                let bh = content.height * 0.45
                let block = CGRect(x: content.midX - bw / 2, y: content.minY + 1.2,
                                   width: bw, height: bh)
                fillRect(context, block, color: fill, cr: ir)

                let headHeight: CGFloat = 3.4
                let headHalfWidth: CGFloat = 2.8
                let tipY = content.maxY - 0.4
                var shaft = Path()
                shaft.move(to: CGPoint(x: content.midX, y: block.maxY + 2.4))
                shaft.addLine(to: CGPoint(x: content.midX, y: tipY - headHeight))
                context.stroke(shaft, with: .color(fill),
                               style: StrokeStyle(lineWidth: 1.7, lineCap: .round))

                var head = Path()
                head.move(to: CGPoint(x: content.midX - headHalfWidth, y: tipY - headHeight))
                head.addLine(to: CGPoint(x: content.midX + headHalfWidth, y: tipY - headHeight))
                head.addLine(to: CGPoint(x: content.midX, y: tipY))
                head.closeSubpath()
                context.fill(head, with: .color(fill))

            case .restoreOriginal:
                // Screen outline only — the SF Symbol overlay draws the rest.
                break

            // MARK: Fill & Arrange
            case .fill:
                fillRect(context, CGRect(x: content.minX, y: content.minY,
                     width: content.width, height: content.height),
                     color: fill, cr: ir)

            case .fillRight:
                fillRect(context, CGRect(x: content.minX, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height),
                     color: dim, cr: ir)
                fillRect(context, CGRect(x: content.midX + gap / 2, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height),
                     color: fill, cr: ir)

            case .leftAndRight:
                fillRect(context, CGRect(x: content.minX, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height),
                     color: fill, cr: ir)
                fillRect(context, CGRect(x: content.midX + gap / 2, y: content.minY,
                     width: content.width / 2 - gap / 2, height: content.height),
                     color: dim, cr: ir)

            case .quarters:
                let w = (content.width - gap) / 2
                let h = (content.height - gap) / 2
                let rects = [
                    CGRect(x: content.minX, y: content.minY, width: w, height: h),
                    CGRect(x: content.midX + gap / 2, y: content.minY, width: w, height: h),
                    CGRect(x: content.minX, y: content.midY + gap / 2, width: w, height: h),
                    CGRect(x: content.midX + gap / 2, y: content.midY + gap / 2, width: w, height: h),
                ]
                for (i, r) in rects.enumerated() {
                    fillRect(context, r, color: i == 0 ? fill : dim, cr: 1.5)
                }
            }
        }
    }

    private func fillRect(_ context: GraphicsContext, _ rect: CGRect, color: Color, cr: CGFloat) {
        context.fill(Path(roundedRect: rect, cornerRadius: cr), with: .color(color))
    }
}
