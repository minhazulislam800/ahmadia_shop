// ============================================================
// product_screen.dart
// পণ্যের তালিকা, সার্চ (নাম/কোড দিয়ে), নতুন পণ্য যোগ — প্রতিটা
// পণ্যের একটা ইউনিক কোড থাকা বাধ্যতামূলক (পণ্যের গায়ে লেখা কোড
// হাতে বসিয়ে দেওয়া হয়) — এটাই পণ্যের "আসল পরিচয়", নাম বদলালেও
// বা দুইটা পণ্যের নাম কাকতালীয়ভাবে মিলে গেলেও কোড দিয়ে আলাদা
// করা যায়, আর দুই ডিভাইসে মার্জের সময়ও এই কোড দিয়েই মেলানো হয়
// ============================================================

import 'package:flutter/material.dart';
import '../database/db_helper.dart';
import '../models/product_unit.dart';
import '../utils/app_theme.dart';
import '../utils/sync_id.dart';

class ProductScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const ProductScreen({super.key, required this.currentUser});

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  final _dbHelper = DBHelper.instance;
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final products = await db.rawQuery('''
      SELECT p.*, c.name as category_name,
             COALESCE(SUM(pb.remaining_quantity), 0) as current_stock
      FROM products p
      LEFT JOIN categories c ON c.id = p.category_id
      LEFT JOIN purchase_batches pb ON pb.product_id = p.id
      WHERE p.is_active = 1
      GROUP BY p.id
      ORDER BY p.name ASC
    ''');
    if (!mounted) return;
    setState(() {
      _products = products;
      _filtered = products;
      _loading = false;
    });
  }

  void _filter(String query) {
    final q = query.toLowerCase().trim();
    setState(() {
      _filtered = _products.where((p) {
        final name = (p['name'] as String).toLowerCase();
        final code = (p['product_code'] as String? ?? '').toLowerCase();
        return name.contains(q) || code.contains(q);
      }).toList();
    });
  }

  Future<bool> _checkDuplicateName(String name) async {
    final db = await _dbHelper.database;
    final result = await db.query('products',
        where: 'LOWER(name) = ? AND is_active = 1',
        whereArgs: [name.toLowerCase().trim()]);
    return result.isNotEmpty;
  }

  Future<bool> _checkDuplicateCode(String code) async {
    final db = await _dbHelper.database;
    final result = await db.query('products',
        where: 'LOWER(product_code) = ? AND is_active = 1',
        whereArgs: [code.toLowerCase().trim()]);
    return result.isNotEmpty;
  }

  // ----------------------------------------------------------
  // Phase 1 (multi-unit): এই product-এর বিক্রয়যোগ্য pack unit
  // (250g/500g/1kg ইত্যাদি) ব্যবস্থাপনা — লোড, যোগ, নিষ্ক্রিয় করা
  // ----------------------------------------------------------
  Future<List<ProductUnit>> _loadUnits(int productId) async {
    final db = await _dbHelper.database;
    final rows = await db.query('product_units',
        where: 'product_id = ? AND is_active = 1',
        whereArgs: [productId],
        orderBy: 'conversion_factor_to_base ASC');
    return rows.map((r) => ProductUnit.fromMap(r)).toList();
  }

  Future<void> _addUnit(ProductUnit unit) async {
    final db = await _dbHelper.database;
    if (unit.isDefault) {
      // একবারে একটাই ডিফল্ট pack থাকতে পারে — বাকিগুলো থেকে ডিফল্ট সরানো
      await db.update('product_units', {'is_default': 0},
          where: 'product_id = ?', whereArgs: [unit.productId]);
    }
    await db.insert('product_units',
        unit.copyWith(syncId: generateSyncId()).toMap());
  }

  // একক নিষ্ক্রিয় করা (হার্ড ডিলিট নয়) — কারণ পুরনো sale/purchase/
  // adjustment রেকর্ড এই unit-কে রেফারেন্স করে থাকতে পারে; ডিলিট করলে
  // সেই পুরনো ইতিহাস ভেঙে যাবে (Data Safety নীতি অনুযায়ী)। নিষ্ক্রিয়
  // করলে শুধু নতুন বিক্রি/ক্রয়ের সময় pick-list-এ আর দেখাবে না।
  Future<void> _deactivateUnit(int unitId) async {
    final db = await _dbHelper.database;
    await db.update('product_units', {'is_active': 0},
        where: 'id = ?', whereArgs: [unitId]);
  }

  Future<void> _showManageUnitsDialog(Map<String, dynamic> product) async {
    final productId = product['id'] as int;
    final baseUnit = product['unit'] as String;
    var units = await _loadUnits(productId);
    final labelController = TextEditingController();
    final factorController = TextEditingController();
    final priceController = TextEditingController();
    bool asDefault = units.isEmpty; // প্রথম pack হলে ডিফল্ট হিসেবে সাজেস্ট করা

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('${product['name']} — বিক্রয় একক (Pack)'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('বেস ইউনিট: $baseUnit (স্টক এই এককেই সংরক্ষিত হয়)',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 8),
                  if (units.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('এখনো কোনো pack যোগ করা হয়নি।'),
                    )
                  else
                    ...units.map((u) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                              '${u.unitLabel}${u.isDefault ? "  (ডিফল্ট)" : ""}'),
                          subtitle: Text(
                              '= ${u.conversionFactorToBase} $baseUnit'
                              '${u.sellingPrice != null ? " • দাম: ৳${u.sellingPrice}" : ""}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: AppColors.warning),
                            tooltip: 'নিষ্ক্রিয় করুন',
                            onPressed: () async {
                              await _deactivateUnit(u.id!);
                              units = await _loadUnits(productId);
                              setDialogState(() {});
                            },
                          ),
                        )),
                  const Divider(height: 24),
                  const Text('নতুন Pack যোগ করুন',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: labelController,
                    decoration: const InputDecoration(
                        labelText: 'নাম (যেমন: 500g, ডজন)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: factorController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: '১ $baseUnit-এ কত আছে (যেমন 500g হলে 500)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: priceController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'বিক্রয় মূল্য (ঐচ্ছিক)'),
                  ),
                  Row(
                    children: [
                      Checkbox(
                        value: asDefault,
                        onChanged: (v) =>
                            setDialogState(() => asDefault = v ?? false),
                      ),
                      const Text('ডিফল্ট pack হিসেবে সেট করুন'),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      onPressed: () async {
                        final label = labelController.text.trim();
                        final factor =
                            double.tryParse(factorController.text.trim());
                        if (label.isEmpty || factor == null || factor <= 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                              content:
                                  Text('সঠিক নাম ও conversion মান দিন')));
                          return;
                        }
                        await _addUnit(ProductUnit(
                          productId: productId,
                          unitLabel: label,
                          conversionFactorToBase: factor,
                          sellingPrice:
                              double.tryParse(priceController.text.trim()),
                          isDefault: asDefault,
                        ));
                        labelController.clear();
                        factorController.clear();
                        priceController.clear();
                        units = await _loadUnits(productId);
                        setDialogState(() => asDefault = false);
                      },
                      child: const Text('যোগ করুন'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _loadProducts();
                },
                child: const Text('বন্ধ করুন')),
          ],
        ),
      ),
    );
  }

  bool get _isMaster => widget.currentUser['role'] == 'master';

  // পণ্যের নাম/কোড/ক্যাটাগরি/থ্রেশহোল্ড/দাম edit — কিন্তু base unit
  // (product['unit']) ইচ্ছাকৃতভাবে এখানে edit করা যাবে না, কারণ এটা
  // বদলালে সব পুরনো stock/sale/purchase-এর quantity ভুল hisab হয়ে
  // যাবে (Phase 1-এর multi-unit ভিত্তি এই base unit-এর ওপর দাঁড়িয়ে)।
  Future<void> _showEditProductDialog(Map<String, dynamic> product) async {
    final nameController = TextEditingController(text: product['name'] as String);
    final codeController =
        TextEditingController(text: product['product_code'] as String? ?? '');
    final categoryController =
        TextEditingController(text: product['category_name'] as String? ?? '');
    final thresholdController = TextEditingController(
        text: (product['low_stock_threshold'] as num? ?? 0).toString());
    final retailPriceController = TextEditingController(
        text: (product['retail_price'] as num?)?.toString() ?? '');
    final wholesalePriceController = TextEditingController(
        text: (product['wholesale_price'] as num?)?.toString() ?? '');
    String? codeError;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('পণ্যের তথ্য সম্পাদনা'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'পণ্যের নাম'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  decoration: InputDecoration(
                      labelText: 'পণ্য কোড', errorText: codeError),
                  onChanged: (_) {
                    if (codeError != null) setDialogState(() => codeError = null);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: categoryController,
                  decoration: const InputDecoration(labelText: 'ক্যাটাগরি (ঐচ্ছিক)'),
                ),
                const SizedBox(height: 12),
                Text('বেস ইউনিট: ${product['unit']} (পরিবর্তনযোগ্য নয়)',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 12),
                TextField(
                  controller: thresholdController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'লো-স্টক সতর্কতা সীমা'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: retailPriceController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'খুচরা দাম (ঐচ্ছিক)'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: wholesalePriceController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'পাইকারি দাম (ঐচ্ছিক)'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final code = codeController.text.trim();
                if (name.isEmpty || code.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('নাম ও কোড আবশ্যক')));
                  return;
                }
                final db = await _dbHelper.database;
                final codeClash = await db.query('products',
                    where: 'LOWER(product_code) = ? AND is_active = 1 AND id != ?',
                    whereArgs: [code.toLowerCase(), product['id']]);
                if (codeClash.isNotEmpty) {
                  setDialogState(() => codeError = 'এই কোড অন্য পণ্যে ব্যবহৃত হয়েছে');
                  return;
                }

                int? categoryId;
                final categoryName = categoryController.text.trim();
                if (categoryName.isNotEmpty) {
                  final existing = await db.query('categories',
                      where: 'name = ?', whereArgs: [categoryName]);
                  categoryId = existing.isNotEmpty
                      ? existing.first['id'] as int
                      : await db.insert('categories',
                          {'name': categoryName, 'sync_id': generateSyncId()});
                }

                await db.update(
                    'products',
                    {
                      'name': name,
                      'product_code': code,
                      'category_id': categoryId,
                      'low_stock_threshold': double.tryParse(thresholdController.text) ?? 0,
                      'retail_price': double.tryParse(retailPriceController.text),
                      'wholesale_price': double.tryParse(wholesalePriceController.text),
                    },
                    where: 'id = ?',
                    whereArgs: [product['id']]);
                await _dbHelper.logActivity(
                    userId: widget.currentUser['id'] as int?,
                    action: 'update',
                    entityType: 'product',
                    entityId: product['id'] as int,
                    details: 'পণ্যের তথ্য সম্পাদনা: $name');

                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                _loadProducts();
              },
              child: const Text('সংরক্ষণ করুন'),
            ),
          ],
        ),
      ),
    );
  }

  // §5/§6-এর নীতি অনুযায়ী: হার্ড ডিলিট নয়, নিষ্ক্রিয় করা (is_active=0) —
  // পুরনো sale/purchase/stock_adjustment-এ product_id রেফারেন্স অক্ষত
  // থাকে, শুধু নতুন বিক্রয়/ক্রয়ের পিক-লিস্টে আর দেখাবে না
  Future<void> _confirmDeactivateProduct(Map<String, dynamic> product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('"${product['name']}"-কে নিষ্ক্রিয় করবেন?'),
        content: const Text(
            'এই পণ্য নতুন বিক্রয়/ক্রয়ের সময় আর তালিকায় দেখাবে না, কিন্তু আগের সব হিসাব অক্ষত থাকবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: const Text('নিষ্ক্রিয় করুন')),
        ],
      ),
    );
    if (confirmed != true) return;
    final db = await _dbHelper.database;
    await db.update('products', {'is_active': 0},
        where: 'id = ?', whereArgs: [product['id']]);
    await _dbHelper.logActivity(
        userId: widget.currentUser['id'] as int?,
        action: 'delete',
        entityType: 'product',
        entityId: product['id'] as int,
        details: 'পণ্য নিষ্ক্রিয় করা হলো: ${product['name']}');
    if (!mounted) return;
    _loadProducts();
  }

  Future<void> _showAddProductDialog() async {
    final nameController = TextEditingController();
    final codeController = TextEditingController();
    final unitController = TextEditingController();
    final thresholdController = TextEditingController(text: '0');
    final categoryController = TextEditingController();
    final retailPriceController = TextEditingController();
    final wholesalePriceController = TextEditingController();
    String? codeError;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('নতুন পণ্য যোগ করুন'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'পণ্যের নাম'),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  decoration: InputDecoration(
                    labelText: 'পণ্য কোড (আবশ্যক)',
                    helperText: 'পণ্যের গায়ে লেখা কোড/নম্বর — এটাই এই পণ্যের ইউনিক পরিচয়',
                    errorText: codeError,
                  ),
                  onChanged: (_) {
                    if (codeError != null) setDialogState(() => codeError = null);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: categoryController,
                  decoration:
                      const InputDecoration(labelText: 'ক্যাটাগরি (ঐচ্ছিক)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: unitController,
                  decoration: const InputDecoration(
                      labelText: 'ইউনিট (যেমন: কেজি, লিটার, পিস)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: thresholdController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'লো-স্টক সতর্কতা সীমা'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: retailPriceController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'খুচরা দাম (ঐচ্ছিক)'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: wholesalePriceController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'পাইকারি দাম (ঐচ্ছিক)'),
                      ),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'দাম দুটো শুধু বিক্রয় ফর্মে অটো-ফিল করার সুবিধার জন্য — চাইলে বিক্রির সময় বদলে দেওয়া যাবে',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final code = codeController.text.trim();
                final unit = unitController.text.trim();

                if (name.isEmpty || unit.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('নাম ও ইউনিট আবশ্যক')));
                  return;
                }
                if (code.isEmpty) {
                  setDialogState(() => codeError = 'পণ্য কোড আবশ্যক');
                  return;
                }

                // কোড ইউনিক হতেই হবে — এটা "সতর্কতা" না, সরাসরি আটকে দেওয়া হয়
                final codeExists = await _checkDuplicateCode(code);
                if (codeExists) {
                  setDialogState(() => codeError = 'এই কোড আগে থেকেই অন্য পণ্যে ব্যবহৃত হয়েছে');
                  return;
                }

                final isDuplicateName = await _checkDuplicateName(name);
                if (isDuplicateName) {
                  if (!ctx.mounted) return;
                  final proceed = await showDialog<bool>(
                    context: ctx,
                    builder: (dctx) => AlertDialog(
                      title: const Text('⚠️ একই নামের পণ্য আগে থেকেই আছে'),
                      content: Text(
                          '"$name" নামে ইতিমধ্যে একটা পণ্য আছে (হয়তো ভিন্ন কোডে/সাইজে)। তবুও নতুন করে যোগ করবেন?'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dctx, false),
                            child: const Text('বাতিল')),
                        ElevatedButton(
                            onPressed: () => Navigator.pop(dctx, true),
                            child: const Text('তবুও যোগ করুন')),
                      ],
                    ),
                  );
                  if (proceed != true) return;
                }

                int? categoryId;
                final categoryName = categoryController.text.trim();
                final db = await _dbHelper.database;
                if (categoryName.isNotEmpty) {
                  final existing = await db.query('categories',
                      where: 'name = ?', whereArgs: [categoryName]);
                  if (existing.isNotEmpty) {
                    categoryId = existing.first['id'] as int;
                  } else {
                    categoryId = await db.insert('categories',
                        {'name': categoryName, 'sync_id': generateSyncId()});
                  }
                }

                await db.insert('products', {
                  'name': name,
                  'product_code': code,
                  'category_id': categoryId,
                  'unit': unit,
                  'low_stock_threshold':
                      double.tryParse(thresholdController.text) ?? 0,
                  'retail_price': double.tryParse(retailPriceController.text),
                  'wholesale_price': double.tryParse(wholesalePriceController.text),
                  'is_active': 1,
                  'created_at': DateTime.now().toIso8601String(),
                  'sync_id': generateSyncId(),
                });

                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                _loadProducts();
              },
              child: const Text('যোগ করুন'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('পণ্য তালিকা')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddProductDialog,
        icon: const Icon(Icons.add),
        label: const Text('নতুন পণ্য'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _filter,
                    decoration: const InputDecoration(
                      hintText: 'পণ্যের নাম বা কোড দিয়ে খুঁজুন...',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                Expanded(
                  child: _filtered.isEmpty
                      ? const Center(child: Text('কোনো পণ্য পাওয়া যায়নি'))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _filtered.length,
                          itemBuilder: (ctx, i) {
                            final p = _filtered[i];
                            final stock = (p['current_stock'] as num).toDouble();
                            final threshold =
                                (p['low_stock_threshold'] as num).toDouble();
                            final isLow = stock <= threshold;
                            final code = p['product_code'] as String? ?? '';
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                title: Text(p['name'] as String),
                                subtitle: Text(
                                    '${code.isNotEmpty ? "কোড: $code • " : ""}${p['category_name'] as String? ?? 'ক্যাটাগরি নেই'}'),
                                onTap: () => _showManageUnitsDialog(p),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text('$stock ${p['unit']}',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: isLow
                                                  ? AppColors.warning
                                                  : AppColors.textPrimary,
                                            )),
                                        if (isLow)
                                          const Text('লো-স্টক',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.warning)),
                                      ],
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.tune,
                                          size: 20, color: AppColors.textSecondary),
                                      tooltip: 'বিক্রয় একক (Pack) ব্যবস্থাপনা',
                                      onPressed: () => _showManageUnitsDialog(p),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined,
                                          size: 20, color: AppColors.textSecondary),
                                      tooltip: 'তথ্য সম্পাদনা',
                                      onPressed: () => _showEditProductDialog(p),
                                    ),
                                    if (_isMaster)
                                      IconButton(
                                        icon: const Icon(Icons.visibility_off_outlined,
                                            size: 20, color: AppColors.danger),
                                        tooltip: 'নিষ্ক্রিয় করুন (Master)',
                                        onPressed: () => _confirmDeactivateProduct(p),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
