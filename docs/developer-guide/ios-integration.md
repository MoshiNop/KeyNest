# iOS Native Integration & Credential Provider Extension

This document explains KeyNest's iOS architecture, the `KeyNestAutofill` app extension, the headless `autofill_module`, and Apple App Group data sharing.

---

## 1. High-Level iOS Architecture

iOS credential autofill is strictly separated from the main application process. Apple launches an App Extension process (`ASCredentialProviderViewController`) that runs inside a restricted memory sandbox (~120 MB ceiling).

```text
┌────────────────────────────────────────────────────────┐
│                   Main KeyNest App                     │
│  - Standard Flutter Application                        │
│  - Edits KDBX vaults                                   │
│  - Mirrors vaults to Shared App Group Container        │
│  - Stores TransformedKey in Darwin Keychain Group      │
└───────────────────────────┬────────────────────────────┘
                            │
               Shared App Group Container
               & Shared Keychain Access Group
                            │
┌───────────────────────────▼────────────────────────────┐
│      KeyNestAutofill App Extension (Swift)             │
│  - ASCredentialProviderViewController                  │
│  - Embedded Headless FlutterEngine ("keynest-autofill")│
│  - autofill_module (Dart): Reads vault mirror          │
│  - Unlocks vault using cached TransformedKey           │
│  - Returns ASPasswordCredential to iOS                 │
└────────────────────────────────────────────────────────┘
```

---

## 2. Shared App Group & Keychain Security

1. **Shared App Group (`group.app.keynest.keynest`):**
   - A sandboxed shared filesystem directory accessible by both the main app and the extension.
   - Contains a stripped `vault_manifest.json` and mirrored `.kdbx` vault files.
2. **Keychain Access Group (`$(AppIdentifierPrefix)app.keynest.keynest`):**
   - The main app caches the **Transformed Key** (output of Argon2/AES-KDF) inside the shared keychain, protected with `kSecAccessControlBiometryAny`.
   - The extension reads the transformed key directly. This is critical: **the extension never computes Argon2 derivation**, avoiding the memory and CPU spikes that would cause iOS to terminate the extension process.

---

## 3. Headless Flutter Module (`autofill_module/`)

- Compiles as an embedded headless module without a `UIApplication`.
- Listens on the `keynest/autofill_module` method channel.
- Implements:
  - `listCredentials(domain)`: Queries the mirrored KDBX vault for entries matching the domain.
  - `getCredential(entryId)`: Decrypts and returns the username, password, and TOTP token.

---

[← Android Integration](android-integration.md) • [Developer Guide Index](README.md) • [Cloud Integrations →](cloud-integrations.md)
