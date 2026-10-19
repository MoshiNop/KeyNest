# KeyNest Shared Autofill Contract (`autofill_shared`)

A pure Dart package defining the data structures and domain matching rules shared between the main application and platform autofill extensions.

## Why Pure Dart?

This package deliberately excludes all Flutter framework dependencies (`flutter/material.dart`, rendering engines, platform channels). It compiles directly to native code or runs on minimal Dart runtimes, ensuring that memory overhead is measured in kilobytes rather than megabytes.

## Responsibilities

1. **Vault Mirror Manifest (`vault_manifest.dart`):**
   - Serializes and deserializes the index of mirrored `.kdbx` files shared between the main application and sandboxed extensions.
2. **Effective Top-Level Domain (eTLD+1) Matcher (`credential_matcher.dart`):**
   - Normalizes incoming web URLs and app package IDs using the public suffix list (`public_suffix`).
   - Ensures that credentials saved for `https://subdomain.example.com` safely match `example.com` while strictly isolating untrusted multi-tenant domains (e.g. `github.io`, `web.app`).

## Related Documentation

- [iOS Integration Guide](../docs/developer-guide/ios-integration.md)
- [Android Integration Guide](../docs/developer-guide/android-integration.md)
- [Project Structure](../docs/developer-guide/project-structure.md)
