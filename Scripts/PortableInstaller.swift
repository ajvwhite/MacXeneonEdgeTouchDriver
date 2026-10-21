import AppKit
import Foundation
import Darwin

// The signed app contains the installer scripts; installation runs as the
// current user and never requests administrator privileges.
let application = NSApplication.shared
application.setActivationPolicy(.regular)
final class InstallerDelegate: NSObject, NSApplicationDelegate {
    var operationInProgress = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            runInstallerFlow()
            if !self.operationInProgress { NSApplication.shared.terminate(nil) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        operationInProgress ? .terminateCancel : .terminateNow
    }
}
let installerDelegate = InstallerDelegate()
application.delegate = installerDelegate

func showMessage(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    application.activate(ignoringOtherApps: true)
    alert.runModal()
}

func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    // Use a private log file, so a full pipe cannot deadlock an installation.
    let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath: log.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { try? FileManager.default.removeItem(at: log) }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    task.standardOutput = output
    task.standardError = output
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["HOME"] = NSHomeDirectory()
    environment.removeValue(forKey: "CODESIGN_IDENTITY")
    environment.removeValue(forKey: "NOTARIZATION_PROFILE")
    task.environment = environment
    try task.run()
    task.waitUntilExit()
    let input = try FileHandle(forReadingFrom: log)
    defer { try? input.close() }
    let size = try input.seekToEnd()
    if size > 32_768 { try input.seek(toOffset: size - 32_768) }
    else { try input.seek(toOffset: 0) }
    return (task.terminationStatus, String(decoding: try input.readToEnd() ?? Data(), as: UTF8.self))
}

func runInstallerFlow() {
    guard getuid() != 0, getuid() == geteuid() else {
        showMessage("Open this app as yourself", "Install the driver from your normal Mac account. Do not run this installer with sudo or as root.", style: .warning)
        return
    }
    let bundle = Bundle.main.bundleURL
    guard bundle.pathExtension == "app", let resources = Bundle.main.resourceURL else {
        showMessage("Installer files are missing", "Extract the complete portable installer ZIP and open Install Xeneon Touch.app.", style: .critical)
        return
    }
    do {
        // Verify the outer seal before executing any bundled shell resources.
        let check = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"com.ajvwhite.MacXeneonEdgeTouchDriver.Installer\"", bundle.path])
        guard check.0 == 0 else {
            showMessage("The installer could not be verified", "Its files may be incomplete or changed. Make a new portable installer on the development Mac.\n\n" + check.1, style: .critical)
            return
        }
        let outer = try run("/usr/bin/codesign", ["-dv", "--verbose=2", bundle.path])
        let driver = try run("/usr/bin/codesign", ["-dv", "--verbose=2", bundle.appendingPathComponent("Contents/Helpers/MacXeneonEdgeTouchDriver").path])
        func team(_ text: String) -> String? {
            text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }).map(String.init)
        }
        guard outer.0 == 0, driver.0 == 0, let outerTeam = team(outer.1),
              outerTeam != "TeamIdentifier=not set", outerTeam == team(driver.1) else {
            showMessage("The installer and driver have different signers", "Make a new portable installer on the development Mac. No files were installed.", style: .critical)
            return
        }
    } catch {
        showMessage("The installer could not be verified", error.localizedDescription, style: .critical)
        return
    }

    let choice = NSAlert()
    choice.messageText = "Xeneon Edge touch driver"
    choice.informativeText = "Install or update the driver for your Mac account. Your current settings will be kept.\n\nLift every finger off the Edge and release all mouse buttons before continuing."
    choice.addButton(withTitle: "Install or Update")
    choice.addButton(withTitle: "Remove Driver")
    choice.addButton(withTitle: "Cancel")
    application.activate(ignoringOtherApps: true)
    let response = choice.runModal()
    let removing = response == .alertSecondButtonReturn
    guard response == .alertFirstButtonReturn || removing else { return }
    if removing {
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Remove the driver and its settings?"
        confirm.informativeText = "This removes the driver, your settings and saved installation backups from this Mac account. Logs are kept. Keep all fingers off the Edge and release mouse buttons."
        confirm.addButton(withTitle: "Cancel")
        confirm.addButton(withTitle: "Remove Driver")
        guard confirm.runModal() == .alertSecondButtonReturn else { return }
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 110),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = removing ? "Removing driver" : "Installing driver"
    window.isReleasedWhenClosed = false
    let label = NSTextField(labelWithString: "Please wait. Keep fingers off the Edge.")
    label.frame = NSRect(x: 24, y: 65, width: 355, height: 20)
    let progress = NSProgressIndicator(frame: NSRect(x: 24, y: 28, width: 352, height: 20))
    progress.style = .bar
    progress.isIndeterminate = true
    window.contentView?.addSubview(label)
    window.contentView?.addSubview(progress)
    window.center()
    window.makeKeyAndOrderFront(nil)
    progress.startAnimation(nil)
    let script = resources.appendingPathComponent(removing ? "Scripts/uninstall.sh" : "Scripts/install.sh")
    let arguments = [script.path] + (removing ? [] : ["--prebuilt"])
    installerDelegate.operationInProgress = true
    DispatchQueue.global(qos: .userInitiated).async {
        let result: (Int32, String)
        do { result = try run("/bin/sh", arguments) }
        catch { result = (1, error.localizedDescription) }
        DispatchQueue.main.async {
            window.close()
            if result.0 != 0 {
                showMessage(removing ? "Removal did not finish" : "Installation did not finish",
                            "The details below explain what happened. If recovery was incomplete, keep the saved backups.\n\n" + result.1,
                            style: .critical)
            } else if removing {
                showMessage("Driver removed", "The driver and its settings have been removed from this Mac account. Logs were kept.")
            } else {
                showInstalled()
            }
            installerDelegate.operationInProgress = false
            application.terminate(nil)
        }
    }
}

func showInstalled() {
    let driver = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/MacXeneonEdgeTouchDriver/bin/MacXeneonEdgeTouchDriver")
    while true {
        let alert = NSAlert()
        alert.messageText = "Driver files installed"
        alert.informativeText = "macOS has accepted the background service. Check that touch works before relying on it.\n\nIn System Settings → Privacy & Security, allow the driver under Device Control and Data Access (Accessibility on older macOS) and Input Monitoring. If it is missing, use Show Driver to find the exact file to add.\n\nThis Mac needs its own permissions, even if the driver already worked on another Mac."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Show Driver")
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([driver])
        } else { return }
    }
}

let menu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
let quit = NSMenuItem(title: "Quit Install Xeneon Touch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
quit.target = application
appMenu.addItem(quit)
appMenuItem.submenu = appMenu
menu.addItem(appMenuItem)
application.mainMenu = menu
application.run()
