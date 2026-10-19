# KeyNest Headless Autofill Module (`autofill_module`)

This directory contains the lightweight, headless Flutter module designed specifically for the **iOS Credential Provider Extension** (`KeyNestAutofill`).

## Architectural Purpose

- **Process Memory Limits:**
  - iOS App Extensions are allocated an extremely constrained memory ceiling (~120 MB).
  - Exceeding this limit causes iOS watchdog services to immediately terminate the process (`EXC_RESOURCE RESOURCE_TYPE_MEMORY`).
- **Headless Execution:**
  - This module is compiled without a `UIApplication` or heavy UI widgets.
  - It runs on a dedicated, lightweight `FlutterEngine` instance spawned by the native Swift extension.
- **Fast Vault Unlocking:**
  - Opens mirrored `.kdbx` vaults using pre-transformed keys cached in the shared Darwin Keychain Access Group by the main KeyNest app.
  - By bypassing the Argon2 / AES-KDF password hashing phase inside the extension, vault unlocking completes in milliseconds with minimal CPU and RAM usage.

## Interacting Components

- **Parent iOS Extension:** [`keynest/ios/KeyNestAutofill/`](../keynest/ios/KeyNestAutofill/README.md)
- **Shared Data Contract:** [`autofill_shared/`](../autofill_shared/README.md)
- **Developer Guide:** [iOS Integration & Autofill Extension](../docs/developer-guide/ios-integration.md)
