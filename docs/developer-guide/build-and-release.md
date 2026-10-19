# Build & Release Engineering

This document outlines the build automation, packaging scripts, and release procedures for KeyNest across supported desktop and mobile targets.

---

## 1. Release Automation Tooling (`keynest/_tools/`)

KeyNest maintains production release and signing scripts inside [`keynest/_tools/`](../../keynest/_tools/):

| Script | Purpose |
| :--- | :--- |
| `ci-release.sh` | Main CI entry point for coordinating version increments and multi-platform packaging. |
| `release.sh` | Orchestrates local release builds, tag creation, and artifact generation. |
| `build-android.sh` / `upload-android.sh` | Builds release AAB / APK bundles and publishes to Google Play tracks. |
| `build-ios.sh` / `upload-ios.sh` | Archives Xcode Runner and uploads to Apple App Store Connect / TestFlight. |
| `build-macos.sh` / `upload-macos.sh` | Builds signed and notarized macOS `.app` and `.pkg` bundles. |
| `notarize-macos.sh` | Automates Apple `notarytool` submissions and staple operations. |
| `windows/create_release.sh` | Compiles Windows release binaries and packages MSIX installer. |

---

## 2. Platform Build Instructions

### Android Release Build
```bash
cd keynest
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab

flutter build apk --release --split-per-abi
# Output: build/app/outputs/apk/release/*.apk
```

### iOS Release Build (macOS Host Only)
```bash
cd keynest
flutter build ipa --release
# Output: build/ios/ipa/*.ipa
```

### Windows Desktop & MSIX
```bash
cd keynest
flutter build windows --release
flutter pub run msix:create
# Output: build/windows/x64/runner/Release/keynest.msix
```

### macOS Desktop & DMG
```bash
cd keynest
flutter build macos --release
```

### Linux Desktop & Debian Package
```bash
cd keynest
flutter build linux --release
# To create .deb package:
# .github/workflows/make_deb.yaml
```

---

[← Testing Guide](testing.md) • [Developer Guide Index](README.md) • [Reference Index →](../reference/README.md)
