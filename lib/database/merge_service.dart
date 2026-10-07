// ============================================================
// merge_service.dart
// দুইটা আলাদা ডিভাইসের ডাটাবেস (একটা লোকাল, একটা ব্যাকআপ ফাইল
// থেকে) একসাথে "মার্জ" করে — শুধু প্রতিস্থাপন (replace) না।
//
// কীভাবে কাজ করে:
//  ১. ব্যাকআপ ফাইলের ডাটাবেস আলাদা একটা কানেকশনে খোলা হয়
//  ২. প্রতিটা টেবিলের প্রতিটা রেকর্ডের একটা ইউনিক sync_id আছে
//     (তৈরির সময় থেকেই)। লোকাল ডাটাবেসে সেই sync_id না থাকলে
//     সেটা নতুন রেকর্ড হিসেবে যোগ হয় (ডুপ্লিকেট হয় না)
//  ৩. পণ্য/কাস্টমার/সাপ্লায়ার আগে মার্জ হয়, তারপর ক্রয়/বিক্রয়/
//     খরচ ইত্যাদি — কারণ পরের টেবিলগুলো আগেরগুলোর উপর নির্ভরশীল
//     (foreign key), তাই ID রিম্যাপ করে সঠিক জায়গায় বসাতে হয়
//  ৪. পার্টনার মার্জ হয় না (দুই ডিভাইসেই একই ২ জন পার্টনার
//     ধরে নেওয়া হয়) — শুধু ক্রমানুযায়ী ম্যাপ করা হয় (১ম↔১ম, ২য়↔২য়)
//
// সীমাবদ্ধতা: যদি দুই ডিভাইসে একই পণ্য/কাস্টমার/সাপ্লায়ার আলাদা
// আলাদাভাবে তৈরি করা হয় (একই নাম, ভিন্ন sync_id), মার্জের পর
// দুইটা আলাদা এন্ট্রি থাকবে (ডুপ্লিকেট) — এটা মার্জ রিপোর্টে
// দেখানো হয়, যাতে ব্যবহারকারী ম্যানুয়ালি বুঝে নিতে পারেন।
// ============================================================

import 'package:sqflite/sqflite.dart';
import 'db_helper.dart';

class MergeReport {
  final Map<String, int> insertedCounts = {};
  final List<String> possibleDuplicates = [];
  int get totalInserted =>
      insertedCounts.values.fold(0, (sum, c) => sum + c);
}

class MergeService {
  final DBHelper _dbHelper = DBHelper.instance;

