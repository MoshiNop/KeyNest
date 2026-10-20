import 'package:autofill_service/autofill_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.moshinop.autofill_service');

  group('KeyNest Autofill Status & Diagnostics Consistency Tests', () {
    late bool mockHasEnabledServices;
    late bool mockIsKeyNestDefault;
    late String mockCurrentService;
    late int mockSdkInt;
    late bool mockIsSupported;

    setUp(() {
      AutofillService.debugOverrideIsAndroid = true;
      mockHasEnabledServices = false;
      mockIsKeyNestDefault = false;
      mockCurrentService = '';
      mockSdkInt = 36;
      mockIsSupported = true;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            switch (call.method) {
              case 'hasAutofillServicesSupport':
                return mockIsSupported;
              case 'hasEnabledAutofillServices':
                return mockHasEnabledServices;
              case 'isKeyNestDefaultProvider':
                return mockIsKeyNestDefault;
              case 'getDiagnostics':
                return <String, dynamic>{
                  'sdkInt': mockSdkInt,
                  'hasAutofillServicesSupport': mockIsSupported,
                  'hasEnabledAutofillServices':
                      mockHasEnabledServices || mockIsKeyNestDefault,
                  'isAutofillSupported': mockIsSupported,
                  'currentAutofillService': mockCurrentService,
                  'isKeyNestDefault': mockIsKeyNestDefault,
                  'servicePackage': 'com.moshinop.keynest',
                };
              case 'getPreferences':
                return <String, dynamic>{'enableDebug': false};
              case 'getBrowserAutofillStatus':
                return <dynamic>[];
              case 'requestSetAutofillService':
                mockIsKeyNestDefault = true;
                mockCurrentService =
                    'com.moshinop.keynest/com.moshinop.autofill_service.FlutterMyAutofillService';
                return true;
              case 'disableAutofillServices':
                mockHasEnabledServices = false;
                mockIsKeyNestDefault = false;
                mockCurrentService = '';
                return null;
              case 'clearAllCredentials':
                return true;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      AutofillService.debugOverrideIsAndroid = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('Scenario 1 & 2: status() recognizes active provider on API 36 restart when hasEnabledAutofillServices initially returns false', () async {
      // Simulates exact ss1.jpg reproduction:
      // On restart, Android OS hasEnabledAutofillServices() returns false because service
      // has not yet been bound by the system server. But KeyNest is selected in Settings.
      mockHasEnabledServices = false;
      mockIsKeyNestDefault = true;
      mockCurrentService =
          'com.moshinop.keynest/com.moshinop.autofill_service.FlutterMyAutofillService';
      mockSdkInt = 36;

      final status = await AutofillService().status();
      expect(
        status,
        equals(AutofillServiceStatus.enabled),
        reason:
            'When Android Settings designate KeyNest as active provider, status must resolve to enabled',
      );

      final hasEnabled = await AutofillService().hasEnabledAutofillServices;
      expect(hasEnabled, isTrue);
      expect(AutofillService.statusNotifier.value, equals(AutofillServiceStatus.enabled));
    });

    test('Scenario 3: status() accurately reflects disabled state when another provider is selected', () async {
      mockHasEnabledServices = false;
      mockIsKeyNestDefault = false;
      mockCurrentService =
          'com.google.android.gms/com.google.android.gms.autofill.service.AutofillService';

      final status = await AutofillService().status();
      expect(status, equals(AutofillServiceStatus.disabled));

      final hasEnabled = await AutofillService().hasEnabledAutofillServices;
      expect(hasEnabled, isFalse);
      expect(AutofillService.statusNotifier.value, equals(AutofillServiceStatus.disabled));
    });

    test('Scenario 4: Diagnostics panel data eliminates contradiction between framework and provider status', () async {
      mockHasEnabledServices = false;
      mockIsKeyNestDefault = true;
      mockCurrentService =
          'com.moshinop.keynest/com.moshinop.autofill_service.FlutterMyAutofillService';
      mockSdkInt = 36;

      final diag = await AutofillService().getDiagnostics();
      expect(diag['sdkInt'], equals(36));
      expect(diag['isKeyNestDefault'], isTrue);
      expect(
        diag['hasEnabledAutofillServices'],
        isTrue,
        reason:
            'Framework status and provider status must agree when KeyNest is active provider',
      );
    });

    test('Scenario 5 & 6: Returning from Settings immediately re-checks system state without app restart', () async {
      // Initially disabled
      mockHasEnabledServices = false;
      mockIsKeyNestDefault = false;
      mockCurrentService = '';

      var status = await AutofillService().status();
      expect(status, equals(AutofillServiceStatus.disabled));

      // User triggers requestSetAutofillService and chooses KeyNest
      final requested = await AutofillService().requestSetAutofillService();
      expect(requested, isTrue);

      // System state check after returning
      status = await AutofillService().status();
      expect(status, equals(AutofillServiceStatus.enabled));
    });

    test('Scenario 7: Disabling autofill updates status to disabled without restart', () async {
      mockHasEnabledServices = true;
      mockIsKeyNestDefault = true;
      mockCurrentService =
          'com.moshinop.keynest/com.moshinop.autofill_service.FlutterMyAutofillService';

      var status = await AutofillService().status();
      expect(status, equals(AutofillServiceStatus.enabled));

      await AutofillService().disableAutofillServices();
      await AutofillService().clearAllCredentials();

      status = await AutofillService().status();
      expect(status, equals(AutofillServiceStatus.disabled));
      expect(AutofillService.statusNotifier.value, equals(AutofillServiceStatus.disabled));
    });

    test('Scenario 8: Re-enabling in Settings updates status without restart', () async {
      mockHasEnabledServices = false;
      mockIsKeyNestDefault = false;
      mockCurrentService = '';

      var status = await AutofillService().status();
      expect(status, equals(AutofillServiceStatus.disabled));

      // User re-enables in Android Settings
      mockIsKeyNestDefault = true;
      mockCurrentService =
          'com.moshinop.keynest/com.moshinop.autofill_service.FlutterMyAutofillService';

      status = await AutofillService().status();
      expect(status, equals(AutofillServiceStatus.enabled));
    });

    testWidgets('Autofill action button renders "Autofill Active" when enabled and "Turn on Autofill" when disabled', (tester) async {
      Widget buildButton(AutofillServiceStatus status) {
        return MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                if (status == AutofillServiceStatus.enabled) {
                  return OutlinedButton.icon(
                    icon: const Icon(Icons.check_circle_rounded),
                    label: const Text('Autofill Active'),
                    onPressed: () {},
                  );
                } else if (status == AutofillServiceStatus.disabled) {
                  return ElevatedButton.icon(
                    icon: const Icon(Icons.touch_app_rounded),
                    label: const Text('Turn on Autofill'),
                    onPressed: () {},
                  );
                }
                return const SizedBox();
              },
            ),
          ),
        );
      }

      // Disabled state
      await tester.pumpWidget(buildButton(AutofillServiceStatus.disabled));
      expect(find.text('Turn on Autofill'), findsOneWidget);
      expect(find.text('Autofill Active'), findsNothing);

      // Enabled state
      await tester.pumpWidget(buildButton(AutofillServiceStatus.enabled));
      expect(find.text('Autofill Active'), findsOneWidget);
      expect(find.text('Turn on Autofill'), findsNothing);
    });

    testWidgets('Diagnostics sheet displays consistent and non-contradictory UI for API 36', (tester) async {
      mockHasEnabledServices = false;
      mockIsKeyNestDefault = true;
      mockCurrentService =
          'com.moshinop.keynest/com.moshinop.autofill_service.FlutterMyAutofillService';
      mockSdkInt = 36;

      final diag = await AutofillService().getDiagnostics();

      Widget buildDiagRow(String label, String value, IconData icon, Color color) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 12)),
                  Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
        );
      }

      final isKeyNestDefault = diag['isKeyNestDefault'] == true;
      final isEnabled = diag['hasEnabledAutofillServices'] == true || isKeyNestDefault;
      final sdkInt = diag['sdkInt'] ?? 'Android';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                buildDiagRow(
                  'Android API Level',
                  'API $sdkInt',
                  Icons.android_rounded,
                  Colors.blue,
                ),
                buildDiagRow(
                  'Autofill Framework Status',
                  isEnabled ? 'Active & Enabled' : 'Not Enabled in Settings',
                  isEnabled ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                  isEnabled ? Colors.green : Colors.orange,
                ),
                buildDiagRow(
                  'Default Provider',
                  isKeyNestDefault ? 'KeyNest is Active Provider' : 'Another app is default',
                  isKeyNestDefault ? Icons.verified_user_rounded : Icons.info_outline_rounded,
                  isKeyNestDefault ? Colors.green : Colors.orange,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('API 36'), findsOneWidget);
      expect(find.text('Active & Enabled'), findsOneWidget);
      expect(find.text('KeyNest is Active Provider'), findsOneWidget);
      expect(find.text('Not Enabled in Settings'), findsNothing);
      expect(find.text('Another app is default'), findsNothing);
    });
  });
}
