# KeyNest Android Autofill Plugin (`deps/autofill_service`)

A custom Flutter plugin implementing the native Android `AutofillService` framework API (`android.service.autofill.AutofillService`).

## Architectural Purpose

This plugin provides the low-level bridge between the Android operating system's autofill framework and KeyNest's background credential matcher:
- Intercepts system `onFillRequest` events from web browsers and native apps.
- Parses the view hierarchy `AssistStructure` to extract domain names, autofill hints, and web attributes.
- Displays inline autofill suggestion chips and bottom sheet credential selectors.
- Commits credentials to the target input fields via `FillResponse`.

## Key Files

- `android/src/main/kotlin/.../AutofillServicePlugin.kt`: Platform channel handler for Dart communication.
- `android/src/main/kotlin/.../KeyNestAutofillService.kt`: Native `AutofillService` implementation.
- `lib/autofill_service.dart`: Dart interface exposing service registration and response builders.

## Related Documentation

- [Android Integration Guide](../../docs/developer-guide/android-integration.md)
- [User Guide: Android Autofill Setup](../../docs/user-guide/autofill.md#1-android-autofill-setup)
- [Android Autofill Framework Reference](https://developer.android.com/guide/topics/text/autofill)
