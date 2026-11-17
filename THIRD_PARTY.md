# License and attribution

AltTab2 is distributed as a whole under the GNU General Public License, version 3 (GPL-3.0-only). You may redistribute and modify it under those terms. It comes WITHOUT ANY WARRANTY, including implied warranties of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.

Copyright (C) 2026 glasss13 for the AltTab2 changes. Portions derived from AltTab are copyright their respective authors, lwouis and contributors.

AltTab2 is a modified work incorporating code adapted from [AltTab](https://github.com/lwouis/alt-tab-macos), commit `2a9cbbb5462fbd0a76bb3f5f50d71b357823d6ab` (v11.10.2), distributed under GPLv3. It is not an official AltTab release.

Modified on 2026-11-17: the focus-event layout, private window-fronting calls, Space enumeration, and remote Accessibility token discovery were adapted into `Sources/WindowBridge/WindowBridge.c`. The Swift application implements a reduced feature set with cached thumbnails and asynchronous window discovery and focus.

Upstream source references:

- `src/macos/api-wrappers/WindowFocusEvent.swift`
- `src/macos/api-wrappers/SkyLight.framework.swift`
- `src/macos/api-wrappers/ApplicationServices.HIServices.framework.swift`
- `src/macos/api-wrappers/AXUIElement.swift`
- `src/macos/CGSCallScheduler.swift`

Corresponding source and build/install scripts: https://github.com/glasss13/alttab2

No AltTab artwork or third-party packages are bundled.
