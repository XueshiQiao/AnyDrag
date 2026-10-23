import AppKit
import SwiftUI

// MARK: - Candidate Model

struct SnapAssistCandidate: Identifiable {
    let windowID: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let axWindow: AXUIElement
    let appName: String
    let windowTitle: String
    let appIcon: NSImage?
    let thumbnail: NSImage?

    var id: CGWindowID { windowID }

    /// Header / primary label: prefer the specific window title when non-empty,
    /// falling back to the application name.
    var displayTitle: String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return appName }
        return trimmed
    }

    /// True when the window title differs from the app name (so the fallback
    /// card can show the app name as a secondary subtitle without duplicating).
    var hasDistinctAppSubtitle: Bool {
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApp.isEmpty else { return false }
        return displayTitle.caseInsensitiveCompare(trimmedApp) != .orderedSame
    }

    /// Clamped width-to-height aspect ratio of the source window so portrait
    /// windows render narrower and wide windows render wider (matching
    /// Windows 11 Snap Assist).
    var clampedAspectRatio: CGFloat {
        guard frame.height > 1 else { return 1.45 }
        let raw = frame.width / frame.height
        return min(max(raw, 0.68), 1.85)
    }
}

// MARK: - SnapAssistOverlay

/// Windows 11 Snap Assist–style picker shown on the opposite half of the screen
/// after the user tiles a window to the left or right half. Displays live
/// window thumbnails when Screen Recording permission is granted, or a clean
/// single-icon card fallback when it is not.
final class SnapAssistOverlay {

    private var panel: SnapAssistPanel?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func show(
        candidates: [SnapAssistCandidate],
        in oppositeScreenRectNS: NSRect,
        onSelect: @escaping (SnapAssistCandidate) -> Void
    ) {
        hide()
        guard !candidates.isEmpty else { return }

        let insetRect = oppositeScreenRectNS.insetBy(dx: 14, dy: 14)
        guard insetRect.width > 120, insetRect.height > 120 else { return }

        let newPanel = SnapAssistPanel(
            frame: insetRect,
            candidates: candidates,
            onSelect: { [weak self] candidate in
                self?.hide()
                onSelect(candidate)
            },
            onCancel: { [weak self] in
                self?.hide()
            }
        )
        panel = newPanel
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        installMonitors(onSelectFirst: { [weak self] in
            guard let first = candidates.first else { return }
            self?.hide()
            onSelect(first)
        })
    }

    func hide() {
        removeMonitors()
        guard let existing = panel else { return }
        panel = nil
        existing.orderOut(nil)
    }

