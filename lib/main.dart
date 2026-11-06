import 'package:flutter/material.dart';

import 'ui/setup_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VinfastCopilotApp());
}

class VinfastCopilotApp extends StatelessWidget {
  const VinfastCopilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vinfast Copilot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F7B5F)),
        visualDensity: VisualDensity.standard,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0F7B5F), brightness: Brightness.dark),
      ),
      home: const SetupScreen(),
    );
  }
}
