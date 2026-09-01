import AppKit
import CoreGraphics
import Foundation

/// UI boundary used by the pairing coordinator and its tests.
public protocol PairingOverlayPresenting: AnyObject {
    @discardableResult
    func show(on display: DisplaySnapshot, step: Int, total: Int) -> Bool
    func showConfirmation(on display: DisplaySnapshot)
    func hide()
}

/// Native, dependency-free full-screen pairing overlay.
public final class PairingOverlayController: PairingOverlayPresenting {
    private var window: NSWindow?

    public init() {}

    @discardableResult
    public func show(on display: DisplaySnapshot, step: Int, total: Int) -> Bool {
        present(
            on: display,
            title: "Touch this display",
            detail: "Pairing touchscreen \(step) of \(total)"
        )
    }

    public func showConfirmation(on display: DisplaySnapshot) {
        _ = present(on: display, title: "Paired", detail: "Touch input is assigned to this display")
    }

    public func hide() {
        runOnMain { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        }
    }

    private func present(on display: DisplaySnapshot, title: String, detail: String) -> Bool {
        runOnMainReturning { [weak self] in
            let screens = NSScreen.screens
            guard let self,
                  let primaryScreen = screens.first,
                  let screen = Self.screen(for: display.displayID, in: screens) else {
                DriverLoggers.log(.error, category: .display, "Could not present pairing overlay for display \(display.displayID).")
                return false
            }

            let expectedFrame = PairingOverlayGeometry.appKitFrame(
                for: display.bounds,
                primaryCoreGraphicsFrame: CGDisplayBounds(CGMainDisplayID()),
                primaryAppKitFrame: primaryScreen.frame
            )
            guard PairingOverlayGeometry.framesMatch(screen.frame, expectedFrame) else {
                DriverLoggers.log(
                    .warning,
                    category: .display,
                    "AppKit screen geometry is not ready for display \(display.displayID); expected \(expectedFrame), received \(screen.frame)."
                )
                return false
            }

            self.window?.orderOut(nil)

            let window = NSWindow(
                contentRect: .zero,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 0.98)
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
            window.contentView = PairingOverlayView(title: title, detail: detail)
            window.setFrame(expectedFrame, display: true)
            window.orderFrontRegardless()

            guard Self.displayID(for: window.screen) == display.displayID,
                  PairingOverlayGeometry.framesMatch(window.frame, expectedFrame) else {
                DriverLoggers.log(
                    .warning,
                    category: .display,
                    "Pairing overlay moved away from target display \(display.displayID); presentation will retry."
                )
                window.orderOut(nil)
                return false
            }

            self.window = window
            return true
        }
    }

    private static func screen(
        for displayID: CGDirectDisplayID,
        in screens: [NSScreen]
    ) -> NSScreen? {
        screens.first { Self.displayID(for: $0) == displayID }
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func runOnMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.async(execute: operation)
        }
    }

    private func runOnMainReturning<T>(_ operation: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return operation()
        }
        return DispatchQueue.main.sync(execute: operation)
    }
}

/// Pure coordinate conversion and comparison used to validate AppKit readiness.
enum PairingOverlayGeometry {
    static func appKitFrame(
        for coreGraphicsFrame: CGRect,
        primaryCoreGraphicsFrame: CGRect,
        primaryAppKitFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: primaryAppKitFrame.minX + coreGraphicsFrame.minX - primaryCoreGraphicsFrame.minX,
            y: primaryAppKitFrame.maxY - (coreGraphicsFrame.maxY - primaryCoreGraphicsFrame.minY),
            width: coreGraphicsFrame.width,
            height: coreGraphicsFrame.height
        )
    }

    static func framesMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}

private final class PairingOverlayView: NSView {
    private let titleText: String
    private let detailText: String

    init(title: String, detail: String) {
        self.titleText = title
        self.detailText = detail
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
        dirtyRect.fill()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)
        ]

        drawCentered(titleText, atY: center.y + 8, attributes: titleAttributes)
        drawCentered(detailText, atY: center.y - 34, attributes: detailAttributes)

        let radius: CGFloat = 18
        let ring = NSBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y + 64 - radius,
            width: radius * 2,
            height: radius * 2
        ))
        ring.lineWidth = 3
        NSColor.systemIndigo.setStroke()
        ring.stroke()
    }

    private func drawCentered(
        _ text: String,
        atY y: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: y - size.height / 2),
            withAttributes: attributes
        )
    }
}
