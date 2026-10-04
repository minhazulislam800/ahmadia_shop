// ============================================================
// sync_id.dart
// প্রতিটা রেকর্ডের জন্য একটা গ্লোবালি-ইউনিক আইডি তৈরি করে (UUID
// লাইব্রেরি ছাড়াই, timestamp + random সংমিশ্রণে)। এই sync_id
// দিয়েই দুইটা আলাদা ডিভাইসের ডাটাবেস মার্জ করার সময় বোঝা যায়
// কোন রেকর্ড কোনটার সাথে মেলে।
// ============================================================

import 'dart:math';

final _random = Random.secure();

String generateSyncId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final randomPart =
      List.generate(12, (_) => _random.nextInt(36).toRadixString(36)).join();
  return '$timestamp-$randomPart';
}
