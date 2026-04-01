import SwiftUI
import AppKit

// MARK: - Tile Action

enum TileAction: Hashable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case fill, fillRight, leftAndRight, quarters
}

// MARK: - TilingPanel

final class TilingPanel: NSPanel {

    var onAction: ((TileAction) -> Void)?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    init() {
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

        let panelView = TilingPanelView { [weak self] action in
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
    let onAction: (TileAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Move & Resize")
            tileRow([.leftHalf, .rightHalf, .topHalf, .bottomHalf])

            Divider().padding(.vertical, 8)

            sectionHeader("Fill & Arrange")
            tileRow([.fill, .fillRight, .leftAndRight, .quarters])

            Divider().padding(.vertical, 8)

            menuRow(icon: "macwindow.on.rectangle", title: "Full Screen", showChevron: true)

            if NSScreen.screens.count > 1,
               let other = NSScreen.screens.first(where: { $0 != NSScreen.main }) {
                menuRow(icon: "display", title: "Move to \(other.localizedName)")
            }
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

    @ViewBuilder
    private func tileRow(_ actions: [TileAction]) -> some View {
        HStack(spacing: 4) {
            ForEach(actions, id: \.self) { action in
                TileButton(action: action) { onAction(action) }
            }
        }
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
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            TileIconView(action: action, isHovered: isHovered)
                .frame(width: 44, height: 30)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.accentColor : .clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - TileIconView

private struct TileIconView: View {
    let action: TileAction
    let isHovered: Bool

    var body: some View {
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
