# Android Native Integration

This document covers KeyNest's native Android integration, including the Android Autofill Service, Storage Access Framework (SAF), and native platform channels.

---

## 1. Architecture Overview

KeyNest interacts with Android OS services through two primary native layers:
1. **`MainActivity.java` (`keynest/android/app/src/main/java/...`):**
   - The primary Flutter activity managing window security flags (`FLAG_SECURE`), custom intent filters, and system UI styling.
2. **`autofill_service` Plugin (`deps/autofill_service/`):**
   - A dedicated Flutter plugin implementing Android's `AutofillService` framework API (`android.service.autofill.AutofillService`).

---

## 2. Android Autofill Service Architecture

```text
Target Application / Chrome
             │ (User taps input field)
             ▼
   Android Autofill Framework
             │ (Calls onFillRequest)
             ▼
   AutofillService (Java / Kotlin in deps/autofill_service)
             │ (Platform Channel: "autofill_service/service")
             ▼
   KeyNest Background Engine (Dart)
             │ (Matches domain via public_suffix eTLD+1)
             ▼
      Matched Credentials
             │
             ▼
   FillResponse & Inline Presentation Dataset
             │
             ▼
   Android Displays Autofill Suggestions
```

### Key Integration Points:
- **`onFillRequest`:** Android passes an `AssistStructure` containing the target view hierarchy, autofill hints (e.g. `AUTOFILL_HINT_USERNAME`, `AUTOFILL_HINT_PASSWORD`), and web domain attributes.
- **Domain Normalization:** The plugin extracts web domains or Android package names and queries KeyNest's vault mirror index.
- **Authentication Gateway:** If the required vault is locked, the service returns an authentication `IntentSender`, prompting the user for biometric or master password verification before returning credentials.

---

## 3. Storage Access Framework (SAF) (`KeyNestSafService`)

Due to modern Android Scoped Storage restrictions, apps cannot access arbitrary filesystem paths. KeyNest implements full SAF support:

- **Persistent URI Permissions:**
  - Uses `Intent.ACTION_OPEN_DOCUMENT` and `Intent.ACTION_CREATE_DOCUMENT`.
  - Calls `takePersistableUriPermission(uri, flags)` to retain access across device reboots and app updates.
- **Atomic Document Writing:**
  - Opens `ParcelFileDescriptor` with mode `"rwt"` (read/write/truncate) to write encrypted KDBX buffers atomically, preventing file corruption in the event of unexpected app termination.

---

[← Security Design](security-design.md) • [Developer Guide Index](README.md) • [iOS Integration →](ios-integration.md)
