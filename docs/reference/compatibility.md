# Compatibility Specification & Matrix

This document outlines KeyNest's compatibility with the KeePass database format, external KeePass clients, and operating system platforms.

---

## 1. KeePass / KDBX Format Matrix

| Format | Read Support | Write Support | Key Derivation Functions | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **KDBX 3.1** | Yes | Yes | AES-KDF | Full backward compatibility with legacy KeePass 2.x databases. |
| **KDBX 4.0** | Yes | Yes | Argon2id, Argon2d, AES-KDF | Primary default format for all newly created vaults. |
| **KDBX 4.1** | Yes | Yes | Argon2id, Argon2d, AES-KDF | Supports custom entry data and enhanced header tags. |

---

## 2. Interoperability with External KeePass Clients

Vaults created or edited in KeyNest are 100% interoperable with other major KeePass-compatible applications:

| External Client | Platform | Compatibility Level |
| :--- | :--- | :--- |
| **KeePassXC** | Windows, macOS, Linux | Full read/write compatibility, custom fields, entry history, and TOTP seeds. |
| **KeePass 2.x** | Windows (.NET / Mono) | Full read/write compatibility. (Argon2 requires KeePass 2.35+). |
| **KeePassDX** | Android | Full read/write compatibility. |
| **Strongbox** | iOS, macOS | Full read/write compatibility. |
| **KeeWeb** | Web / Desktop | Full read/write compatibility. |

---

## 3. Platform Operating System Support

| Operating System | Architecture | Minimum Supported OS Version | Status |
| :--- | :--- | :--- | :--- |
| **Android** | `arm64-v8a`, `armeabi-v7a`, `x86_64` | Android 8.0 (API 26) or newer. | Verified |
| **Windows** | `x64` | Windows 10 (Build 19041+) or Windows 11. | Verified |
| **Linux** | `x86_64` | Ubuntu 20.04+, Debian 11+, Fedora 36+ or compatible GTK3 distribution. | Verified |
| **Web** | Any modern Evergreen browser | Chrome 90+, Safari 14+, Firefox 88+, Edge 90+. | Verified |
| **iOS** | `arm64` | iOS 15.0 or newer. | Not verified |
| **macOS** | `arm64` (Apple Silicon), `x86_64` (Intel) | macOS 11.0 (Big Sur) or newer. | Not verified |

---

[← Configuration](configuration.md) • [Reference Index](README.md) • [Documentation Index →](../README.md)