  Future<MergeReport> merge(String secondaryDbPath) async {
    final localDb = await _dbHelper.database;
    final secondaryDb = await openDatabase(secondaryDbPath, readOnly: true);
    final report = MergeReport();

    try {
      // নিরাপত্তা-চেক: দুই ডেটাবেসে একই (sync_id) স্টক-ব্যাচ আছে অথচ দুই জায়গায় তার
      // বাকি-পরিমাণ আলাদা — মানে একই ব্যাকআপ থেকে শুরু করে দুই ডিভাইসেই একই মাল বিক্রি/ব্যবহার
      // হয়েছে। এই অবস্থায় মার্জ করলে স্টক ও হিসাব ভুল হয় (টেস্টে ২৪ হাজার টাকার গরমিল),
      // তাই মার্জ না করে সম্পূর্ণ রিস্টোর করতে বলা হয়।
      final localBatchRows = await localDb
          .query('purchase_batches', columns: ['sync_id', 'remaining_quantity']);
      final localRemaining = <String, double>{
        for (final r in localBatchRows)
          if (r['sync_id'] != null)
            r['sync_id'] as String: (r['remaining_quantity'] as num).toDouble()
      };
      final secondaryBatchRows = await secondaryDb
          .query('purchase_batches', columns: ['sync_id', 'remaining_quantity']);
      var conflictingBatches = 0;
      for (final r in secondaryBatchRows) {
        final syncId = r['sync_id'] as String?;
        if (syncId == null) continue;
        final local = localRemaining[syncId];
        if (local == null) continue;
        final other = (r['remaining_quantity'] as num).toDouble();
        if ((other - local).abs() > 0.0005) conflictingBatches++;
      }
      if (conflictingBatches > 0) {
        throw Exception(
            'এই দুই ডেটাবেস একই ব্যাকআপ থেকে শুরু হয়ে আলাদাভাবে বদলেছে ($conflictingBatches টি স্টক-ব্যাচে '
            'গরমিল) — মার্জ করলে স্টক ও হিসাব ভুল হতো, তাই কিছু বদলানো হয়নি। '
            'বদলে এক ডিভাইসের ব্যাকআপ অন্যটায় "রিস্টোর" করুন।');
      }

      await localDb.transaction((txn) async {
        // --- ধাপ ১: মাস্টার ডেটা (ক্যাটাগরি, পণ্য, সাপ্লায়ার, কাস্টমার) ---
        final categoryIdMap = await _mergeSimpleTable(
            txn, secondaryDb, 'categories', report,
            ['name']);

        final productIdMap = await _mergeProducts(
            txn, secondaryDb, categoryIdMap, report);

        // Phase 1 (multi-unit): product_units-ও products-এর ঠিক পরেই
        // মার্জ হবে, কারণ purchase_batches/sale_items/stock_adjustments
        // এর product_unit_id এর ওপর নির্ভর করে
        final productUnitIdMap = await _mergeProductUnits(
            txn, secondaryDb, productIdMap, report);

        final supplierIdMap = await _mergePartyTable(
            txn, secondaryDb, 'suppliers', report);

        final customerIdMap = await _mergePartyTable(
            txn, secondaryDb, 'customers', report);

        // --- ধাপ ২: পার্টনার — ক্রমানুযায়ী ম্যাপ (মার্জ না, শুধু ID মেলানো) ---
        final partnerIdMap = await _mapPartnersByPosition(txn, secondaryDb);

        // --- ধাপ ৩: ক্রয় ও ব্যাচ ---
        final purchaseIdMap = await _mergePurchases(
            txn, secondaryDb, supplierIdMap, report);
        final batchIdMap = await _mergePurchaseBatches(
            txn, secondaryDb, purchaseIdMap, productIdMap, productUnitIdMap, report);

        // --- ধাপ ৪: বিক্রয়, আইটেম, ব্যাচ-অ্যালোকেশন ---
        final saleIdMap = await _mergeSales(
            txn, secondaryDb, customerIdMap, report);
        final saleItemIdMap = await _mergeSaleItems(
            txn, secondaryDb, saleIdMap, productIdMap, productUnitIdMap, report);
        await _mergeSaleItemBatchAllocations(
            txn, secondaryDb, saleItemIdMap, batchIdMap, report);

        // --- ধাপ ৫: রিটার্ন ---
        await _mergeSaleReturns(txn, secondaryDb, saleItemIdMap, report);
        await _mergePurchaseReturns(txn, secondaryDb, batchIdMap, report);

        // --- ধাপ ৬: স্টক অ্যাডজাস্টমেন্ট, খরচ, মূলধন, বাকি-পরিশোধ ---
        await _mergeStockAdjustments(txn, secondaryDb, productIdMap, productUnitIdMap, report);
        final expenseIdMap = await _mergeExpenses(txn, secondaryDb, report);
        final capitalIdMap = await _mergeCapitalTransactions(
            txn, secondaryDb, partnerIdMap, report);
        final duePaymentIdMap = await _mergeDuePayments(
            txn, secondaryDb, customerIdMap, supplierIdMap, report);

        // --- ধাপ ৭: ক্যাশ লেজার (সবশেষে, কারণ এটা বাকি সবকিছুর উপর নির্ভরশীল) ---
        await _mergeCashLedger(
            txn,
            secondaryDb,
            report,
            {
              'purchase': purchaseIdMap,
              'sale': saleIdMap,
              'expense': expenseIdMap,
              'capital': capitalIdMap,
              'due_payment': duePaymentIdMap,
              'sale_return': <String, int>{},
              'purchase_return': <String, int>{},
            });

        // --- ডুপ্লিকেট-সম্ভাব্য নাম শনাক্ত করা (পণ্য/কাস্টমার/সাপ্লায়ার) ---
        report.possibleDuplicates.addAll(
            await _findPossibleDuplicates(txn, 'products'));
        report.possibleDuplicates.addAll(
            await _findPossibleDuplicates(txn, 'customers'));
        report.possibleDuplicates.addAll(
            await _findPossibleDuplicates(txn, 'suppliers'));
      });
    } finally {
      await secondaryDb.close();
    }

    return report;
  }

