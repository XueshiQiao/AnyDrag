import AppKit

/// Hides an instantaneous cursor warp behind a short visual glide. The real
/// cursor is moved to the bento's cancel center immediately so gesture math is
/// correct; a mouse-transparent cursor image animates there from the press
/// point before the system cursor is revealed again.
final class BentoCursorTransition {

    private static let duration: TimeInterval = 0.10

    private let panel: NSPanel
    private let imageView = NSImageView()
    private var cursorHidden = false
    private var generation = 0
    private var startPoint: NSPoint?
    private var endPoint: NSPoint?
    private var suppressMotionUntil: TimeInterval = 0

    private(set) var isActive = false

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        imageView.imageScaling = .scaleNone
        panel.contentView = imageView
    }

    deinit {
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    func move(from startNS: NSPoint, to endNS: NSPoint) {
        dispatchPrecondition(condition: .onQueue(.main))
        finishImmediately()

        let distance = hypot(endNS.x - startNS.x, endNS.y - startNS.y)
        guard distance >= 1, let primary = NSScreen.screens.first else { return }

        let cursor = NSCursor.current
        let image = cursor.image
        let hotSpot = cursor.hotSpot
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        panel.setContentSize(image.size)

        let origin: (NSPoint) -> NSPoint = { point in
            NSPoint(
                x: point.x - hotSpot.x,
                y: point.y - (image.size.height - hotSpot.y)
            )
        }
        panel.setFrameOrigin(origin(startNS))
        panel.orderFrontRegardless()

        startPoint = startNS
        endPoint = endNS
        suppressMotionUntil = ProcessInfo.processInfo.systemUptime + 0.05
        isActive = true
        cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        let targetCG = CGPoint(x: endNS.x, y: primary.frame.height - endNS.y)
        guard CGWarpMouseCursorPosition(targetCG) == .success else {
            finishImmediately()
            return
        }

        generation &+= 1
        let currentGeneration = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin(endNS))
        } completionHandler: { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.finishImmediately()
        }
    }

    /// Called on the first real drag event so user input always wins over the
    /// cosmetic transition and the system cursor becomes visible immediately.
    func finishImmediately() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        isActive = false
        startPoint = nil
        endPoint = nil
        suppressMotionUntil = 0
        panel.orderOut(nil)
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
    }

    /// Suppress queued events at the pre-warp and post-warp locations. A point
    /// elsewhere is real user movement, which cancels the cosmetic transition
    /// and should proceed through normal tile resolution.
    func shouldSuppressMotion(at point: NSPoint) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive, let startPoint, let endPoint else { return false }
        if ProcessInfo.processInfo.systemUptime < suppressMotionUntil {
            return true
        }
        let nearStart = hypot(point.x - startPoint.x, point.y - startPoint.y) <= 2
        let nearEnd = hypot(point.x - endPoint.x, point.y - endPoint.y) <= 2
        if nearStart || nearEnd {
            return true
        }
        finishImmediately()
        return false
    }
}
