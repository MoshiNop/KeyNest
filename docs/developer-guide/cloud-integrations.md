# Cloud Storage Integrations & Synchronization Engine

This document details the architecture of KeyNest's cloud storage subsystem, provider interfaces, and background synchronization flows.

---

## 1. The `CloudStorageProvider` Interface

All cloud storage backends implement the `CloudStorageProvider` abstract class located in [`lib/cloud_storage/cloud_storage_provider.dart`](../../keynest/lib/cloud_storage/cloud_storage_provider.dart):

```dart
abstract class CloudStorageProvider {
  String get id;
  String get displayName;
  
  Future<List<CloudFile>> listFiles({String? folderId});
  Future<Uint8List> downloadFile(CloudFile file);
  Future<CloudFile> uploadFile({
    required String path,
    required Uint8List content,
    String? previousEtag,
  });
  Future<void> deleteFile(CloudFile file);
}
```

---

## 2. Implemented Providers

### 1. WebDAV (`lib/cloud_storage/webdav/`)
- Pure HTTP client supporting `PROPFIND`, `GET`, `PUT`, and `DELETE`.
- Parses standard WebDAV XML responses (`D:multistatus`, `D:response`, `D:getetag`).
- Supports Nextcloud, ownCloud, mailbox.org, and generic Apache/Nginx WebDAV servers.

### 2. Google Drive (`lib/cloud_storage/google_drive/`)
- Authenticates using `google_sign_in` and `googleapis_auth`.
- Operates within restricted OAuth scopes (`https://www.googleapis.com/auth/drive.file` and app data folder), preventing broad access to unrelated user files.

### 3. Dropbox (`lib/cloud_storage/dropbox/`)
- Uses standard OAuth 2.0 PKCE flow.
- Interacts with Dropbox v2 API endpoints (`/2/files/list_folder`, `/2/files/download`, `/2/files/upload`).

### 4. OneDrive (`lib/cloud_storage/onedrive/`)
- Interacts with Microsoft Graph REST API endpoints (`/me/drive/root/children`).
- Handles silent refresh token rotation.

---

## 3. Background Synchronization Lifecycle

```text
Periodic Timer / Network Available Event
                    │
                    ▼
     Check Remote Metadata (ETag / MTime)
                    │
       ┌────────────┴────────────┐
       ▼                         ▼
   No Change                ETag Differs
       │                         │
     (Done)                      ▼
                      Download Remote Bytes
                                 │
                                 ▼
                     Decrypt Remote KdbxFile
                                 │
                                 ▼
                    Execute Three-Way Merge
                 (Base, Local State, Remote)
                                 │
                                 ▼
                     Re-encrypt & Save Local
                                 │
                                 ▼
                    Upload Merged KDBX to Cloud
                                 │
                                 ▼
                       Update Cached ETag
```

---

[← iOS Integration](ios-integration.md) • [Developer Guide Index](README.md) • [Testing Guide →](testing.md)
