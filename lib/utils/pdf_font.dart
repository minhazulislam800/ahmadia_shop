// ============================================================
// pdf_font.dart
// PDF-এ বাংলা টেক্সট সঠিকভাবে দেখানোর জন্য প্রয়োজনীয় Unicode
// ফন্ট লোড করে। pdf প্যাকেজের ডিফল্ট ফন্টে বাংলা অক্ষর সাপোর্ট
// নেই বলে ফন্ট ফাইল বান্ডল করে ব্যবহার করা হচ্ছে (নেটওয়ার্ক
// ছাড়াই, সম্পূর্ণ অফলাইন কাজ করার জন্য)।
// ============================================================

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

class PdfFontHelper {
  static pw.Font? _regular;
  static pw.Font? _bold;

  /// একবার লোড হলে ক্যাশে রাখা হয়, বারবার ফাইল পড়তে হয় না
  static Future<pw.ThemeData> getTheme() async {
    _regular ??= pw.Font.ttf(
        await rootBundle.load('assets/fonts/NotoSansBengali-Regular.ttf'));
    _bold ??= pw.Font.ttf(
        await rootBundle.load('assets/fonts/NotoSansBengali-Bold.ttf'));
    return pw.ThemeData.withFont(base: _regular!, bold: _bold!);
  }
}
