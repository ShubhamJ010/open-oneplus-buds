# Changelog

All notable changes to **Buds** are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.1] - 2026-10-13

### Added
- **Dynamic Beat & Waveform Playback Animations**: Integrated `MediaRemote` and CoreAudio hardware state listeners to detect live system audio output. When media is playing, the popover header icon springs to the beat with bouncing earbuds and musical note companion (`music.quarternote.3`), paired with an active animated `waveform` visualizer.
- **Audio "Now Playing" Subtitle**: Popover status automatically reflects active playback state without polling.

### Improved
- **Bluetooth State Diagnostics**: Clear contextual guidance, direct System Settings shortcut, and permission prompts when Bluetooth is powered off or unauthorized.
- **Refined Liquid Glass UX**: Streamlined popover header layout, eliminated redundant error chips, and maintained minimal menu bar footprint.

---

## [0.1.0] - 2026-10-13

### Added
- **OnePlus Buds Z2 Support**: Added GATT routing (`000008A4`), multi-frame packet parsing (decoupling concatenated `0xAA` frames), and accurate mapping for Normal (`0x04`) and Max (`0x08`) noise cancellation modes.
- **Liquid Glass Redesign**: Complete UI overhaul featuring native macOS glass cards, interactive metric pills, dynamic status badges, and polished quit controls.
- **Audio Connection Snatching**: Single-click take-over of audio playback from a connected mobile device to macOS using baseband paging takeover in `reconnectNow`.
- **Seamless Disconnect & Handoff**: Release the Bluetooth Classic ACL link to allow earbuds to automatically fall back to paired mobile devices.
- **Menu Bar Right-Click Shortcut**: Added low-overhead `MenuBarRightClickMonitor` for secondary-click or two-finger tap disconnect directly on the status bar icon.
- **Lid-Open Advertisement Telemetry**: Decodes manufacturer broadcast packets (`Company ID 0x072F`) for instant battery readouts when case lid opens.
- **Release Packaging Automation**: Scripts for building `.dmg` and `.zip` distribution bundles with best-effort ad-hoc code signing.

---

## [0.0.1] - Initial Release

- Core reverse-engineered OPOv1 protocol support.
- Native SwiftUI menu bar app for noise cancellation toggle (Off, Transparency, ANC).
- Standalone CLI tool (`nordbuds.swift`).
- Event-driven CoreBluetooth architecture with zero polling.
