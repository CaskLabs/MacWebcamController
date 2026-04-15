# MacWebcamController

A lightweight macOS menu bar app to control UVC camera settings —
brightness, contrast, saturation, white balance, focus, and more —
directly from your menu bar or a full standalone window.

> **Inspired by [CameraController](https://github.com/itaybre/CameraController)**,
> which is no longer actively maintained. MacWebcamController is a
> modern, open-source rewrite built with SwiftUI and native IOKit.

---

## Features

- 📷 **Supports any UVC-compliant USB camera** with 🎛️ **full UVC control surface**
- 🎥 **Live camera preview**
- 🖥️ **Menu bar mode** and 🪟 **Standalone window mode**
- 🤖 **Auto exposure, auto white balance & auto focus toggles**
- 💾 **Camera presets**
- 🔄 **Per-camera settings persistence**
- 🔃 **Reset all controls to device defaults** — one-click button in the menu bar and full window
- 🚀 **Launch at Login**
- 🍎 **Native macOS app** — built with SwiftUI + AppKit, no external dependencies
  
---

## Requirements

- **macOS 26 (Tahoe)** or later (older version might work, but were not tested)
- An external USB UVC-compliant camera
  _(built-in FaceTime cameras have limited UVC support due to Apple restrictions)_
- Xcode 26 or later (to build from source)

---

## Installation

Build from source using Xcode:

1. Clone the repository
2. Open `MacWebcamController.xcodeproj` in Xcode 26+
3. Select your Mac as the run destination
4. Build and run (⌘R)

No additional configuration is needed — the app has the sandbox disabled to allow direct IOKit USB access.

Later on it might be available through Homebrew.

---

## Usage

- **Menu bar icon (left-click)** — opens the compact popover with a camera picker and quick sliders for brightness, contrast, white balance, exposure and focus. Only controls supported by the connected camera are shown.
- **Menu bar icon (right-click)** — shows a context menu with "Open Full Controls", "Settings", and "Quit"
- **Auto toggles** — Auto Exposure toggle appears above the exposure slider in both the popover and the full window; Auto White Balance and Auto Focus work the same way
- **Reset button** — the ↺ button next to the camera picker in the menu bar resets all controls to device defaults
- **Full controls** — click "Open Full Controls" (or right-click the icon) to open the main window with all UVC controls organised in collapsible sections
- **Settings** — click the gear icon in the popover footer or the main window to open the settings page (appearance, launch at login)
- **Presets** — in the Presets section, click + to save the current settings as a named preset; apply, update, or delete presets at any time
- **Reset** — click "Reset" to restore all controls to their device defaults

---

## Architecture

```
MacWebcamController/
├── MacWebcamControllerApp.swift   # App entry point, AppDelegate, status bar right-click menu, dock icon management
├── UVC/
│   ├── UVCConstants.swift         # UVC spec constants (request codes, descriptor types)
│   ├── UVCControl.swift           # Enum of all UVC controls with selectors and data lengths
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
│   ├── CameraPreviewView.swift    # Live AVCaptureSession preview
│   └── SettingsView.swift         # Inline settings (appearance, launch at login)
└── Persistence/
    └── SettingsPersistence.swift  # UserDefaults persistence + preset JSON storage
```

**Tech stack:**
- UI: SwiftUI + AppKit
- Camera discovery: AVFoundation
- UVC control: IOKit / IOUSBHost (direct USB control requests, no external libraries)
- Persistence: UserDefaults (per camera, keyed by device ID)
- Concurrency: Swift 6 strict concurrency, dedicated serial DispatchQueue for IOKit I/O

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

## References

- [USB Video Class 1.5 Specification](https://www.usb.org/document-library/video-class-v15-document-set)
- [CameraController](https://github.com/itaybre/CameraController) — original inspiration, Objective-C + IOKit
- [uvc-util](https://github.com/jtfrey/uvc-util) — CLI reference for UVC descriptor parsing

---

## Planned / TODO

- [ ] **First Release**
- [ ] **Live preview in menu bar popover** — show a 16:9 camera preview directly in the compact popover. Blocked by a macOS AVFoundation limitation: two `AVCaptureSession` instances cannot capture the same device simultaneously. Requires sharing a single session between the menu bar and main window previews, which needs further investigation.
- [ ] **iCloud Sync Settings** (optional)

---

## Contributing

Contributions are welcome. Open an issue to discuss ideas or bugs, or submit a pull request directly.
