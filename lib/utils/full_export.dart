// ============================================================
// full_export.dart
// অ্যাপের সব তথ্য একটা Excel ওয়ার্কবুকে — প্রতিটা বিষয়ের আলাদা শিট
// (বিক্রয়, ক্রয়, খরচ, মূলধন, কাস্টমার, সাপ্লায়ার, পণ্য, স্টক, ক্যাশ ...),
// প্রতিটাতেই তারিখ, নাম, পরিমাণ, রেট, টাকা সহ।
// নিরাপত্তার জন্য ইউজারের পাসওয়ার্ড/সিকিউরিটি তথ্য এক্সপোর্টে নেই।
// ============================================================

import 'package:excel/excel.dart' as x;
import '../database/db_helper.dart';
import 'txn_items.dart';

class FullExport {
  static const _typeLabels = {
    'invest': 'বিনিয়োগ',
    'withdraw_capital': 'মূলধন উত্তোলন',
    'withdraw_profit': 'লাভ উত্তোলন',
  };
  static const _reasonLabels = {
    'damaged': 'নষ্ট পণ্য',
    'shortage': 'ঘাটতি',
    'gift': 'Gift',
    'sample': 'Sample',
    'internal_use': 'Internal use',
    'excess_found': 'অতিরিক্ত পাওয়া',
    'other': 'অন্যান্য',
  };

  static x.CellValue _cv(Object? v) {
    if (v == null) return x.TextCellValue('');
    if (v is int) return x.IntCellValue(v);
    if (v is double) return x.DoubleCellValue(v);
    if (v is num) return x.DoubleCellValue(v.toDouble());
    return x.TextCellValue(v.toString());
  }

  static void _sheet(x.Excel wb, String name, List<String> headers,
      List<List<Object?>> rows) {
    final sheet = wb[name];
    sheet.appendRow(headers.map((h) => x.TextCellValue(h)).toList());
    for (final r in rows) {
      sheet.appendRow(r.map(_cv).toList());
    }
  }

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

