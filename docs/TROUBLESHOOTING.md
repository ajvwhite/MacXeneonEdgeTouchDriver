# Troubleshooting

## Touch does not work

Check the Edge's USB connection as well as its display connection. Wait for the screen to return after a reconnect, then lift your fingers and try a single tap on a harmless control.

In System Settings > Privacy & Security, enable `MacXeneonEdgeTouchDriver` under Device Control and Data Access (Accessibility on macOS 26 and earlier) and Input Monitoring. The driver waits for approval. Approving the installer app alone does not grant access to the installed driver.

If the driver is listed as enabled but still cannot use that permission, remove its entry from the affected category and add the installed driver again. After a successful installation, the installer app's **Show Driver** button reveals the file. You can also find it without running installation again: in Finder, choose Go > Go to Folder, paste `~/Library/Application Support/MacXeneonEdgeTouchDriver/bin`, then select `MacXeneonEdgeTouchDriver`. Change only this driver's entry. A work Mac may require your administrator to approve these permissions.

Close any other touch driver or USB diagnostic program using the Edge, then restart this driver. Only one program can take exclusive control of its touch input.

## Touches land on the wrong screen

Wait for macOS to finish arranging the displays. If the problem remains, check System Settings > Displays and restart the driver. Disconnect an extra matching Edge if one is attached; this version supports one panel.

The [display settings](SETTINGS.md) can narrow the match to a particular serial number. If you need help identifying the display, the [developer tools](../CONTRIBUTING.md#investigate-input-or-display-problems) can list it. Those tools require a development setup; ordinary installation does not.

## Find the logs

In Finder, choose Go > Go to Folder and paste:

```text
~/Library/Logs/MacXeneonEdgeTouchDriver
```

Open `driver.log` with a text editor. It records startup, permission and device errors. The same folder contains `stdout.log` and `stderr.log`; those files are normally empty. You do not need to understand every line to report a problem. Include the message around the time it occurred, after reviewing it for information you do not want to share.

## Restart the driver

Lift your fingers from the Edge and release all mouse buttons before restarting. Open Terminal and run these commands as your own logged-in user, without `sudo`:

```sh
launchctl bootout "gui/$(id -u)/com.ajvwhite.MacXeneonEdgeTouchDriver"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ajvwhite.MacXeneonEdgeTouchDriver.plist"
```

The first command stops the installed service; the second starts it again. If stopping reports an error, check its meaning before starting another copy. For registration checks and recovery details, see [Start, stop and status](TECHNICAL-REFERENCE.md#start-stop-and-status).

## Installation could not finish

Read the installer message before retrying. It checks the new files before stopping the current driver and keeps a backup when replacing an existing installation. If recovery cannot finish, the message gives the backup location. Keep those files and the error message so you can investigate or ask for help.

If macOS blocks the installer, check the source of the ZIP and whether its builder completed notarization. Signing identifies the builder; notarization is Apple's separate check of the software. Do not disable macOS security checks to make it run. On a managed work Mac, ask the administrator how to install approved software.

## Current limits

- This version supports one Xeneon Edge in landscape orientation. Rotation and multiple Edge panels have not been tested.
- If touch reports stop, `timing.stuckGestureTimeoutMs` releases the gesture. Lift and touch again to continue.
- Apps must expose their windows and text fields through macOS Accessibility for focus restoration to work. Mouse clicks, typing and scrolling cancel further restoration, but a request already sent to an app may still finish afterward.
- With cursor return enabled, moving the mouse during a touch does not change the saved return position. With it disabled, the cursor stays where it is after cleanup.
- The supported report format contains one position, so multi-contact gestures are unsupported.
- Killing the process with `SIGKILL` prevents normal cleanup. Restarting the driver or moving the mouse after cursor control is restored may be needed.

For details about permission waiting and startup recovery, see [Permission startup](TECHNICAL-REFERENCE.md#permission-startup).
