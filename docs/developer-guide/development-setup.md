# Development Setup & Toolchain Prerequisites

This document outlines the required developer toolchains, environment configurations, and initial repository setup needed to build and debug KeyNest locally.

---

## 1. Prerequisites

### Required Tools
- **Flutter SDK:** Flutter 3.10.0+ through 3.29.x (Dart 3.x).
- **Git:** Version 2.30+ with submodules support.
- **Platform Toolchains:**
  - **Android:** Android Studio / Android SDK (API 34+ build-tools, NDK for Argon2 FFI compilation, Java 17).
  - **iOS / macOS:** Xcode 15+ (macOS host only), CocoaPods 1.13+.
  - **Windows:** Visual Studio 2022 with **Desktop development with C++** and Windows 10/11 SDK.
  - **Linux:** `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libsecret-1-dev`.

---

## 2. Cloning the Repository

Clone the repository recursively to ensure all submodules and vendored plugins are checked out:

```bash
git clone --recursive https://github.com/moshinop/keynest.git
cd keynest
```

If you previously cloned without `--recursive`:
```bash
git submodule update --init --recursive
```

---

## 3. Resolving Dependencies

KeyNest contains multiple connected packages. Install dependencies across the primary packages:

```bash
# 1. Main Flutter application
cd keynest
flutter pub get

# 2. Shared autofill contract (pure Dart)
cd ../autofill_shared
dart pub get

# 3. Headless autofill module (Flutter module)
cd ../autofill_module
flutter pub get

# Return to main app directory
cd ../keynest
```

---

## 4. Code Generation

KeyNest uses `build_runner` for generating JSON serialization, BuiltValue, Freezed, and Mockito test mocks:

```bash
cd keynest
flutter pub run build_runner build --delete-conflicting-outputs
```

---

## 5. Running the Application

### Running on Connected Device / Emulator
```bash
cd keynest
flutter run
```

### Specifying Target Platform
```bash
# Run on Windows Desktop
flutter run -d windows

# Run on macOS Desktop
flutter run -d macos

# Run on Linux Desktop
flutter run -d linux

# Run on Android Emulator / USB Device
flutter run -d android

# Run on iOS Simulator
flutter run -d ios

# Run in Chrome
flutter run -d chrome
```

---

## 6. Code Style & Quality Checks

Run the analyzer and test suite before submitting pull requests:

```bash
cd keynest

# 1. Static Analysis
flutter analyze

# 2. Unit & Widget Tests
flutter test
```

---

[← Developer Guide Index](README.md) • [Architecture Overview →](architecture.md)
