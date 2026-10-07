// ============================================================
// purchase_entry_screen.dart
// একাধিক পণ্য একসাথে ক্রয় করার ফর্ম — সাবমিট করলে
// TransactionService.recordPurchase() কল হয়ে সব টেবিল
// স্বয়ংক্রিয়ভাবে আপডেট হয়ে যায় (নতুন FIFO ব্যাচসহ)
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../models/product_unit.dart';
import '../utils/app_theme.dart';
import '../widgets/party_selector.dart';
import '../widgets/date_field.dart';
import '../widgets/app_bottom_nav.dart';

class PurchaseEntryScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final int? editPurchaseId; // দেওয়া হলে screen "edit mode"-এ খুলবে
  const PurchaseEntryScreen(
      {super.key, required this.currentUser, this.editPurchaseId});

  @override
  State<PurchaseEntryScreen> createState() => _PurchaseEntryScreenState();
}

class _PurchaseItemRow {
  int? productId;
  String productName = '';
  String baseUnit = ''; // product-এর base unit (stock এই এককে সংরক্ষিত হয়)
  // Phase 1 (multi-unit): null = সরাসরি base unit-এ কেনা, নাহলে pack unit
  ProductUnit? selectedUnit;
  List<ProductUnit> availableUnits = [];
  double quantity = 0; // নির্বাচিত unit-এ (pack হলে pack-সংখ্যা)
  double unitCost = 0; // নির্বাচিত unit-এর প্রতি এককের দাম (সেভ ও হিসাব এটা দিয়েই)
  // ঘরে লেখা সংখ্যা: priceIsPerBase হলে প্রতি base unit (যেমন কেজি) দাম, নাহলে প্রতি
  // নির্বাচিত unit-এর দাম। unitCost এটা থেকে স্বয়ংক্রিয় হিসাব হয়।
  double priceInput = 0;
  bool priceIsPerBase = false;
  final TextEditingController unitCostController = TextEditingController();

  double get conversionFactor => selectedUnit?.conversionFactorToBase ?? 1;

  void recomputePrice() {
    unitCost = (selectedUnit != null && priceIsPerBase)
        ? ((priceInput * conversionFactor) * 1000000).round() / 1000000
        : priceInput;
  }

  String get displayUnitLabel => selectedUnit?.unitLabel ?? baseUnit;
}

