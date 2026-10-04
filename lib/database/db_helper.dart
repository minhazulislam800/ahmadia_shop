// ============================================================
// db_helper.dart
// Ahmadia Shop — সম্পূর্ণ ডাটাবেস স্কিমা + FIFO হিসাব-ইঞ্জিন
//
// এই ফাইলটাই অ্যাপের হৃদয়। এখানে:
//  - সব টেবিল তৈরি হয় (products, purchases, sales, expenses,
//    capital, cash ledger, activity log ইত্যাদি)
//  - FIFO ব্যাচ লজিক (ক্রয়ে ব্যাচ তৈরি, বিক্রয়ে পুরনো ব্যাচ
//    থেকে আগে কাটা) সম্পূর্ণভাবে হ্যান্ডেল হয়
//  - প্রতিটা লেনদেন কেন্দ্রীয় cash_ledger টেবিলে রেকর্ড হয়,
//    যা থেকে ড্যাশবোর্ডের সব সংখ্যা (ক্যাশ, বাকি, লাভ) বের
//    হয় — কোনো আলাদা "ম্যানুয়াল" হিসাব রাখতে হয় না
// ============================================================

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DBHelper {
  DBHelper._privateConstructor();
  static final DBHelper instance = DBHelper._privateConstructor();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  /// ব্যাকআপ রিস্টোরের আগে বর্তমান ডাটাবেস কানেকশন বন্ধ করে — এরপর
  /// `database` চাইলে ফাইল থেকে নতুন করে খোলা হবে
  Future<void> closeConnection() async {
    final db = _database;
    _database = null;
    if (db != null) {
      try {
        await db.close();
      } catch (_) {}
    }
  }

  // Phase 4 (§13): UI screen থেকে সরাসরি audit log লেখার জন্য public
  // helper — TransactionService-এর ভেতরের transaction-চেইন সংক্রান্ত
  // action ছাড়া, যেমন সাধারণ edit (product/customer/supplier তথ্য
  // পরিবর্তন) যেগুলো কোনো stock/accounting reversal-এর সাথে জড়িত না,
  // সেগুলোর জন্য এটা ব্যবহার হবে।
  Future<void> logActivity({
    required int? userId,
    required String action, // 'create' | 'update' | 'delete'
    required String entityType,
    required int? entityId,
    required String details,
  }) async {
    final db = await database;
    await db.insert('activity_log', {
      'user_id': userId,
      'action': action,
      'entity_type': entityType,
      'entity_id': entityId,
      'details': details,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'ahmadia_shop.db');
    return await openDatabase(
      path,
      version: 4,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
      onConfigure: (db) async {
        // ফরেন কী সমর্থন চালু রাখা — ডেটা ইন্টিগ্রিটির জন্য জরুরি
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  // ----------------------------------------------------------
  // সব টেবিল তৈরি
  // ----------------------------------------------------------
  // ----------------------------------------------------------
  // পুরনো ডাটাবেস (v1, sync_id ছাড়া) থেকে নতুন স্ট্রাকচারে (v2)
  // নিরাপদে আপগ্রেড করা — আগের সব ডেটা অক্ষত থাকবে, শুধু নতুন
  // কলাম যোগ হবে এবং পুরনো রো-গুলোর জন্য sync_id জেনারেট হবে
  // ----------------------------------------------------------
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      final alterStatements = [
        "ALTER TABLE categories ADD COLUMN sync_id TEXT",
        "ALTER TABLE products ADD COLUMN retail_price REAL",
        "ALTER TABLE products ADD COLUMN wholesale_price REAL",
        "ALTER TABLE products ADD COLUMN sync_id TEXT",
        "ALTER TABLE suppliers ADD COLUMN sync_id TEXT",
        "ALTER TABLE customers ADD COLUMN sync_id TEXT",
        "ALTER TABLE purchases ADD COLUMN sync_id TEXT",
        "ALTER TABLE purchase_batches ADD COLUMN sync_id TEXT",
        "ALTER TABLE sales ADD COLUMN sale_type TEXT NOT NULL DEFAULT 'retail'",
        "ALTER TABLE sales ADD COLUMN sync_id TEXT",
        "ALTER TABLE sale_items ADD COLUMN sync_id TEXT",
        "ALTER TABLE sale_item_batch_allocations ADD COLUMN sync_id TEXT",
        "ALTER TABLE sale_returns ADD COLUMN sync_id TEXT",
        "ALTER TABLE purchase_returns ADD COLUMN sync_id TEXT",
        "ALTER TABLE stock_adjustments ADD COLUMN sync_id TEXT",
        "ALTER TABLE expenses ADD COLUMN sync_id TEXT",
        "ALTER TABLE capital_transactions ADD COLUMN sync_id TEXT",
        "ALTER TABLE cash_ledger ADD COLUMN sync_id TEXT",
        "ALTER TABLE cash_ledger ADD COLUMN ref_sync_id TEXT",
        "ALTER TABLE due_payments ADD COLUMN sync_id TEXT",
        "ALTER TABLE users ADD COLUMN recovery_code_hash TEXT",
      ];
      for (final stmt in alterStatements) {
        try {
          await db.execute(stmt);
        } catch (_) {
          // কলাম আগে থেকেই থাকলে এরর আসতে পারে, নিরাপদে উপেক্ষা করা হচ্ছে
        }
      }

      // last_backup_at সেটিং না থাকলে যোগ করা
      final existing = await db.query('app_settings',
          where: 'key = ?', whereArgs: ['last_backup_at']);
      if (existing.isEmpty) {
        await db.insert('app_settings', {'key': 'last_backup_at', 'value': ''});
      }

      // পুরনো রো-গুলোর জন্য sync_id জেনারেট করা (যাদের এখনো নেই)
      const syncTables = [
        'categories', 'products', 'suppliers', 'customers', 'purchases',
        'purchase_batches', 'sales', 'sale_items', 'sale_item_batch_allocations',
        'sale_returns', 'purchase_returns', 'stock_adjustments', 'expenses',
        'capital_transactions', 'cash_ledger', 'due_payments',
      ];
      for (final table in syncTables) {
        final rows = await db.query(table, columns: ['id'],
            where: 'sync_id IS NULL');
        for (final row in rows) {
          final id = row['id'];
          final syncId =
              '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$table-$id';
          await db.update(table, {'sync_id': syncId},
              where: 'id = ?', whereArgs: [id]);
        }
      }
    }

    if (oldVersion < 3) {
      try {
        await db.execute("ALTER TABLE products ADD COLUMN product_code TEXT");
      } catch (_) {
        // কলাম আগে থেকেই থাকলে উপেক্ষা করা হচ্ছে
      }
    }

    // ============================================================
    // v4 — Phase 1 (multi-unit) migration
    // পুরনো ব্যবহারকারীদের ডেটা কখনো নষ্ট হবে না: existing sale_items/
    // stock_adjustments-এর quantity ইতিমধ্যে base unit-এই ছিল (আগে
    // multi-unit সাপোর্ট ছিল না), তাই base_quantity = quantity বসিয়ে
    // backfill করা হচ্ছে, product_unit_id NULL থাকবে (মানে base unit)।
    // ============================================================
    if (oldVersion < 4) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS product_units (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product_id INTEGER NOT NULL,
            unit_label TEXT NOT NULL,
            conversion_factor_to_base REAL NOT NULL,
            selling_price REAL,
            is_default INTEGER NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 1,
            sync_id TEXT UNIQUE,
            FOREIGN KEY (product_id) REFERENCES products (id)
          )
        ''');
      } catch (_) {}

      final alterStatementsV4 = [
        "ALTER TABLE sale_items ADD COLUMN product_unit_id INTEGER",
        "ALTER TABLE sale_items ADD COLUMN base_quantity REAL",
        "ALTER TABLE stock_adjustments ADD COLUMN product_unit_id INTEGER",
        "ALTER TABLE stock_adjustments ADD COLUMN base_quantity REAL",
        "ALTER TABLE stock_adjustments ADD COLUMN total_cost REAL NOT NULL DEFAULT 0",
        "ALTER TABLE purchase_batches ADD COLUMN product_unit_id INTEGER",
        "ALTER TABLE purchase_batches ADD COLUMN display_quantity REAL",
        "ALTER TABLE customers ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE suppliers ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1",
      ];
      for (final stmt in alterStatementsV4) {
        try {
          await db.execute(stmt);
        } catch (_) {
          // কলাম আগে থেকেই থাকলে উপেক্ষা করা হচ্ছে
        }
      }

      // পুরনো রো-গুলোর base_quantity backfill (আগে base unit-এই সব হিসাব হতো)
      try {
        await db.execute(
            "UPDATE sale_items SET base_quantity = quantity WHERE base_quantity IS NULL");
        await db.execute(
            "UPDATE stock_adjustments SET base_quantity = quantity WHERE base_quantity IS NULL");
      } catch (_) {}
    }
  }

  Future<void> _createDB(Database db, int version) async {
    // অ্যাপ সেটিংস (দোকানের নাম, ঠিকানা, ফোন, লোগো, সিকিউরিটি প্রশ্ন)
    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    // ইউজার — মাস্টার ও নরমাল (দুইটা ফিক্সড রো, অ্যাপ প্রথম চালুর সময় তৈরি হয়)
    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL CHECK(role IN ('master','normal')),
        security_question TEXT,
        security_answer_hash TEXT,
        recovery_code_hash TEXT
      )
    ''');

    // পার্টনার (মূলধন/লাভ-ভাগের হিসাবের জন্য)
    await db.execute('''
      CREATE TABLE partners (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        profit_share_percent REAL NOT NULL DEFAULT 50.0
      )
    ''');

    // পণ্যের ক্যাটাগরি
    await db.execute('''
      CREATE TABLE categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        sync_id TEXT UNIQUE
      )
    ''');

    // পণ্য
    await db.execute('''
      CREATE TABLE products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        product_code TEXT UNIQUE,
        category_id INTEGER,
        unit TEXT NOT NULL,
        low_stock_threshold REAL DEFAULT 0,
        retail_price REAL,
        wholesale_price REAL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (category_id) REFERENCES categories (id)
      )
    ''');

    // ============================================================
    // Phase 1 (multi-unit): একটা product-এর একাধিক বিক্রয়-একক (pack)
    // ============================================================
    // products.unit-কে এখন "base unit" (stock এই এককেই সংরক্ষিত হয়,
    // যেমন gram) হিসেবে ধরা হচ্ছে। এই টেবিলে base unit-এর ওপর ভিত্তি
    // করে বিক্রয়যোগ্য pack (250g, 500g, 1kg...) সংজ্ঞায়িত হয়।
    // conversion_factor_to_base = এই pack-এ base unit-এর কত পরিমাণ আছে
    // (যেমন base unit gram হলে, 500g pack-এর conversion_factor_to_base = 500)।
    // is_default = 1 মানে এই unit-টাই বিক্রির সময় ডিফল্ট হিসেবে দেখাবে।
    await db.execute('''
      CREATE TABLE product_units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        unit_label TEXT NOT NULL,
        conversion_factor_to_base REAL NOT NULL,
        selling_price REAL,
        is_default INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (product_id) REFERENCES products (id)
      )
    ''');

    // সাপ্লায়ার
    await db.execute('''
      CREATE TABLE suppliers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT,
        address TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        sync_id TEXT UNIQUE
      )
    ''');

    // কাস্টমার
    await db.execute('''
      CREATE TABLE customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT,
        address TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        sync_id TEXT UNIQUE
      )
    ''');

    // ক্রয় (একটা ক্রয় এন্ট্রি একাধিক পণ্য নিয়ে হতে পারে -> purchase_items)
    await db.execute('''
      CREATE TABLE purchases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        supplier_id INTEGER,
        purchase_date TEXT NOT NULL,
        total_amount REAL NOT NULL,
        paid_amount REAL NOT NULL DEFAULT 0,
        is_credit INTEGER NOT NULL DEFAULT 0,
        created_by INTEGER,
        created_at TEXT NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (supplier_id) REFERENCES suppliers (id),
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');

    // ক্রয়ের প্রতিটা লাইন = একটা নতুন FIFO ব্যাচ
    // Phase 1 (multi-unit): quantity/remaining_quantity/unit_cost সবসময়
    // base unit-এই থাকে (যাতে FIFO allocation লজিক অপরিবর্তিত থাকে)।
    // product_unit_id/display_quantity শুধু "কোন pack-এ, কত পরিমাণে
    // কেনা হয়েছিল" সেই তথ্য সংরক্ষণের জন্য (invoice/history display-এ
    // ব্যবহার হবে) — হিসাবের মূল ভিত্তি নয়।
    await db.execute('''
      CREATE TABLE purchase_batches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        purchase_id INTEGER,
        product_id INTEGER NOT NULL,
        product_unit_id INTEGER,
        display_quantity REAL,
        quantity REAL NOT NULL,
        remaining_quantity REAL NOT NULL,
        unit_cost REAL NOT NULL,
        batch_date TEXT NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (purchase_id) REFERENCES purchases (id),
        FOREIGN KEY (product_id) REFERENCES products (id),
        FOREIGN KEY (product_unit_id) REFERENCES product_units (id)
      )
    ''');

    // বিক্রয় (মাল্টি-আইটেম বিল)
    await db.execute('''
      CREATE TABLE sales (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customer_id INTEGER,
        sale_date TEXT NOT NULL,
        courier_charge REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL,
        paid_amount REAL NOT NULL DEFAULT 0,
        is_credit INTEGER NOT NULL DEFAULT 0,
        sale_type TEXT NOT NULL DEFAULT 'retail',
        created_by INTEGER,
        created_at TEXT NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (customer_id) REFERENCES customers (id),
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');

    // বিক্রয়ের প্রতিটা লাইন-আইটেম
    // Phase 1 (multi-unit): product_unit_id = কোন pack unit-এ বিক্রি হয়েছে
    // (NULL হলে বোঝাবে সরাসরি product-এর base unit-এ বিক্রি হয়েছে)।
    // base_quantity = stock থেকে বাস্তবে কত base-unit কাটা হয়েছে, এটাই
    // stock/FIFO হিসাবের জন্য ব্যবহৃত হবে (quantity ফিল্ডটা থাকে display/
    // sold-unit-এর সংখ্যা হিসেবে, যেমন "২ x 500g" হলে quantity = 2)।
    // base_quantity বিক্রির সময়ের conversion_factor দিয়ে snapshot করে
    // রাখা হয়, যাতে পরে কেউ product_units-এর conversion factor বদলালেও
    // পুরনো বিক্রয়ের হিসাব না বদলে যায় (Data Safety নীতি অনুযায়ী)।
    await db.execute('''
      CREATE TABLE sale_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL,
        product_id INTEGER NOT NULL,
        product_unit_id INTEGER,
        quantity REAL NOT NULL,
        base_quantity REAL NOT NULL,
        unit_price REAL NOT NULL,
        total_cost REAL NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (sale_id) REFERENCES sales (id),
        FOREIGN KEY (product_id) REFERENCES products (id),
        FOREIGN KEY (product_unit_id) REFERENCES product_units (id)
      )
    ''');

    // একটা sale_item কোন কোন FIFO ব্যাচ থেকে কী পরিমাণ কেটেছে তার হিসাব
    // (একটা বিক্রয়ে একাধিক পুরনো ব্যাচ থেকে মাল যেতে পারে)
    await db.execute('''
      CREATE TABLE sale_item_batch_allocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_item_id INTEGER NOT NULL,
        purchase_batch_id INTEGER NOT NULL,
        quantity REAL NOT NULL,
        unit_cost REAL NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (sale_item_id) REFERENCES sale_items (id),
        FOREIGN KEY (purchase_batch_id) REFERENCES purchase_batches (id)
      )
    ''');

    // বিক্রয় ফেরত
    await db.execute('''
      CREATE TABLE sale_returns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_item_id INTEGER NOT NULL,
        quantity REAL NOT NULL,
        return_date TEXT NOT NULL,
        refund_amount REAL NOT NULL,
        cost_amount REAL NOT NULL DEFAULT 0,
        created_by INTEGER,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (sale_item_id) REFERENCES sale_items (id)
      )
    ''');

    // ক্রয় ফেরত
    await db.execute('''
      CREATE TABLE purchase_returns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        purchase_batch_id INTEGER NOT NULL,
        quantity REAL NOT NULL,
        return_date TEXT NOT NULL,
        refund_amount REAL NOT NULL,
        created_by INTEGER,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (purchase_batch_id) REFERENCES purchase_batches (id)
      )
    ''');

    // স্টক অ্যাডজাস্টমেন্ট (গিফট/নষ্ট/নমুনা)
    // Phase 1 (multi-unit): product_unit_id + base_quantity একই নীতিতে,
    // যাতে adjustment-ও pack-unit-এ ইনপুট দেওয়া যায় (যেমন "৫টা 500g নষ্ট")।
    await db.execute('''
      CREATE TABLE stock_adjustments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        product_unit_id INTEGER,
        quantity REAL NOT NULL,
        base_quantity REAL NOT NULL,
        total_cost REAL NOT NULL DEFAULT 0,
        reason TEXT NOT NULL,
        note TEXT,
        adjustment_date TEXT NOT NULL,
        created_by INTEGER,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (product_id) REFERENCES products (id),
        FOREIGN KEY (product_unit_id) REFERENCES product_units (id)
      )
    ''');

    // খরচ
    await db.execute('''
      CREATE TABLE expenses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        amount REAL NOT NULL,
        description TEXT,
        expense_date TEXT NOT NULL,
        created_by INTEGER,
        created_at TEXT NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');

    // পার্টনার মূলধন/উত্তোলন লেনদেন
    await db.execute('''
      CREATE TABLE capital_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        partner_id INTEGER NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('invest','withdraw_capital','withdraw_profit')),
        amount REAL NOT NULL,
        transaction_date TEXT NOT NULL,
        note TEXT,
        created_by INTEGER,
        created_at TEXT NOT NULL,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (partner_id) REFERENCES partners (id)
      )
    ''');

    // কেন্দ্রীয় ক্যাশ লেজার — প্রতিটা টাকার আনাগোনা এখানে রেকর্ড হয়
    // (এখান থেকেই "বর্তমান ক্যাশ" যোগফল করে বের করা হয়)
    await db.execute('''
      CREATE TABLE cash_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount REAL NOT NULL,
        direction TEXT NOT NULL CHECK(direction IN ('in','out')),
        reference_type TEXT NOT NULL,
        reference_id INTEGER,
        description TEXT,
        transaction_date TEXT NOT NULL,
        created_at TEXT NOT NULL,
        sync_id TEXT UNIQUE,
        ref_sync_id TEXT
      )
    ''');

    // বাকি (পাওনা/দেনা) আদায়/শোধ লেনদেন
    await db.execute('''
      CREATE TABLE due_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        party_type TEXT NOT NULL CHECK(party_type IN ('customer','supplier')),
        party_id INTEGER NOT NULL,
        reference_type TEXT NOT NULL,
        reference_id INTEGER,
        amount REAL NOT NULL,
        payment_date TEXT NOT NULL,
        created_by INTEGER,
        sync_id TEXT UNIQUE,
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');

    // অ্যাক্টিভিটি লগ — কে কী এডিট/ডিলিট করলো
    await db.execute('''
      CREATE TABLE activity_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        action TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id INTEGER,
        details TEXT,
        timestamp TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users (id)
      )
    ''');

    // ওপেনিং ব্যালেন্স (ঐচ্ছিক)
    await db.execute('''
      CREATE TABLE opening_balance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cash_amount REAL NOT NULL DEFAULT 0,
        entry_date TEXT NOT NULL
      )
    ''');

    // দোকানের ডিফল্ট সেটিংস — পরে সেটিংস স্ক্রিন থেকে পরিবর্তন করা যাবে
    await db.insert('app_settings', {'key': 'shop_name', 'value': 'Ahmadia Shop'});
    await db.insert('app_settings', {'key': 'shop_address', 'value': ''});
    await db.insert('app_settings', {'key': 'shop_phone', 'value': ''});
    await db.insert('app_settings', {'key': 'shop_logo_path', 'value': ''});
    await db.insert('app_settings', {'key': 'last_backup_at', 'value': ''});

    // দুইজন ফিক্সড পার্টনার — নাম পরে সেটিংস থেকে বদলানো যাবে
    await db.insert('partners', {'name': 'পার্টনার ১', 'profit_share_percent': 50.0});
    await db.insert('partners', {'name': 'পার্টনার ২', 'profit_share_percent': 50.0});
  }

  // ============================================================
  // FIFO হিসাব-ইঞ্জিন — এখানেই আসল জাদু
  // ============================================================

  /// একটা পণ্যে বিক্রয়ের সময়, পুরনো ব্যাচ থেকে আগে কেটে (FIFO)
  /// প্রয়োজনীয় পরিমাণ বের করে দেয়, আর প্রতিটা ব্যাচ থেকে কত
  /// পরিমাণ+কী দামে কাটা হলো তার তালিকা রিটার্ন করে।
  ///
  /// রিটার্ন করে: [{batch_id, quantity, unit_cost}, ...]
  /// যদি স্টকে যথেষ্ট মাল না থাকে -> Exception ছুঁড়ে দেয়
  /// (এটাই "নেগেটিভ স্টক প্রতিরোধ" ফিচারের মূল লজিক)
  Future<List<Map<String, dynamic>>> allocateFIFO(
      DatabaseExecutor db, int productId, double requiredQty) async {
    final batches = await db.query(
      'purchase_batches',
      where: 'product_id = ? AND remaining_quantity > 0',
      whereArgs: [productId],
      orderBy: 'batch_date ASC, id ASC', // সবচেয়ে পুরনো ব্যাচ আগে
    );

    double remaining = requiredQty;
    final allocations = <Map<String, dynamic>>[];

    for (final batch in batches) {
      if (remaining <= 0) break;
      final batchRemaining = batch['remaining_quantity'] as double;
      final take = remaining <= batchRemaining ? remaining : batchRemaining;

      allocations.add({
        'batch_id': batch['id'],
        'quantity': take,
        'unit_cost': batch['unit_cost'],
      });

      remaining -= take;
    }

    if (remaining > 0.0001) {
      // পর্যাপ্ত স্টক নেই — নেগেটিভ স্টক প্রতিরোধ
      throw Exception(
          'পর্যাপ্ত স্টক নেই। চাহিদা: $requiredQty, পাওয়া গেছে: ${requiredQty - remaining}');
    }

    return allocations;
  }

  /// বর্তমান মোট স্টক পরিমাণ (একটা পণ্যের সব ব্যাচ মিলিয়ে)
  Future<double> getCurrentStock(Database db, int productId) async {
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(remaining_quantity), 0) as total
      FROM purchase_batches WHERE product_id = ?
    ''', [productId]);
    return (result.first['total'] as num).toDouble();
  }

  /// বর্তমান ইনভেন্টরি ভ্যালু (FIFO অনুযায়ী, সব পণ্য মিলিয়ে)
  Future<double> getInventoryValue(Database db) async {
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(remaining_quantity * unit_cost), 0) as total
      FROM purchase_batches
    ''');
    return (result.first['total'] as num).toDouble();
  }

  /// বর্তমান ক্যাশ ইন হ্যান্ড (cash_ledger টেবিলের যোগফল থেকে)
  Future<double> getCurrentCash(Database db) async {
    final inResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total FROM cash_ledger WHERE direction = 'in'
    ''');
    final outResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total FROM cash_ledger WHERE direction = 'out'
    ''');
    final cashIn = (inResult.first['total'] as num).toDouble();
    final cashOut = (outResult.first['total'] as num).toDouble();
    return cashIn - cashOut;
  }

  /// মোট গ্রস প্রফিট (সব বিক্রয় থেকে, বিক্রয়মূল্য - FIFO ক্রয়মূল্য)
  Future<double> getGrossProfit(Database db) async {
    final salesResult = await db.rawQuery('''
      SELECT COALESCE(SUM((si.unit_price * si.quantity) - si.total_cost), 0) as profit
      FROM sale_items si
    ''');
    final grossFromSales = (salesResult.first['profit'] as num).toDouble();

    // বিক্রয় ফেরতের কারণে বিয়োগ হবে — শুধু লাভের অংশটুকু
    // (refund_amount - cost_amount), পুরো ফেরত-টাকা না, কারণ
    // ক্যাশ/বাকির হিসাব আলাদাভাবে (cash_ledger/sales.total_amount
    // থেকে) সামলানো হয়
    final returnsResult = await db.rawQuery('''
      SELECT COALESCE(SUM(sr.refund_amount - sr.cost_amount), 0) as total
      FROM sale_returns sr
    ''');
    final returns = (returnsResult.first['total'] as num).toDouble();

    return grossFromSales - returns;
  }

  /// মোট খরচ
  Future<double> getTotalExpenses(Database db) async {
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total FROM expenses
    ''');
    return (result.first['total'] as num).toDouble();
  }

  /// স্টক সমন্বয়ের (নষ্ট/গিফট/নমুনা/ঘাটতি/অতিরিক্ত পাওয়া) আর্থিক প্রভাব।
  /// স্টক কমলে (base_quantity < 0) সেই মালের ক্রয়মূল্য ক্ষতি (ঋণাত্মক),
  /// স্টক বাড়লে (অতিরিক্ত পাওয়া) অনুমিত মূল্য লাভ (ধনাত্মক)। এটা না ধরলে
  /// ইনভেন্টরি কমে যায় অথচ লাভ-ক্ষতির হিসাবে তার খরচ আসে না।
  Future<double> getStockAdjustmentImpact(Database db) async {
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(CASE WHEN base_quantity > 0 THEN total_cost
                               ELSE -total_cost END), 0) as total
      FROM stock_adjustments
    ''');
    return (result.first['total'] as num).toDouble();
  }

  /// নিট প্রফিট = গ্রস প্রফিট - মোট খরচ ± স্টক সমন্বয়ের প্রভাব
  /// (পজিটিভ = লাভ, নেগেটিভ = লোকসান)
  Future<double> getNetProfit(Database db) async {
    final gross = await getGrossProfit(db);
    final expenses = await getTotalExpenses(db);
    final adjustments = await getStockAdjustmentImpact(db);
    return gross - expenses + adjustments;
  }

  /// এখন পর্যন্ত পার্টনারদের মোট উত্তোলিত লাভ (withdraw_profit টাইপ)
  Future<double> getTotalProfitWithdrawn(Database db) async {
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total
      FROM capital_transactions WHERE type = 'withdraw_profit'
    ''');
    return (result.first['total'] as num).toDouble();
  }

  /// উত্তোলনযোগ্য অবশিষ্ট লাভ = নিট প্রফিট - এখন পর্যন্ত উত্তোলিত লাভ
  Future<double> getAvailableProfit(Database db) async {
    final net = await getNetProfit(db);
    final withdrawn = await getTotalProfitWithdrawn(db);
    return net - withdrawn;
  }

  /// মোট কাস্টমার বাকি (পাওনা)
  Future<double> getTotalReceivables(Database db) async {
    final salesResult = await db.rawQuery('''
      SELECT COALESCE(SUM(total_amount - paid_amount), 0) as total
      FROM sales WHERE is_credit = 1
    ''');
    final totalDue = (salesResult.first['total'] as num).toDouble();

    final paidResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total
      FROM due_payments WHERE party_type = 'customer'
    ''');
    final totalPaid = (paidResult.first['total'] as num).toDouble();

    return totalDue - totalPaid;
  }

  /// মোট সাপ্লায়ার বাকি (দেনা)
  Future<double> getTotalPayables(Database db) async {
    final purchaseResult = await db.rawQuery('''
      SELECT COALESCE(SUM(total_amount - paid_amount), 0) as total
      FROM purchases WHERE is_credit = 1
    ''');
    final totalDue = (purchaseResult.first['total'] as num).toDouble();

    final paidResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total
      FROM due_payments WHERE party_type = 'supplier'
    ''');
    final totalPaid = (paidResult.first['total'] as num).toDouble();

    return totalDue - totalPaid;
  }

  /// প্রতি পার্টনারের নিট ব্যালেন্স (ক্যাপিটাল + লাভের ভাগ - উত্তোলন)
  Future<double> getPartnerBalance(Database db, int partnerId) async {
    final result = await db.rawQuery('''
      SELECT type, COALESCE(SUM(amount), 0) as total
      FROM capital_transactions WHERE partner_id = ?
      GROUP BY type
    ''', [partnerId]);

    double invested = 0, withdrawnCapital = 0, withdrawnProfit = 0;
    for (final row in result) {
      final total = (row['total'] as num).toDouble();
      if (row['type'] == 'invest') invested = total;
      if (row['type'] == 'withdraw_capital') withdrawnCapital = total;
      if (row['type'] == 'withdraw_profit') withdrawnProfit = total;
    }

    final netProfit = await getNetProfit(db);
    final partner = (await db.query('partners',
            where: 'id = ?', whereArgs: [partnerId]))
        .first;
    final sharePercent = (partner['profit_share_percent'] as num).toDouble();
    final profitShare = netProfit * (sharePercent / 100);

    return invested - withdrawnCapital + profitShare - withdrawnProfit;
  }

  /// লো-স্টক পণ্যের তালিকা
  Future<List<Map<String, dynamic>>> getLowStockProducts(Database db) async {
    return await db.rawQuery('''
      SELECT p.id, p.name, p.unit, p.low_stock_threshold,
             COALESCE(SUM(pb.remaining_quantity), 0) as current_stock
      FROM products p
      LEFT JOIN purchase_batches pb ON pb.product_id = p.id
      WHERE p.is_active = 1
      GROUP BY p.id
      HAVING current_stock <= p.low_stock_threshold
    ''');
  }
}
