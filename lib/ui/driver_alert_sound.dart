import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Chime and vibration, played natively so the sound goes out as navigation audio.
class DriverAlertSound {
  static const _channel = MethodChannel('vinfast_copilot/alert');

  static Future<void> play({required bool urgent}) async {
    try {
      await _channel.invokeMethod<void>('alert', {'urgent': urgent});
    } catch (e) {
      // The on-screen alert still shows.
      debugPrint('Alert sound failed: $e');
      await HapticFeedback.heavyImpact();
    }
  }
}
