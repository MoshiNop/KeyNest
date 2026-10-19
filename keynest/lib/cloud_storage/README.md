# Cloud Storage Subsystem (`keynest/lib/cloud_storage`)

This directory contains the provider abstractions, network clients, authentication flows, and background synchronization manager for KeyNest.

## Structure & Modules

- **Core Interfaces & Architecture:**
  - `cloud_storage_provider.dart`: Abstract interface defining required capabilities (`listFiles`, `downloadFile`, `uploadFile`, `deleteFile`).
  - `keynest_cloud_sync_manager.dart`: Background coordinator responsible for checking remote timestamps, queuing uploads, and orchestrating three-way merges.
  - `cloud_storage_bloc.dart`: State controller managing authenticated accounts and connection statuses.
  - `cloud_config_store.dart`: Secure persistence of provider credentials and refresh tokens.
- **Provider Implementations:**
  - `webdav/`: Pure HTTP client supporting WebDAV `PROPFIND`, `GET`, `PUT`, Digest/Basic auth (Nextcloud, ownCloud).
  - `google_drive/`: Google Drive v3 REST API integration using OAuth 2.0 PKCE and restricted app file scopes.
  - `dropbox/`: Dropbox v2 API implementation.
  - `onedrive/`: Microsoft Graph API integration.

## Technical Details

For detailed architecture diagrams, three-way merge resolution algorithms, and OAuth token handling, refer to:
- [Cloud Storage Developer Guide](../../../docs/developer-guide/cloud-integrations.md)
- [User Guide: Cloud Storage & Sync](../../../docs/user-guide/cloud-storage.md)
