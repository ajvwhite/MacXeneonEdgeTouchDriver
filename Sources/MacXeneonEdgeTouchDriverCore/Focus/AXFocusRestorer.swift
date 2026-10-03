import ApplicationServices
import CoreGraphics
import Foundation

/// Restores focus to the exact AX window that was focused before a touch gesture.
public final class AXFocusRestorer: FocusRestorer {
    /// Keeps focus restoration testable without sending AX requests or cursor events.
    struct Operations {
        var copyAttribute: (AXUIElement, String) -> CFTypeRef?
        var setAttribute: (AXUIElement, String, CFTypeRef) -> AXError
        var performAction: (AXUIElement, String) -> AXError
        var cursorPosition: () -> CGPoint?
        var postMouseEvent: (CGEventType, CGPoint) -> Void
        var warpCursor: (CGPoint) -> Void

        static let live = Operations(
            copyAttribute: { element, attribute in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
                    return nil
                }
                return value
            },
            setAttribute: { AXUIElementSetAttributeValue($0, $1 as CFString, $2) },
            performAction: { AXUIElementPerformAction($0, $1 as CFString) },
            cursorPosition: { CGEvent(source: nil)?.location },
            postMouseEvent: { AXFocusRestorer.postMouseEvent(type: $0, at: $1) },
            warpCursor: { CGWarpMouseCursorPosition($0) }
        )
    }

    private struct CapturedWindow {
        let application: AXUIElement
        let window: AXUIElement
    }

    private let systemWideElement: AXUIElement
    private let operations: Operations
    private var capturedWindow: CapturedWindow?

    public convenience init(systemWideElement: AXUIElement = AXUIElementCreateSystemWide()) {
        self.init(systemWideElement: systemWideElement, operations: .live)
    }

    init(systemWideElement: AXUIElement, operations: Operations) {
        self.systemWideElement = systemWideElement
        self.operations = operations
    }

    public func captureFocusedWindow() {
        capturedWindow = nil

        guard let application = copyElementAttribute(systemWideElement, attribute: kAXFocusedApplicationAttribute) else {
            DriverLoggers.log(.debug, category: .focus, "Could not capture focused application before touch gesture.")
            return
        }

        guard let window = copyElementAttribute(application, attribute: kAXFocusedWindowAttribute) else {
            DriverLoggers.log(.debug, category: .focus, "Could not capture focused window before touch gesture.")
            return
        }

        capturedWindow = CapturedWindow(application: application, window: window)
    }

    public func restoreCapturedWindow() {
        guard let capturedWindow else {
            return
        }
        self.capturedWindow = nil

        // Restoring an already focused window can turn a touch into a second click.
        guard !isWindowFocused(capturedWindow) else {
            return
        }

        // Do not use app-level AXFrontmost here; it raises sibling windows from the same application.
        let focusedWindowResult = operations.setAttribute(
            capturedWindow.application,
            kAXFocusedWindowAttribute,
            capturedWindow.window
        )
        let mainWindowResult = operations.setAttribute(
            capturedWindow.application,
            kAXMainWindowAttribute,
            capturedWindow.window
        )
        let raiseResult = operations.performAction(capturedWindow.window, kAXRaiseAction)
        let sessionClickResult = clickCapturedWindowTitleBar(capturedWindow)
        let refocusedWindowResult = operations.setAttribute(
            capturedWindow.application,
            kAXFocusedWindowAttribute,
            capturedWindow.window
        )
        let remadeMainWindowResult = operations.setAttribute(
            capturedWindow.application,
            kAXMainWindowAttribute,
            capturedWindow.window
        )
        let mainResult = operations.setAttribute(
            capturedWindow.window,
            kAXMainAttribute,
            kCFBooleanTrue
        )
        let focusedResult = operations.setAttribute(
            capturedWindow.window,
            kAXFocusedAttribute,
            kCFBooleanTrue
        )

        guard isWindowFocused(capturedWindow) else {
            DriverLoggers.log(
                .warning,
                category: .focus,
                "Could not verify restore of the previously focused window. focusedWindow=\(focusedWindowResult.rawValue), mainWindow=\(mainWindowResult.rawValue), raise=\(raiseResult.rawValue), sessionClick=\(sessionClickResult), refocusedWindow=\(refocusedWindowResult.rawValue), remadeMainWindow=\(remadeMainWindowResult.rawValue), windowMain=\(mainResult.rawValue), windowFocused=\(focusedResult.rawValue)."
            )
            return
        }
    }

    public func discardCapturedWindow() {
        capturedWindow = nil
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = operations.copyAttribute(element, attribute) else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func isWindowFocused(_ capturedWindow: CapturedWindow) -> Bool {
        guard let focusedApplication = copyElementAttribute(systemWideElement, attribute: kAXFocusedApplicationAttribute),
              CFEqual(focusedApplication, capturedWindow.application) else {
            return false
        }

        guard let focusedWindow = copyElementAttribute(capturedWindow.application, attribute: kAXFocusedWindowAttribute) else {
            return false
        }

        return CFEqual(focusedWindow, capturedWindow.window)
    }

    private func clickCapturedWindowTitleBar(_ capturedWindow: CapturedWindow) -> Bool {
        guard let clickPoint = titleBarClickPoint(for: capturedWindow.window) else {
            return false
        }

        let originalPosition = operations.cursorPosition()
        operations.postMouseEvent(.leftMouseDown, clickPoint)
        operations.postMouseEvent(.leftMouseUp, clickPoint)

        if let originalPosition {
            operations.warpCursor(originalPosition)
        }
        return true
    }

    private static func postMouseEvent(type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .privateState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            DriverLoggers.log(.error, category: .focus, "Failed to create focus restore mouse event of type \(type.rawValue).")
            return
        }

        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func titleBarClickPoint(for window: AXUIElement) -> CGPoint? {
        if let title = copyElementAttribute(window, attribute: kAXTitleUIElementAttribute),
           let position = copyCGPointAttribute(title, attribute: kAXPositionAttribute),
           let size = copyCGSizeAttribute(title, attribute: kAXSizeAttribute),
           size.width > 0,
           size.height > 0 {
            return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        }

        guard let position = copyCGPointAttribute(window, attribute: kAXPositionAttribute),
              let size = copyCGSizeAttribute(window, attribute: kAXSizeAttribute),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGPoint(
            x: position.x + min(max(size.width / 2, 24), max(size.width - 24, 1)),
            y: position.y + min(max(12, 1), max(size.height - 1, 1))
        )
    }

    private func copyCGPointAttribute(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = operations.copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func copyCGSizeAttribute(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = operations.copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
