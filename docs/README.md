# KeyNest Documentation Index

Welcome to the comprehensive documentation system for **KeyNest**, the cross-platform, zero-knowledge password manager built with Flutter and based on the open KDBX vault standard.

---

## Documentation Sections

### 1. [User Guide](user-guide/README.md)
Instructions and tutorials for everyday users:
- [Installation](user-guide/installation.md) - Platform installation options and system requirements.
- [Getting Started](user-guide/getting-started.md) - Creating your first vault, master passwords, and interface walkthrough.
- [Vault Management](user-guide/vault-management.md) - Multi-vault workflows, vault health audits, and key files.
- [Passwords & Entries](user-guide/passwords-and-entries.md) - Entry archetypes (Logins, Cards, Notes, Records), custom fields, generator.
- [Two-Factor Authentication (TOTP)](user-guide/totp.md) - Built-in TOTP authenticator, QR code scanner, migration import.
- [Autofill Integration](user-guide/autofill.md) - Native Android Autofill and iOS Credential Provider setup.
- [Cloud Storage & Sync](user-guide/cloud-storage.md) - WebDAV (Nextcloud), Google Drive, Dropbox, OneDrive, 3-way merge.
- [Import & Export](user-guide/import-export.md) - Migrating from Bitwarden, 1Password, KeePass, or Chrome CSV.
- [Troubleshooting](user-guide/troubleshooting.md) - Common issues, error messages, and sync conflict resolution.

### 2. [Developer Guide](developer-guide/README.md)
Technical architecture, system designs, and development workflows for contributors:
- [Development Setup](developer-guide/development-setup.md) - Prerequisites, toolchain setup, and running KeyNest locally.
- [Architecture Overview](developer-guide/architecture.md) - High-level system design, BLoC pattern, reactive state management.
- [Project Structure](developer-guide/project-structure.md) - Monorepo package boundaries (`keynest`, `autofill_module`, `autofill_shared`).
- [Data Models](developer-guide/data-models.md) - KDBX object hierarchy, `KdbxEntry`, `ProtectedValue`, archetypes.
- [KDBX Integration](developer-guide/kdbx-integration.md) - Key derivation (Argon2id/AES), KDBX 3.1/4.x, three-way merge engine.
- [Security Design](developer-guide/security-design.md) - Threat model, memory protection, hardware keystore biometrics, `FLAG_SECURE`.
- [Android Integration](developer-guide/android-integration.md) - Native AutofillService plugin, Storage Access Framework (SAF).
- [iOS Integration](developer-guide/ios-integration.md) - Apple Credential Provider Extension, headless Flutter module, Keychain App Group.
- [Cloud Integrations](developer-guide/cloud-integrations.md) - `CloudStorageProvider` interface, OAuth2, WebDAV, background sync engine.
- [Testing Guide](developer-guide/testing.md) - Unit tests, widget tests, Mockito mocks, integration test suite.
- [Build & Release](developer-guide/build-and-release.md) - Build configurations, MSIX packaging, Debian packages, release scripts.

### 3. [Technical Reference](reference/README.md)
Specifications, dependencies, and compatibility tables:
- [Dependencies & Justifications](reference/dependencies.md) - Complete audit of third-party packages and architectural roles.
- [Configuration Reference](reference/configuration.md) - Build flags, MSIX package config, localization setup.
- [Compatibility Matrix](reference/compatibility.md) - KeePass format compatibility, external client interoperability, OS support.

### 4. [Assets & Branding](assets/README.md)
- [Logo Specifications](assets/logo/README.md) - Official logos, colors, and iconography.
- [Screenshot Repository & Manifest](assets/screenshots/README.md) - Screenshot specifications, naming conventions, and gallery guide.

---

[← Back to Main Repository Homepage](../README.md)
