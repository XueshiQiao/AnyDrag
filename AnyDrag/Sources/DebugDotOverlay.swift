import Cocoa

/// Diagnostic overlay that flashes a small dot at a screen point. Used to
/// visualize the synthesized title-bar click location so we can see where the
/// drag is being targeted (e.g. when debugging apps with non-standard top
/// regions like WeChat).
final class DebugDotOverlay {

    private var window: NSWindow?
    private let dotSize: CGFloat = 14
    private let fadeDuration: TimeInterval = 1.0

    /// Flash a dot at the given CGEvent screen point (y measured from top of
    /// the primary screen, per Quartz convention). Safe to call from any
    /// thread — UI work is dispatched to main.
    func flash(at cgScreenPoint: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            self?.show(at: cgScreenPoint)
        }
    }

    private func show(at cgScreenPoint: CGPoint) {
        // CGEvent uses Quartz screen coords (top-left origin, y down). NSWindow
        // uses NS screen coords (bottom-left of primary screen, y up). Flip Y
        // using the height of the screen whose origin is at (0,0).
        let originScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let flipReference = originScreen?.frame.maxY ?? 0
        let nsY = flipReference - cgScreenPoint.y

        let frame = NSRect(
            x: cgScreenPoint.x - dotSize / 2,
            y: nsY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )

        // Cancel any in-flight fade from a prior drag.
        window?.orderOut(nil)

        let w = NSWindow(
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

        let dot = NSView(frame: NSRect(origin: .zero, size: frame.size))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSize / 2
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.borderColor = NSColor.white.cgColor
        dot.layer?.borderWidth = 2
        w.contentView = dot
        w.alphaValue = 1.0
        w.orderFrontRegardless()

        window = w

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            w.orderOut(nil)
            if self?.window === w { self?.window = nil }
        })
    }
}
