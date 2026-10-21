# Contributing

Bug reports, fixes and test results are welcome. For a problem report, include your macOS version, Mac model, how the Edge is connected, display arrangement and steps that reproduce the issue. Describe what you expected and what happened. Check logs and input recordings before sharing them; recordings include touch positions and USB identifiers.

## Build and install on your Mac

Use macOS with Xcode or Apple's Command Line Tools and Swift 5.9 or later. From the checked-out repository folder, run:

```sh
./Scripts/install.sh
```

This builds the driver and installs it for your logged-in account. It does not use `sudo`. Lift your fingers from the Edge and release mouse buttons before replacing a running driver. Approve the installed driver in Privacy & Security as described in the [README](README.md#allow-touch-input).

For Developer ID signing during source installation, set `CODESIGN_IDENTITY` to your own signing identity. Your private key remains in your Mac's keychain. To build here and install on another Mac without development tools, follow [Make a portable installer](docs/PORTABLE-INSTALLER.md).

## Run the checks


Run the native tests and both build configurations on macOS:

```sh
swift test
swift build --configuration debug
swift build --configuration release
/bin/sh -n Scripts/install.sh
/bin/sh -n Scripts/uninstall.sh
python3 Scripts/test-install.py
python3 Scripts/test-uninstall.py
```

The tests use simulated input and a virtual clock. They do not run the driver, need an attached Edge or request macOS permissions. GitHub Actions runs tests and builds on macOS for pushes and pull requests.

Installer and uninstaller tests use temporary folders and simulated signing and launchctl commands. They cover failures without changing your installed driver. The installer workflow runs when its scripts, template or workflow change.

The package declares macOS 13 as its minimum deployment target. A successful build or CI run does not establish runtime validation on macOS 13.

## Investigate input or display problems

`swift run DisplayInfo` lists connected displays so you can check the optional display settings. The driver refreshes its selection before a new touch; it pauses input when several displays match equally well.

For USB touch reports, stop the installed driver first, then run `swift run HIDDump`. This tool uses non-seize mode, so it does not take exclusive control of the Edge. Do not run a seizing diagnostic or a second driver alongside the production driver. Quit HIDDump before restarting the installed service.

`swift run HIDDump --describe-input-cache` reports descriptors and cached-read errors without opening the device. Add `--open` for non-seize cached reads after stopping the driver. This requires an existing Input Monitoring grant; it does not request permission or send feature requests.

The [technical reference](docs/TECHNICAL-REFERENCE.md) has service commands, permission recovery details, opt-in hardware checks, timing measurements and offline report replay. [Settings](docs/SETTINGS.md) documents the config fields and input behavior.

## Submit a change

Keep a pull request focused on a problem or feature that can be reviewed on its own. Explain the behavior before and after the change, the checks you ran, and anything you could not test. Add regression coverage for behavior that can be reproduced without hardware.

Keep hardware claims specific to the setup and actions you checked. A passing simulated test or cross-compile does not establish that another Mac, macOS version or display arrangement works. Include a short hardware checklist when a change affects touch delivery, focus, reconnects or installation.

Use plain language in public instructions. Put the steps a user needs first and keep implementation details in the contributor references. Credit contributions where their code, tests or proposals are used.
