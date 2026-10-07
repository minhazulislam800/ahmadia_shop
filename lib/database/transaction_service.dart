// ============================================================
// transaction_service.dart
// প্রতিটা রিয়েল-ওয়ার্ল্ড লেনদেন (ক্রয়, বিক্রয়, খরচ, উত্তোলন...)
// এখানে একটা ফাংশন কল করলেই সংশ্লিষ্ট সব টেবিল
// (purchase_batches, sale_items, cash_ledger, activity_log)
// স্বয়ংক্রিয়ভাবে সঠিকভাবে আপডেট হয়ে যায় — যাতে ব্যবহারকারীকে
// (বা UI কোডকে) কখনো ম্যানুয়ালি একাধিক জায়গায় হিসাব মেলাতে না হয়।
// ============================================================

import 'package:sqflite/sqflite.dart';
import 'db_helper.dart';
import '../utils/sync_id.dart';
import '../utils/quantity_math.dart';

class TransactionService {
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
    if (amount <= 0) return; // শূন্য/ঋণাত্মক টাকা লেজারে যোগ করার দরকার নেই
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
  // Phase 1 (multi-unit) হেল্পার: একটা product_unit_id থেকে
  // conversion_factor_to_base বের করে আনা (sale/adjustment-এর সময়
  // pack quantity-কে base quantity-তে বদলাতে লাগবে)
  // ----------------------------------------------------------
  Future<double> _conversionFactorFor(
      DatabaseExecutor db, int? productUnitId) async {
    if (productUnitId == null) return 1.0; // সরাসরি base unit-এ লেনদেন
    final rows = await db.query('product_units',
        where: 'id = ?', whereArgs: [productUnitId]);
    if (rows.isEmpty) {
      throw Exception('Product unit খুঁজে পাওয়া যায়নি: $productUnitId');
    }
    return (rows.first['conversion_factor_to_base'] as num).toDouble();
  }

