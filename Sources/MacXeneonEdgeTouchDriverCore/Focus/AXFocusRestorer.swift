import ApplicationServices
import CoreGraphics
import Foundation

/// Restores focus to the exact AX window that was focused before a touch gesture.
public final class AXFocusRestorer: FocusRestorer {
    private struct CapturedWindow {
        let application: AXUIElement
        let window: AXUIElement
    }

    private let systemWideElement: AXUIElement
    private var capturedWindow: CapturedWindow?

    public init(systemWideElement: AXUIElement = AXUIElementCreateSystemWide()) {
        self.systemWideElement = systemWideElement
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

        // If the captured window is still the focused window, the touched surface never took
        // focus (for example a non-activating, never-key kiosk panel), so there is nothing to
        // restore. Skipping here matters: the restore below ends in a synthetic click on the
        // captured window's title bar, and a click on an *already active* window's title bar is
        // a real click to macOS (rename popover in document apps, a window drag if the gesture
        // continues). Restoring an inactive window merely activates it, which is the intended
        // case and is unchanged.
        if isWindowFocused(capturedWindow) {
            DriverLoggers.log(.debug, category: .focus, "Focused window unchanged after touch gesture; skipping restore.")
            return
        }

        // Do not use app-level AXFrontmost here; it raises sibling windows from the same application.
        let focusedWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFocusedWindowAttribute as CFString,
            capturedWindow.window
        )
        let mainWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXMainWindowAttribute as CFString,
            capturedWindow.window
        )
        let raiseResult = AXUIElementPerformAction(capturedWindow.window, kAXRaiseAction as CFString)
        let sessionClickResult = clickCapturedWindowTitleBar(capturedWindow)
        let refocusedWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFocusedWindowAttribute as CFString,
            capturedWindow.window
        )
        let remadeMainWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXMainWindowAttribute as CFString,
            capturedWindow.window
        )
        let mainResult = AXUIElementSetAttributeValue(
            capturedWindow.window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let focusedResult = AXUIElementSetAttributeValue(
            capturedWindow.window,
            kAXFocusedAttribute as CFString,
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
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
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

        let originalPosition = CGEvent(source: nil)?.location
        postMouseEvent(type: .leftMouseDown, at: clickPoint)
        postMouseEvent(type: .leftMouseUp, at: clickPoint)

        if let originalPosition {
            CGWarpMouseCursorPosition(originalPosition)
        }
        return true
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint) {
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
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
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
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
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
