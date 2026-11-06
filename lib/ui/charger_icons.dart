import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart';

/// Draws the big map pins once, because marker images must be registered natively.
class ChargerIcons {
  ChargerIcons._(this.free, this.other, this.recommended, this.ultraFast);

  static const _free = Color(0xFF0F9D58);
  static const _other = Color(0xFFE8710A);
  static const _recommended = Color(0xFF1A56DB);
  static const ultraFastColor = Color(0xFF7B1FA2);
  static const _pixelRatio = 3.0;

  final ImageDescriptor free;
  final ImageDescriptor other;
  final ImageDescriptor recommended;

  /// 180 kW and up: labelled with the power, since that's why it's on the map.
  final ImageDescriptor ultraFast;

  static Future<ChargerIcons> create() async => ChargerIcons._(
        await _pin(_free, 64),
        await _pin(_other, 64),
        await _pin(_recommended, 88),
        await _pin(ultraFastColor, 76, label: '180+'),
      );

  static Future<ImageDescriptor> _pin(Color color, double logicalSize, {String? label}) async {
    final size = logicalSize * _pixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final radius = size * 0.42;
    final center = Offset(size / 2, radius + size * 0.02);

    final pin = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..moveTo(center.dx - radius * 0.6, center.dy + radius * 0.8)
      ..lineTo(size / 2, size * 0.99)
      ..lineTo(center.dx + radius * 0.6, center.dy + radius * 0.8)
      ..close();
    canvas.drawPath(pin, Paint()..color = color);
    canvas.drawCircle(center, radius,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = size * 0.035);

    final bolt = TextPainter(
      textDirection: TextDirection.ltr,
      text: label != null
          ? TextSpan(
              text: label,
              style: TextStyle(fontSize: radius * 0.72, fontWeight: FontWeight.w800, color: Colors.white),
            )
          : TextSpan(
              text: String.fromCharCode(Icons.bolt.codePoint),
              style: TextStyle(
                fontFamily: Icons.bolt.fontFamily,
                package: Icons.bolt.fontPackage,
                fontSize: radius * 1.6,
                color: Colors.white,
              ),
            ),
    )..layout();
    bolt.paint(canvas, center - Offset(bolt.width / 2, bolt.height / 2));

    final image = await recorder.endRecording().toImage(size.round(), size.round());
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return registerBitmapImage(bitmap: png!, imagePixelRatio: _pixelRatio);
  }
}
