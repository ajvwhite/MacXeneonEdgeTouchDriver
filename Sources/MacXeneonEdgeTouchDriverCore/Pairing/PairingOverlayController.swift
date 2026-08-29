import AppKit
import CoreGraphics
import Foundation

/// UI boundary used by the pairing coordinator and its tests.
public protocol PairingOverlayPresenting: AnyObject {
    func show(on display: DisplaySnapshot, step: Int, total: Int)
    func showConfirmation(on display: DisplaySnapshot)
    func hide()
}

/// Native, dependency-free full-screen pairing overlay.
public final class PairingOverlayController: PairingOverlayPresenting {
    private var window: NSWindow?

    public init() {}

    public func show(on display: DisplaySnapshot, step: Int, total: Int) {
        present(
            on: display,
            title: "Touch this display",
            detail: "Pairing touchscreen \(step) of \(total)"
        )
    }

    public func showConfirmation(on display: DisplaySnapshot) {
        present(on: display, title: "Paired", detail: "Touch input is assigned to this display")
    }

    public func hide() {
        runOnMain { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        }
    }

    private func present(on display: DisplaySnapshot, title: String, detail: String) {
        runOnMain { [weak self] in
            guard let self, let screen = Self.screen(for: display.displayID) else {
                DriverLoggers.log(.error, category: .display, "Could not present pairing overlay for display \(display.displayID).")
                return
            }

            self.window?.orderOut(nil)

            let window = NSWindow(
                contentRect: screen.frame,
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
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = PairingOverlayView(title: title, detail: detail)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            self.window = window
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func runOnMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.async(execute: operation)
        }
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
