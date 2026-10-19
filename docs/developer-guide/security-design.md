# Security Design & Threat Model

This document outlines KeyNest's security architecture, memory safety guarantees, cryptographic boundaries, and threat model.

---

## 1. Threat Model & Security Boundaries

### In Scope
- **Untrusted Storage Providers:** Cloud providers (Google Drive, Dropbox, WebDAV) must never be able to view decrypted vault contents, master passwords, or metadata.
- **Lost / Stolen Devices:** An attacker who obtains an encrypted `.kdbx` file cannot decrypt it without performing an intractable brute-force attack against Argon2id / AES-KDF.
- **Application Process Observation:** Malicious background processes or screen recorders attempting to snapshot credentials during user sessions.

### Out of Scope / Fundamental Assumptions
- **Compromised Host Kernel / Root Malware:** If the operating system kernel is rooted or keylogged, memory protection cannot prevent key extraction.
- **Weak Master Passwords:** An excessively short or predictable master password (e.g. `password123`) cannot be saved by cryptography alone.

---

## 2. In-Memory Protection

- **ProtectedValue Encrypted Streams:** Sensitive fields (passwords, PINs, OTP seeds) are maintained as `ProtectedValue` instances. In memory, they are not stored as contiguous raw ASCII strings.
- **Short-Lived Allocations:** Cryptographic keys and plain buffers are overwritten with zeros or garbage collected as rapidly as possible after I/O operations.
- **Auto-Lock Timers:** Inactivity timers automatically clear decrypted vault state and master credentials from memory when the app is backgrounded or idle.

---

## 3. Hardware-Backed Biometric Storage

When Biometric Unlock is enabled:
- KeyNest generates an encryption key stored within the OS hardware keystore:
  - **Android:** Android KeyStore with `KeyGenParameterSpec` requiring user biometric authentication (`setUserAuthenticationRequired(true)`).
  - **iOS / macOS:** Apple Secure Enclave / Keychain Services with `kSecAccessControlBiometryAny`.
- The key never leaves the hardware security module and cannot be exported.

---

## 4. Screen Security & Process Obfuscation

- **Android `FLAG_SECURE`:**
  - KeyNest sets `WindowManager.LayoutParams.FLAG_SECURE` on its Android activity window.
  - This prevents Android from saving snapshots of the app in the recent apps task switcher and blocks OS-level screenshots or screen capture malware.
- **iOS Privacy Shield:**
  - When the app is backgrounded on iOS, KeyNest displays an opaque privacy overlay to prevent iOS multitasking snapshots from exposing credentials.
- **Clipboard Auto-Clearing:**
  - Whenever a password or TOTP token is copied, KeyNest schedules an automatic clipboard purge (default: 45 seconds).

---

[← KDBX Integration](kdbx-integration.md) • [Developer Guide Index](README.md) • [Android Integration →](android-integration.md)
