import UIKit
import Flutter
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var privacyOverlay: UIVisualEffectView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      AutofillIdentityChannel.register(with: controller)
      let miscChannel = FlutterMethodChannel(
        name: "app.keynest/misc",
        binaryMessenger: controller.binaryMessenger
      )
      miscChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "setSensitiveClipboard":
          guard let args = call.arguments as? [String: Any],
                let text = args["text"] as? String else {
            result(false)
            return
          }
          let clearSeconds = (args["clearSeconds"] as? Int) ?? 30
          var options: [UIPasteboard.OptionsKey: Any] = [
            .localOnly: true
          ]
          if clearSeconds > 0 {
            options[.expirationDate] = Date().addingTimeInterval(TimeInterval(clearSeconds))
          }
          if #available(iOS 14.0, *) {
            UIPasteboard.general.setItems(
              [[UTType.plainText.identifier: text]],
              options: options
            )
          } else {
            UIPasteboard.general.setItems(
              [["public.utf8-plain-text": text]],
              options: options
            )
          }
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard privacyOverlay == nil, let window = self.window else { return }
    let blurEffect = UIBlurEffect(style: .systemMaterial)
    let effectView = UIVisualEffectView(effect: blurEffect)
    effectView.frame = window.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(effectView)
    privacyOverlay = effectView
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyOverlay?.removeFromSuperview()
    privacyOverlay = nil
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }
}
