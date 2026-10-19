# Project Structure & Repository Layout

This document details the monorepo organization, directory responsibilities, and package boundaries of KeyNest.

---

## 1. Top-Level Repository Layout

```text
authpass-main/
├── .github/                      # GitHub Actions CI/CD workflows
├── keynest/                      # Primary Flutter cross-platform client app
├── autofill_shared/              # Pure Dart package: shared manifest & matching contract
├── autofill_module/              # Headless Flutter module for iOS Credential Provider Extension
├── deps/                         # Vendored and submodule plugins
│   └── autofill_service/         # Custom Flutter plugin for Android AutofillService
├── docs/                         # Comprehensive project documentation system
├── LICENSE                       # GNU General Public License v3.0
└── analysis_options.yaml         # Root linting rules
```

---

## 2. Main Flutter Application (`keynest/`)

The `keynest/` folder contains the primary client application:

```text
keynest/
├── android/                      # Native Android project (MainActivity, Gradle, Manifest)
├── ios/                          # Native iOS project & Runner
│   └── KeyNestAutofill/          # Native Swift ASCredentialProviderViewController extension
├── macos/                        # Native macOS Runner (App Sandbox, entitlements)
├── windows/                      # Native Windows C++ Runner (Win32, MSIX setup)
├── linux/                        # Native Linux GTK Runner
├── web/                          # Static Web shell (index.html, service worker)
├── assets/                       # Bundled static assets
│   ├── fonts/                    # Inter, JetBrains Mono, KeyNestIcons font
│   └── images/                   # App icons, splash screens, branding assets
├── lib/                          # Dart source code
│   ├── autofill/                 # Autofill mirror synchronization
│   ├── bloc/                     # State management (KdbxBloc, AppData, Analytics)
│   ├── cloud_storage/            # Cloud providers (WebDAV, Google Drive, Dropbox, OneDrive)
│   ├── env/                      # Build environment definitions
│   ├── l10n/                     # Localization ARB files (multiple languages)
│   ├── services/                 # Business logic services (Merge engine, SAF, Import/Export)
│   ├── ui/                       # Presentation widgets, screens, and design system
│   └── utils/                    # Helper utilities (TOTP, password generator, crypto, paths)
├── test/                         # Unit and widget test suite
├── integration_test/             # End-to-end device integration tests
└── _tools/                       # Release automation scripts, CI helpers, build tools
```

---

## 3. Package Responsibilities & Boundaries

### `autofill_shared/` (Pure Dart)
- **Role:** Defines the data contract between KeyNest and credential providers.
- **Why Pure Dart:** Apple enforces a strict ~120 MB RAM limit on iOS App Extensions. Loading heavy Flutter framework dependencies inside the extension's helper contracts would risk OS termination.
- **Key Modules:**
  - `vault_manifest.dart`: Binary/JSON index of mirrored vaults.
  - `credential_matcher.dart`: Effective Top-Level Domain (`eTLD+1`) matching via the public suffix list.

### `autofill_module/` (Headless Flutter Module)
- **Role:** Compiled as a headless Flutter engine for the iOS Extension.
- **Responsibilities:** Opens mirrored KDBX vaults using pre-transformed keys (avoiding expensive Argon2 derivation inside the extension) and returns matching credentials to Swift.

### `deps/autofill_service/` (Android Plugin)
- **Role:** Bridges Flutter with Android's native `android.service.autofill.AutofillService` API.
- **Responsibilities:** Handles `onFillRequest`, displays KeyNest UI overlays, and commits filled values via `FillResponse`.

---

[← Architecture Overview](architecture.md) • [Developer Guide Index](README.md) • [Data Models →](data-models.md)
