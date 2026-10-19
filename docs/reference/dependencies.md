# Dependencies & Architectural Justifications

This document audits the core runtime and development dependencies utilized by KeyNest as defined in [`keynest/pubspec.yaml`](../../keynest/pubspec.yaml).

---

## 1. Vault Storage & Cryptography

| Package | Version | Purpose & Architectural Justification |
| :--- | :--- | :--- |
| `kdbx` | `^2.5.0` | Core KeePass database reader, writer, and XML DOM parser. Supports `TransformedKeyCredentials` and `kdfFingerprint` required for lightweight autofill unlocking. |
| `argon2_ffi` / `argon2_ffi_base` | `^1.1.1` | Native C FFI bindings for the Argon2 password hashing algorithm, providing high-performance key derivation across all supported OS targets. |
| `pointycastle` | `^4.0.0` | Comprehensive Dart cryptography library used for internal crypto operations, hashes, and stream ciphers. |
| `crypto` | `^3.0.3` | Standard Dart cryptographic hash primitives (SHA-1, SHA-256, HMAC). |
| `zxcvbn` | `^1.0.0` | Client-side password strength estimation and entropy calculator based on realistic password-cracking patterns. |
| `biometric_storage` | `^5.2.0-dev.1` | Secure persistent storage backed by Android KeyStore and Apple Keychain Services with `darwinKeychainAccessGroup` support. |

---

## 2. Cloud Storage & Network Protocols

| Package | Version | Purpose & Architectural Justification |
| :--- | :--- | :--- |
| `http` | `^1.2.0` | Foundation HTTP client for cloud API requests and synchronization. |
| `http_auth` | `^1.0.0` | Basic and Digest authentication support for WebDAV server connections. |
| `xml` | `>=5.5.0 <7.0.0` | Parsing WebDAV `PROPFIND` multistatus XML payloads and KeePass XML export files. |
| `googleapis` / `googleapis_auth` | `^15.0.0` / `^2.0.0` | Official Google APIs client library for Google Drive file operations. |
| `google_sign_in` | `^7.0.0` | Native OAuth 2.0 Google account authentication across Android, iOS, and Web. |
| `oauth2` | `git` | RFC 6749 OAuth 2.0 PKCE authentication client for Dropbox and OneDrive integrations. |

---

## 3. Native Integration & System Services

| Package | Version | Purpose & Architectural Justification |
| :--- | :--- | :--- |
| `autofill_service` | `path: ../deps/autofill_service` | Custom plugin interfacing with Android's native `AutofillService` API. |
| `autofill_shared` | `path: ../autofill_shared` | Shared pure Dart vault manifest index and domain matcher. |
| `public_suffix` | `^3.0.0` | Effective Top-Level Domain (`eTLD+1`) domain normalization to prevent autofill phishing across subdomains. |
| `file_picker_writable` | `^2.1.0+1` | Android Storage Access Framework (SAF) integration for persistable file write permissions. |
| `mobile_scanner` | `^7.0.1` | Native camera-based barcode and QR code scanner for scanning 2FA/TOTP setup codes. |
| `otp` / `otpauth_migration` | `^3.0.0` | RFC 6238 TOTP algorithm implementation and Google Authenticator protobuf migration decoder. |
| `flutter_windowmanager` | `git` | Sets `FLAG_SECURE` on Android to block screen captures and task-switcher snapshots. |
| `winsparkle_flutter` | `git` | Automatic updater integration for Windows desktop releases via WinSparkle. |
| `msix` | `^3.6.2` | Generates modern Windows MSIX installer packages for Windows Store and direct distribution. |

---

[← Reference Index](README.md) • [Configuration Reference →](configuration.md)
