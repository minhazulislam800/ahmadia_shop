// ============================================================
// return_service.dart
// বিক্রয় ফেরত ও ক্রয় ফেরত — স্টক ও ক্যাশ/বাকি স্বয়ংক্রিয়ভাবে
// সমন্বয় করে
// ============================================================

import 'package:sqflite/sqflite.dart';
import 'db_helper.dart';
import '../utils/sync_id.dart';
import '../utils/quantity_math.dart';

class ReturnService {
  final DBHelper _dbHelper = DBHelper.instance;

  Future<void> _logActivity(DatabaseExecutor db, int? userId, String action,
      String entityType, int? entityId, String details) async {
    await db.insert('activity_log', {
      'user_id': userId,
      'action': action,
      'entity_type': entityType,
      'entity_id': entityId,
      'details': details,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _addCashLedger(DatabaseExecutor db, double amount, String direction,
      String refType, int? refId, String description, String date,
      {String? refSyncId}) async {
    if (amount <= 0) return;
    await db.insert('cash_ledger', {
      'amount': amount,
      'direction': direction,
      'reference_type': refType,
      'reference_id': refId,
      'description': description,
      'transaction_date': date,
      'created_at': DateTime.now().toIso8601String(),
      'sync_id': generateSyncId(),
      'ref_sync_id': refSyncId,
    });
  }

  // ----------------------------------------------------------
  // বিক্রয় ফেরত — কাস্টমার পণ্য ফেরত দিলে
  // ----------------------------------------------------------
  /// একটা sale_item-এর কতটুকু ফেরত আসছে সেটা নির্দিষ্ট করে দিতে হবে।
  /// ফেরত আসা মাল একটা নতুন FIFO ব্যাচ হিসেবে (মূল ক্রয়মূল্যে) আবার
  /// স্টকে যোগ হয়, যাতে ভবিষ্যতের FIFO হিসাব ঠিক থাকে।
  /// refundToCash: true হলে ক্যাশ থেকে টাকা ফেরত দেওয়া হলো ধরা হবে,
  /// false হলে শুধু বাকির হিসাব সমন্বয় হবে (বাকি বিক্রয়ের ক্ষেত্রে)
  ///
  /// *** সংশোধন (Phase 1, multi-unit) ***: sale_items.quantity এখন যে
  /// unit-এ বিক্রি হয়েছিল সেই এককেই থাকে (pack হলে pack-সংখ্যা), base
  /// unit না। আগের ভার্সনে `quantity` প্যারামিটার সরাসরি
  /// purchase_batches.quantity/remaining_quantity-তে (যেটা সবসময় base
  /// unit-এ থাকে) বসিয়ে দেওয়া হতো — অর্থাৎ কেউ "1" pack (=500g) ফেরত
  /// দিলে স্টকে মাত্র ১ গ্রাম যোগ হতো, ৫০০ গ্রাম না। এখন sale_item-এর
  /// product_unit_id থেকে conversion factor বের করে সঠিকভাবে base
  /// quantity-তে কনভার্ট করে stock/cost হিসাব করা হচ্ছে। `quantity`
  /// প্যারামিটার এখনো display/sold unit-এই থাকে (UI থেকে যেভাবে আসে),
  /// শুধু ভেতরের হিসাবটা ঠিক করা হয়েছে।
  Future<int> recordSaleReturn({
    required int saleItemId,
    required double quantity, // যে unit-এ বিক্রি হয়েছিল সেই এককে (sale_items.quantity-এর মতোই)
    required bool refundToCash,
    required String returnDate,
    required int? createdBy,
  }) async {
    final db = await _dbHelper.database;

    return await db.transaction((txn) async {
      final saleItem = (await txn.query('sale_items',
              where: 'id = ?', whereArgs: [saleItemId]))
          .first;

      // নিরাপত্তা-চেক (UI ছাড়াও সার্ভিসেই): বিক্রিত পরিমাণের বেশি ফেরত
      // নেওয়া যাবে না, আর নগদ বিক্রয়ে "বাকির হিসাব সমন্বয়" চলবে না —
      // নাহলে টাকা না দিয়েই লাভ কমে যেত / স্টক বেশি দেখাত
      final soldQty = (saleItem['quantity'] as num).toDouble();
      final returnedRows = await txn.rawQuery(
          'SELECT COALESCE(SUM(quantity), 0) as q FROM sale_returns WHERE sale_item_id = ?',
          [saleItemId]);
      final alreadyReturned = (returnedRows.first['q'] as num).toDouble();
      if (quantity <= 0 ||
          QuantityMath.round(quantity) >
              QuantityMath.round(soldQty - alreadyReturned)) {
        throw Exception(
            'ফেরতযোগ্য পরিমাণের বেশি ফেরত নেওয়া যাবে না (সর্বোচ্চ: ${QuantityMath.round(soldQty - alreadyReturned)})');
      }
      final saleRow = (await txn.query('sales',
              where: 'id = ?', whereArgs: [saleItem['sale_id']]))
          .first;
      if (!refundToCash && (saleRow['is_credit'] as int? ?? 0) != 1) {
        throw Exception(
            'নগদ বিক্রয়ের ফেরতে ক্যাশ ফেরত দিতে হবে (শুধু বাকির বিক্রয়ে বাকি থেকে সমন্বয় চলে)');
      }

      final productId = saleItem['product_id'] as int;
      final unitPrice = (saleItem['unit_price'] as num).toDouble();
      final productUnitId = saleItem['product_unit_id'] as int?;

      // বাকির সাথে সমন্বয় কাস্টমারের বর্তমান বাকির চেয়ে বেশি হতে পারে না — নাহলে
      // কাস্টমারের বাকি ঋণাত্মক হয়ে যেত; বাড়তি অংশ ক্যাশে ফেরত দিতে হবে
      final customerId = saleRow['customer_id'] as int?;
      if (!refundToCash && customerId != null) {
        final preview = QuantityMath.round(quantity * unitPrice);
        final dueRows = await txn.rawQuery('''
          SELECT COALESCE((SELECT SUM(total_amount - paid_amount) FROM sales
                           WHERE customer_id = ? AND is_credit = 1), 0)
               - COALESCE((SELECT SUM(amount) FROM due_payments
                           WHERE party_type = 'customer' AND party_id = ?), 0) AS due
        ''', [customerId, customerId]);
        final due = (dueRows.first['due'] as num).toDouble();
        if (preview > (due > 0 ? due : 0) + 0.005) {
          throw Exception(
              'বাকির হিসাবে সমন্বয় করা যাবে কাস্টমারের বর্তমান বাকি (৳${due > 0 ? due.toStringAsFixed(0) : '0'}) পর্যন্ত — '
              'ফেরতের মূল্য ৳${preview.toStringAsFixed(0)}। বাড়তি অংশের জন্য "ক্যাশ ফেরত" চালু করুন।');
        }
      }

      double conversionFactor = 1;
      if (productUnitId != null) {
        final puRows = await txn.query('product_units',
            where: 'id = ?', whereArgs: [productUnitId]);
        if (puRows.isNotEmpty) {
          conversionFactor =
              (puRows.first['conversion_factor_to_base'] as num).toDouble();
        }
      }
      QuantityMath.requireRepresentable(quantity, conversionFactor);
      final baseQty = QuantityMath.toBase(quantity, conversionFactor);

      // এই sale_item কোন কোন ব্যাচ থেকে কাটা হয়েছিল, সেই একই
      // গড় ক্রয়মূল্যে ফেরত মাল আবার স্টকে যোগ হবে (নতুন ব্যাচ হিসেবে)
      // — allocation-এর quantity সবসময় base unit-এ, তাই এখানে সরাসরি
      // ব্যবহার করা নিরাপদ
      final allocations = await txn.query('sale_item_batch_allocations',
          where: 'sale_item_id = ?', whereArgs: [saleItemId]);
      double totalQty = 0, totalCost = 0;
      for (final a in allocations) {
        totalQty += (a['quantity'] as num).toDouble();
        totalCost += (a['quantity'] as num).toDouble() *
            (a['unit_cost'] as num).toDouble();
      }
      final avgCost = totalQty > 0 ? totalCost / totalQty : 0.0;

      // নতুন FIFO ব্যাচ তৈরি (base unit-এ) — আজকের তারিখে, যাতে এটা
      // সবচেয়ে "পুরনো" ব্যাচগুলোর পরে বিবেচিত হয় (FIFO ক্রম ঠিক থাকে)
      await txn.insert('purchase_batches', {
        'purchase_id': null,
        'product_id': productId,
        'product_unit_id': productUnitId,
        'display_quantity': productUnitId == null ? null : quantity,
        'quantity': baseQty,
        'remaining_quantity': baseQty,
        'unit_cost': avgCost,
        'batch_date': returnDate,
        'sync_id': generateSyncId(),
      });

      final refundAmount = QuantityMath.round(quantity * unitPrice);
      final costAmount = QuantityMath.round(baseQty * avgCost);

      final returnSyncId = generateSyncId();
      final id = await txn.insert('sale_returns', {
        'sale_item_id': saleItemId,
        'quantity': quantity,
        'return_date': returnDate,
        'refund_amount': refundAmount,
        'cost_amount': costAmount,
        'created_by': createdBy,
        'sync_id': returnSyncId,
      });

      if (refundToCash) {
        await _addCashLedger(txn, refundAmount, 'out',
            'sale_return', id, 'বিক্রয় ফেরত — ক্যাশ ফেরত', returnDate,
            refSyncId: returnSyncId);
      }
      // যদি refundToCash false হয় (বাকির উপর ফেরত), তাহলে শুধু
      // due_payments/receivables হিসাব থেকেই স্বয়ংক্রিয়ভাবে কমে যাবে,
      // কারণ getTotalReceivables() sales.total_amount ব্যবহার করে না —
      // received amount এর ভিত্তিতে হিসাব করে। এক্ষেত্রে sales টেবিলের
      // total_amount কমিয়ে দেওয়া দরকার:
      if (!refundToCash) {
        await txn.rawUpdate('''
          UPDATE sales SET total_amount = total_amount - ?
          WHERE id = (SELECT sale_id FROM sale_items WHERE id = ?)
        ''', [refundAmount, saleItemId]);
      }

      await _logActivity(txn, createdBy, 'create', 'sale_return',
          id, 'পরিমাণ: $quantity, ফেরত: $refundAmount');

      return id;
    });
  }

  // ----------------------------------------------------------
  // ক্রয় ফেরত — সাপ্লায়ারকে মাল ফেরত দিলে
  // ----------------------------------------------------------
  Future<int> recordPurchaseReturn({
    required int purchaseBatchId,
    required double quantity,
    required bool refundToCash,
    required String returnDate,
    required int? createdBy,
  }) async {
    final db = await _dbHelper.database;

    return await db.transaction((txn) async {
      final batch = (await txn.query('purchase_batches',
              where: 'id = ?', whereArgs: [purchaseBatchId]))
          .first;
      final remaining = (batch['remaining_quantity'] as num).toDouble();
      if (quantity > remaining) {
        throw Exception(
            'এত পরিমাণ ফেরত দেওয়া যাবে না। স্টকে আছে: $remaining');
      }
      final unitCost = (batch['unit_cost'] as num).toDouble();

      if (quantity <= 0) {
        throw Exception('সঠিক পরিমাণ দিন');
      }
      QuantityMath.requireRepresentable(quantity, 1);
      if (!refundToCash) {
        // দেনার সাথে সমন্বয় শুধু বাকিতে কেনা ক্রয়ের ক্ষেত্রে চলে
        final purchaseId = batch['purchase_id'];
        final isCredit = purchaseId == null
            ? 0
            : ((await txn.query('purchases',
                            columns: ['is_credit'],
                            where: 'id = ?',
                            whereArgs: [purchaseId]))
                        .first['is_credit'] as int? ??
                    0);
        if (isCredit != 1) {
          throw Exception(
              'নগদে কেনা মালের ফেরতে সাপ্লায়ার থেকে ক্যাশ ফেরত নিতে হবে (শুধু বাকির ক্রয়ে দেনা থেকে সমন্বয় চলে)');
        }
        // দেনার সাথে সমন্বয় সাপ্লায়ারের বর্তমান দেনার চেয়ে বেশি হতে পারে না
        final supplierId = (await txn.query('purchases',
                columns: ['supplier_id'],
                where: 'id = ?',
                whereArgs: [purchaseId]))
            .first['supplier_id'] as int?;
        if (supplierId != null) {
          final preview = quantity * unitCost;
          final dueRows = await txn.rawQuery('''
            SELECT COALESCE((SELECT SUM(total_amount - paid_amount) FROM purchases
                             WHERE supplier_id = ? AND is_credit = 1), 0)
                 - COALESCE((SELECT SUM(amount) FROM due_payments
                             WHERE party_type = 'supplier' AND party_id = ?), 0) AS due
          ''', [supplierId, supplierId]);
          final due = (dueRows.first['due'] as num).toDouble();
          if (preview > (due > 0 ? due : 0) + 0.005) {
            throw Exception(
                'দেনার হিসাবে সমন্বয় করা যাবে সাপ্লায়ারের বর্তমান দেনা (৳${due > 0 ? due.toStringAsFixed(0) : '0'}) পর্যন্ত — '
                'ফেরতের মূল্য ৳${preview.toStringAsFixed(0)}। বাড়তি অংশের জন্য "ক্যাশ ফেরত" চালু করুন।');
          }
        }
      }

      await txn.update('purchase_batches',
          {'remaining_quantity': remaining - quantity},
          where: 'id = ?', whereArgs: [purchaseBatchId]);

      final refundAmount = quantity * unitCost;

      final purchaseReturnSyncId = generateSyncId();
      final id = await txn.insert('purchase_returns', {
        'purchase_batch_id': purchaseBatchId,
        'quantity': quantity,
        'return_date': returnDate,
        'refund_amount': refundAmount,
        'created_by': createdBy,
        'sync_id': purchaseReturnSyncId,
      });

      if (refundToCash) {
        await _addCashLedger(txn, refundAmount, 'in',
            'purchase_return', id, 'ক্রয় ফেরত — ক্যাশ ফেরত পাওয়া', returnDate,
            refSyncId: purchaseReturnSyncId);
      } else {
        final purchaseId = batch['purchase_id'];
        if (purchaseId != null) {
          await txn.rawUpdate('''
            UPDATE purchases SET total_amount = total_amount - ?
            WHERE id = ?
          ''', [refundAmount, purchaseId]);
        }
      }

      await _logActivity(txn, createdBy, 'create',
          'purchase_return', id, 'পরিমাণ: $quantity, ফেরত: $refundAmount');

      return id;
    });
  }
}
