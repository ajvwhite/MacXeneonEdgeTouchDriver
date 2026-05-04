import ApplicationServices
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

        // Avoid app-level activation here; that can raise sibling windows from the same app.
        let focusedWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFocusedWindowAttribute as CFString,
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
        let raiseResult = AXUIElementPerformAction(capturedWindow.window, kAXRaiseAction as CFString)

        guard [focusedWindowResult, mainResult, focusedResult, raiseResult].contains(.success) else {
            DriverLoggers.log(
                .warning,
                category: .focus,
                "Could not restore the previously focused window. focusedWindow=\(focusedWindowResult.rawValue), main=\(mainResult.rawValue), focused=\(focusedResult.rawValue), raise=\(raiseResult.rawValue)."
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
}
