import Cocoa

/// Marker subclass so this window is identifiable as AnyDrag-owned (a plain
/// `NSWindow` would report an AppKit bundle, indistinguishable from Sparkle's
/// `NSAlert` panel — see `UpdateController.isOwnedByAnyDrag`).
final class DebugDotWindow: NSWindow {}

/// Diagnostic overlay that flashes a small dot at a screen point. Used to
/// visualize the synthesized title-bar click location so we can see where the
/// drag is being targeted (e.g. when debugging apps with non-standard top
/// regions like WeChat).
final class DebugDotOverlay {

    private var window: NSWindow?
    private let dotSize: CGFloat = 14
    /// Held fully opaque this long before fading, so the marker survives long
    /// enough to be screenshotted after the mouse comes up.
    private let holdDuration: TimeInterval = 3.0
    private let fadeDuration: TimeInterval = 0.6
    /// Caption sits to the right of the dot, flipping to the left near a screen
    /// edge. Long enough for an accessibility role plus two sizes.
    private let captionWidth: CGFloat = 420
    private let captionHeight: CGFloat = 22

    /// Flash a dot at the given CGEvent screen point (y measured from top of
    /// the primary screen, per Quartz convention). Safe to call from any
    /// thread — UI work is dispatched to main.
    /// `caption` is the accessibility answer that decided this click point —
    /// see `DragEngine.visibleTopInset`. Shown beside the dot so the reason a
    /// window aims where it does is visible without reading the log.
    func flash(at cgScreenPoint: CGPoint, caption: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.show(at: cgScreenPoint, caption: caption)
        }
    }

    private func show(at cgScreenPoint: CGPoint, caption: String?) {
        // CGEvent uses Quartz screen coords (top-left origin, y down). NSWindow
        // uses NS screen coords (bottom-left of primary screen, y up). Flip Y
        // using the height of the screen whose origin is at (0,0).
        let originScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let flipReference = originScreen?.frame.maxY ?? 0
        let nsY = flipReference - cgScreenPoint.y

        let dotFrame = NSRect(
            x: cgScreenPoint.x - dotSize / 2,
            y: nsY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        // The window has to cover the dot *and* the caption, so grow it to the
        // side the caption will sit on.
        let screenMaxX = (originScreen ?? NSScreen.main)?.frame.maxX ?? dotFrame.maxX
        let captionOnRight = dotFrame.maxX + 8 + captionWidth < screenMaxX
        var frame = dotFrame
        if caption != nil {
            frame = captionOnRight
                ? NSRect(x: dotFrame.minX, y: dotFrame.minY, width: dotSize + 8 + captionWidth, height: max(dotSize, captionHeight))
                : NSRect(x: dotFrame.minX - 8 - captionWidth, y: dotFrame.minY, width: dotSize + 8 + captionWidth, height: max(dotSize, captionHeight))
        }

        // Cancel any in-flight fade from a prior drag.
        window?.orderOut(nil)

        let w = DebugDotWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true

        let dotX = (caption == nil || captionOnRight) ? 0 : frame.width - dotSize
        let dot = NSView(frame: NSRect(x: dotX, y: (frame.height - dotSize) / 2, width: dotSize, height: dotSize))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSize / 2
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.borderColor = NSColor.white.cgColor
        dot.layer?.borderWidth = 2
        container.addSubview(dot)

        if let caption {
            let label = NSTextField(labelWithString: caption)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.backgroundColor = .clear
            label.lineBreakMode = .byTruncatingMiddle
            label.frame = NSRect(x: 6, y: 3, width: captionWidth - 12, height: captionHeight - 6)

            let plate = NSView(frame: NSRect(
                x: captionOnRight ? dotSize + 8 : 0,
                y: (frame.height - captionHeight) / 2,
                width: captionWidth, height: captionHeight))
            plate.wantsLayer = true
            plate.layer?.cornerRadius = 5
            plate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
            plate.addSubview(label)
            container.addSubview(plate)
        }
        w.contentView = container
        w.alphaValue = 1.0
        w.orderFrontRegardless()

        window = w

        // Hold, then fade. A later flash calls `orderOut` on this window in
        // `show(at:caption:)` above and takes over `window`, so the delayed
        // block checks it is still the current one before animating.
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
            guard self?.window === w else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = self?.fadeDuration ?? 0.6
                w.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                w.orderOut(nil)
                if self?.window === w { self?.window = nil }
            })
        }
    }
}
