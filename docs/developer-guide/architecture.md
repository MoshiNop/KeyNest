# System Architecture & Design

This document details the architectural layers, state management patterns, and data flows of KeyNest.

---

## 1. High-Level Architectural Layers

KeyNest follows a strict layered architecture separating UI presentation, business logic, domain models, and native hardware/cloud interfaces:

```text
┌─────────────────────────────────────────────────────────────────┐
│                       Presentation Layer                        │
│   Flutter Screens, Dialogs, Filter Chips, Entry ViewModels      │
└───────────────────────────────┬─────────────────────────────────┘
                                │ (Events / Streams / ViewModels)
┌───────────────────────────────▼─────────────────────────────────┐
│                       Application Logic                         │
│   BLoCs: KdbxBloc, AppData, CloudStorageBloc, AnalyticsBloc     │
│   Services: MergeEngine, ImportExportService, SecurityService   │
└───────────────────────────────┬─────────────────────────────────┘
                                │ (KdbxFile, KdbxEntry, Streams)
┌───────────────────────────────▼─────────────────────────────────┐
│                     Domain & Vault Engine                       │
│   kdbx package: KdbxTree, KdbxGroup, KdbxEntry, ProtectedValue │
│   TransformedKeyCredentials, Argon2id / AES-KDF, 3-Way Merge    │
└───────────────────────────────┬─────────────────────────────────┘
                                │ (FileSource, Binary Bytes, I/O)
┌───────────────────────────────▼─────────────────────────────────┐
│                 Platform & Storage Adapters                     │
│  - CloudStorageProvider (Google Drive, WebDAV, Dropbox, 365)    │
│  - Local FileSource (Android SAF, Desktop POSIX/Win32 file I/O) │
│  - Native Plugins (Android AutofillService, Darwin Keychain)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. State Management: The BLoC Pattern

KeyNest utilizes the BLoC (Business Logic Component) pattern coupled with reactive Dart `Stream`s:

1. **`KdbxBloc` (`lib/bloc/kdbx_bloc.dart`):**
   - The primary controller for vault state.
   - Manages active open vaults, active file sources (`FileSourceLocal`, `FileSourceCloudStorage`), vault locking/unlocking, entry selection, and save queuing.
   - Dispatches mutation events when entries are added, modified, moved, or deleted.
2. **`AppData` (`lib/bloc/app_data.dart`):**
   - Manages global application preferences, UI themes (dark/light/system), auto-lock timers, search query states, and recent vault history.
3. **`CloudStorageBloc` (`lib/cloud_storage/cloud_storage_bloc.dart`):**
   - Manages active cloud accounts, OAuth token refresh cycles, and provider discovery.
4. **`KeyNestCloudSyncManager` (`lib/cloud_storage/keynest_cloud_sync_manager.dart`):**
   - Background coordinator for polling remote storage, checking ETags/timestamps, queuing pending uploads, and orchestrating three-way merges.

---

## 3. Data Flow: Reading & Writing a Vault

```text
User Input (Master Password + Key File)
            │
            ▼
   TransformedKeyCredentials
            │ (Argon2 / AES-KDF Derivation via native FFI)
            ▼
    KdbxFile.read(stream, credentials)
            │
            ▼
   Decrypted XML DOM in memory
            │ (Sensitive fields kept as ProtectedValue)
            ▼
   KdbxBloc broadcasts VaultLoadedEvent
            │
            ▼
   UI updates entry list & category chips
```

When an entry is modified:
1. UI dispatches an update through `EntryViewModel`.
2. `KdbxBloc` updates the in-memory `KdbxEntry` and marks the vault dirty.
3. The vault serialization pipeline serializes the XML DOM, encrypts it with an updated master header and random initialization vector (IV), and writes it atomically to the target `FileSource`.
4. If the vault is cloud-backed, `KeyNestCloudSyncManager` pushes the updated payload to the remote provider and records the new ETag.

---

[← Development Setup](development-setup.md) • [Developer Guide Index](README.md) • [Project Structure →](project-structure.md)