class _PurchaseEntryScreenState extends State<PurchaseEntryScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();

  List<Map<String, dynamic>> _products = [];
  final List<_PurchaseItemRow> _items = [_PurchaseItemRow()];
  int? _supplierId;
  bool _isCredit = false;
  double _paidAmount = 0;
  DateTime _purchaseDate = DateTime.now();
  bool _saving = false;
  late bool _prefilling = widget.editPurchaseId != null;

  bool get _isEditMode => widget.editPurchaseId != null;

  double get _totalAmount =>
      _items.fold(0, (sum, item) => sum + (item.quantity * item.unitCost));

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadProducts();
    if (_isEditMode) {
      await _prefillFromExistingPurchase(widget.editPurchaseId!);
    }
  }

  // Phase 2 — ক্রয় edit: পুরনো purchase-এর ডেটা ফর্মে লোড করা।
  // purchase-এ (sale-এর মতো) কোনো "স্টক আছে কিনা" upper-bound চেক নেই
  // (কেনাকাটা তো স্টক *বাড়ায়়*), তাই availableStock নিয়ে সমন্বয়ের
  // দরকার নেই — শুধু আগের ডেটা হুবহু ফর্মে বসিয়ে দেওয়া হচ্ছে।
  Future<void> _prefillFromExistingPurchase(int purchaseId) async {
    setState(() => _prefilling = true);
    final db = await _dbHelper.database;
    final purchaseRows =
        await db.query('purchases', where: 'id = ?', whereArgs: [purchaseId]);
    if (purchaseRows.isEmpty) {
      if (!mounted) return;
      setState(() => _prefilling = false);
      return;
    }
    final purchase = purchaseRows.first;
    final batches = await db.query('purchase_batches',
        where: 'purchase_id = ?', whereArgs: [purchaseId]);

    final newItems = <_PurchaseItemRow>[];
    for (final b in batches) {
      final productId = b['product_id'] as int;
      final product = _products.firstWhere((p) => p['id'] == productId,
          orElse: () => <String, dynamic>{});
      final productUnitId = b['product_unit_id'] as int?;

      final unitRows = await db.query('product_units',
          where: 'product_id = ?', whereArgs: [productId]);
      ProductUnit? selectedUnit;
      var availableUnits =
          unitRows.map((r) => ProductUnit.fromMap(r)).where((u) => u.isActive).toList();
      double conversionFactor = 1;
      if (productUnitId != null) {
        final matchRows = unitRows.where((r) => r['id'] == productUnitId);
        if (matchRows.isNotEmpty) {
          selectedUnit = ProductUnit.fromMap(matchRows.first);
          conversionFactor = selectedUnit.conversionFactorToBase;
          if (!availableUnits.any((u) => u.id == selectedUnit!.id)) {
            availableUnits = [...availableUnits, selectedUnit];
          }
        }
      }

      // batch.quantity/unit_cost সবসময় base unit-এ থাকে (Phase 1 নীতি
      // অনুযায়ী) — ফর্মে দেখানোর জন্য আসল purchase-unit-এ ফিরিয়ে আনা হচ্ছে
      final baseQty = (b['quantity'] as num).toDouble();
      final baseUnitCost = (b['unit_cost'] as num).toDouble();
      final displayQty = (b['display_quantity'] as num?)?.toDouble() ??
          (conversionFactor == 0 ? baseQty : baseQty / conversionFactor);
      final displayUnitCost =
          productUnitId == null ? baseUnitCost : baseUnitCost * conversionFactor;

      newItems.add(_PurchaseItemRow()
        ..productId = productId
        ..productName = product['name'] as String? ?? ''
        ..baseUnit = product['unit'] as String? ?? ''
        ..selectedUnit = selectedUnit
        ..availableUnits = availableUnits
        ..quantity = displayQty
        ..unitCost = displayUnitCost
        ..priceInput = displayUnitCost
        ..unitCostController.text = _formatPrice(displayUnitCost));
    }

    if (!mounted) return;
    setState(() {
      _supplierId = purchase['supplier_id'] as int?;
      _isCredit = (purchase['is_credit'] as int? ?? 0) == 1;
      _paidAmount = (purchase['paid_amount'] as num?)?.toDouble() ?? 0;
      _purchaseDate =
          DateTime.tryParse(purchase['purchase_date'] as String) ?? DateTime.now();
      _items
        ..clear()
        ..addAll(newItems.isEmpty ? [_PurchaseItemRow()] : newItems);
      _prefilling = false;
    });
  }

  Future<void> _loadProducts() async {
    final db = await _dbHelper.database;
    final result = await db.query('products',
        where: 'is_active = 1', orderBy: 'name ASC');
    setState(() => _products = result);
  }

  void _addItemRow() {
    setState(() => _items.add(_PurchaseItemRow()));
  }

  void _removeItemRow(int index) {
    setState(() => _items.removeAt(index));
  }

  String _formatPrice(double price) => price == price.roundToDouble()
      ? price.toInt().toString()
      : price.toString();

  double _round6(double v) => (v * 1000000).round() / 1000000;

  void _showPrice(_PurchaseItemRow item) {
    item.recomputePrice();
    item.unitCostController.text =
        item.priceInput > 0 ? _formatPrice(item.priceInput) : '';
  }

  // Phase 1 (multi-unit): product বেছে নেওয়া হলে তার pack unit-গুলো লোড করা
  Future<void> _loadUnitsForRow(_PurchaseItemRow item, int productId) async {
    final db = await _dbHelper.database;
    final rows = await db.query('product_units',
        where: 'product_id = ? AND is_active = 1',
        whereArgs: [productId],
        orderBy: 'conversion_factor_to_base ASC');
    final units = rows.map((r) => ProductUnit.fromMap(r)).toList();
    if (!mounted) return;
    setState(() => item.availableUnits = units);
  }

  Future<void> _save() async {
    final validItems = _items
        .where((item) => item.productId != null && item.quantity > 0)
        .toList();

    if (validItems.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('কমপক্ষে একটা পণ্য যোগ করুন')));
      return;
    }

    // বাকির ক্রয়ে সাপ্লায়ার থাকতেই হবে, আর পরিশোধিত টাকা মোটের বেশি/ঋণাত্মক হতে পারে না
    if (_isCredit) {
      if (_supplierId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('বাকির ক্রয়ে সাপ্লায়ার নির্বাচন করুন')));
        return;
      }
      if (_paidAmount < 0 || _paidAmount > _totalAmount + 0.005) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('পরিশোধের পরিমাণ ০ থেকে মোট ক্রয়ের মধ্যে হতে হবে')));
        return;
      }
    }

    setState(() => _saving = true);
    try {
      if (_isEditMode) {
        await _transactionService.editPurchase(
          purchaseId: widget.editPurchaseId!,
          editedBy: widget.currentUser['id'] as int?,
          supplierId: _supplierId,
          items: validItems
              .map((item) => {
                    'product_id': item.productId,
                    'product_unit_id': item.selectedUnit?.id,
                    'quantity': item.quantity,
                    'unit_cost': item.unitCost,
                  })
              .toList(),
          paidAmount: _isCredit ? _paidAmount : _totalAmount,
          isCredit: _isCredit,
          purchaseDate: DateFormat('yyyy-MM-dd').format(_purchaseDate),
        );
      } else {
        await _transactionService.recordPurchase(
          supplierId: _supplierId,
          items: validItems
              .map((item) => {
                    'product_id': item.productId,
                    'product_unit_id': item.selectedUnit?.id,
                    'quantity': item.quantity,
                    'unit_cost': item.unitCost,
                  })
              .toList(),
          paidAmount: _isCredit ? _paidAmount : _totalAmount,
          isCredit: _isCredit,
          purchaseDate: DateFormat('yyyy-MM-dd').format(_purchaseDate),
          createdBy: widget.currentUser['id'] as int?,
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_isEditMode ? '✅ পরিবর্তন সংরক্ষিত হয়েছে' : '✅ ক্রয় সফলভাবে সংরক্ষিত হয়েছে')));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('সমস্যা হয়েছে: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _itemRowWidget(int index) {
    final item = _items[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: item.productId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'পণ্য'),
                    items: _products
                        .map((p) => DropdownMenuItem<int>(
                              value: p['id'] as int,
                              child: Text(
                                  '${p['name']}${(p['product_code'] as String? ?? '').isNotEmpty ? " [${p['product_code']}]" : ""}',
                                  overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (val) {
                      final product =
                          _products.firstWhere((p) => p['id'] == val);
                      setState(() {
                        item.productId = val;
                        item.productName = product['name'] as String;
                        item.baseUnit = product['unit'] as String;
                        item.selectedUnit = null;
                        item.availableUnits = [];
                        item.priceIsPerBase = false;
                        item.recomputePrice();
                      });
                      _loadUnitsForRow(item, val as int);
                    },
                  ),
                ),
                if (_items.length > 1)
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.danger),
                    onPressed: () => _removeItemRow(index),
                  ),
              ],
            ),
            if (item.availableUnits.isNotEmpty) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<ProductUnit?>(
                value: item.selectedUnit,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'ক্রয় একক'),
                items: [
                  DropdownMenuItem<ProductUnit?>(
                    value: null,
                    child: Text('সরাসরি ${item.baseUnit} (base unit)'),
                  ),
                  ...item.availableUnits.map((u) => DropdownMenuItem<ProductUnit?>(
                        value: u,
                        child: Text('${u.unitLabel} (= ${u.conversionFactorToBase} ${item.baseUnit})'),
                      )),
                ],
                onChanged: (u) {
                  setState(() {
                    // ক্রয়মূল্যের "প্রতি base unit" মান ধরে রাখা — unit বদলালে দাম নিজে
                    // থেকে রূপান্তর হয় (যেমন কেজি ৳১০০ → গ্রাম ৳০.১)
                    final oldFactor = item.conversionFactor;
                    final perBase = oldFactor > 0 ? item.unitCost / oldFactor : 0.0;
                    item.selectedUnit = u;
                    item.priceIsPerBase = u != null && u.conversionFactorToBase < 1;
                    if (perBase > 0) {
                      item.priceInput = (u == null || item.priceIsPerBase)
                          ? _round6(perBase)
                          : _round6(perBase * item.conversionFactor);
                    }
                    _showPrice(item);
                  });
                },
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: 'পরিমাণ (${item.displayUnitLabel})'),
                    onChanged: (val) =>
                        setState(() => item.quantity = double.tryParse(val) ?? 0),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: item.unitCostController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText:
                            'প্রতি ${item.priceIsPerBase ? item.baseUnit : item.displayUnitLabel} ক্রয়মূল্য'),
                    onChanged: (val) => setState(() {
                      item.priceInput = double.tryParse(val) ?? 0;
                      item.recomputePrice();
                    }),
                  ),
                ),
              ],
            ),
            if (item.selectedUnit != null && item.conversionFactor != 1) ...[
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                      value: false, label: Text('প্রতি ${item.displayUnitLabel}')),
                  ButtonSegment(value: true, label: Text('প্রতি ${item.baseUnit}')),
                ],
                selected: {item.priceIsPerBase},
                onSelectionChanged: (s) => setState(() {
                  final toBase = s.first;
                  if (toBase == item.priceIsPerBase) return;
                  final f = item.conversionFactor;
                  item.priceInput =
                      _round6(toBase ? item.priceInput / f : item.priceInput * f);
                  item.priceIsPerBase = toBase;
                  _showPrice(item);
                }),
              ),
              if (item.unitCost > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'প্রতি ${item.displayUnitLabel}: ৳${_formatPrice(_round6(item.unitCost))}'
                      '  •  প্রতি ${item.baseUnit}: ৳${_formatPrice(_round6(item.unitCost / item.conversionFactor))}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ),
            ],
            if (item.quantity > 0 && item.unitCost > 0) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                    'সাবটোটাল: ৳${(item.quantity * item.unitCost).toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEditMode ? 'ক্রয় সম্পাদনা' : 'নতুন ক্রয়')),
      bottomNavigationBar: _isEditMode
          ? null
          : AppBottomNav(currentTab: AppTab.purchase, currentUser: widget.currentUser),
      body: _prefilling
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PartySelector(
            tableName: 'suppliers',
            label: 'সাপ্লায়ার (ঐচ্ছিক)',
            onSelected: (id) => setState(() => _supplierId = id),
            initialId: _supplierId,
          ),
          const SizedBox(height: 16),
          DateField(
            date: _purchaseDate,
            onChanged: (d) => setState(() => _purchaseDate = d),
          ),
          const SizedBox(height: 16),
          const Text('পণ্য তালিকা', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ..._items.asMap().entries.map((e) => _itemRowWidget(e.key)),
          OutlinedButton.icon(
            onPressed: _addItemRow,
            icon: const Icon(Icons.add),
            label: const Text('আরও পণ্য যোগ করুন'),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('মোট টাকা',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      Text('৳${_totalAmount.toStringAsFixed(0)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 18)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('বাকিতে ক্রয়'),
                    value: _isCredit,
                    onChanged: (val) => setState(() {
                      _isCredit = val;
                      if (!val) _paidAmount = _totalAmount;
                    }),
                  ),
                  if (_isCredit)
                    TextFormField(
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'কত টাকা এখন দিচ্ছেন (নগদ অংশ)'),
                      onChanged: (val) =>
                          setState(() => _paidAmount = double.tryParse(val) ?? 0),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(_isEditMode ? 'পরিবর্তন সংরক্ষণ করুন' : 'ক্রয় সংরক্ষণ করুন'),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
