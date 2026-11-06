import CarPlay
import Flutter
import GoogleMaps
import GoogleNavigation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GMSServices.provideAPIKey(dartDefine("MAPS_API_KEY") ?? "")
    return true
  }

  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    if connectingSceneSession.role == .carTemplateApplication {
      let scene = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
      scene.delegateClass = CarSceneDelegate.self
      return scene
    }
    let scene = UISceneConfiguration(name: "Phone", sessionRole: connectingSceneSession.role)
    scene.delegateClass = PhoneSceneDelegate.self
    return scene
  }

  /// Reads a value passed with --dart-define-from-file=config/keys.json.
  private func dartDefine(_ key: String) -> String? {
    guard let defines = Bundle.main.infoDictionary?["DART_DEFINES"] as? String else { return nil }
    for encoded in defines.components(separatedBy: ",") {
      guard let data = Data(base64Encoded: encoded),
        let decoded = String(data: data, encoding: .utf8),
        decoded.hasPrefix("\(key)=")
      else { continue }
      return String(decoded.dropFirst(key.count + 1))
    }
    return nil
  }
}
