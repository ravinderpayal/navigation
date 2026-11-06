import AudioToolbox
import UIKit

class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var alertChannel: FlutterMethodChannel?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let windowScene = scene as? UIWindowScene {
      window = UIWindow(windowScene: windowScene)
      let flutterEngine = FlutterEngine(name: "PhoneSceneDelegateEngine")
      flutterEngine.run()
      GeneratedPluginRegistrant.register(with: flutterEngine)
      alertChannel = DriverAlertPlayer.channel(messenger: flutterEngine.binaryMessenger)
      let controller = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
      window?.rootViewController = controller
      window?.makeKeyAndVisible()
    }
  }
}

/// Plays the chime and vibrates. An alert sound mixes with navigation voice and
/// music. The ring/silent switch mutes it, but the phone still vibrates.
enum DriverAlertPlayer {
  private static var soundId: SystemSoundID = 0

  static func channel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "vinfast_copilot/alert", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "alert" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let urgent = (call.arguments as? [String: Any])?["urgent"] as? Bool ?? false
      play(urgent: urgent)
      result(nil)
    }
    return channel
  }

  static func play(urgent: Bool) {
    chime()
    if urgent {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        chime()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
      }
    }
  }

  private static func chime() {
    if soundId == 0 {
      let key = FlutterDartProject.lookupKey(forAsset: "assets/sounds/chime.wav")
      if let path = Bundle.main.path(forResource: key, ofType: nil) {
        AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &soundId)
      }
    }
    if soundId != 0 {
      AudioServicesPlayAlertSound(soundId)
    } else {
      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
  }
}
