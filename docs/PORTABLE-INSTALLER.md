# Make a portable installer

Build and sign the driver on a Mac with your development tools and signing certificate, then copy the resulting ZIP to the Mac that will use the Edge. The receiving Mac does not need Xcode, Swift or your certificate. Your signing key stays on the Mac that builds it.

This guide creates an installer for your own use or sharing. It does not publish a GitHub release.

## On the Mac that builds the installer

You need macOS, Xcode or Apple's Command Line Tools, and a Developer ID Application certificate in your keychain. Developer ID is Apple's signing certificate for software used outside the App Store. Use your own signing identity. Your private key stays on the development Mac. Signed files include the public certificate, which identifies the signer.

1. Open Terminal in the checked-out repository folder.
2. List the signing identities available on this Mac:

   ```sh
   security find-identity -v -p codesigning
   ```

3. Find your `Developer ID Application` identity. Use its full quoted name in this command, replacing the example with your own:

   ```sh
   CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
     ./Scripts/build-portable-installer.sh
   ```

The builder creates:

```text
artifacts/MacXeneonEdgeTouchDriver-Installer-universal.zip
```

The default installer includes both Apple Silicon and Intel builds. It requires macOS 13 or later. Including an Intel build does not mean it has been tested on Intel hardware.

Keep the ZIP intact when copying it to another Mac. You can use AirDrop, a USB drive or your organisation's approved file-transfer method. The ZIP contains `Install Xeneon Touch.app` and `START HERE.txt`.

### Let Apple check the installer

Signing identifies who built the software. Notarization is a separate Apple check that helps macOS decide whether downloaded software can open. A signed installer without notarization can still be blocked by macOS or your work Mac's software policy.

If `NOTARIZATION_PROFILE` is already set in your shell, the builder uses it automatically. Otherwise, if you have a profile saved in your keychain, add its name when building:

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARIZATION_PROFILE='Your keychain profile' \
  ./Scripts/build-portable-installer.sh
```

The builder first submits the driver and setup helper to Apple, then signs and submits the complete installer app. This follows Apple's [two-stage process for custom installers](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). It attaches Apple's approval to the app and creates the final ZIP. Use the output from a successful run; a failed submission is not a notarized installer. This requires an internet connection and a configured Apple developer account. The profile stays in your keychain and is not included in the ZIP.

The standalone driver cannot carry an attached approval ticket in the same way as an app. macOS may need an internet connection to check that approval when the driver first runs.

If you need to create a profile, follow Apple's [notarization instructions](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). Do that on the development Mac. Do not copy its credentials to the receiving Mac or put them in this repository.

### Choose a processor or output folder

The default `universal` build works with both processor types. To build only for Apple Silicon, add `--arch arm64`; for Intel, use `--arch x86_64`. Select the processor in Apple menu > About This Mac on the receiving Mac: an Apple M-series chip means Apple Silicon; an Intel processor means Intel.

Use `--output` to choose a different output folder:

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./Scripts/build-portable-installer.sh --arch arm64 --output "$HOME/Desktop/Xeneon installer"
```

The older `Scripts/build-release.sh` creates a binary-only archive. It does not create this installer app.

## Before sharing the installer

Signed files include the name on your signing certificate and your Apple developer team ID. Check those details and the ZIP's contents before sharing it outside your own Macs. The builder does not publish the file or include your private signing key, notarization credentials or local driver settings.

## On the Mac that will use the Edge

Make sure the Edge has a working picture and a USB connection for touch.

1. Copy the ZIP to the Mac and double-click it to extract the files.
2. Open `Install Xeneon Touch.app`. Read the explanation, lift your fingers from the Edge and release all mouse buttons.
3. Choose **Install or Update**. The installer sets up the driver for your logged-in account and starts it. It keeps existing settings when updating.
4. Choose **Open Privacy Settings**. In Privacy & Security, enable `MacXeneonEdgeTouchDriver` under Device Control and Data Access and Input Monitoring. On macOS 26 and earlier, the first category is called Accessibility.
5. Use **Show Driver** if you need to add the installed executable to a permission list. Approve that driver, rather than the installer app.
6. Tap a harmless control on the Edge once, lift your finger, and check that the control responds and the mouse still works normally.

The driver waits while permission is missing. Each Mac needs its own approvals, even when the same certificate signed both copies. Work Mac permissions may be managed by your administrator.

You can close the installer app after setup. Keep a copy so you can reopen it to remove the driver. To update, make or obtain a ZIP built from the newer driver source and use that installer app; the app does not download updates. **Remove Driver** asks for confirmation before removing the driver, settings and saved installation backups; logs are kept.

If macOS blocks the app or touch does not work, see [Troubleshooting](TROUBLESHOOTING.md). Keep macOS security checks enabled. The builder's successful signing or notarization checks do not prove touch works on a different machine, so complete the simple tap and mouse check there.
