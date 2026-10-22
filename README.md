# Mac Xeneon Edge Touch Driver

Use a Corsair Xeneon Edge touchscreen on your Mac. Tap to click, tap twice to double-click, or hold and move your finger to drag. You can also enable one-finger scrolling.

The driver supports one Xeneon Edge in landscape orientation. Two-finger gestures and multiple touch panels are not supported. It requires macOS 13 or later. Hardware testing has used Apple Silicon; Intel hardware has not been tested.

## Building an install for another Mac

A portable installer lets you build and sign the driver on one Mac, then install it on another. The receiving Mac needs neither Xcode nor your signing certificate. To create the ZIP on your development Mac, follow [Make a portable installer](docs/PORTABLE-INSTALLER.md).

Make sure the Edge has a working picture and a USB connection for touch. If you already have the installer ZIP:

1. Copy it to the Mac that will use the Edge, then double-click the ZIP to extract it.
2. Open `Install Xeneon Touch.app` in the extracted folder.
3. Lift your fingers from the Edge, release any mouse buttons, and choose **Install or Update**.
4. When installation finishes, grant the permissions below and try a touch.

The installer runs for your own account and keeps your existing settings when updating. Keep the installer app if you want to update or remove the driver later. You do not need to leave it open.

To build and install on the same Mac, follow [Building and installing from source](CONTRIBUTING.md#build-and-install-on-your-mac).

## Allow touch input

Open System Settings > Privacy & Security. Enable `MacXeneonEdgeTouchDriver` in both:

- **Device Control and Data Access**, called **Accessibility** on macOS 26 and earlier.
- **Input Monitoring**.

The installer has **Open Privacy Settings** and **Show Driver** buttons to help you find the settings and the installed file. Approve the driver, rather than the installer app. Each Mac needs its own permission approvals.

The driver waits while access is missing and continues after approval. Try tapping a harmless button once, then check that your mouse still works normally. If touch does not work, follow [Troubleshooting](docs/TROUBLESHOOTING.md).

## Everyday use

By default, a touch returns the cursor to where it was and tries to return typing to the window and text field you were using. You can turn either behavior off. Apps need to provide macOS with information about their windows and text fields for typing to return reliably.

To scroll with one finger, enable the optional scroll mode. Quick taps still click; hold still before moving to drag. [Settings](docs/SETTINGS.md) explains how to change this and includes the full settings file.

After a USB reconnect, let the display return before touching it. If a held touch stops responding, lift your finger and touch again. The driver releases a held mouse button when the connection is lost or touch reports stop.

## Update or remove

To update, first make or obtain an installer ZIP built from the newer driver source. Open that copy of `Install Xeneon Touch.app` and choose **Install or Update**. The app does not download updates. The installer keeps your settings and saves the previous files. macOS may ask you to approve the driver again after an update.

To uninstall, reopen the installer app and choose **Remove Driver**. Confirm only if you want to remove the driver, settings and saved installation backups. Logs are kept.

## Help and development

- [Troubleshooting](docs/TROUBLESHOOTING.md): permissions, missing touch input, logs and restarting.
- [Settings](docs/SETTINGS.md): scrolling, cursor behavior and display selection.
- [Contributing](CONTRIBUTING.md): build, test and investigate the driver.
- [Technical reference](docs/TECHNICAL-REFERENCE.md): installation recovery, input handling and diagnostics.
- [Changelog](CHANGELOG.md): changes between versions.

If you report a problem, include your macOS version, Mac model, display arrangement and what happened. Review logs or recordings before sharing them, especially on a work Mac.

## Contributors

Thanks to [Greg Thompson (`isleofgreg`)](https://github.com/isleofgreg) for the per-touch-down display refresh proposal and moved-display regression test in [PR #4](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/4), which this driver adapts.

Thanks to [Clark Hager](https://github.com/clarkhager) for the focus check proposed in [PR #5](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/5). The driver keeps that check to avoid unnecessarily refocusing an already focused window.

Thanks to [`mrnocreativity`](https://github.com/mrnocreativity) for the touch-stream validation and gesture proposals in [PR #3](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/3). The noise tracking, double-click and optional scroll work follows those proposals with separate implementation and tests.
