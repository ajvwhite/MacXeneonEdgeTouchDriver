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

        // Make only the captured window the app's target before and after app activation.
        // Avoid NSRunningApplication activation here; it can raise sibling windows from the same app.
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
        let frontmostResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
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
                "Could not verify restore of the previously focused window. focusedWindow=\(focusedWindowResult.rawValue), mainWindow=\(mainWindowResult.rawValue), raise=\(raiseResult.rawValue), frontmost=\(frontmostResult.rawValue), refocusedWindow=\(refocusedWindowResult.rawValue), remadeMainWindow=\(remadeMainWindowResult.rawValue), windowMain=\(mainResult.rawValue), windowFocused=\(focusedResult.rawValue)."
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
}
