import Flutter
import UIKit
import DuanjuCore
import CFNetwork

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      let channel = FlutterMethodChannel(name: "duanju/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "systemProxy" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func address(_ prefix: String) -> String {
          guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                let host = settings["\(prefix)Proxy"] as? String,
                let port = settings["\(prefix)Port"] as? NSNumber,
                !host.isEmpty, port.intValue > 0 else { return "" }
          let name = host.contains(":") ? "[\(host)]" : host
          return "http://\(name):\(port.intValue)"
        }
        let http = address("HTTP")
        let https = address("HTTPS")
        result(["http": http, "https": https.isEmpty ? http : https,
                "bypass": settings["ExceptionsList"] as? [String] ?? [],
                "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
      }
    }
  }
}
