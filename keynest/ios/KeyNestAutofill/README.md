# KeyNest iOS Autofill Extension (`KeyNestAutofill`)

This directory houses the native Apple Swift implementation of KeyNest's iOS Credential Provider Extension.

## Overview

The extension implements Apple's `ASCredentialProviderViewController` interface, allowing KeyNest credentials to appear in the native iOS QuickType keyboard bar across Safari and third-party apps.

## Key Files & Responsibilities

- `CredentialProviderViewController.swift`:
  - Entry point for iOS autofill events (`prepareCredentialList(for:serviceIdentifiers:)`, `provideCredentialWithoutUserInteraction(for:)`).
  - Spawns and manages the headless `FlutterEngine` (`"keynest-autofill"`).
- `AutofillEngine.swift`:
  - Manages bidirectional MethodChannel communication with the embedded Dart module.
- `AutofillVaultStore.swift`:
  - Accesses the secure shared App Group container (`group.app.keynest.keynest`) to locate mirrored `.kdbx` databases.
- `ConfigurationViewController.swift`:
  - Displays user settings and vault selection inside the extension.

## Related Documentation

- [iOS Integration Guide](../../../docs/developer-guide/ios-integration.md)
- [Headless Autofill Module](../../../autofill_module/README.md)
- [User Guide: iOS Autofill Setup](../../../docs/user-guide/autofill.md#ios-setup)
