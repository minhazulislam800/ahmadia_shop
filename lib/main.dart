// ============================================================
// main.dart — অ্যাপের শুরুর বিন্দু
// ============================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'utils/app_theme.dart';
import 'utils/crash_log.dart';
import 'utils/incoming_file.dart';
import 'utils/route_observer.dart';

void main() {
  // সব ত্রুটি ধরে ফাইলে লিখে রাখা হয় — পরেরবার অ্যাপ খুললে দেখানো হবে
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      CrashLog.record(details.exception, details.stack);
    };
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      CrashLog.record(error, stack);
      return true;
    };
    IncomingFileService.init();
    runApp(const AhmadiaShopApp());
  }, (error, stack) {
    CrashLog.record(error, stack);
  });
}

class AhmadiaShopApp extends StatelessWidget {
  const AhmadiaShopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ahmadia Shop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      navigatorKey: IncomingFileService.navigatorKey,
      navigatorObservers: [appRouteObserver],
      home: const LoginScreen(),
    );
  }
}
