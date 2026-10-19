# Data Models & KDBX Object Hierarchy

This document explains the data models representing encrypted KeePass vaults, entries, custom fields, and archetypes in KeyNest.

---

## 1. KDBX Object Hierarchy

KeyNest maps directly to the standard KeePass XML DOM structure using the pure Dart `kdbx` package:

```text
KdbxFile
 ├── Header (CipherID, CompressionFlags, MasterSeed, TransformSeed, KdfParameters)
 └── RootGroup (KdbxGroup)
      ├── Groups (List<KdbxGroup>) [Nested folders / groups]
      │    └── Groups / Entries...
      ├── Entries (List<KdbxEntry>)
      │    ├── UUID (KdbxUuid)
      │    ├── Times (CreationTime, LastModificationTime, LastAccessTime, ExpiryTime)
      │    ├── Strings (Map<String, StringEntry>)
      │    │    ├── "Title"        -> PlainValue
      │    │    ├── "UserName"     -> PlainValue
      │    │    ├── "Password"     -> ProtectedValue (encrypted in memory/stream)
      │    │    ├── "URL"          -> PlainValue
      │    │    └── "Notes"        -> PlainValue
      │    ├── CustomData (Map<String, String>) [Archetype & Metadata]
      │    │    ├── "ItemType"     -> "login" | "card" | "note" | "record" | "twoFactor"
      │    │    └── "FieldType_*"  -> "pin" | "hidden" | "authenticator"
      │    └── History (List<KdbxEntry>) [Previous revisions for undo/audit]
      └── DeletedObjects (List<KdbxDeletedObject>) [Tombstones for 3-way sync]
```

---

## 2. Key Classes & Types

### `KdbxFile`
- Represents a complete KeePass vault database.
- Controls database-level metadata, custom icons, key derivation parameters (Argon2 / AES-KDF), and the XML DOM root.

### `KdbxGroup`
- Represents a folder/group in the vault tree.
- Groups can nest arbitrarily and contain both sub-groups and entries.

### `KdbxEntry`
- Represents an individual record (credential, payment card, secure note).
- Standard fields (`Title`, `UserName`, `Password`, `URL`, `Notes`) are accessed via `entry.getString('FieldName')` or `entry.setString('FieldName', value)`.

### `ProtectedValue` vs. Plain String
- Sensitive values (passwords, PINs, OTP secret seeds, recovery phrases) are wrapped in `ProtectedValue`.
- In memory and during serialization, `ProtectedValue` instances are processed through a Salsa20 or ChaCha20 inner stream cipher to prevent plaintext exposure in core memory dumps or process inspection.

---

## 3. KeyNest Archetypes (`KeyNestItemTypeHelper`)

To present rich UI cards while maintaining 100% standard KeePass compatibility, KeyNest stores archetype hints in standard KeePass `CustomData` attributes:

```dart
enum KeyNestItemType {
  login,     // Standard credential with username, password, URL
  card,      // Payment card with cardholder, number, expiry, CVV
  note,      // Secure note
  record,    // Structured identity / server record
  twoFactor, // Standalone TOTP authenticator
}
```

- When read by other KeePass clients (e.g. KeePassXC on desktop), these entries open as standard KeePass entries with custom fields, ensuring no vendor lock-in.

---

[← Project Structure](project-structure.md) • [Developer Guide Index](README.md) • [KDBX Integration →](kdbx-integration.md)
