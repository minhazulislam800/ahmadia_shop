// ============================================================
// txn_items.dart
// বিক্রয়/ক্রয়ের প্রতিটা লাইনের বিবরণ (পণ্য, পরিমাণ + একক, রেট, মোট) —
// রিপোর্ট, কাস্টমার/সাপ্লায়ার লেজার ও Excel এক্সপোর্টে একই নিয়মে দেখানোর জন্য।
// পরিমাণ ও রেট সবসময় যে এককে (কেজি/গ্রাম/প্যাক) লেনদেন হয়েছিল সেই এককেই দেখায়।
// ============================================================

import 'package:sqflite/sqflite.dart';
import 'quantity_math.dart';

class TxnItemLine {
  final int txnId;
  final String productName;
  final double quantity;
  final String unit;
  final double rate;

  const TxnItemLine({
    required this.txnId,
    required this.productName,
    required this.quantity,
    required this.unit,
    required this.rate,
  });

  double get total => quantity * rate;

  static String _num(double v, {int maxDecimals = 3}) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    var s = v.toStringAsFixed(maxDecimals);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  String get quantityText => '${_num(quantity)} $unit';
  String get rateText => '৳${_num(rate, maxDecimals: 4)}';
  String get totalText => '৳${_num(total, maxDecimals: 2)}';

  /// যেমন: "চিনি — 5 কেজি × ৳75 = ৳375"
  String get summary => '$productName — $quantityText × $rateText = $totalText';
}

class TxnItems {
  static String _ids(List<int> ids) => ids.join(','); // শুধু পূর্ণসংখ্যা — SQL-এ সরাসরি বসানো নিরাপদ

  /// বিক্রয়ের লাইনগুলো: sale_id → লাইনের তালিকা
  static Future<Map<int, List<TxnItemLine>>> forSales(
      Database db, List<int> saleIds) async {
    final out = <int, List<TxnItemLine>>{};
    if (saleIds.isEmpty) return out;
    final rows = await db.rawQuery('''
      SELECT si.id, si.sale_id AS txn_id, si.quantity, si.unit_price,
             p.name AS product_name, p.unit AS base_unit,
             pu.unit_label AS pack_unit_label
      FROM sale_items si
      JOIN products p ON p.id = si.product_id
      LEFT JOIN product_units pu ON pu.id = si.product_unit_id
      WHERE si.sale_id IN (${_ids(saleIds)})
      ORDER BY si.id
    ''');
    for (final r in rows) {
      final id = r['txn_id'] as int;
      (out[id] ??= []).add(TxnItemLine(
        txnId: id,
        productName: r['product_name'] as String,
        quantity: (r['quantity'] as num).toDouble(),
        unit: (r['pack_unit_label'] as String?) ?? (r['base_unit'] as String),
        rate: (r['unit_price'] as num).toDouble(),
      ));
    }
    return out;
  }

  /// ক্রয়ের লাইনগুলো: purchase_id → লাইনের তালিকা।
  /// ব্যাচে পরিমাণ ও দাম base unit-এ রাখা থাকে, তাই কেনার এককে ফিরিয়ে দেখানো হয়।
  static Future<Map<int, List<TxnItemLine>>> forPurchases(
      Database db, List<int> purchaseIds) async {
    final out = <int, List<TxnItemLine>>{};
    if (purchaseIds.isEmpty) return out;
    final rows = await db.rawQuery('''
      SELECT pb.id, pb.purchase_id AS txn_id, pb.quantity, pb.unit_cost,
             pb.display_quantity,
             p.name AS product_name, p.unit AS base_unit,
             pu.unit_label AS pack_unit_label,
             pu.conversion_factor_to_base AS factor
      FROM purchase_batches pb
      JOIN products p ON p.id = pb.product_id
      LEFT JOIN product_units pu ON pu.id = pb.product_unit_id
      WHERE pb.purchase_id IN (${_ids(purchaseIds)})
      ORDER BY pb.id
    ''');
    for (final r in rows) {
      final id = r['txn_id'] as int;
      final factor = (r['factor'] as num?)?.toDouble();
      final baseQty = (r['quantity'] as num).toDouble();
      final baseCost = (r['unit_cost'] as num).toDouble();
      final shown = (r['display_quantity'] as num?)?.toDouble();
      final qty = factor == null
          ? baseQty
          : (shown ?? QuantityMath.round(baseQty / factor));
      // রেট = মোট দাম ÷ কেনার এককের পরিমাণ (পুরনো এন্ট্রিতেও ঠিক আসে)
      final rate = factor == null
          ? baseCost
          : (qty > 0
              ? ((baseQty * baseCost) / qty * 10000).round() / 10000
              : baseCost * factor);
      (out[id] ??= []).add(TxnItemLine(
        txnId: id,
        productName: r['product_name'] as String,
        quantity: qty,
        unit: (r['pack_unit_label'] as String?) ?? (r['base_unit'] as String),
        rate: rate,
      ));
    }
    return out;
  }
}
