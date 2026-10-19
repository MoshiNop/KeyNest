# KeyNest Core Application Package

This directory contains the primary Flutter client application for **KeyNest**.

## Directory Responsibilities

- **Platform Runners:**
  - `android/`: Native Android project (`MainActivity`, Gradle build scripts, AndroidManifest).
  - `ios/`: Native iOS Xcode workspace, App Store provisioning, and Runner target.
  - `macos/`: Native macOS desktop host application with App Sandbox entitlements.
  - `windows/`: Native Windows desktop host application with Win32 and MSIX packaging.
  - `linux/`: Native Linux GTK3 desktop host application.
  - `web/`: Static Progressive Web App (PWA) shell and web service workers.
- **Dart Source Code (`lib/`):**
  - `bloc/`: Core state controllers (`KdbxBloc`, `AppData`, `CloudStorageBloc`, `AnalyticsBloc`).
  - `cloud_storage/`: Cloud storage provider implementations (WebDAV, Google Drive, Dropbox, OneDrive).
  - `services/`: Specialized services (`KeyNestVaultMergeEngine`, `KeyNestImportExportService`, `KeyNestSafService`, `KeyFileStore`, `SecurityService`).
  - `ui/`: Design tokens, screens, dialogs, and reusable custom widgets.
  - `utils/`: Helper utilities (RFC 6238 TOTP, CSPRNG password generator, path helpers).
- **Automated Tests (`test/`, `integration_test/`):**
  - Over 300 unit, widget, and integration tests covering vault health audits, password generation, master password rotation, and storage badge layouts.
- **Automation Tooling (`_tools/`):**
  - Release automation and signing scripts (`ci-release.sh`, `notarize-macos.sh`, `windows/create_release.sh`).

## Development Quick Start

```bash
# 1. Install dependencies
flutter pub get

# 2. Run code generation
flutter pub run build_runner build --delete-conflicting-outputs

# 3. Run test suite
flutter test

# 4. Run application
flutter run
```

For complete documentation, see the [KeyNest Documentation Index](../docs/README.md).