  static Future<List<int>?> build() async {
    final db = await DBHelper.instance.database;
    final h = DBHelper.instance;
    final wb = x.Excel.createExcel();

    // ---------- সারাংশ ----------
    final cash = await h.getCurrentCash(db);
    final inventory = await h.getInventoryValue(db);
    final receivables = await h.getTotalReceivables(db);
    final payables = await h.getTotalPayables(db);
    final gross = await h.getGrossProfit(db);
    final expenses = await h.getTotalExpenses(db);
    final adjustments = await h.getStockAdjustmentImpact(db);
    final net = await h.getNetProfit(db);
    final partners = await db.query('partners', orderBy: 'id ASC');
    final summary = <List<Object?>>[
      ['এক্সপোর্টের সময়', DateTime.now().toString().substring(0, 16)],
      ['হাতে নগদ ক্যাশ', cash],
      ['স্টকের মূল্য', inventory],
      ['মোট পাওনা (কাস্টমারের কাছে)', receivables],
      ['মোট দেনা (সাপ্লায়ারকে)', payables],
      ['গ্রস প্রফিট', gross],
      ['মোট খরচ', expenses],
      ['স্টক নষ্ট/গিফট/অতিরিক্ত বাবদ প্রভাব', adjustments],
      ['নিট প্রফিট', net],
    ];
    for (final p in partners) {
      summary.add([
        'পার্টনার ব্যালেন্স — ${p['name']} (${p['profit_share_percent']}%)',
        await h.getPartnerBalance(db, p['id'] as int),
      ]);
    }
    _sheet(wb, 'সারাংশ', ['বিষয়', 'মান'], summary);

    // ---------- বিক্রয় ----------
    final sales = await db.rawQuery('''
      SELECT s.*, c.name AS customer_name FROM sales s
      LEFT JOIN customers c ON c.id = s.customer_id
      ORDER BY s.sale_date, s.id
    ''');
    _sheet(
        wb,
        'বিক্রয়',
        ['বিল #', 'তারিখ', 'কাস্টমার', 'ধরন', 'মোট', 'কুরিয়ার চার্জ', 'পরিশোধিত', 'বাকি', 'বাকিতে?'],
        sales.map((s) {
          final total = _d(s['total_amount']);
          final paid = _d(s['paid_amount']);
          final credit = (s['is_credit'] as int? ?? 0) == 1;
          return <Object?>[
            s['id'],
            s['sale_date'],
            s['customer_name'] ?? 'নগদ',
            s['sale_type'] == 'wholesale' ? 'পাইকারি' : 'খুচরা',
            total,
            _d(s['courier_charge']),
            paid,
            credit ? total - paid : 0.0,
            credit ? 'হ্যাঁ' : 'না',
          ];
        }).toList());

    final saleLines = await db.rawQuery('''
      SELECT si.id, si.sale_id, s.sale_date, c.name AS customer_name,
             p.name AS product_name, p.unit AS base_unit, pu.unit_label,
             si.quantity, si.base_quantity, si.unit_price, si.total_cost
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      JOIN products p ON p.id = si.product_id
      LEFT JOIN customers c ON c.id = s.customer_id
      LEFT JOIN product_units pu ON pu.id = si.product_unit_id
      ORDER BY s.sale_date, si.sale_id, si.id
    ''');
    _sheet(
        wb,
        'বিক্রয়ের আইটেম',
        ['বিল #', 'তারিখ', 'কাস্টমার', 'পণ্য', 'পরিমাণ', 'একক', 'রেট', 'টাকা', 'ক্রয়মূল্য (খরচ)', 'লাভ'],
        saleLines.map((r) {
          final qty = _d(r['quantity']);
          final price = _d(r['unit_price']);
          final cost = _d(r['total_cost']);
          return <Object?>[
            r['sale_id'],
            r['sale_date'],
            r['customer_name'] ?? 'নগদ',
            r['product_name'],
            qty,
            r['unit_label'] ?? r['base_unit'],
            price,
            qty * price,
            cost,
            qty * price - cost,
          ];
        }).toList());

    // ---------- ক্রয় ----------
    final purchases = await db.rawQuery('''
      SELECT p.*, sp.name AS supplier_name FROM purchases p
      LEFT JOIN suppliers sp ON sp.id = p.supplier_id
      ORDER BY p.purchase_date, p.id
    ''');
    _sheet(
        wb,
        'ক্রয়',
        ['ক্রয় #', 'তারিখ', 'সাপ্লায়ার', 'মোট', 'পরিশোধিত', 'দেনা', 'বাকিতে?'],
        purchases.map((p) {
          final total = _d(p['total_amount']);
          final paid = _d(p['paid_amount']);
          final credit = (p['is_credit'] as int? ?? 0) == 1;
          return <Object?>[
            p['id'],
            p['purchase_date'],
            p['supplier_name'] ?? '—',
            total,
            paid,
            credit ? total - paid : 0.0,
            credit ? 'হ্যাঁ' : 'না',
          ];
        }).toList());

    final purchaseIds = purchases.map((p) => p['id'] as int).toList();
    final pItems = await TxnItems.forPurchases(db, purchaseIds);
    final purchaseRows = <List<Object?>>[];
    for (final p in purchases) {
      for (final l in pItems[p['id'] as int] ?? const <TxnItemLine>[]) {
        purchaseRows.add([
          p['id'],
          p['purchase_date'],
          p['supplier_name'] ?? '—',
          l.productName,
          l.quantity,
          l.unit,
          l.rate,
          l.total,
        ]);
      }
    }
    _sheet(wb, 'ক্রয়ের আইটেম',
        ['ক্রয় #', 'তারিখ', 'সাপ্লায়ার', 'পণ্য', 'পরিমাণ', 'একক', 'রেট', 'টাকা'], purchaseRows);

    // ---------- খরচ ----------
    final exp = await db.query('expenses', orderBy: 'expense_date, id');
    _sheet(
        wb,
        'খরচ',
        ['#', 'তারিখ', 'ক্যাটাগরি', 'টাকা', 'বিস্তারিত'],
        exp
            .map((e) => <Object?>[e['id'], e['expense_date'], e['category'], _d(e['amount']), e['description'] ?? ''])
            .toList());

    // ---------- মূলধন ----------
    final cap = await db.rawQuery('''
      SELECT ct.*, p.name AS partner_name FROM capital_transactions ct
      JOIN partners p ON p.id = ct.partner_id
      ORDER BY ct.transaction_date, ct.id
    ''');
    _sheet(
        wb,
        'মূলধন লেনদেন',
        ['#', 'তারিখ', 'পার্টনার', 'ধরন', 'টাকা', 'নোট'],
        cap
            .map((c) => <Object?>[
                  c['id'],
                  c['transaction_date'],
                  c['partner_name'],
                  _typeLabels[c['type']] ?? c['type'],
                  _d(c['amount']),
                  c['note'] ?? '',
                ])
            .toList());

    final partnerRows = <List<Object?>>[];
    for (final p in partners) {
      final id = p['id'] as int;
      double sumOf(String t) => cap
          .where((c) => c['partner_id'] == id && c['type'] == t)
          .fold(0.0, (a, c) => a + _d(c['amount']));
      partnerRows.add([
        p['name'],
        _d(p['profit_share_percent']),
        sumOf('invest'),
        sumOf('withdraw_capital'),
        sumOf('withdraw_profit'),
        await h.getPartnerBalance(db, id),
      ]);
    }
    _sheet(wb, 'পার্টনার',
        ['নাম', 'লাভের ভাগ %', 'মোট বিনিয়োগ', 'মূলধন উত্তোলন', 'লাভ উত্তোলন', 'বর্তমান ব্যালেন্স'],
        partnerRows);

    // ---------- কাস্টমার / সাপ্লায়ার ----------
    final customers = await db.rawQuery('''
      SELECT c.*,
        COALESCE((SELECT SUM(total_amount) FROM sales WHERE customer_id = c.id), 0) AS total_purchase,
        COALESCE((SELECT SUM(total_amount - paid_amount) FROM sales WHERE customer_id = c.id AND is_credit = 1), 0)
        - COALESCE((SELECT SUM(amount) FROM due_payments WHERE party_type = 'customer' AND party_id = c.id), 0) AS due
      FROM customers c ORDER BY c.name
    ''');
    _sheet(
        wb,
        'কাস্টমার',
        ['নাম', 'ফোন', 'ঠিকানা', 'সক্রিয়', 'মোট কেনাকাটা', 'বর্তমান বাকি'],
        customers
            .map((c) => <Object?>[
                  c['name'],
                  c['phone'] ?? '',
                  c['address'] ?? '',
                  (c['is_active'] as int? ?? 1) == 1 ? 'হ্যাঁ' : 'না',
                  _d(c['total_purchase']),
                  _d(c['due']),
                ])
            .toList());

    final suppliers = await db.rawQuery('''
      SELECT s.*,
        COALESCE((SELECT SUM(total_amount) FROM purchases WHERE supplier_id = s.id), 0) AS total_purchase,
        COALESCE((SELECT SUM(total_amount - paid_amount) FROM purchases WHERE supplier_id = s.id AND is_credit = 1), 0)
        - COALESCE((SELECT SUM(amount) FROM due_payments WHERE party_type = 'supplier' AND party_id = s.id), 0) AS due
      FROM suppliers s ORDER BY s.name
    ''');
    _sheet(
        wb,
        'সাপ্লায়ার',
        ['নাম', 'ফোন', 'ঠিকানা', 'সক্রিয়', 'মোট ক্রয়', 'বর্তমান দেনা'],
        suppliers
            .map((c) => <Object?>[
                  c['name'],
                  c['phone'] ?? '',
                  c['address'] ?? '',
                  (c['is_active'] as int? ?? 1) == 1 ? 'হ্যাঁ' : 'না',
                  _d(c['total_purchase']),
                  _d(c['due']),
                ])
            .toList());

    // ---------- বাকি আদায়/শোধ ----------
    final dues = await db.rawQuery('''
      SELECT d.*,
        CASE d.party_type WHEN 'customer' THEN (SELECT name FROM customers WHERE id = d.party_id)
                          ELSE (SELECT name FROM suppliers WHERE id = d.party_id) END AS party_name
      FROM due_payments d ORDER BY d.payment_date, d.id
    ''');
    _sheet(
        wb,
        'বাকি আদায় ও শোধ',
        ['#', 'তারিখ', 'ধরন', 'নাম', 'টাকা'],
        dues
            .map((d) => <Object?>[
                  d['id'],
                  d['payment_date'],
                  d['party_type'] == 'customer' ? 'কাস্টমার থেকে আদায়' : 'সাপ্লায়ারকে শোধ',
                  d['party_name'] ?? '',
                  _d(d['amount']),
                ])
            .toList());

    // ---------- ফেরত ----------
    final saleReturns = await db.rawQuery('''
      SELECT sr.*, si.sale_id, p.name AS product_name, p.unit AS base_unit, pu.unit_label
      FROM sale_returns sr
      JOIN sale_items si ON si.id = sr.sale_item_id
      JOIN products p ON p.id = si.product_id
      LEFT JOIN product_units pu ON pu.id = si.product_unit_id
      ORDER BY sr.return_date, sr.id
    ''');
    _sheet(
        wb,
        'বিক্রয় ফেরত',
        ['তারিখ', 'বিল #', 'পণ্য', 'পরিমাণ', 'একক', 'ফেরত টাকা', 'ক্রয়মূল্য'],
        saleReturns
            .map((r) => <Object?>[
                  r['return_date'],
                  r['sale_id'],
                  r['product_name'],
                  _d(r['quantity']),
                  r['unit_label'] ?? r['base_unit'],
                  _d(r['refund_amount']),
                  _d(r['cost_amount']),
                ])
            .toList());

    final purchaseReturns = await db.rawQuery('''
      SELECT pr.*, pb.purchase_id, p.name AS product_name, p.unit AS base_unit
      FROM purchase_returns pr
      JOIN purchase_batches pb ON pb.id = pr.purchase_batch_id
      JOIN products p ON p.id = pb.product_id
      ORDER BY pr.return_date, pr.id
    ''');
    _sheet(
        wb,
        'ক্রয় ফেরত',
        ['তারিখ', 'ক্রয় #', 'পণ্য', 'পরিমাণ (বেস একক)', 'একক', 'ফেরত টাকা'],
        purchaseReturns
            .map((r) => <Object?>[
                  r['return_date'],
                  r['purchase_id'] ?? '',
                  r['product_name'],
                  _d(r['quantity']),
                  r['base_unit'],
                  _d(r['refund_amount']),
                ])
            .toList());

    // ---------- স্টক সমন্বয় ----------
    final adj = await db.rawQuery('''
      SELECT sa.*, p.name AS product_name, p.unit AS base_unit, pu.unit_label
      FROM stock_adjustments sa
      JOIN products p ON p.id = sa.product_id
      LEFT JOIN product_units pu ON pu.id = sa.product_unit_id
      ORDER BY sa.adjustment_date, sa.id
    ''');
    _sheet(
        wb,
        'স্টক সমন্বয়',
        ['#', 'তারিখ', 'পণ্য', 'কারণ', 'পরিমাণ', 'একক', 'মূল্য', 'নোট'],
        adj
            .map((a) => <Object?>[
                  a['id'],
                  a['adjustment_date'],
                  a['product_name'],
                  _reasonLabels[a['reason']] ?? a['reason'],
                  _d(a['quantity']),
                  a['unit_label'] ?? a['base_unit'],
                  _d(a['total_cost']),
                  a['note'] ?? '',
                ])
            .toList());

    // ---------- পণ্য ও স্টক ----------
    final products = await db.rawQuery('''
      SELECT p.*, c.name AS category_name,
        COALESCE((SELECT SUM(remaining_quantity) FROM purchase_batches WHERE product_id = p.id), 0) AS stock,
        COALESCE((SELECT SUM(remaining_quantity * unit_cost) FROM purchase_batches WHERE product_id = p.id), 0) AS stock_value
      FROM products p LEFT JOIN categories c ON c.id = p.category_id
      ORDER BY p.name
    ''');
    _sheet(
        wb,
        'পণ্য',
        ['#', 'নাম', 'কোড', 'ক্যাটাগরি', 'বেস একক', 'বর্তমান স্টক', 'স্টকের মূল্য', 'লো-স্টক সীমা', 'খুচরা দাম', 'পাইকারি দাম', 'সক্রিয়'],
        products
            .map((p) => <Object?>[
                  p['id'],
                  p['name'],
                  p['product_code'] ?? '',
                  p['category_name'] ?? '',
                  p['unit'],
                  _d(p['stock']),
                  _d(p['stock_value']),
                  _d(p['low_stock_threshold']),
                  p['retail_price'] == null ? '' : _d(p['retail_price']),
                  p['wholesale_price'] == null ? '' : _d(p['wholesale_price']),
                  (p['is_active'] as int? ?? 1) == 1 ? 'হ্যাঁ' : 'না',
                ])
            .toList());

    final units = await db.rawQuery('''
      SELECT pu.*, p.name AS product_name, p.unit AS base_unit
      FROM product_units pu JOIN products p ON p.id = pu.product_id
      ORDER BY p.name, pu.id
    ''');
    _sheet(
        wb,
        'পণ্যের ইউনিট',
        ['পণ্য', 'ইউনিট', 'বেস এককে মান', 'বেস একক', 'বিক্রয় মূল্য', 'সক্রিয়'],
        units
            .map((u) => <Object?>[
                  u['product_name'],
                  u['unit_label'],
                  _d(u['conversion_factor_to_base']),
                  u['base_unit'],
                  u['selling_price'] == null ? '' : _d(u['selling_price']),
                  (u['is_active'] as int? ?? 1) == 1 ? 'হ্যাঁ' : 'না',
                ])
            .toList());

    final batches = await db.rawQuery('''
      SELECT pb.*, p.name AS product_name, p.unit AS base_unit
      FROM purchase_batches pb JOIN products p ON p.id = pb.product_id
      ORDER BY pb.batch_date, pb.id
    ''');
    _sheet(
        wb,
        'স্টক ব্যাচ',
        ['তারিখ', 'পণ্য', 'ক্রয় #', 'মূল পরিমাণ', 'বাকি পরিমাণ', 'বেস একক', 'প্রতি বেস এককের দাম', 'বাকির মূল্য'],
        batches
            .map((b) => <Object?>[
                  b['batch_date'],
                  b['product_name'],
                  b['purchase_id'] ?? 'সমন্বয়/ফেরত',
                  _d(b['quantity']),
                  _d(b['remaining_quantity']),
                  b['base_unit'],
                  _d(b['unit_cost']),
                  _d(b['remaining_quantity']) * _d(b['unit_cost']),
                ])
            .toList());

    // ---------- ক্যাশ লেজার ----------
    final ledger = await db.query('cash_ledger', orderBy: 'transaction_date, id');
    _sheet(
        wb,
        'ক্যাশ লেজার',
        ['তারিখ', 'ঢুকেছে', 'বেরিয়েছে', 'ধরন', 'বিবরণ'],
        ledger
            .map((l) => <Object?>[
                  l['transaction_date'],
                  l['direction'] == 'in' ? _d(l['amount']) : '',
                  l['direction'] == 'out' ? _d(l['amount']) : '',
                  l['reference_type'],
                  l['description'] ?? '',
                ])
            .toList());

    // ---------- কার্যকলাপ লগ (সর্বশেষ ৫০০০টা) ----------
    final log = await db.rawQuery('''
      SELECT a.*, u.username FROM activity_log a
      LEFT JOIN users u ON u.id = a.user_id
      ORDER BY a.id DESC LIMIT 5000
    ''');
    _sheet(
        wb,
        'কার্যকলাপ লগ',
        ['সময়', 'ইউজার', 'কাজ', 'বিষয়', 'বিবরণ'],
        log
            .map((a) => <Object?>[
                  a['timestamp'],
                  a['username'] ?? '',
                  a['action'],
                  a['entity_type'],
                  a['details'] ?? '',
                ])
            .toList());

    // খালি ডিফল্ট শিট সরানো
    wb.delete('Sheet1');
    return wb.encode();
  }
}
