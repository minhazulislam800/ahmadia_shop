// ============================================================
// crash_log.dart
// অ্যাপ কোনো ত্রুটিতে বন্ধ/আটকে গেলে ত্রুটির বিবরণ ফাইলে জমিয়ে রাখে,
// আর পরেরবার অ্যাপ খুললে একটা ডায়ালগে দেখায় (কপি করে পাঠানো যায়) —
// যাতে "অ্যাপ খুলেই বন্ধ হয়ে যায়" ধরনের সমস্যার আসল কারণ জানা যায়।
// ============================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'incoming_file.dart';

class CrashLog {
  static const int _maxChars = 6000;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/crash_log.txt');
  }

  /// ত্রুটি লিখে রাখা — এই ফাংশন নিজে কখনো exception ছোঁড়ে না
  static Future<void> record(Object error, StackTrace? stack) async {
    try {
      final file = await _file();
      var old = '';
      if (await file.exists()) old = await file.readAsString();
      var text = '$old${DateTime.now().toIso8601String()}\n$error\n${stack ?? ''}\n\n';
      if (text.length > _maxChars) text = text.substring(text.length - _maxChars);
      await file.writeAsString(text);
    } catch (_) {}
  }

  /// আগের বারের জমানো ত্রুটি (Dart + Android) নিয়ে ফাইল মুছে ফেলে
  static Future<String?> takePrevious() async {
    final parts = <String>[];
    try {
      final file = await _file();
      if (await file.exists()) {
        final text = (await file.readAsString()).trim();
        if (text.isNotEmpty) parts.add('[Dart]\n$text');
        await file.delete();
      }
    } catch (_) {}
    final native = await IncomingFileService.takeNativeCrash();
    if (native != null && native.trim().isNotEmpty) {
      parts.add('[Android]\n${native.trim()}');
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  static Future<void> showPreviousIfAny(BuildContext context) async {
    final text = await takePrevious();
    if (text == null || !context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('আগের বার অ্যাপে সমস্যা হয়েছিল'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontSize: 11)),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            child: const Text('কপি করুন'),
          ),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('বন্ধ করুন')),
        ],
      ),
    );
  }
}