  // ----------------------------------------------------------
  // ক্রয় রেকর্ড করা — একাধিক পণ্য একসাথে, প্রতিটাই নতুন FIFO ব্যাচ
  // ----------------------------------------------------------
  /// items: [{product_id, quantity, unit_cost}, ...]
  // ----------------------------------------------------------
  // ক্রয় রেকর্ড করা — একাধিক পণ্য একসাথে, প্রতিটাই নতুন FIFO ব্যাচ
  // ----------------------------------------------------------
  /// items: [{product_id, quantity, unit_cost, product_unit_id?}, ...]
  /// Phase 1 (multi-unit): item-এ 'product_unit_id' দিলে, 'quantity' ও
  /// 'unit_cost' সেই pack unit-এ ধরা হবে (যেমন quantity=10 সাক, unit_cost=
  /// প্রতি সাকের দাম) — ভেতরে ভেতরে base unit-এ কনভার্ট হয়ে stock/FIFO-তে
  /// সংরক্ষিত হবে, যাতে বিক্রির সময়কার FIFO লজিক অপরিবর্তিত থাকে।
  /// 'product_unit_id' না দিলে আগের মতোই সরাসরি base unit ধরা হবে।
  Future<int> recordPurchase({
    required int? supplierId,
    required List<Map<String, dynamic>> items,
    required double paidAmount,
    required bool isCredit,
    required String purchaseDate,
    required int? createdBy,
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) => _recordPurchaseInTxn(txn, supplierId: supplierId, items: items, paidAmount: paidAmount, isCredit: isCredit, purchaseDate: purchaseDate, createdBy: createdBy));
  }

  /// ওপরের মেথডের মূল কাজ — অন্য transaction-এর ভেতর থেকেও কল করা যায় (edit = delete + record একই transaction-এ)
  Future<int> _recordPurchaseInTxn(
    DatabaseExecutor txn, {
    required int? supplierId,
    required List<Map<String, dynamic>> items,
    required double paidAmount,
    required bool isCredit,
    required String purchaseDate,
    required int? createdBy,
  }) async {
    double totalAmount = 0;
    for (final item in items) {
      totalAmount += (item['quantity'] as double) * (item['unit_cost'] as double);
    }

    
      final purchaseSyncId = generateSyncId();
      final purchaseId = await txn.insert('purchases', {
        'supplier_id': supplierId,
        'purchase_date': purchaseDate,
        'total_amount': totalAmount,
        'paid_amount': paidAmount,
        'is_credit': isCredit ? 1 : 0,
        'created_by': createdBy,
        'created_at': DateTime.now().toIso8601String(),
        'sync_id': purchaseSyncId,
      });

      for (final item in items) {
        final productUnitId = item['product_unit_id'] as int?;
        final displayQty = item['quantity'] as double;
        final displayUnitCost = item['unit_cost'] as double;
        final conversionFactor =
            await _conversionFactorFor(txn, productUnitId);

        // stock/FIFO সবসময় base unit-এ — pack-এ কেনা হলে কনভার্ট করা হচ্ছে
        QuantityMath.requireRepresentable(displayQty, conversionFactor);
        final baseQty = QuantityMath.toBase(displayQty, conversionFactor);
        // per-base-unit দাম round করা হয় না — round করলে (যেমন ৭টার প্যাক
        // ১০০ টাকা → ১৪.২৮৬) ইনভেন্টরি/লাভে প্রতি প্যাকে সামান্য গরমিল জমে
        final baseUnitCost = productUnitId == null
            ? displayUnitCost
            : displayUnitCost / conversionFactor;

        await txn.insert('purchase_batches', {
          'purchase_id': purchaseId,
          'product_id': item['product_id'],
          'product_unit_id': productUnitId,
          'display_quantity': productUnitId == null ? null : displayQty,
          'quantity': baseQty,
          'remaining_quantity': baseQty, // শুরুতে পুরোটাই স্টকে থাকে
          'unit_cost': baseUnitCost,
          'batch_date': purchaseDate,
          'sync_id': generateSyncId(),
        });
      }

      // ক্যাশে প্রভাব — শুধু যা নগদে দেওয়া হয়েছে সেটুকুই ক্যাশ থেকে কমবে
      if (paidAmount > 0) {
        await _addCashLedger(txn, paidAmount, 'out', 'purchase',
            purchaseId, 'ক্রয় পেমেন্ট', purchaseDate, refSyncId: purchaseSyncId);
      }

      await _logActivity(txn, createdBy, 'create', 'purchase',
          purchaseId, 'নতুন ক্রয় এন্ট্রি, মোট: $totalAmount');

      return purchaseId;
  }

  // ----------------------------------------------------------
  // বিক্রয় রেকর্ড করা — মাল্টি-আইটেম বিল, FIFO থেকে অটো কস্ট-কাটিং
  // ----------------------------------------------------------
  /// items: [{product_id, quantity, unit_price}, ...]
  /// রিটার্ন করে নতুন sale_id
  /// যদি কোনো পণ্যে পর্যাপ্ত স্টক না থাকে, পুরো লেনদেন বাতিল হয়ে যাবে
  /// (transaction rollback) — নেগেটিভ স্টক কখনোই হবে না
  Future<int> recordSale({
    required int? customerId,
    required List<Map<String, dynamic>> items,
    required double courierCharge,
    required double paidAmount,
    required bool isCredit,
    required String saleDate,
    required int? createdBy,
    String saleType = 'retail', // 'retail' অথবা 'wholesale'
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) => _recordSaleInTxn(txn, customerId: customerId, items: items, courierCharge: courierCharge, paidAmount: paidAmount, isCredit: isCredit, saleDate: saleDate, createdBy: createdBy, saleType: saleType));
  }

  /// ওপরের মেথডের মূল কাজ — অন্য transaction-এর ভেতর থেকেও কল করা যায় (edit = delete + record একই transaction-এ)
  Future<int> _recordSaleInTxn(
    DatabaseExecutor txn, {
    required int? customerId,
    required List<Map<String, dynamic>> items,
    required double courierCharge,
    required double paidAmount,
    required bool isCredit,
    required String saleDate,
    required int? createdBy,
    String saleType = 'retail', // 'retail' অথবা 'wholesale'
  }) async {

    double productsTotal = 0;
    for (final item in items) {
      productsTotal += (item['quantity'] as double) * (item['unit_price'] as double);
    }
    // কুরিয়ার চার্জ শুধু ইনভয়েসে তথ্যগত — মোট বিক্রয়মূল্যে/ক্যাশে যোগ হবে না
    final totalAmount = productsTotal;

    
      final saleSyncId = generateSyncId();
      final saleId = await txn.insert('sales', {
        'customer_id': customerId,
        'sale_date': saleDate,
        'courier_charge': courierCharge,
        'total_amount': totalAmount,
        'paid_amount': paidAmount,
        'is_credit': isCredit ? 1 : 0,
        'sale_type': saleType,
        'created_by': createdBy,
        'created_at': DateTime.now().toIso8601String(),
        'sync_id': saleSyncId,
      });

      for (final item in items) {
        final productId = item['product_id'] as int;
        final qty = item['quantity'] as double;
        final unitPrice = item['unit_price'] as double;
        // Phase 1 (multi-unit): item-এ 'product_unit_id' না থাকলে বোঝাবে
        // সরাসরি product-এর base unit-এ বিক্রি হয়েছে (আগের মতোই আচরণ)
        final productUnitId = item['product_unit_id'] as int?;
        final conversionFactor =
            await _conversionFactorFor(txn, productUnitId);
        // stock থেকে বাস্তবে যা কাটা হবে সেটা সবসময় base unit-এ, আর
        // rounding drift এড়াতে QuantityMath দিয়ে round করা হচ্ছে
        QuantityMath.requireRepresentable(qty, conversionFactor);
        final baseQty =
            QuantityMath.toBase(qty, conversionFactor);

        // FIFO অনুযায়ী পুরনো ব্যাচ থেকে কাটা (স্টক না থাকলে Exception -> পুরো
        // txn.transaction() ব্লক বাতিল হয়ে যাবে, sqflite নিজেই rollback করবে)
        final allocations =
            await _dbHelper.allocateFIFO(txn, productId, baseQty);

        double totalCost = 0;
        for (final alloc in allocations) {
          totalCost += (alloc['quantity'] as double) * (alloc['unit_cost'] as double);
        }

        final saleItemId = await txn.insert('sale_items', {
          'sale_id': saleId,
          'product_id': productId,
          'product_unit_id': productUnitId,
          'quantity': qty,
          'base_quantity': baseQty,
          'unit_price': unitPrice,
          'total_cost': totalCost,
          'sync_id': generateSyncId(),
        });

        for (final alloc in allocations) {
          await txn.insert('sale_item_batch_allocations', {
            'sale_item_id': saleItemId,
            'purchase_batch_id': alloc['batch_id'],
            'quantity': alloc['quantity'],
            'unit_cost': alloc['unit_cost'],
            'sync_id': generateSyncId(),
          });

          // সেই ব্যাচের remaining_quantity কমানো
          final batch = (await txn.query('purchase_batches',
                  where: 'id = ?', whereArgs: [alloc['batch_id']]))
              .first;
          final newRemaining = QuantityMath.subtract(
              (batch['remaining_quantity'] as num).toDouble(),
              (alloc['quantity'] as double));
          await txn.update('purchase_batches',
              {'remaining_quantity': newRemaining},
              where: 'id = ?', whereArgs: [alloc['batch_id']]);
        }
      }

      if (paidAmount > 0) {
        await _addCashLedger(txn, paidAmount, 'in', 'sale', saleId,
            'বিক্রয় থেকে আয়', saleDate, refSyncId: saleSyncId);
      }

      await _logActivity(txn, createdBy, 'create', 'sale', saleId,
          'নতুন বিক্রয়, মোট: $totalAmount');

      return saleId;
  }

  // ----------------------------------------------------------
  // খরচ এন্ট্রি
  // ----------------------------------------------------------
  Future<int> recordExpense({
    required String category,
    required double amount,
    required String? description,
    required String expenseDate,
    required int? createdBy,
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      final expenseSyncId = generateSyncId();
      final id = await txn.insert('expenses', {
        'category': category,
        'amount': amount,
        'description': description,
        'expense_date': expenseDate,
        'created_by': createdBy,
        'created_at': DateTime.now().toIso8601String(),
        'sync_id': expenseSyncId,
      });

      await _addCashLedger(txn, amount, 'out', 'expense', id,
          category, expenseDate, refSyncId: expenseSyncId);

      await _logActivity(
          txn, createdBy, 'create', 'expense', id, '$category: $amount');

      return id;
    });
  }

  // ----------------------------------------------------------
  // পার্টনার মূলধন বিনিয়োগ / উত্তোলন (ক্যাপিটাল বা লাভ)
  // ----------------------------------------------------------
  Future<int> recordCapitalTransaction({
    required int partnerId,
    required String type, // invest / withdraw_capital / withdraw_profit
    required double amount,
    required String date,
    String? note,
    required int? createdBy,
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      final capitalSyncId = generateSyncId();
      final id = await txn.insert('capital_transactions', {
        'partner_id': partnerId,
        'type': type,
        'amount': amount,
        'transaction_date': date,
        'note': note,
        'created_by': createdBy,
        'created_at': DateTime.now().toIso8601String(),
        'sync_id': capitalSyncId,
      });

      if (type == 'invest') {
        await _addCashLedger(txn, amount, 'in', 'capital', id,
            'পার্টনার বিনিয়োগ', date, refSyncId: capitalSyncId);
      } else {
        // withdraw_capital বা withdraw_profit — দুটোই ক্যাশ থেকে বের হবে
        await _addCashLedger(txn, amount, 'out', 'capital', id,
            type == 'withdraw_profit' ? 'লাভ উত্তোলন' : 'মূলধন উত্তোলন', date,
            refSyncId: capitalSyncId);
      }

      await _logActivity(txn, createdBy, 'create',
          'capital_transaction', id, '$type: $amount');

      return id;
    });
  }

  // ----------------------------------------------------------
  // খরচ এডিট — ক্যাশ লেজারের সংশ্লিষ্ট এন্ট্রিও একসাথে নতুন মানে বদলায়
  // (একই transaction-এ, তাই মাঝপথে হিসাব ভাঙে না)
  // ----------------------------------------------------------
  Future<void> editExpense({
    required int expenseId,
    required String category,
    required double amount,
    required String? description,
    required String expenseDate,
    required int? editedBy,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final rows =
          await txn.query('expenses', where: 'id = ?', whereArgs: [expenseId]);
      if (rows.isEmpty) throw Exception('খরচ খুঁজে পাওয়া যায়নি');
      final old = rows.first;

      await txn.update(
          'expenses',
          {
            'category': category,
            'amount': amount,
            'description': description,
            'expense_date': expenseDate,
          },
          where: 'id = ?',
          whereArgs: [expenseId]);

      await txn.delete('cash_ledger',
          where: "reference_type = 'expense' AND reference_id = ?",
          whereArgs: [expenseId]);
      await _addCashLedger(txn, amount, 'out', 'expense', expenseId, category,
          expenseDate,
          refSyncId: old['sync_id'] as String?);

      await _logActivity(
          txn,
          editedBy,
          'update',
          'expense',
          expenseId,
          'আগে: ${old['category']} ${old['amount']} (${old['expense_date']}) → এখন: $category $amount ($expenseDate)');
    });
  }

  // ----------------------------------------------------------
  // মূলধন/উত্তোলন এন্ট্রি এডিট — ধরন, পরিমাণ, তারিখ, নোট বদলানো যায়;
  // ক্যাশ লেজারও একই সাথে নতুন মানে বদলায়
  // ----------------------------------------------------------
  Future<void> editCapitalTransaction({
    required int transactionId,
    required String type, // invest / withdraw_capital / withdraw_profit
    required double amount,
    required String date,
    String? note,
    required int? editedBy,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query('capital_transactions',
          where: 'id = ?', whereArgs: [transactionId]);
      if (rows.isEmpty) throw Exception('এন্ট্রি খুঁজে পাওয়া যায়নি');
      final old = rows.first;

      await txn.update(
          'capital_transactions',
          {
            'type': type,
            'amount': amount,
            'transaction_date': date,
            'note': note,
          },
          where: 'id = ?',
          whereArgs: [transactionId]);

      await txn.delete('cash_ledger',
          where: "reference_type = 'capital' AND reference_id = ?",
          whereArgs: [transactionId]);
      final refSync = old['sync_id'] as String?;
      if (type == 'invest') {
        await _addCashLedger(txn, amount, 'in', 'capital', transactionId,
            'পার্টনার বিনিয়োগ', date,
            refSyncId: refSync);
      } else {
        await _addCashLedger(
            txn,
            amount,
            'out',
            'capital',
            transactionId,
            type == 'withdraw_profit' ? 'লাভ উত্তোলন' : 'মূলধন উত্তোলন',
            date,
            refSyncId: refSync);
      }

      await _logActivity(
          txn,
          editedBy,
          'update',
          'capital_transaction',
          transactionId,
          'আগে: ${old['type']} ${old['amount']} (${old['transaction_date']}) → এখন: $type $amount ($date)');
    });
  }

  // ----------------------------------------------------------
  // বাকি আদায়/শোধ
  // ----------------------------------------------------------
  Future<int> recordDuePayment({
    required String partyType, // customer / supplier
    required int partyId,
    required String referenceType,
    required int? referenceId,
    required double amount,
    required String date,
    required int? createdBy,
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      final dueSyncId = generateSyncId();
      final id = await txn.insert('due_payments', {
        'party_type': partyType,
        'party_id': partyId,
        'reference_type': referenceType,
        'reference_id': referenceId,
        'amount': amount,
        'payment_date': date,
        'created_by': createdBy,
        'sync_id': dueSyncId,
      });

      if (partyType == 'customer') {
        // কাস্টমার টাকা দিলে ক্যাশ বাড়বে
        await _addCashLedger(txn, amount, 'in', 'due_payment', id,
            'বাকি আদায়', date, refSyncId: dueSyncId);
      } else {
        // সাপ্লায়ারকে টাকা দিলে ক্যাশ কমবে
        await _addCashLedger(txn, amount, 'out', 'due_payment', id,
            'সাপ্লায়ার বাকি শোধ', date, refSyncId: dueSyncId);
      }

      await _logActivity(txn, createdBy, 'create', 'due_payment',
          id, '$partyType বাকি: $amount');

      return id;
    });
  }

  // ----------------------------------------------------------
  // স্টক অ্যাডজাস্টমেন্ট (নষ্ট/ঘাটতি/Gift/Sample/অতিরিক্ত পাওয়া) —
  // ক্যাশে প্রভাব নেই, কিন্তু stock ও (§7 অনুযায়ী) cost-reporting-এ
  // আলাদা category হিসেবে প্রভাব ফেলে।
  //
  // sign convention: quantity ঋণাত্মক হলে stock কমবে (নষ্ট/ঘাটতি/Gift/
  // Sample/Internal use), ধনাত্মক হলে stock বাড়বে (অতিরিক্ত পাওয়া)।
  //
  // *** সংশোধন (Phase 1) ***: আগের ভার্সনে quantity-এর sign যাই হোক না
  // কেন সবসময় allocateFIFO (যেটা শুধু স্টক *কমাতে* পারে) কল করা হতো —
  // অর্থাৎ "অতিরিক্ত পাওয়া" (positive adjustment) আসলে ভুলভাবে স্টক
  // কমিয়ে দিত বা exception ছুঁড়ে দিত। এখন ঠিক করা হয়েছে: positive
  // quantity হলে নতুন একটা ব্যাচ তৈরি হয় (stock বাড়ানোর জন্য), negative
  // হলে আগের মতোই FIFO থেকে কাটা হয় (তখন প্রকৃত ক্রয়মূল্য থেকেই এই
  // adjustment-এর টাকার মূল্য নির্ভুলভাবে বের হয়)।
  //
  // NOTE for developer: "অতিরিক্ত পাওয়া" স্টকের cost জানা না থাকলে
  // estimatedUnitCost প্যারামিটার না দিলে 0 ধরা হবে (দুই সিস্টেমই রাখা
  // হয়েছে — user চাইলে UI থেকে আন্দাজ দাম দিতে পারবে, না দিলে 0)।
  // ----------------------------------------------------------
  Future<int> recordStockAdjustment({
    required int productId,
    int? productUnitId, // Phase 1 (multi-unit): NULL হলে base unit ধরা হবে
    required double quantity, // input unit-এ, sign convention উপরে দেখুন
    required String reason,
    String? note,
    required String date,
    required int? createdBy,
    double? estimatedUnitCost, // শুধু positive (excess_found) adjustment-এর জন্য প্রযোজ্য
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      final conversionFactor =
          await _conversionFactorFor(txn, productUnitId);
      QuantityMath.requireRepresentable(quantity, conversionFactor);
      final baseQty = QuantityMath.toBase(quantity, conversionFactor);
      double totalCost = 0;

      if (baseQty < 0) {
        // স্টক কমছে — FIFO অনুযায়ী কেটে নেওয়া (পর্যাপ্ত স্টক না থাকলে
        // Exception, পুরো transaction rollback হয়ে যাবে)
        final allocations =
            await _dbHelper.allocateFIFO(txn, productId, -baseQty);

        for (final alloc in allocations) {
          // FIFO ব্যাচের প্রকৃত ক্রয়মূল্য থেকেই এই adjustment-এর আসল
          // টাকার মূল্য বের হচ্ছে — অনুমান নয়, সঠিক হিসাব
          totalCost += QuantityMath.round(
              (alloc['quantity'] as double) * (alloc['unit_cost'] as num).toDouble());

          final batch = (await txn.query('purchase_batches',
                  where: 'id = ?', whereArgs: [alloc['batch_id']]))
              .first;
          final newRemaining = QuantityMath.subtract(
              (batch['remaining_quantity'] as num).toDouble(),
              (alloc['quantity'] as double));
          await txn.update('purchase_batches',
              {'remaining_quantity': newRemaining},
              where: 'id = ?', whereArgs: [alloc['batch_id']]);
        }
      } else if (baseQty > 0) {
        // স্টক বাড়ছে ("অতিরিক্ত পাওয়া") — নতুন ব্যাচ তৈরি, cost হিসেবে
        // user-এর দেওয়া অনুমিত দাম (থাকলে) নাহলে 0 ব্যবহার হবে
        final unitCost = estimatedUnitCost ?? 0;
        totalCost = QuantityMath.round(baseQty * unitCost);
        await txn.insert('purchase_batches', {
          'purchase_id': null,
          'product_id': productId,
          'quantity': baseQty,
          'remaining_quantity': baseQty,
          'unit_cost': unitCost,
          'batch_date': date,
          'sync_id': generateSyncId(),
        });
      }

      final id = await txn.insert('stock_adjustments', {
        'product_id': productId,
        'product_unit_id': productUnitId,
        'quantity': quantity,
        'base_quantity': baseQty,
        'total_cost': totalCost,
        'reason': reason,
        'note': note,
        'adjustment_date': date,
        'created_by': createdBy,
        'sync_id': generateSyncId(),
      });

      await _logActivity(txn, createdBy, 'create',
          'stock_adjustment', id, '$reason: $quantity, মূল্য: $totalCost ($note)');

      return id;
    });
  }

  // ----------------------------------------------------------
  // স্টক সমন্বয় এডিট — কারণ, নোট, তারিখ ও পরিমাণ বদলানো যায়
  // (পণ্য ও স্টক কমবে/বাড়বে — এই দিক বদলানো যায় না; উল্টোটা লাগলে
  // নতুন এন্ট্রি দিন)। পরিমাণ বদলালে শুধু পার্থক্যটুকু স্টকে প্রয়োগ হয়:
  //   • ক্ষতি বাড়লে → বাড়তি অংশ FIFO অনুযায়ী আরও কাটা হয়
  //   • ক্ষতি কমলে  → ফেরত অংশ আগের গড় দামে নতুন ব্যাচ হিসেবে স্টকে ফেরে
  //   • "অতিরিক্ত পাওয়া" বাড়লে → আগের একক-দামে নতুন ব্যাচ; কমলে FIFO থেকে কাটা
  // total_cost সবসময় স্টকের মূল্য-পরিবর্তনের সাথে মিলিয়ে বদলায়, তাই
  // ইনভেন্টরি ও লাভ-ক্ষতির হিসাব মিলে থাকে।
  // ----------------------------------------------------------
  Future<void> editStockAdjustment({
    required int adjustmentId,
    required double newQuantityAbs, // ধনাত্মক সংখ্যা, newProductUnitId-এর এককে (দিক আগেরটাই থাকবে)
    required int? newProductUnitId, // null = base unit (যেমন কেজি), নাহলে বেছে নেওয়া unit (যেমন গ্রাম)
    required String reason,
    String? note,
    required String date,
    required int? editedBy,
  }) async {
    if (newQuantityAbs <= 0) throw Exception('সঠিক পরিমাণ দিন');
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query('stock_adjustments',
          where: 'id = ?', whereArgs: [adjustmentId]);
      if (rows.isEmpty) throw Exception('এন্ট্রি খুঁজে পাওয়া যায়নি');
      final old = rows.first;
      final productId = old['product_id'] as int;
      final productUnitId = newProductUnitId;
      final oldBase = (old['base_quantity'] as num).toDouble();
      final oldCost = (old['total_cost'] as num?)?.toDouble() ?? 0;
      final isLoss = oldBase < 0;

      final factor = await _conversionFactorFor(txn, productUnitId);
      QuantityMath.requireRepresentable(newQuantityAbs, factor);
      final newSigned = isLoss ? -newQuantityAbs : newQuantityAbs;
      final newBase = QuantityMath.toBase(newSigned, factor);
      final deltaBase = QuantityMath.round(newBase - oldBase);
      var newCost = oldCost;

      Future<double> consumeFifo(double qty) async {
        var cost = 0.0;
        final allocations = await _dbHelper.allocateFIFO(txn, productId, qty);
        for (final alloc in allocations) {
          cost += QuantityMath.round((alloc['quantity'] as double) *
              (alloc['unit_cost'] as num).toDouble());
          final batch = (await txn.query('purchase_batches',
                  where: 'id = ?', whereArgs: [alloc['batch_id']]))
              .first;
          await txn.update(
              'purchase_batches',
              {
                'remaining_quantity': QuantityMath.subtract(
                    (batch['remaining_quantity'] as num).toDouble(),
                    (alloc['quantity'] as double))
              },
              where: 'id = ?',
              whereArgs: [alloc['batch_id']]);
        }
        return cost;
      }

      Future<void> addBatch(double qty, double unitCost) async {
        await txn.insert('purchase_batches', {
          'purchase_id': null,
          'product_id': productId,
          'quantity': qty,
          'remaining_quantity': qty,
          'unit_cost': unitCost,
          'batch_date': date,
          'sync_id': generateSyncId(),
        });
      }

      if (deltaBase.abs() > 0.0000001) {
        final avgUnitCost = oldBase.abs() > 0 ? oldCost / oldBase.abs() : 0.0;
        if (isLoss) {
          if (deltaBase < 0) {
            // ক্ষতি বাড়ল — বাড়তি অংশ আরও কাটা (পর্যাপ্ত স্টক না থাকলে Exception)
            newCost = oldCost + await consumeFifo(-deltaBase);
          } else {
            await addBatch(deltaBase, avgUnitCost);
            newCost = oldCost - QuantityMath.round(deltaBase * avgUnitCost);
          }
        } else {
          if (deltaBase > 0) {
            await addBatch(deltaBase, avgUnitCost);
            newCost = oldCost + QuantityMath.round(deltaBase * avgUnitCost);
          } else {
            // বাড়তি-পাওয়া স্টক কমানো: "ক্রয়-ছাড়া" ব্যাচ (সমন্বয়/ফেরত থেকে আসা), যেগুলোর
            // দাম এই এন্ট্রির দামের সবচেয়ে কাছাকাছি, সেখান থেকে কাটা হয় — সবচেয়ে পুরনো
            // ক্রয়ের ব্যাচ থেকে কাটলে লাভ-ক্ষতির হিসাব ভেঙে যেত
            var need = -deltaBase;
            var removedCost = 0.0;
            final candidates = await txn.rawQuery('''
              SELECT id, remaining_quantity, unit_cost FROM purchase_batches
              WHERE product_id = ? AND purchase_id IS NULL AND remaining_quantity > 0
              ORDER BY ABS(unit_cost - ?) ASC, id DESC
            ''', [productId, avgUnitCost]);
            for (final b in candidates) {
              if (need <= 0) break;
              final rem = (b['remaining_quantity'] as num).toDouble();
              final take = need <= rem ? need : rem;
              removedCost += take * (b['unit_cost'] as num).toDouble();
              await txn.update(
                  'purchase_batches',
                  {'remaining_quantity': QuantityMath.subtract(rem, take)},
                  where: 'id = ?',
                  whereArgs: [b['id']]);
              need = QuantityMath.subtract(need, take);
            }
            if (need > 0.0000001 || removedCost > oldCost + 0.01) {
              throw Exception(
                  'এই বাড়তি স্টকের কিছু অংশ ইতিমধ্যে বিক্রি/ব্যবহার হয়ে গেছে, তাই পরিমাণ এত কমানো যাচ্ছে না। '
                  'বদলে নতুন একটা "নষ্ট/ঘাটতি" সমন্বয় এন্ট্রি দিন।');
            }
            newCost = oldCost - removedCost;
          }
        }
        if (newCost < 0) newCost = 0;
      }

      await txn.update(
          'stock_adjustments',
          {
            'product_unit_id': productUnitId,
            'quantity': newSigned,
            'base_quantity': newBase,
            'total_cost': newCost,
            'reason': reason,
            'note': note,
            'adjustment_date': date,
          },
          where: 'id = ?',
          whereArgs: [adjustmentId]);

      await _logActivity(
          txn,
          editedBy,
          'update',
          'stock_adjustment',
          adjustmentId,
          'আগে: ${old['reason']} ${old['quantity']} (মূল্য ${old['total_cost']}, ${old['adjustment_date']}) → এখন: $reason $newSigned (মূল্য $newCost, $date)');
    });
  }

  // ----------------------------------------------------------
  // Phase 2 — বিক্রয় (invoice) Delete/Edit (শুধু Master)
  // ----------------------------------------------------------
  /// একটা সম্পূর্ণ বিক্রয় বাতিল করা — chain অনুযায়ী সব রিভার্স হবে:
  ///   Sale → Stock (FIFO ব্যাচে ফেরত) → Customer Ledger (স্বয়ংক্রিয়,
  ///   কারণ receivables লাইভ SUM থেকে হিসাব হয়) → Revenue/Cost/Profit
  ///   (স্বয়ংক্রিয়, কারণ এগুলোও sale_items থেকে লাইভ হিসাব হয়)
  /// activity_log-এ মুছে ফেলার আগের পুরো ডেটা (before-snapshot হিসেবে)
  /// সংরক্ষণ করা হয় — Data Safety/Audit নীতি অনুযায়ী।
  ///
  /// নিরাপত্তা: এই sale-এর কোনো item-এ যদি আগে থেকেই return থাকে,
  /// delete আটকে যাবে (আগে return বাতিল/সমন্বয় করতে হবে) — যাতে
  /// sale_returns-এর reference ভেঙে না যায়।
  Future<void> deleteSale({
    required int saleId,
    required int? deletedBy,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) => _deleteSaleInTxn(txn, saleId: saleId, deletedBy: deletedBy));
  }

  /// ওপরের মেথডের মূল কাজ — অন্য transaction-এর ভেতর থেকেও কল করা যায় (edit = delete + record একই transaction-এ)
  Future<void> _deleteSaleInTxn(
    DatabaseExecutor txn, {
    required int saleId,
    required int? deletedBy,
  }) async {
    
      final saleRows =
          await txn.query('sales', where: 'id = ?', whereArgs: [saleId]);
      if (saleRows.isEmpty) {
        throw Exception('Sale খুঁজে পাওয়া যায়নি: $saleId');
      }
      final saleItems = await txn.query('sale_items',
          where: 'sale_id = ?', whereArgs: [saleId]);

      // নিরাপত্তা-চেক: এই sale-এর কোনো item-এ return থাকলে delete আটকানো
      for (final item in saleItems) {
        final returns = await txn.query('sale_returns',
            where: 'sale_item_id = ?', whereArgs: [item['id']]);
        if (returns.isNotEmpty) {
          throw Exception(
              'এই বিক্রয়ে return এন্ট্রি আছে — আগে return বাতিল করুন, তারপর sale delete করুন।');
        }
      }

      // স্টক ফেরত: প্রতিটা batch allocation যেখান থেকে কাটা হয়েছিল,
      // সেখানেই ঠিক ততটুকু ফেরত (remaining_quantity বাড়িয়ে)
      for (final item in saleItems) {
        final allocations = await txn.query('sale_item_batch_allocations',
            where: 'sale_item_id = ?', whereArgs: [item['id']]);
        for (final alloc in allocations) {
          final batch = (await txn.query('purchase_batches',
                  where: 'id = ?', whereArgs: [alloc['purchase_batch_id']]))
              .first;
          final restored = QuantityMath.add(
              (batch['remaining_quantity'] as num).toDouble(),
              (alloc['quantity'] as num).toDouble());
          await txn.update('purchase_batches',
              {'remaining_quantity': restored},
              where: 'id = ?', whereArgs: [alloc['purchase_batch_id']]);
        }
        await txn.delete('sale_item_batch_allocations',
            where: 'sale_item_id = ?', whereArgs: [item['id']]);
      }

      // ক্যাশ রিভার্স — এই বিক্রয়ের সাথে যুক্ত cash_ledger এন্ট্রি মুছে
      // ফেললেই dashboard-এর cash-in-hand স্বয়ংক্রিয়ভাবে ঠিক হয়ে যাবে
      await txn.delete('cash_ledger',
          where: "reference_type = 'sale' AND reference_id = ?", whereArgs: [saleId]);

      // audit-এর জন্য before-snapshot (§13/§18 — history নষ্ট করা যাবে না)
      final snapshot = {'sale': saleRows.first, 'items': saleItems};
      await _logActivity(txn, deletedBy, 'delete', 'sale', saleId,
          'বিক্রয় ডিলিট করা হলো, আগের ডেটা: $snapshot');

      await txn.delete('sale_items', where: 'sale_id = ?', whereArgs: [saleId]);
      await txn.delete('sales', where: 'id = ?', whereArgs: [saleId]);
  }

  /// বিক্রয় edit — সহজ ও নিরাপদ approach: পুরনোটা সম্পূর্ণ reverse করে
  /// (deleteSale) নতুন ডেটা দিয়ে recordSale — জটিল "partial-update" লজিক
  /// এড়িয়ে পুরো chain-ই নতুন করে নির্ভুলভাবে তৈরি হয়। একই db.transaction-এ
  /// দুটোই হয় বলে মাঝপথে কোনো state ভাঙা অবস্থায় থাকে না।
  Future<int> editSale({
    required int saleId,
    required int? editedBy,
    required int? customerId,
    required List<Map<String, dynamic>> items,
    required double courierCharge,
    required double paidAmount,
    required bool isCredit,
    required String saleType,
    required String saleDate,
  }) async {
    // একই transaction-এ পুরনোটা মুছে নতুনটা তৈরি — নতুনটা ব্যর্থ হলে (যেমন স্টক
    // কম) পুরনো বিক্রয়ও যেমন ছিল তেমনই থাকে, কিছু হারায় না
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      await _deleteSaleInTxn(txn, saleId: saleId, deletedBy: editedBy);
      return _recordSaleInTxn(
        txn,
        customerId: customerId,
        items: items,
        courierCharge: courierCharge,
        paidAmount: paidAmount,
        isCredit: isCredit,
        saleType: saleType,
        saleDate: saleDate,
        createdBy: editedBy,
      );
    });
  }

  // ----------------------------------------------------------
  // Phase 2 — ক্রয় Delete/Edit (শুধু Master)
  // ----------------------------------------------------------
  /// নিরাপত্তা: এই ক্রয়ের কোনো ব্যাচ থেকে যদি ইতিমধ্যে কিছু বিক্রি/
  /// adjustment হয়ে থাকে (remaining_quantity < quantity), delete আটকে
  /// যাবে — কারণ সেই বিক্রি কোন cost-এর ভিত্তিতে হয়েছিল তার প্রমাণ
  /// (purchase_batches) মুছে ফেললে আগের বিক্রয়ের profit হিসাব ভেঙে
  /// যাবে (Data Safety নীতি)।
  Future<void> deletePurchase({
    required int purchaseId,
    required int? deletedBy,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) => _deletePurchaseInTxn(txn, purchaseId: purchaseId, deletedBy: deletedBy));
  }

  /// ওপরের মেথডের মূল কাজ — অন্য transaction-এর ভেতর থেকেও কল করা যায় (edit = delete + record একই transaction-এ)
  Future<void> _deletePurchaseInTxn(
    DatabaseExecutor txn, {
    required int purchaseId,
    required int? deletedBy,
  }) async {
    
      final purchaseRows = await txn
          .query('purchases', where: 'id = ?', whereArgs: [purchaseId]);
      if (purchaseRows.isEmpty) {
        throw Exception('Purchase খুঁজে পাওয়া যায়নি: $purchaseId');
      }
      final batches = await txn.query('purchase_batches',
          where: 'purchase_id = ?', whereArgs: [purchaseId]);

      for (final batch in batches) {
        final qty = (batch['quantity'] as num).toDouble();
        final remaining = (batch['remaining_quantity'] as num).toDouble();
        if (!QuantityMath.approxEqual(qty, remaining)) {
          throw Exception(
              'এই ক্রয়ের কিছু মাল ইতিমধ্যে বিক্রি/ব্যবহার হয়ে গেছে — আগে সেই বিক্রয়/adjustment বাতিল করুন, তারপর purchase delete করুন।');
        }
      }

      await txn.delete('cash_ledger',
          where: "reference_type = 'purchase' AND reference_id = ?",
          whereArgs: [purchaseId]);

      final snapshot = {'purchase': purchaseRows.first, 'batches': batches};
      await _logActivity(txn, deletedBy, 'delete', 'purchase', purchaseId,
          'ক্রয় ডিলিট করা হলো, আগের ডেটা: $snapshot');

      await txn.delete('purchase_batches',
          where: 'purchase_id = ?', whereArgs: [purchaseId]);
      await txn.delete('purchases', where: 'id = ?', whereArgs: [purchaseId]);
  }

  Future<int> editPurchase({
    required int purchaseId,
    required int? editedBy,
    required int? supplierId,
    required List<Map<String, dynamic>> items,
    required double paidAmount,
    required bool isCredit,
    required String purchaseDate,
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      await _deletePurchaseInTxn(txn, purchaseId: purchaseId, deletedBy: editedBy);
      return _recordPurchaseInTxn(
        txn,
        supplierId: supplierId,
        items: items,
        paidAmount: paidAmount,
        isCredit: isCredit,
        purchaseDate: purchaseDate,
        createdBy: editedBy,
      );
    });
  }
}