  /// ফোন নম্বর থেকে শুধু সংখ্যা রাখে, +৮৮/০ প্রিফিক্স স্বাভাবিক করে —
  /// যাতে "01712345678" আর "+8801712345678" একই নম্বর হিসেবে মেলে
  String _normalizePhone(String? phone) {
    if (phone == null) return '';
    var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('88') && digits.length > 11) {
      digits = digits.substring(2);
    }
    return digits;
  }

  /// কাস্টমার/সাপ্লায়ার মার্জ — sync_id মিললে তো মেলেই, কিন্তু
  /// sync_id না মিললেও যদি ফোন নম্বর মেলে (দুই ডিভাইসে আলাদাভাবে
  /// তৈরি করা একই মানুষ), তাহলেও ডুপ্লিকেট না বানিয়ে বিদ্যমান
  /// রেকর্ডের সাথেই ম্যাপ করে দেওয়া হয় — এটাই মূল ডুপ্লিকেট-প্রতিরোধ লজিক
  Future<Map<String, int>> _mergePartyTable(
      Transaction txn, Database secondaryDb, String table, MergeReport report) async {
    final idMap = <String, int>{};
    final localRows = await txn.query(table);
    final localBySyncId = {
      for (final r in localRows)
        if (r['sync_id'] != null) r['sync_id'] as String: r['id'] as int
    };
    final localByPhone = <String, int>{};
    for (final r in localRows) {
      final normalized = _normalizePhone(r['phone'] as String?);
      if (normalized.isNotEmpty) localByPhone[normalized] = r['id'] as int;
    }

    final secondaryRows = await secondaryDb.query(table);
    int inserted = 0;
    int matchedByPhone = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;

      // ১. sync_id দিয়ে সরাসরি মিলে গেলে (আগেই মার্জ হয়েছিল)
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }

      // ২. sync_id না মিললেও ফোন নম্বর মিললে — একই মানুষ ধরে নেওয়া হয়,
      // নতুন এন্ট্রি তৈরি না করে বিদ্যমান রেকর্ডের সাথেই ম্যাপ করা হয়
      final normalizedPhone = _normalizePhone(row['phone'] as String?);
      if (normalizedPhone.isNotEmpty && localByPhone.containsKey(normalizedPhone)) {
        idMap[syncId] = localByPhone[normalizedPhone]!;
        matchedByPhone++;
        continue;
      }

      // ৩. দুটোই না মিললে — সত্যিই নতুন, যোগ করা হবে
      final newId = await txn.insert(table, {
        'name': row['name'],
        'phone': row['phone'],
        'address': row['address'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      // নতুন রেকর্ডও ফোন-ম্যাপে যোগ করা হচ্ছে, যাতে এই ব্যাচের মধ্যেই
      // পরবর্তী রেকর্ড এটার সাথে মিলতে পারে
      if (normalizedPhone.isNotEmpty) localByPhone[normalizedPhone] = newId;
      inserted++;
    }
    report.insertedCounts[table] = inserted;
    if (matchedByPhone > 0) {
      report.insertedCounts['$table (ফোন নম্বরে মিলে যাওয়ায় ডুপ্লিকেট এড়ানো হয়েছে)'] =
          matchedByPhone;
    }
    return idMap;
  }

  /// সাধারণ টেবিল মার্জ (sync_id দিয়ে) — যাদের কোনো foreign key নেই
  /// এবং প্রাকৃতিক ইউনিক পরিচয় (যেমন ফোন) নেই — যেমন categories
  Future<Map<String, int>> _mergeSimpleTable(
      Transaction txn,
      Database secondaryDb,
      String table,
      MergeReport report,
      List<String> columns) async {
    final idMap = <String, int>{};
    final localRows = await txn.query(table);
    final localBySyncId = {
      for (final r in localRows)
        if (r['sync_id'] != null) r['sync_id'] as String: r['id'] as int
    };

    final secondaryRows = await secondaryDb.query(table);
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final newRow = <String, dynamic>{'sync_id': syncId};
      for (final col in columns) {
        newRow[col] = row[col];
      }
      final newId = await txn.insert(table, newRow);
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts[table] = inserted;
    return idMap;
  }

  Future<Map<String, int>> _mergeProducts(Transaction txn, Database secondaryDb,
      Map<String, int> categoryIdMap, MergeReport report) async {
    final idMap = <String, int>{};
    final localRows = await txn.query('products');
    final localBySyncId = {
      for (final r in localRows)
        if (r['sync_id'] != null) r['sync_id'] as String: r['id'] as int
    };
    // পণ্য কোড দিয়ে ম্যাচিং — এটাই পণ্যের আসল ইউনিট পরিচয় (নামের
    // চেয়ে বেশি নির্ভরযোগ্য, কারণ দুই ডিভাইসে একই পণ্য আলাদা নামে
    // লেখা থাকলেও কোড একই থাকবে)
    final localByCode = <String, int>{};
    for (final r in localRows) {
      final code = (r['product_code'] as String?)?.toLowerCase().trim();
      if (code != null && code.isNotEmpty) localByCode[code] = r['id'] as int;
    }

    final secondaryRows = await secondaryDb.query('products');
    int inserted = 0;
    int matchedByCode = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;

      // ১. sync_id মিললে সরাসরি
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }

      // ২. sync_id না মিললেও পণ্য কোড মিললে — একই পণ্য ধরে নেওয়া হয়
      final code = (row['product_code'] as String?)?.toLowerCase().trim();
      if (code != null && code.isNotEmpty && localByCode.containsKey(code)) {
        idMap[syncId] = localByCode[code]!;
        matchedByCode++;
        continue;
      }

      // ৩. ক্যাটাগরির sync_id বের করে লোকাল category_id-তে রিম্যাপ
      int? newCategoryId;
      final oldCategoryId = row['category_id'];
      if (oldCategoryId != null) {
        final catRow = await secondaryDb
            .query('categories', where: 'id = ?', whereArgs: [oldCategoryId]);
        if (catRow.isNotEmpty) {
          final catSyncId = catRow.first['sync_id'] as String?;
          if (catSyncId != null) newCategoryId = categoryIdMap[catSyncId];
        }
      }

      final newId = await txn.insert('products', {
        'name': row['name'],
        'product_code': row['product_code'],
        'category_id': newCategoryId,
        'unit': row['unit'],
        'low_stock_threshold': row['low_stock_threshold'],
        'retail_price': row['retail_price'],
        'wholesale_price': row['wholesale_price'],
        'is_active': row['is_active'],
        'created_at': row['created_at'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      if (code != null && code.isNotEmpty) localByCode[code] = newId;
      inserted++;
    }
    report.insertedCounts['products'] = inserted;
    if (matchedByCode > 0) {
      report.insertedCounts['products (কোড মিলে যাওয়ায় ডুপ্লিকেট এড়ানো হয়েছে)'] =
          matchedByCode;
    }
    return idMap;
  }

  /// Phase 1 (multi-unit): product_units মার্জ — একই product-এর জন্য
  /// একই unit_label থাকলে ডুপ্লিকেট এড়ানো হয় (sync_id না মিললেও)
  Future<Map<String, int>> _mergeProductUnits(
      Transaction txn,
      Database secondaryDb,
      Map<String, int> productIdMap,
      MergeReport report) async {
    final idMap = <String, int>{};
    final localRows = await txn.query('product_units');
    final localBySyncId = {
      for (final r in localRows)
        if (r['sync_id'] != null) r['sync_id'] as String: r['id'] as int
    };
    final localByProductAndLabel = <String, int>{
      for (final r in localRows)
        '${r['product_id']}::${(r['unit_label'] as String).toLowerCase().trim()}':
            r['id'] as int
    };

    final secondaryRows = await secondaryDb.query('product_units');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }

      final productSyncId =
          await _findSyncId(secondaryDb, 'products', row['product_id']);
      final newProductId =
          productSyncId != null ? productIdMap[productSyncId] : null;
      if (newProductId == null) continue; // পণ্য মার্জ না হলে unit-ও যোগ করা যাবে না

      final label = (row['unit_label'] as String).toLowerCase().trim();
      final dupeKey = '$newProductId::$label';
      if (localByProductAndLabel.containsKey(dupeKey)) {
        idMap[syncId] = localByProductAndLabel[dupeKey]!;
        continue;
      }

      final newId = await txn.insert('product_units', {
        'product_id': newProductId,
        'unit_label': row['unit_label'],
        'conversion_factor_to_base': row['conversion_factor_to_base'],
        'selling_price': row['selling_price'],
        'is_default': row['is_default'],
        'is_active': row['is_active'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      localByProductAndLabel[dupeKey] = newId;
      inserted++;
    }
    report.insertedCounts['product_units'] = inserted;
    return idMap;
  }

  /// পার্টনার মার্জ হয় না, শুধু id-position দিয়ে ম্যাপ হয় (dependency-free)
  Future<Map<int, int>> _mapPartnersByPosition(
      Transaction txn, Database secondaryDb) async {
    final localPartners = await txn.query('partners', orderBy: 'id ASC');
    final secondaryPartners =
        await secondaryDb.query('partners', orderBy: 'id ASC');
    final map = <int, int>{};
    for (var i = 0; i < secondaryPartners.length && i < localPartners.length; i++) {
      map[secondaryPartners[i]['id'] as int] = localPartners[i]['id'] as int;
    }
    return map;
  }

  Future<Map<String, int>> _mergePurchases(Transaction txn, Database secondaryDb,
      Map<String, int> supplierIdMap, MergeReport report) async {
    final idMap = <String, int>{};
    final localBySyncId = await _syncIdMap(txn, 'purchases');
    final secondaryRows = await secondaryDb.query('purchases');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final supplierSyncId = await _findSyncId(
          secondaryDb, 'suppliers', row['supplier_id']);
      final newId = await txn.insert('purchases', {
        'supplier_id': supplierSyncId != null ? supplierIdMap[supplierSyncId] : null,
        'purchase_date': row['purchase_date'],
        'total_amount': row['total_amount'],
        'paid_amount': row['paid_amount'],
        'is_credit': row['is_credit'],
        'created_by': null, // ভিন্ন ডিভাইসের ইউজার আইডি মেলে না
        'created_at': row['created_at'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts['purchases'] = inserted;
    return idMap;
  }

  Future<Map<String, int>> _mergePurchaseBatches(
      Transaction txn,
      Database secondaryDb,
      Map<String, int> purchaseIdMap,
      Map<String, int> productIdMap,
      Map<String, int> productUnitIdMap,
      MergeReport report) async {
    final idMap = <String, int>{};
    final localBySyncId = await _syncIdMap(txn, 'purchase_batches');
    final secondaryRows = await secondaryDb.query('purchase_batches');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final purchaseSyncId =
          await _findSyncId(secondaryDb, 'purchases', row['purchase_id']);
      final productSyncId =
          await _findSyncId(secondaryDb, 'products', row['product_id']);
      if (productSyncId == null || productIdMap[productSyncId] == null) {
        continue; // পণ্য মার্জ না হলে ব্যাচও যোগ করা যাবে না
      }
      // Phase 1 (multi-unit): product_unit_id NULL হতে পারে (base unit-এ
      // কেনা হলে) — সেক্ষেত্রে remap-এর দরকার নেই
      int? newProductUnitId;
      if (row['product_unit_id'] != null) {
        final unitSyncId = await _findSyncId(
            secondaryDb, 'product_units', row['product_unit_id']);
        if (unitSyncId != null) newProductUnitId = productUnitIdMap[unitSyncId];
      }
      final newId = await txn.insert('purchase_batches', {
        'purchase_id':
            purchaseSyncId != null ? purchaseIdMap[purchaseSyncId] : null,
        'product_id': productIdMap[productSyncId],
        'product_unit_id': newProductUnitId,
        'display_quantity': row['display_quantity'],
        'quantity': row['quantity'],
        'remaining_quantity': row['remaining_quantity'],
        'unit_cost': row['unit_cost'],
        'batch_date': row['batch_date'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts['purchase_batches'] = inserted;
    return idMap;
  }

  Future<Map<String, int>> _mergeSales(Transaction txn, Database secondaryDb,
      Map<String, int> customerIdMap, MergeReport report) async {
    final idMap = <String, int>{};
    final localBySyncId = await _syncIdMap(txn, 'sales');
    final secondaryRows = await secondaryDb.query('sales');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final customerSyncId =
          await _findSyncId(secondaryDb, 'customers', row['customer_id']);
      final newId = await txn.insert('sales', {
        'customer_id': customerSyncId != null ? customerIdMap[customerSyncId] : null,
        'sale_date': row['sale_date'],
        'courier_charge': row['courier_charge'],
        'total_amount': row['total_amount'],
        'paid_amount': row['paid_amount'],
        'is_credit': row['is_credit'],
        'sale_type': row['sale_type'] ?? 'retail',
        'created_by': null,
        'created_at': row['created_at'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts['sales'] = inserted;
    return idMap;
  }

  Future<Map<String, int>> _mergeSaleItems(
      Transaction txn,
      Database secondaryDb,
      Map<String, int> saleIdMap,
      Map<String, int> productIdMap,
      Map<String, int> productUnitIdMap,
      MergeReport report) async {
    final idMap = <String, int>{};
    final localBySyncId = await _syncIdMap(txn, 'sale_items');
    final secondaryRows = await secondaryDb.query('sale_items');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final saleSyncId = await _findSyncId(secondaryDb, 'sales', row['sale_id']);
      final productSyncId =
          await _findSyncId(secondaryDb, 'products', row['product_id']);
      if (saleSyncId == null || saleIdMap[saleSyncId] == null) continue;
      if (productSyncId == null || productIdMap[productSyncId] == null) continue;

      int? newProductUnitId;
      if (row['product_unit_id'] != null) {
        final unitSyncId = await _findSyncId(
            secondaryDb, 'product_units', row['product_unit_id']);
        if (unitSyncId != null) newProductUnitId = productUnitIdMap[unitSyncId];
      }

      final newId = await txn.insert('sale_items', {
        'sale_id': saleIdMap[saleSyncId],
        'product_id': productIdMap[productSyncId],
        'product_unit_id': newProductUnitId,
        'quantity': row['quantity'],
        // পুরনো (v3-পূর্ববর্তী) ব্যাকআপে base_quantity নাও থাকতে পারে
        'base_quantity': row['base_quantity'] ?? row['quantity'],
        'unit_price': row['unit_price'],
        'total_cost': row['total_cost'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts['sale_items'] = inserted;
    return idMap;
  }

  Future<void> _mergeSaleItemBatchAllocations(
      Transaction txn,
      Database secondaryDb,
      Map<String, int> saleItemIdMap,
      Map<String, int> batchIdMap,
      MergeReport report) async {
    final localBySyncId = await _syncIdMap(txn, 'sale_item_batch_allocations');
    final secondaryRows = await secondaryDb.query('sale_item_batch_allocations');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null || localBySyncId.containsKey(syncId)) continue;
      final saleItemSyncId =
          await _findSyncId(secondaryDb, 'sale_items', row['sale_item_id']);
      final batchSyncId = await _findSyncId(
          secondaryDb, 'purchase_batches', row['purchase_batch_id']);
      if (saleItemSyncId == null || saleItemIdMap[saleItemSyncId] == null) continue;
      if (batchSyncId == null || batchIdMap[batchSyncId] == null) continue;

      await txn.insert('sale_item_batch_allocations', {
        'sale_item_id': saleItemIdMap[saleItemSyncId],
        'purchase_batch_id': batchIdMap[batchSyncId],
        'quantity': row['quantity'],
        'unit_cost': row['unit_cost'],
        'sync_id': syncId,
      });
      inserted++;
    }
    report.insertedCounts['sale_item_batch_allocations'] = inserted;
  }

  Future<void> _mergeSaleReturns(Transaction txn, Database secondaryDb,
      Map<String, int> saleItemIdMap, MergeReport report) async {
    final localBySyncId = await _syncIdMap(txn, 'sale_returns');
    final secondaryRows = await secondaryDb.query('sale_returns');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null || localBySyncId.containsKey(syncId)) continue;
      final saleItemSyncId =
          await _findSyncId(secondaryDb, 'sale_items', row['sale_item_id']);
      if (saleItemSyncId == null || saleItemIdMap[saleItemSyncId] == null) continue;

      await txn.insert('sale_returns', {
        'sale_item_id': saleItemIdMap[saleItemSyncId],
        'quantity': row['quantity'],
        'return_date': row['return_date'],
        'refund_amount': row['refund_amount'],
        'cost_amount': row['cost_amount'],
        'created_by': null,
        'sync_id': syncId,
      });
      inserted++;
    }
    report.insertedCounts['sale_returns'] = inserted;
  }

  Future<void> _mergePurchaseReturns(Transaction txn, Database secondaryDb,
      Map<String, int> batchIdMap, MergeReport report) async {
    final localBySyncId = await _syncIdMap(txn, 'purchase_returns');
    final secondaryRows = await secondaryDb.query('purchase_returns');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null || localBySyncId.containsKey(syncId)) continue;
      final batchSyncId = await _findSyncId(
          secondaryDb, 'purchase_batches', row['purchase_batch_id']);
      if (batchSyncId == null || batchIdMap[batchSyncId] == null) continue;

      await txn.insert('purchase_returns', {
        'purchase_batch_id': batchIdMap[batchSyncId],
        'quantity': row['quantity'],
        'return_date': row['return_date'],
        'refund_amount': row['refund_amount'],
        'created_by': null,
        'sync_id': syncId,
      });
      inserted++;
    }
    report.insertedCounts['purchase_returns'] = inserted;
  }

  Future<void> _mergeStockAdjustments(Transaction txn, Database secondaryDb,
      Map<String, int> productIdMap, Map<String, int> productUnitIdMap,
      MergeReport report) async {
    final localBySyncId = await _syncIdMap(txn, 'stock_adjustments');
    final secondaryRows = await secondaryDb.query('stock_adjustments');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null || localBySyncId.containsKey(syncId)) continue;
      final productSyncId =
          await _findSyncId(secondaryDb, 'products', row['product_id']);
      if (productSyncId == null || productIdMap[productSyncId] == null) continue;

      int? newProductUnitId;
      if (row['product_unit_id'] != null) {
        final unitSyncId = await _findSyncId(
            secondaryDb, 'product_units', row['product_unit_id']);
        if (unitSyncId != null) newProductUnitId = productUnitIdMap[unitSyncId];
      }

      await txn.insert('stock_adjustments', {
        'product_id': productIdMap[productSyncId],
        'product_unit_id': newProductUnitId,
        'quantity': row['quantity'],
        'base_quantity': row['base_quantity'] ?? row['quantity'],
        'total_cost': row['total_cost'] ?? 0,
        'reason': row['reason'],
        'note': row['note'],
        'adjustment_date': row['adjustment_date'],
        'created_by': null,
        'sync_id': syncId,
      });
      inserted++;
    }
    report.insertedCounts['stock_adjustments'] = inserted;
  }

  Future<Map<String, int>> _mergeExpenses(
      Transaction txn, Database secondaryDb, MergeReport report) async {
    final idMap = <String, int>{};
    final localBySyncId = await _syncIdMap(txn, 'expenses');
    final secondaryRows = await secondaryDb.query('expenses');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final newId = await txn.insert('expenses', {
        'category': row['category'],
        'amount': row['amount'],
        'description': row['description'],
        'expense_date': row['expense_date'],
        'created_by': null,
        'created_at': row['created_at'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts['expenses'] = inserted;
    return idMap;
  }

  Future<Map<String, int>> _mergeCapitalTransactions(Transaction txn,
      Database secondaryDb, Map<int, int> partnerIdMap, MergeReport report) async {
    final idMap = <String, int>{};
    final localBySyncId = await _syncIdMap(txn, 'capital_transactions');
    final secondaryRows = await secondaryDb.query('capital_transactions');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final oldPartnerId = row['partner_id'] as int;
      final newPartnerId = partnerIdMap[oldPartnerId];
      if (newPartnerId == null) continue;

      final newId = await txn.insert('capital_transactions', {
        'partner_id': newPartnerId,
        'type': row['type'],
        'amount': row['amount'],
        'transaction_date': row['transaction_date'],
        'note': row['note'],
        'created_by': null,
        'created_at': row['created_at'],
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts['capital_transactions'] = inserted;
    return idMap;
  }

  Future<Map<String, int>> _mergeDuePayments(
      Transaction txn,
      Database secondaryDb,
      Map<String, int> customerIdMap,
      Map<String, int> supplierIdMap,
      MergeReport report) async {
    final idMap = <String, int>{};
    final localBySyncId = await _syncIdMap(txn, 'due_payments');
    final secondaryRows = await secondaryDb.query('due_payments');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null) continue;
      if (localBySyncId.containsKey(syncId)) {
        idMap[syncId] = localBySyncId[syncId]!;
        continue;
      }
      final partyType = row['party_type'] as String;
      final table = partyType == 'customer' ? 'customers' : 'suppliers';
      final map = partyType == 'customer' ? customerIdMap : supplierIdMap;
      final partySyncId = await _findSyncId(secondaryDb, table, row['party_id']);
      if (partySyncId == null || map[partySyncId] == null) continue;

      final newId = await txn.insert('due_payments', {
        'party_type': partyType,
        'party_id': map[partySyncId],
        'reference_type': row['reference_type'],
        'reference_id': null, // এটা মিলানো জটিল, তথ্যগত হিসেবে বাদ
        'amount': row['amount'],
        'payment_date': row['payment_date'],
        'created_by': null,
        'sync_id': syncId,
      });
      idMap[syncId] = newId;
      inserted++;
    }
    report.insertedCounts['due_payments'] = inserted;
    return idMap;
  }

  Future<void> _mergeCashLedger(
      Transaction txn,
      Database secondaryDb,
      MergeReport report,
      Map<String, Map<String, int>> refIdMapsByType) async {
    final localBySyncId = await _syncIdMap(txn, 'cash_ledger');
    final secondaryRows = await secondaryDb.query('cash_ledger');
    int inserted = 0;
    for (final row in secondaryRows) {
      final syncId = row['sync_id'] as String?;
      if (syncId == null || localBySyncId.containsKey(syncId)) continue;

      final refType = row['reference_type'] as String;
      final refSyncId = row['ref_sync_id'] as String?;
      int? newRefId;
      if (refSyncId != null && refIdMapsByType.containsKey(refType)) {
        newRefId = refIdMapsByType[refType]![refSyncId];
      }

      await txn.insert('cash_ledger', {
        'amount': row['amount'],
        'direction': row['direction'],
        'reference_type': refType,
        'reference_id': newRefId,
        'description': row['description'],
        'transaction_date': row['transaction_date'],
        'created_at': row['created_at'],
        'sync_id': syncId,
        'ref_sync_id': refSyncId,
      });
      inserted++;
    }
    report.insertedCounts['cash_ledger'] = inserted;
  }

  // ------------------------------------------------------------
  // হেল্পার ফাংশন
  // ------------------------------------------------------------

  Future<Map<String, int>> _syncIdMap(Transaction txn, String table) async {
    final rows = await txn.query(table);
    return {
      for (final r in rows)
        if (r['sync_id'] != null) r['sync_id'] as String: r['id'] as int
    };
  }

  Future<String?> _findSyncId(Database db, String table, dynamic id) async {
    if (id == null) return null;
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return rows.first['sync_id'] as String?;
  }

  Future<List<String>> _findPossibleDuplicates(
      Transaction txn, String table) async {
    final rows = await txn.rawQuery('''
      SELECT name, COUNT(*) as cnt FROM $table
      GROUP BY LOWER(name) HAVING cnt > 1
    ''');
    return rows.map((r) => '$table: "${r['name']}" (${r['cnt']}টি)').toList();
  }
}
