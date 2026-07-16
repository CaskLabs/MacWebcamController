# MacWebcamController

A lightweight macOS menu bar app for controlling the image settings exposed by UVC-compatible USB cameras. Adjust brightness, contrast, saturation, white balance, exposure, focus, and other supported controls from the menu bar or a standalone window with a live preview.

<p align="center">
  <img src="docs/images/macwebcamcontroller-ugreen-transparent.png" alt="MacWebcamController window showing a live camera preview, image controls, and presets" width="500">
</p>

> **Inspired by [CameraController](https://github.com/itaybre/CameraController)**,
> which is no longer actively maintained. MacWebcamController is a
> modern, open-source rewrite built with SwiftUI and native IOKit.

> [!NOTE]
> MacWebcamController is still a work in progress. Some features may not work as expected, and bugs are possible. Bug reports and feedback are welcome.
---

## Features

- 📷 **Supports UVC-compliant USB cameras** and automatically shows the controls each device reports
- 🖥️ **Menu bar mode** and 🪟 **Standalone window mode**
- 🎥 **Live camera preview** in the full window and, optionally, directly in the menu bar popover
- 🤖 **Auto exposure, auto white balance & auto focus toggles**
- 💾 **Camera presets**
- 🔄 **Per-camera settings persistence**, including automatic restore after reconnecting or changing USB ports
- 🔃 **Reset all controls to device defaults** — one-click button in the menu bar and full window
- 🚀 **Launch at Login**
- 🍎 **Native macOS app** — built with SwiftUI + AppKit, no external dependencies
  
---

## Requirements

- **macOS 26 (Tahoe)** or later on Apple Silicon
- An external USB UVC-compliant camera for hardware controls
  _(built-in, Continuity, and virtual cameras may appear for preview, but normally do not expose controls through the direct USB UVC layer)_
- Xcode 26 or later (to build from source)

---

## Installation

### Prebuilt release
Download the latest version from the [GitHub Releases page](https://github.com/CaskLabs/MacWebcamController/releases), move MacWebcamController.app to your Applications folder, and open it.

>[!NOTE]
> Current builds are unsigned and not notarized.
> If macOS blocks the app, allow it under System Settings → Privacy & Security → Open Anyway.
>
> Alternatively:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/MacWebcamController.app
> ```

### Homebrew
```bash
brew install --cask CaskLabs/tap/macwebcamcontroller
```

The same signing limitation applies to the current Homebrew cask artifact.


### Build from Source
1. Clone the repository.
2. Open `MacWebcamController.xcodeproj` in Xcode 26 or later.
3. Select your Mac and build and run with ⌘R.
   
No additional configuration is needed — the app has the sandbox disabled to allow direct IOKit USB access.

---

## Usage

- **Menu bar icon (left-click)** — opens the compact popover with a camera picker and quick sliders for brightness, contrast, white balance, exposure and focus. Only supported quick controls are shown.
- **Menu bar icon (right-click)** — shows a context menu with "Open Full Controls", "Settings", and "Quit"
- **Auto toggles** — Auto Exposure toggle appears above the exposure slider in both the popover and the full window; Auto White Balance and Auto Focus work the same way
- **Reset button** — the ↺ button in the menu bar and "Reset All" in the full window reset supported manual controls to their device defaults. Controls currently managed by an enabled auto mode are skipped, and the auto modes themselves are not changed.
- **Full controls** — click "Open Full Controls" (or right-click the icon) to open the main window with all UVC controls organised in collapsible sections
- **Menu bar preview** — enable "Show Camera Preview in Menu Bar" in Settings to add a 16:9 live preview to the compact popover
- **Settings** — click the gear icon in the popover footer, the main window, or the menu bar icon's right-click menu to open the settings page (appearance, menu bar preview, launch at login)
- **Presets** — in the Presets section, click + to save the current settings as a named preset; apply, update, or delete presets at any time

Settings are restored automatically when the camera is selected again with the same AVFoundation device ID. If a selected camera is moved to another USB port while the app remains running, the app also attempts an in-session name-based migration. This fallback is not guaranteed across an app restart or when multiple cameras share the same name.

---

## Architecture

```
MacWebcamController/
├── MacWebcamControllerApp.swift   # App entry point, AppDelegate, status bar right-click menu, dock icon management
├── UVC/
│   ├── UVCConstants.swift         # UVC spec constants (request codes, descriptor types)
│   ├── UVCControl.swift           # Enum of all UVC controls with selectors and data lengths
│   ├── UVCControlProber.swift     # Experimental capability prober (not wired into the current UI)
│   ├── UVCDescriptorParser.swift  # Parses config descriptors → PU/CT IDs and bmControls
│   ├── UVCDevice.swift            # IOUSBHostDevice wrapper: getValue / setValue
│   └── UVCDeviceDiscovery.swift   # IOKit matching for Video Control interfaces
├── Camera/
│   ├── CameraManager.swift        # AVFoundation discovery + hot-plug detection
│   └── CameraInfo.swift           # Per-camera data model (name, IDs, UVCDevice)
├── ViewModel/
│   ├── CameraViewModel.swift      # @Observable bridge between UVC hardware and SwiftUI
│   └── ControlState.swift         # Per-control state: current, min, max, default, resolution
├── Views/
│   ├── MenuBarView.swift          # Compact popover with quick controls
│   ├── MainWindowView.swift       # Full control window with collapsible sections
│   ├── ControlSliderView.swift    # Reusable slider with immediate visual response
│   ├── CameraPickerView.swift     # Camera selection dropdown
│   ├── CameraPreviewView.swift    # Shared AVCaptureSession controller and preview view
│   └── SettingsView.swift         # Inline settings (appearance, launch at login)
└── Persistence/
    └── SettingsPersistence.swift  # UserDefaults persistence + preset JSON storage
```

**Tech stack:**
- UI: SwiftUI + AppKit
- Camera discovery: AVFoundation
- UVC control: IOKit / IOUSBHost (direct USB control requests, no external libraries)
- Persistence: UserDefaults (per camera, primarily matched by AVFoundation device ID)
- Concurrency: Swift 6 strict concurrency, dedicated serial DispatchQueue for IOKit I/O
- Tests: XCTest coverage for UVC descriptor parsing, value encoding, settings persistence, and parts of camera matching

---

## Supported UVC Controls

| Control                | Unit             | Signed |
|------------------------|------------------|--------|
| Brightness             | Processing Unit  | yes    |
| Contrast               | Processing Unit  | no     |
| Saturation             | Processing Unit  | no     |
| Sharpness              | Processing Unit  | no     |
| Gamma                  | Processing Unit  | no     |
| White Balance (temp)   | Processing Unit  | no     |
| Gain                   | Processing Unit  | no     |
| Backlight Compensation | Processing Unit  | no     |
| Powerline Frequency    | Processing Unit  | no     |
| Exposure (absolute)    | Camera Terminal  | no     |
| Focus (absolute)       | Camera Terminal  | no     |

Not all cameras support all controls — unsupported controls are automatically hidden in both the menu bar popover and the full window.
Auto exposure, auto white balance and auto focus toggles are shown only when the camera reports support for them.

---

## Privacy and Security

- Camera frames are only used for the local live view. The app does not record or transmit video.
- Camera settings and presets are stored locally.
- The app contains no analytics, accounts, network services, or external runtime dependencies.
- The current build of this app are not signed, notarized or made for general distribution.

---

## References

- [USB Video Class 1.5 Specification](https://www.usb.org/document-library/video-class-v15-document-set)
- [CameraController](https://github.com/itaybre/CameraController) — original inspiration, Objective-C + IOKit
- [uvc-util](https://github.com/jtfrey/uvc-util) — CLI reference for UVC descriptor parsing

---

## Roadmap

- [ ] Improved release pipeline
- [ ] Explicit permission, preview, USB-error, and no-UVC states
- [ ] Stable physical-camera identity across USB ports and app restarts
- [ ] Complete reset semantics for manual and automatic controls
- [ ] Hide all unsupported controls consistently
- [ ] Broader `CameraViewModel`, hardware-mockup, UI, and accessibility test coverage
- [ ] Improved keyboard support for custom controls
- [ ] iCloud Sync Settings (optional)

---

## Contributing

Contributions are welcome. Open an issue to discuss ideas or bugs, or submit a pull request directly.
