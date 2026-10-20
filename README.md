<div align="center">

<img src="docs/assets/banner.png" alt="KeyNest - Your keys. Your privacy. Your control." width="100%" />

<br/><br/>

**Free, open-source, cross-platform password manager powered by the open KeePass KDBX format.**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![KDBX 3.1 & 4.x](https://img.shields.io/badge/KDBX-3.1%20%7C%204.x-338833?logo=keepassxc&logoColor=white)](https://keepass.info)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Web-4A154B)](#supported-platforms)

KeyNest is a modern, zero-knowledge credential manager built with Flutter. It puts you in total control of your digital keys using standard, battle-tested KeePass (`.kdbx`) databases—with no vendor lock-in, no mandatory cloud accounts, and no subscriptions.

[User Guide](docs/user-guide/README.md) • [Installation](docs/user-guide/installation.md) • [Developer Docs](docs/developer-guide/README.md) • [Security Policy](SECURITY.md) • [Contributing](CONTRIBUTING.md)

</div>

---

## Screenshot Showcase

The gallery below presents the core interface across desktop and mobile.

<table>
  <tr>
    <td width="50%" align="center">
      <b>Multi-Vault Dashboard & Search</b><br/>
      <img src="docs/assets/screenshots/vaults-dark.png" alt="KeyNest Multi-Vault Dashboard" width="100%" onerror="this.onerror=null; this.src='https://placehold.co/1280x800/1e1e1e/00e5ff?text=Dashboard+%26+Multi-Vault+View%0A(docs/assets/screenshots/vaults-dark.png)';"/><br/>
      <sub>Manage multiple KDBX vaults with real-time search, category chips, and compact sync badges.</sub>
    </td>
    <td width="50%" align="center">
      <b>Entry Details & Protected Fields</b><br/>
      <img src="docs/assets/screenshots/password-details.png" alt="Entry Details Screen" width="100%" onerror="this.onerror=null; this.src='https://placehold.co/1280x800/1e1e1e/00e5ff?text=Entry+Details+%26+Protected+Fields%0A(docs/assets/screenshots/password-details.png)';"/><br/>
      <sub>Protected memory fields, custom attributes, notes, and visual password strength indicator.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <b>Two-Factor Authenticator (TOTP)</b><br/>
      <img src="docs/assets/screenshots/totp-authenticator.png" alt="TOTP Authenticator Card" width="100%" onerror="this.onerror=null; this.src='https://placehold.co/1080x2400/1e1e1e/00e5ff?text=Integrated+TOTP+Authenticator%0A(docs/assets/screenshots/totp-authenticator.png)';"/><br/>
      <sub>Built-in RFC 6238 one-time code generation with animated countdown progress rings.</sub>
    </td>
    <td width="50%" align="center">
      <b>Cloud Storage & 3-Way Synchronization</b><br/>
      <img src="docs/assets/screenshots/cloud-vaults.png" alt="Cloud Vault Synchronization" width="100%" onerror="this.onerror=null; this.src='https://placehold.co/1280x800/1e1e1e/00e5ff?text=Cloud+Storage+%26+3-Way+Sync%0A(docs/assets/screenshots/cloud-vaults.png)';"/><br/>
      <sub>Sync via Nextcloud (WebDAV), Google Drive, Dropbox, or OneDrive with automatic merge resolution.</sub>
    </td>
  </tr>
</table>

---

## Features at a Glance

### Vault Security & Encryption
- **Standard KDBX Format:** Native support for KeePass 3.1 and 4.x databases with Argon2id and AES-KDF key derivation.
- **Composite Authentication:** Master password protection with optional `.key` and `.keyx` key files.
- **Zero-Knowledge Architecture:** Client-side encryption with in-memory protected byte streams (`ProtectedValue`).
- **Screen Protection:** System-level snapshot blocking via `FLAG_SECURE` on Android.

### Credential & Entry Management
- **Structured Archetypes:** Dedicated schemas for logins, payment cards, secure notes, and network credentials.
- **Custom Attributes:** Support for arbitrary key-value pairs, hidden fields, and attached TOTP seeds.
- **Integrated Authenticator:** RFC 6238 and RFC 4226 compliant TOTP generator with QR code scanning and Google Authenticator migration support.

### System Autofill
- **Platform Integrations:** Native Android Autofill Service and Apple Credential Provider Extension.
- **Phishing Protection:** Domain matching using public suffix lists (eTLD+1) across apps and browsers.

### Synchronization & Portability
- **Cloud Providers:** Synchronization with WebDAV (Nextcloud, ownCloud), Google Drive, Dropbox, and OneDrive.
- **Conflict Resolution:** Automated three-way merge engine to reconcile concurrent offline modifications.
- **Migration & Export:** Visual CSV import mapping for Bitwarden, 1Password, and KeePass, alongside KDBX, XML, and CSV export.
- **Password Generator:** Cryptographically secure pseudorandom generator (CSPRNG) with customizable character sets and passphrase modes.

---

## Supported Platforms

KeyNest targets desktop, mobile, and web environments:

| Platform | Minimum Requirement | Distribution | Status |
| :--- | :--- | :--- | :--- |
| **Android** | Android 8.0 (API 26)+ | Direct APK, Google Play Bundle | Verified |
| **Windows** | Windows 10 (Build 19041+) / Windows 11 (x64) | MSIX Installer, Portable ZIP | Verified |
| **Linux** | Ubuntu 20.04+, Debian 11+, Fedora 36+ | Debian `.deb`, Standalone Tarball | Verified |
| **Web** | Modern Web Browsers (Chrome, Firefox, Safari, Edge) | Static Progressive Web App (PWA) | Verified |
| **iOS** | iOS 15.0+ | Apple App Store, TestFlight | Not verified |
| **macOS** | macOS 11.0 (Big Sur)+ (Intel & Apple Silicon) | Signed macOS `.app`, DMG | Not verified |

---

## Quick Start & Installation

### Option A: Install a Release Package
Download the installer or binary for your operating system from the **[GitHub Releases](https://github.com/moshinop/keynest/releases)** page.

### Option B: Build From Source

#### 1. Prerequisites
- [Flutter SDK 3.x](https://docs.flutter.dev/get-started/install) (Dart 3.x)
- Git with submodules support
- Platform build tools (Xcode for iOS/macOS, Visual Studio for Windows C++, Android SDK for Android)

#### 2. Clone & Build
```bash
# Clone repository recursively
git clone --recursive https://github.com/moshinop/keynest.git
cd keynest

# Install dependencies across packages
cd keynest && flutter pub get
cd ../autofill_shared && dart pub get
cd ../autofill_module && flutter pub get
cd ../keynest

# Run code generation
flutter pub run build_runner build --delete-conflicting-outputs

# Launch on connected device or desktop
flutter run
```

For detailed platform prerequisites, see the [Development Setup Guide](docs/developer-guide/development-setup.md).

---

## Documentation System

KeyNest features comprehensive documentation for both users and developers:

```text
docs/
├── user-guide/                 # End-user tutorials and operational guides
│   ├── installation.md         # Detailed platform installation instructions
│   ├── getting-started.md      # Creating your first vault, master password advice
│   ├── vault-management.md     # Multi-vault, locking, health audits, key files
│   ├── passwords-and-entries.md# Archetypes (cards, notes, logins), custom fields
│   ├── totp.md                 # 2FA setup, QR code scanning, migration import
│   ├── autofill.md             # Android & iOS autofill configuration
│   ├── cloud-storage.md        # WebDAV, Google Drive, Dropbox, 3-way sync engine
│   ├── import-export.md        # Migrating from Bitwarden, 1Password, Chrome
│   └── troubleshooting.md      # Resolving unlock issues and sync conflicts
├── developer-guide/             # Technical architecture and contributor guides
│   ├── development-setup.md    # Toolchains, prerequisites, build commands
│   ├── architecture.md         # BLoC state management, data pipelines, layers
│   ├── project-structure.md    # Repository layout, package boundaries
│   ├── data-models.md          # KDBX object model, ProtectedValue, archetypes
│   ├── kdbx-integration.md     # Argon2id/AES key derivation, 3-way merge engine
│   ├── security-design.md      # Threat model, memory safety, hardware keystores
│   ├── android-integration.md  # AutofillService plugin, Storage Access Framework
│   ├── ios-integration.md      # Apple Credential Provider, headless module
│   ├── cloud-integrations.md   # CloudStorageProvider interface, background sync
│   ├── testing.md              # Running tests (flutter test), mockito, CI pipeline
│   └── build-and-release.md    # Release scripts, packaging MSIX/deb/AAB
└── reference/                  # Technical specifications
    ├── dependencies.md         # Third-party dependency audit & justifications
    ├── configuration.md        # Build-time environment flags, packaging schema
    └── compatibility.md        # KeePass format matrix, client interoperability
```

Visit the **[Complete Documentation Index](docs/README.md)** for a guided tour.

---

## Security & Vulnerability Reporting

Security is the core foundation of KeyNest. If you discover a vulnerability or potential security flaw, **do not open a public issue**. 

Please submit a confidential report through **[GitHub Private Vulnerability Reporting](https://github.com/moshinop/keynest/security/advisories/new)**. See our complete [Security Policy](SECURITY.md) for details on supported versions and cryptographic specifications.

---

## Contributing

We welcome community contributions! Please review our [Contributing Guidelines](CONTRIBUTING.md) for instructions on environment setup, coding standards, and our pull request process.

```bash
# Verify code quality before submitting PRs:
flutter analyze
flutter test
```

---

## License

KeyNest is free and open-source software distributed under the terms of the **[GNU General Public License v3.0](LICENSE)**.

```text
KeyNest - Cross-platform password manager based on KDBX.
Copyright (C) 2026 KeyNest Contributors.
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
```

---

## Acknowledgements

KeyNest builds upon and acknowledges the open-source work and foundations created by the [AuthPass project](https://github.com/authpass) and the KeePass community.
