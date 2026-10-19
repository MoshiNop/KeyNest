# Security Policy

Security and data privacy are the foundation of KeyNest. We welcome security researchers and users who report vulnerabilities responsibly.

---

## 1. Supported Versions

Security updates are actively applied to the latest stable release:

| Version | Supported |
| :--- | :--- |
| `1.x.x` (Latest) | Yes |
| `< 1.0.0` | No |

---

## 2. Reporting a Vulnerability

If you discover a security vulnerability or potential exploit in KeyNest:

1. **Do not report security issues via public GitHub Issues, discussions, or social media.**
2. Use **GitHub Private Vulnerability Reporting**:
   - Navigate to the repository's **Security** tab on GitHub.
   - Click **Report a vulnerability** to open an encrypted private advisory draft directly with the project maintainers.
3. In your report, please include:
   - A detailed description of the vulnerability.
   - Affected platforms (Android, iOS, Windows, macOS, Linux, Web).
   - Minimal proof-of-concept steps or code to reproduce the issue.
   - Any potential impact on encrypted vault data, key derivation, or memory protection.

---

## 3. Cryptographic & Security Architecture

KeyNest is designed with the following security properties:

- **Zero-Knowledge Architecture:** Master keys and decrypted entries exist strictly on your local device. No credentials or plaintext are transmitted to external servers.
- **Open Standards:** Vaults use the standard KeePass KDBX 3.1 and KDBX 4.x file formats.
- **Key Derivation:** Argon2id and AES-KDF are utilized to resist offline dictionary and brute-force attacks.
- **Memory Protection:** Sensitive fields are maintained in memory using `ProtectedValue` structures.
- **Hardware Keystore Integration:** Biometric keys are anchored in hardware security modules (Android KeyStore, Apple Secure Enclave).
- **Process Protection:** Android `FLAG_SECURE` blocks task-switcher snapshots and operating system screen recording.

For technical details, see the [Security Architecture Document](docs/developer-guide/security-design.md).
