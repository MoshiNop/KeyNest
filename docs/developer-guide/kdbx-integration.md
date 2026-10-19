# KDBX Integration & Merge Engine

This document details KeyNest's integration with the KDBX file format, key derivation pipelines, and the three-way vault synchronization merge engine.

---

## 1. Supported Format Versions & Ciphers

KeyNest fully supports reading and writing both major iterations of the KeePass file format:

| Format Version | Header Format | Supported Encryption Ciphers | Supported Key Derivation Functions (KDF) | Inner Stream Encryption |
| :--- | :--- | :--- | :--- | :--- |
| **KDBX 3.1** | Binary Header | AES-256, Twofish | AES-KDF (Transform Rounds) | Salsa20 |
| **KDBX 4.0 / 4.1** | TLV Header + HMAC SHA-256 | AES-256, ChaCha20 | Argon2id, Argon2d, AES-KDF | ChaCha20 |

---

## 2. Cryptographic Key Derivation Flow

When unlocking or creating a vault:

```text
Composite Credentials (Master Password + Key File)
                     │
                     ▼
             SHA-256 Hash Pre-Mix
                     │
                     ▼
         Native FFI Key Derivation
   (Argon2id via argon2_ffi OR AES-KDF)
                     │
                     ▼
              Transformed Key
                     │
                     ▼
        Final Composite Key Derivation
        (SHA-256 with MasterSeed)
                     │
                     ▼
       Decryption Master Key & HMAC Key
```

### Fast Unlocking with `TransformedKeyCredentials`
- Key derivation (especially Argon2 with hundreds of megabytes of memory) is CPU- and memory-intensive.
- For biometric unlock and the iOS autofill extension, KeyNest securely caches the **transformed key** in hardware keystore / Keychain Access Groups.
- When opening an existing vault, the cached transformed key can unlock the database in milliseconds without repeating the heavy Argon2 computation.

---

## 3. The Three-Way Merge Engine (`KeyNestVaultMergeEngine`)

When synchronizing with cloud storage, multiple devices may edit the same vault concurrently while offline. KeyNest implements a deterministic three-way merge algorithm:

### Algorithm Steps:
1. **Ancestry Determination:**
   - Evaluates three versions: **Base** (common ancestor at last sync), **Local** (current user edits), and **Remote** (downloaded cloud payload).
2. **Object Identification:**
   - Entries and groups are tracked by immutable `KdbxUuid`.
3. **Change Detection:**
   - For every entry, inspect `LastModificationTime` and compare string values against Base.
4. **Conflict Resolution Matrix:**
   - **Local Modified, Remote Unmodified:** Apply local modification.
   - **Remote Modified, Local Unmodified:** Apply remote modification.
   - **Both Modified (Same Field, Same Value):** Clean merge.
   - **Both Modified (Same Field, Different Value):** Keep the newer modification based on timestamp; push the older version into the entry's KDBX `History` array to prevent data loss.
5. **Tombstone Handling:**
   - Deletions are tracked via `DeletedObjects`. If an entry was deleted locally but edited remotely, the remote edit takes precedence and resurrects the entry.

---

[← Data Models](data-models.md) • [Developer Guide Index](README.md) • [Security Design →](security-design.md)
