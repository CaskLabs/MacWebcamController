# MacWebcamController

> ⚠️ **This project is in the planning stage. Development has not started
> yet.** The structure, features, and architecture described below
> represent the intended design and are subject to change.

A lightweight macOS menu bar app to control UVC camera settings —
brightness, contrast, saturation, white balance, focus, and more —
directly from your menu bar or a full standalone window.

> **Inspired by [CameraController](https://github.com/itaybre/CameraController)**,
> which is no longer actively maintained. MacWebcamController is a
> modern, open-source rewrite built with SwiftUI and native IOKit.

---

## Planned Features

- 📷 **Supports any UVC-compliant USB camera**
- 🎛️ **Full UVC control surface** — brightness, contrast, saturation,
  sharpness, gamma, white balance, gain, exposure, focus, backlight
  compensation, and anti-flicker (powerline frequency)
- 🖥️ **Menu bar mode** — quick access via a compact popover
- 🪟 **Standalone window mode** — full controls in a dedicated window
- 🔄 **Per-camera settings persistence** — remembers your settings per
  device using `UserDefaults`
- 🍎 **Native macOS app** — built with SwiftUI + AppKit, no external
  dependencies
- ⚡ **Designed for Apple Silicon**

---

## Requirements

- **macOS 26 (Tahoe)** or later
- An external USB UVC-compliant camera
  _(built-in FaceTime cameras have limited UVC support due to Apple
  restrictions)_
- Xcode 26 or later (to build from source)

---

## Installation

> 🚧 No releases or builds are available yet. This section will be
> updated once development begins.

---

## Planned Architecture

```
MacWebcamController
├── AppDelegate          # Menu bar item, popover, and window lifecycle
├── MenuBarView          # Compact SwiftUI popover view
├── MainWindowView       # Full SwiftUI window with all controls
├── CameraManager        # AVFoundation: camera discovery and selection
├── UVCDevice            # IOKit: read/write UVC controls via USB
│   └── UVCControl       # Enum of all standard UVC controls + selectors
└── CameraViewModel      # ObservableObject binding UVC state to SwiftUI
```

**Planned tech stack:**
- UI: SwiftUI
- Camera discovery: AVFoundation
- UVC control: IOKit (direct USB control requests, no external libraries)
- Persistence: UserDefaults (per camera, keyed by device ID)

---

## Planned UVC Controls

| Control                | Unit             |
|------------------------|------------------|
| Brightness             | Processing Unit  |
| Contrast               | Processing Unit  |
| Saturation             | Processing Unit  |
| Sharpness              | Processing Unit  |
| Gamma                  | Processing Unit  |
| White Balance (temp)   | Processing Unit  |
| Gain                   | Processing Unit  |
| Backlight Compensation | Processing Unit  |
| Powerline Frequency    | Processing Unit  |
| Exposure (absolute)    | Camera Terminal  |
| Focus (absolute)       | Camera Terminal  |

> Not all cameras support all controls. Unavailable controls will be
> automatically greyed out.

---

## References

- [USB Video Class 1.5 Specification](https://www.usb.org/document-library/video-class-v15-document-set)
- [CameraController](https://github.com/itaybre/CameraController) —
  original inspiration, Objective-C + IOKit
- [uvc-util](https://github.com/jtfrey/uvc-util) — CLI reference for
  UVC descriptor parsing

---

## Contributing

> 🚧 The project is not yet ready for contributions. Once development
> kicks off, contributions will be welcome. Feel free to open an issue
> to share ideas or feedback in the meantime.
