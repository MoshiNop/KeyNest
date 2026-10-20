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

### 🛡️ True Vault Ownership & Security
- **Open KDBX Standard:** Native support for both **KDBX 3.1** and **KDBX 4.x** (compatible with KeePassXC, KeePass 2.x, KeePassDX, and Strongbox).
- **Modern Key Derivation:** Hardened against GPU brute-force attacks with **Argon2id** and **AES-KDF**.
- **Two-Factor Vault Protection:** Optional **Key File** (`.key` / `.keyx`) composite authentication.
- **In-Memory Hardening:** Sensitive credentials are held in memory as encrypted stream objects (`ProtectedValue`) rather than plain text.
- **Screen Protection:** Enables `FLAG_SECURE` on Android to block screen recordings, task-switcher snapshots, and spyware.

### 🔑 Flexible Entry Archetypes
- **Logins:** Username, password, website URL, custom ports, and attached TOTP seeds.
- **Payment Cards:** Cardholder, card number, expiration date, CVV, PIN, and issuer brand detection.
- **Secure Notes:** Encrypted long-form notes and recovery keys.
- **Structured Records:** Identity cards, server configurations, Wi-Fi credentials, and custom attributes.
- **Custom Attributes:** Attach arbitrary text, hidden/secret fields, or TOTP keys to any entry.

### ⏱️ Integrated Two-Factor Authenticator (TOTP)
- **RFC 6238 / RFC 4226 Compliant:** Built-in TOTP generation with standard 30-second countdown timers.
- **Camera QR Scanner:** Instantly scan 2FA setup QR codes directly through your device camera.
- **Google Authenticator Import:** Import Google Authenticator migration QR codes directly into your vault.

### 📲 Native Operating System Autofill
- **Android Autofill Framework:** Suggests credentials inline and through native bottom sheets in Chrome, Firefox, and native apps (Android 8.0+).
- **iOS Credential Provider Extension:** Integrates with Apple's `ASCredentialProviderViewController` to offer credentials in Safari and iOS apps via Face ID / Touch ID.
- **Domain Matching (eTLD+1):** Uses the public suffix list to prevent phishing across untrusted subdomains.

### ☁️ Cloud Synchronization & 3-Way Merge
- **Multi-Cloud Backends:** Connect to **WebDAV** (Nextcloud / ownCloud), **Google Drive**, **Dropbox**, and **OneDrive**.
- **Intelligent 3-Way Merge Engine:** When multiple devices edit a vault offline, KeyNest automatically detects non-conflicting modifications and resolves conflicts without duplicating files or losing data.
- **Offline First:** Full offline functionality with local cached copies; pending edits upload automatically upon reconnection.

### 🔄 Import, Export & Password Generation
- **Visual CSV Importer:** Interactive column mapping supporting exports from **Bitwarden**, **1Password**, **KeePass**, and **Chrome**.
- **Export Options:** Export to standard KDBX files, KeePass XML, or plain CSV.
- **CSPRNG Password Generator:** Customizable length (8–128 chars), character sets, ambiguous character filters, and passphrase mode.
- **Vault Health Audit:** Identifies reused, weak, and missing 2FA credentials across your vaults.

---

## Supported Platforms

KeyNest is tested and packaged across desktop, mobile, and web targets:

| Platform | Minimum Requirement | Distribution |
| :--- | :--- | :--- |
| **Android** | Android 8.0 (API 26)+ | Direct APK, Google Play Bundle |
| **iOS** | iOS 15.0+ | Apple App Store, TestFlight |
| **Windows** | Windows 10 (Build 19041+) / Windows 11 (x64) | MSIX Installer, Portable ZIP |
| **macOS** | macOS 11.0 (Big Sur)+ (Intel & Apple Silicon) | Signed macOS `.app`, DMG |
| **Linux** | Ubuntu 20.04+, Debian 11+, Fedora 36+ | Debian `.deb`, Standalone Tarball |
| **Web** | Modern Web Browsers (Chrome, Firefox, Safari, Edge) | Static Progressive Web App (PWA) |

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
