import AppKit
import ApplicationServices
import Foundation

/// Restores focus through documented application and Accessibility APIs only.
public final class AXFocusRestorer: FocusRestorer {
    private struct CapturedWindow {
        let application: AXUIElement
        let window: AXUIElement
        let processIdentifier: pid_t
    }

    private let systemWideElement: AXUIElement
    private var capturedWindow: CapturedWindow?

    public init(systemWideElement: AXUIElement = AXUIElementCreateSystemWide()) {
        self.systemWideElement = systemWideElement
    }

    public func captureFocusedWindow() {
        capturedWindow = nil

        guard let application = copyElementAttribute(
            systemWideElement,
            attribute: kAXFocusedApplicationAttribute
        ) else {
            DriverLoggers.log(.debug, category: .focus, "Could not capture focused application before touch gesture.")
            return
        }

        guard let window = copyElementAttribute(
            application,
            attribute: kAXFocusedWindowAttribute
        ) else {
            DriverLoggers.log(.debug, category: .focus, "Could not capture focused window before touch gesture.")
            return
        }

        var processIdentifier = pid_t()
        let processResult = AXUIElementGetPid(application, &processIdentifier)
        guard processResult == .success else {
            DriverLoggers.log(
                .debug,
                category: .focus,
                "Could not capture focused application process before touch gesture: \(processResult.rawValue)."
            )
            return
        }

        capturedWindow = CapturedWindow(
            application: application,
            window: window,
            processIdentifier: processIdentifier
        )
    }

    public func restoreCapturedWindow() {
        guard let capturedWindow else { return }
        self.capturedWindow = nil

        let runningApplication = NSRunningApplication(
            processIdentifier: capturedWindow.processIdentifier
        )
        let activated = runningApplication?.activate(options: []) ?? false
        let frontmostResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
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
        let raiseResult = AXUIElementPerformAction(
            capturedWindow.window,
            kAXRaiseAction as CFString
        )
        let windowMainResult = AXUIElementSetAttributeValue(
            capturedWindow.window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let windowFocusedResult = AXUIElementSetAttributeValue(
            capturedWindow.window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        guard isWindowFocused(capturedWindow) else {
            DriverLoggers.log(
                .warning,
                category: .focus,
                "Could not verify click-free restoration of the previously focused window. activated=\(activated), frontmost=\(frontmostResult.rawValue), focusedWindow=\(focusedWindowResult.rawValue), mainWindow=\(mainWindowResult.rawValue), raise=\(raiseResult.rawValue), windowMain=\(windowMainResult.rawValue), windowFocused=\(windowFocusedResult.rawValue)."
            )
            return
        }
    }

    public func discardCapturedWindow() {
        capturedWindow = nil
    }

    private func copyElementAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func isWindowFocused(_ capturedWindow: CapturedWindow) -> Bool {
        guard let focusedApplication = copyElementAttribute(
            systemWideElement,
            attribute: kAXFocusedApplicationAttribute
        ), CFEqual(focusedApplication, capturedWindow.application) else {
            return false
        }

        guard let focusedWindow = copyElementAttribute(
            capturedWindow.application,
            attribute: kAXFocusedWindowAttribute
        ) else {
            return false
        }
        return CFEqual(focusedWindow, capturedWindow.window)
    }
}
