// ============================================================
// safe_share.dart
// ফাইল শেয়ার করার একটাই নিরাপদ পথ।
//
// share_plus-এর "ফলাফল সহ" পদ্ধতি (shareXFiles) Android-এ আগের শেয়ার-শিটের
// ফলাফল না ফেরা পর্যন্ত নতুন শেয়ার আটকে দেয় এবং
// "Share callback error, prior share-sheet did not call back" ত্রুটি দেয়
// (শেয়ার-শিট কেটে দিলে বা দুবার ট্যাপ করলে এমন হয়)। আমরা শেয়ারের ফলাফল
// ব্যবহার করি না, তাই ফলাফল-ছাড়া পদ্ধতি ব্যবহার করা হয় — এতে কিছুই আটকে যায় না।
// দুবার ট্যাপ হলে দ্বিতীয়টা উপেক্ষা করা হয়।
// ============================================================

import 'package:share_plus/share_plus.dart';

class SafeShare {
  static bool _busy = false;

  static Future<void> files(List<String> paths, {String? text}) async {
    if (_busy) return;
    _busy = true;
    try {
      // ignore: deprecated_member_use
      await Share.shareFiles(paths, text: text);
    } finally {
      // শেয়ার-শিট খোলার পরেই আবার শেয়ারের অনুমতি
      await Future.delayed(const Duration(milliseconds: 800));
      _busy = false;
    }
  }
}