    private func installMonitors(onSelectFirst: @escaping () -> Void) {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.hide()
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if event.keyCode == 53 { // Esc
                self.hide()
            } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                onSelectFirst()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.keyCode == 53 {
                self.hide()
                return nil
            } else if event.keyCode == 36 || event.keyCode == 76 {
                onSelectFirst()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    // MARK: - Live Thumbnail Capture (Silent / Preflight-only)

    private typealias CreateWindowImageFn = @convention(c) (
        CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private static let createWindowImageFn: CreateWindowImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(sym, to: CreateWindowImageFn.self)
    }()

    /// Captures a live thumbnail of `windowID` when Screen Recording permission
    /// is granted (`CGPreflightScreenCaptureAccess()`).
    static func captureThumbnail(for windowID: CGWindowID) -> NSImage? {
        guard CGPreflightScreenCaptureAccess(),
              let fn = createWindowImageFn else { return nil }
        // `.optionIncludingWindow` = 1 << 3 (8)
        // `.boundsIgnoreFraming` = 1 << 0 (1), `.nominalResolution` = 1 << 4 (16)
        let listOption = CGWindowListOption(rawValue: 1 << 3)
        let imageOption = CGWindowImageOption(rawValue: (1 << 0) | (1 << 4))
        guard let cgImage = fn(.null, listOption, windowID, imageOption)?.takeRetainedValue(),
              cgImage.width > 16, cgImage.height > 16 else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// MARK: - SnapAssistPanel

private final class SnapAssistPanel: NSPanel {

    init(
        frame: NSRect,
        candidates: [SnapAssistCandidate],
        onSelect: @escaping (SnapAssistCandidate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true

        let rootView = SnapAssistContentView(
            candidates: candidates,
            containerSize: frame.size,
            onSelect: onSelect,
            onCancel: onCancel
        )
        let hosting = FirstMouseHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
}

/// Ensures the very first click inside the non-activating SnapAssistPanel fires
/// the SwiftUI button action immediately without requiring a first click to
/// activate the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI Views

private struct SnapAssistContentView: View {
    let candidates: [SnapAssistCandidate]
    let containerSize: CGSize
    let onSelect: (SnapAssistCandidate) -> Void
    let onCancel: () -> Void

    private var columnsCount: Int {
        switch candidates.count {
        case 1, 2:
            // Half-screen is tall and narrow (~8:10); 1 or 2 windows look much
            // larger and cleaner stacked in a single column than squeezed side
            // by side.
            return 1
        case 3...6:
            return 2
        default:
            return 3
        }
    }

    private var rowsCount: Int {
        max(1, Int(ceil(Double(candidates.count) / Double(columnsCount))))
    }

    /// Computes a uniform, aligned card size for the grid so every row and
    /// column lines up cleanly, sized to a natural 16:10 window aspect ratio
    /// plus the 30pt header bar.
    private var uniformCardSize: CGSize {
        let outerPadding: CGFloat = 28
        let spacing: CGFloat = 18
        let headerHeight: CGFloat = 30

        let availableW = max(220, containerSize.width - outerPadding * 2 - CGFloat(columnsCount - 1) * spacing)
        let availableH = max(200, containerSize.height - outerPadding * 2 - CGFloat(rowsCount - 1) * spacing)

        let slotW = availableW / CGFloat(columnsCount)
        let slotH = availableH / CGFloat(rowsCount)

        let maxCardW: CGFloat = {
            switch candidates.count {
            case 1: return min(slotW, 560)
            case 2: return min(slotW, 480)
            default: return min(slotW, 420)
            }
        }()

        // Target a 16:10 preview area (aspect 1.6) under the 30pt header bar.
        // If vertical space is tighter, shrink width proportionally so cards
        // never turn into tall square boxes.
        let targetAspect: CGFloat = 1.6
        let maxPreviewHFromWidth = maxCardW / targetAspect
        let maxPreviewHFromSlot = max(90, slotH - headerHeight)

        let previewH = min(maxPreviewHFromWidth, maxPreviewHFromSlot)
        let cardW = min(maxCardW, previewH * targetAspect)
        let cardH = previewH + headerHeight

        return CGSize(width: floor(cardW), height: floor(cardH))
    }

    var body: some View {
        let size = uniformCardSize
        ZStack {
            // Frosted-glass backdrop covering the opposite half. Clicking the
            // empty backdrop cancels Snap Assist (just like Windows 11).
            VisualEffectBackdrop()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onCancel()
                }

            // Centered grid of uniformly sized window cards
            VStack(spacing: 18) {
                ForEach(0..<rowsCount, id: \.self) { row in
                    HStack(spacing: 18) {
                        ForEach(0..<columnsCount, id: \.self) { col in
                            let index = row * columnsCount + col
                            if index < candidates.count {
                                let candidate = candidates[index]
                                SnapAssistCardView(
                                    candidate: candidate,
                                    isPrimaryCandidate: index == 0,
                                    size: size
                                ) {
                                    onSelect(candidate)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }
}

private struct SnapAssistCardView: View {
    let candidate: SnapAssistCandidate
    let isPrimaryCandidate: Bool
    let size: CGSize
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let thumbnail = candidate.thumbnail {
                    liveThumbnailCard(thumbnail: thumbnail)
                } else {
                    cleanIconFallbackCard
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? Color(nsColor: .controlAccentColor)
                            : (isPrimaryCandidate
                                ? Color(nsColor: .controlAccentColor).opacity(0.65)
                                : Color.white.opacity(0.16)),
                        lineWidth: (isHovered || isPrimaryCandidate) ? 2 : 1
                    )
            )
            .shadow(
                color: .black.opacity(isHovered ? 0.34 : 0.18),
                radius: isHovered ? 14 : 7,
                x: 0,
                y: isHovered ? 5 : 2
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// Windows 11 Snap Assist card: dark header bar (app icon + window title)
    /// and edge-to-edge live window thumbnail filling the body below.
    @ViewBuilder
    private func liveThumbnailCard(thumbnail: NSImage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon = candidate.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 16, height: 16)
                }

                Text(candidate.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(white: 0.13).opacity(0.95))

            let previewHeight = max(1, size.height - 30)
            ZStack {
                // Ambient blurred backdrop of the window itself so portrait or
                // ultra-wide windows fill the 16:10 card harmoniously without
                // cropping off any part of the actual window preview.
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: previewHeight)
                    .blur(radius: 18)
                    .overlay(Color.black.opacity(0.35))
                    .clipped()

                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: size.width, maxHeight: previewHeight)
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 1)
            }
            .frame(width: size.width, height: previewHeight)
            .clipped()
        }
        .background(Color(white: 0.10))
    }

    /// Clean single-icon fallback card when Screen Recording permission is not
    /// granted: shows the app icon once, the window title once, and the app
    /// name as a subtle subtitle only when it differs from the window title.
    @ViewBuilder
    private var cleanIconFallbackCard: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            if let icon = candidate.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 3) {
                Text(candidate.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if candidate.hasDistinctAppSubtitle {
                    Text(candidate.appName)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.primary.opacity(isHovered ? 0.14 : 0.07)
        )
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
