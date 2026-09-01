# Third-Party Research and Design References

No third-party source code is vendored by this project, and none of the projects below is a runtime dependency. Their public work informed hardware validation and design decisions in the multi-display implementation.

## Touch-Up

- Repository: [shueber/Touch-Up](https://github.com/shueber/Touch-Up)
- Author: Sebastian Hueber
- License: [MIT](https://github.com/shueber/Touch-Up/blob/main/LICENSE)
- Consulted for: associating a HID location identity with a stable CoreGraphics display UUID, and the direct-touch interaction model of tap, immediate scroll, and hold-to-drag.

## TouchscreenDriver

- Repository: [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver)
- Author credit: Yves-Marie Lainé with Claude
- License: the repository [README](https://github.com/ymlaine/TouchscreenDriver#license) identifies the work as MIT-licensed.
- Consulted for: WCH `27C0:0859` report behavior, raw coordinate ranges, and exclusive user-space HID capture on the Xeneon Edge.

## xeneon-edge-multitouch-macos

- Repository: [Myseri/xeneon-edge-multitouch-macos](https://github.com/Myseri/xeneon-edge-multitouch-macos)
- Author credit: xeneon-touch contributors
- License: [MIT](https://github.com/Myseri/xeneon-edge-multitouch-macos/blob/main/userspace/LICENSE)
- Consulted for: hardware-verified USB interface behavior and evidence for the single-touch limitation on macOS.

## m14t-touch-macos

- Repository: [talesmousinho/m14t-touch-macos](https://github.com/talesmousinho/m14t-touch-macos)
- Author: Tales Fonseca
- License: [MIT](https://github.com/talesmousinho/m14t-touch-macos/blob/main/LICENSE)
- Consulted for: separation of HID input, display resolution, coordinate mapping, and synthetic events in a dependency-free native Swift driver.
