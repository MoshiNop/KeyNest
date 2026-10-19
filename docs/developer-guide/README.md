# KeyNest Developer Guide

Welcome to the **KeyNest Developer Guide**. This technical manual is designed for contributors, maintainers, and security researchers working on the KeyNest codebase.

---

## Technical Documentation Index

| Section | Contents | Document |
| :--- | :--- | :--- |
| **Development Setup** | Toolchain prerequisites, environment variables, dependencies, and IDE configuration. | [Read Guide](development-setup.md) |
| **Architecture Overview** | High-level system design, state management (BLoC), reactive data pipelines, and layers. | [Read Guide](architecture.md) |
| **Project Structure** | Monorepo layout, package boundaries (`keynest`, `autofill_module`, `autofill_shared`, `deps`). | [Read Guide](project-structure.md) |
| **Data Models** | KDBX object model, `KdbxFile`, `KdbxGroup`, `KdbxEntry`, `ProtectedValue`, and archetypes. | [Read Guide](data-models.md) |
| **KDBX Integration** | KDBX 3.1 & 4.x parser, Argon2id & AES key derivation, transformed credentials, 3-way merge engine. | [Read Guide](kdbx-integration.md) |
| **Security Design** | Threat model, in-memory protection, hardware keystore biometrics, screen security (`FLAG_SECURE`). | [Read Guide](security-design.md) |
| **Android Integration** | Native `MainActivity`, Android Autofill Service plugin, Storage Access Framework (SAF) engine. | [Read Guide](android-integration.md) |
| **iOS Integration** | Apple `ASCredentialProviderViewController`, headless `autofill_module`, Darwin Keychain App Group. | [Read Guide](ios-integration.md) |
| **Cloud Integrations** | `CloudStorageProvider` interface, OAuth2 flows, WebDAV client, and 3-way synchronization engine. | [Read Guide](cloud-integrations.md) |
| **Testing Guide** | Unit tests (`flutter test`), widget tests, Mockito mocks, integration tests, and CI test pipeline. | [Read Guide](testing.md) |
| **Build & Release** | Build configurations, MSIX packaging, Debian packages, release shell scripts in `_tools/`. | [Read Guide](build-and-release.md) |

---

## Key Technical Facts

- **Framework:** Flutter SDK 3.x (Dart 3.x with sound null safety).
- **Core Library:** Pure Dart [`kdbx`](https://pub.dev/packages/kdbx) package with custom extensions for composite credentials.
- **Argon2 Implementation:** FFI bindings via `argon2_ffi` using compiled native C libraries on Android, iOS, Windows, macOS, and Linux.
- **License:** GNU General Public License v3.0 ([LICENSE](../../LICENSE)).

---

[← Documentation Index](../README.md) • [Proceed to Development Setup →](development-setup.md)
