import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Prevent screen recorders and window sharing from capturing vault contents.
    self.sharingType = .none

    RegisterGeneratedPlugins(registry: flutterViewController)

    let miscChannel = FlutterMethodChannel(
      name: "app.keynest/misc",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    miscChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "setSensitiveClipboard":
        guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String else {
          result(false)
          return
        }
        let pb = NSPasteboard.general
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pb.clearContents()
        pb.declareTypes([.string, concealedType, transientType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: concealedType)
        pb.setData(Data(), forType: transientType)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
