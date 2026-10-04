// ============================================================
// incoming_file.dart
// হোয়াটসঅ্যাপ/ফাইল ম্যানেজার থেকে ব্যাকআপ ফাইল (.backup) "Open with"
// করে এই অ্যাপে খুললে Android (MainActivity) ফাইলটা কপি করে এখানে
// জানায়, আর এখান থেকে ব্যাকআপ ইমপোর্টের স্ক্রিন খোলা হয়।
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../screens/import_backup_screen.dart';

class IncomingFileService {
  static const MethodChannel _channel = MethodChannel('ahmadia/incoming_file');
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static Map<String, String>? _queued;

  /// অ্যাপ চলা অবস্থায় নতুন ফাইল এলে (warm start) শোনার জন্য — main()-এ একবার কল হয়
  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFile' && call.arguments is Map) {
        _handle(_toStringMap(call.arguments as Map));
      }
      return null;
    });
  }

  /// অ্যাপ ফাইল খুলে চালু হলে (cold start) অপেক্ষমান ফাইল আছে কি না দেখা।
  /// লগইন/হোম স্ক্রিন দাঁড়িয়ে যাওয়ার পর কল করা হয়।
  static Future<void> consumeInitial() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getInitialFile');
      if (result != null) _handle(_toStringMap(result));
    } on MissingPluginException {
      // Android ছাড়া অন্য প্ল্যাটফর্মে কিছু করার নেই
    } catch (_) {}
    final queued = _queued;
    if (queued != null) _handle(queued);
  }

  /// Android-এর (Java/Kotlin) আগের ক্র্যাশের বিবরণ, থাকলে — একবারই পাওয়া যায়
  static Future<String?> takeNativeCrash() async {
    try {
      return await _channel.invokeMethod<String>('getNativeCrash');
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _toStringMap(Map<dynamic, dynamic> raw) =>
      raw.map((k, v) => MapEntry('$k', '$v'));

  static void _handle(Map<String, String> file) {
    final path = file['path'];
    final navigator = navigatorKey.currentState;
    if (path == null || path.isEmpty) return;
    if (navigator == null) {
      _queued = file; // নেভিগেটর তৈরি হলে আবার চেষ্টা হবে
      return;
    }
    _queued = null;
    navigator.push(MaterialPageRoute(
      builder: (_) => ImportBackupScreen(path: path, displayName: file['name']),
    ));
  }
}
