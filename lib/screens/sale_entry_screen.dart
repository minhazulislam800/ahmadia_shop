// ============================================================
// sale_entry_screen.dart
// একাধিক পণ্য একসাথে বিক্রয় করার ফর্ম — সাবমিট করলে
// TransactionService.recordSale() কল হয়ে FIFO অনুযায়ী স্টক
// কাটা হয় এবং গ্রস প্রফিট স্বয়ংক্রিয়ভাবে হিসাব হয়ে যায়।
// স্টক অপর্যাপ্ত হলে সংরক্ষণই হবে না (নেগেটিভ স্টক প্রতিরোধ)।
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../models/product_unit.dart';
import '../utils/app_theme.dart';
import '../utils/quantity_math.dart';
import '../widgets/party_selector.dart';
import '../widgets/date_field.dart';
import 'invoice_screen.dart';
import '../widgets/app_bottom_nav.dart';

class SaleEntryScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final int? editSaleId; // দেওয়া হলে screen "edit mode"-এ খুলবে
  const SaleEntryScreen({super.key, required this.currentUser, this.editSaleId});

  @override
  State<SaleEntryScreen> createState() => _SaleEntryScreenState();
}

class _SaleItemRow {
  int? productId;
  String productName = '';
  String baseUnit = ''; // product-এর base unit (stock এই এককে থাকে)
  double availableStock = 0; // base unit-এ
  // Phase 1 (multi-unit): null = সরাসরি base unit-এ বিক্রি, নাহলে
  // নির্বাচিত pack-এর ProductUnit
  ProductUnit? selectedUnit;
  List<ProductUnit> availableUnits = [];
  double quantity = 0; // নির্বাচিত unit-এ (pack হলে pack-সংখ্যা, নাহলে base-এ)
  double unitPrice = 0;
  final TextEditingController unitPriceController = TextEditingController();

  // এই row-এ যে unit-ই নির্বাচিত হোক, কত base-unit লাগবে তার হিসাব
  double get conversionFactor => selectedUnit?.conversionFactorToBase ?? 1;
  double get baseQuantity =>
      QuantityMath.toBase(quantity, conversionFactor);
  String get displayUnitLabel => selectedUnit?.unitLabel ?? baseUnit;
  // এই unit-এ সর্বোচ্চ কত বিক্রি করা যাবে (স্টক অনুযায়ী), UX হিন্টের জন্য
  double get maxQuantityInSelectedUnit =>
      conversionFactor == 0 ? 0 : availableStock / conversionFactor;
}

class _SaleEntryScreenState extends State<SaleEntryScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();

  List<Map<String, dynamic>> _products = [];
  final List<_SaleItemRow> _items = [_SaleItemRow()];
  int? _customerId;
  bool _isCredit = false;
  double _paidAmount = 0;
  double _courierCharge = 0;
  DateTime _saleDate = DateTime.now();
  bool _saving = false;
  String _saleType = 'retail'; // 'retail' অথবা 'wholesale'
  late bool _prefilling = widget.editSaleId != null; // edit mode-এ পুরনো ডেটা লোড হওয়ার সময়

  bool get _isEditMode => widget.editSaleId != null;

  double get _totalAmount =>
      _items.fold(0, (sum, item) => sum + (item.quantity * item.unitPrice));

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadProducts();
    if (_isEditMode) {
      await _prefillFromExistingSale(widget.editSaleId!);
    }
  }

  // Phase 2 — বিক্রয় edit: পুরনো sale-এর ডেটা ফর্মে লোড করা।
  // availableStock হিসাব করার সময় এই sale-এর নিজের বরাদ্দকৃত quantity
  // ফেরত যোগ করা হয় (যেন মনে হয় যেন এই sale-টা এখনো হয়নি) — নাহলে
  // একই quantity দিয়ে re-save করতে গেলেও ভুলভাবে "স্টক নেই" দেখাবে,
  // কারণ আসল স্টক ইতিমধ্যে এই sale-এর জন্য কমে আছে।
  Future<void> _prefillFromExistingSale(int saleId) async {
    setState(() => _prefilling = true);
    final db = await _dbHelper.database;
    final saleRows = await db.query('sales', where: 'id = ?', whereArgs: [saleId]);
    if (saleRows.isEmpty) {
      if (!mounted) return;
      setState(() => _prefilling = false);
      return;
    }
    final sale = saleRows.first;
    final items = await db.query('sale_items', where: 'sale_id = ?', whereArgs: [saleId]);

    final newItems = <_SaleItemRow>[];
    for (final si in items) {
      final productId = si['product_id'] as int;
      final product = _products.firstWhere((p) => p['id'] == productId,
          orElse: () => <String, dynamic>{});
      final row = _SaleItemRow()
        ..productId = productId
        ..productName = product['name'] as String? ?? ''
        ..baseUnit = product['unit'] as String? ?? ''
        ..quantity = (si['quantity'] as num).toDouble()
        ..unitPrice = (si['unit_price'] as num).toDouble();
      row.unitPriceController.text = _formatPrice(row.unitPrice);

      final currentStock = (product['stock'] as num?)?.toDouble() ?? 0;
      final originalBaseQty = (si['base_quantity'] as num?)?.toDouble() ??
          (si['quantity'] as num).toDouble();
      row.availableStock = currentStock + originalBaseQty; // এই sale ফেরত ধরে

      final productUnitId = si['product_unit_id'] as int?;
      final unitRows = await db.query('product_units',
          where: 'product_id = ?', whereArgs: [productId]);
      row.availableUnits = unitRows
          .map((r) => ProductUnit.fromMap(r))
          .where((u) => u.isActive)
          .toList();
      if (productUnitId != null) {
        final matchRows = unitRows.where((r) => r['id'] == productUnitId);
        if (matchRows.isNotEmpty) {
          final pu = ProductUnit.fromMap(matchRows.first);
          row.selectedUnit = pu;
          // নিষ্ক্রিয় করা unit হলেও এই sale-এর জন্য dropdown-এ দেখানো দরকার
          if (!row.availableUnits.any((u) => u.id == pu.id)) {
            row.availableUnits = [...row.availableUnits, pu];
          }
        }
      }
      newItems.add(row);
    }

    if (!mounted) return;
    setState(() {
      _customerId = sale['customer_id'] as int?;
      _courierCharge = (sale['courier_charge'] as num?)?.toDouble() ?? 0;
      _isCredit = (sale['is_credit'] as int? ?? 0) == 1;
      _paidAmount = (sale['paid_amount'] as num?)?.toDouble() ?? 0;
      _saleType = sale['sale_type'] as String? ?? 'retail';
      _saleDate = DateTime.tryParse(sale['sale_date'] as String) ?? DateTime.now();
      _items
        ..clear()
        ..addAll(newItems.isEmpty ? [_SaleItemRow()] : newItems);
      _prefilling = false;
    });
  }

  Future<void> _loadProducts() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery('''
      SELECT p.*, COALESCE(SUM(pb.remaining_quantity), 0) as stock
      FROM products p
      LEFT JOIN purchase_batches pb ON pb.product_id = p.id
      WHERE p.is_active = 1
      GROUP BY p.id
      ORDER BY p.name ASC
    ''');
    setState(() => _products = result);
  }

  void _addItemRow() => setState(() => _items.add(_SaleItemRow()));
  void _removeItemRow(int index) => setState(() => _items.removeAt(index));

  // Phase 1 (multi-unit): কোনো product বেছে নেওয়া হলে তার pack unit-গুলো
  // লোড করে row-তে বসিয়ে দেওয়া, ডিফল্ট pack (থাকলে) আগে থেকেই সিলেক্ট করা
  Future<void> _loadUnitsForRow(_SaleItemRow item, int productId) async {
    final db = await _dbHelper.database;
    final rows = await db.query('product_units',
        where: 'product_id = ? AND is_active = 1',
        whereArgs: [productId],
        orderBy: 'conversion_factor_to_base ASC');
    final units = rows.map((r) => ProductUnit.fromMap(r)).toList();
    if (!mounted) return;
    setState(() {
      item.availableUnits = units;
      ProductUnit? defaultUnit;
      for (final u in units) {
        if (u.isDefault) {
          defaultUnit = u;
          break;
        }
      }
      item.selectedUnit = defaultUnit;
      if (defaultUnit?.sellingPrice != null) {
        item.unitPrice = defaultUnit!.sellingPrice!;
        item.unitPriceController.text = _formatPrice(item.unitPrice);
      }
    });
  }

  String _formatPrice(double price) => price == price.roundToDouble()
      ? price.toInt().toString()
      : price.toString();

  Future<void> _save() async {
    final validItems =
        _items.where((item) => item.productId != null && item.quantity > 0).toList();

    if (validItems.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('কমপক্ষে একটা পণ্য যোগ করুন')));
      return;
    }

    // বাকির বিক্রয়ে কাস্টমার থাকতেই হবে (নাহলে বাকি কার কাছে পাওনা বোঝা যায় না),
    // আর জমা টাকা মোট বিলের বেশি/ঋণাত্মক হতে পারে না
    if (_isCredit) {
      if (_customerId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('বাকির বিক্রয়ে কাস্টমার নির্বাচন করুন')));
        return;
      }
      if (_paidAmount < 0 || _paidAmount > _totalAmount + 0.005) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('জমার পরিমাণ ০ থেকে মোট বিলের মধ্যে হতে হবে')));
        return;
      }
    }

    // ফর্ম-স্তরেই একটা প্রাথমিক স্টক-চেক (ভালো UX-এর জন্য), আসল প্রতিরোধ
    // TransactionService/FIFO ইঞ্জিনেই হয় (ডাটাবেস transaction-এর ভেতরে)
    for (final item in validItems) {
      if (item.baseQuantity > item.availableStock) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '"${item.productName}"-এ পর্যাপ্ত স্টক নেই (আছে: ${item.availableStock} ${item.baseUnit})')));
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final int saleId;
      if (_isEditMode) {
        saleId = await _transactionService.editSale(
          saleId: widget.editSaleId!,
          editedBy: widget.currentUser['id'] as int?,
          customerId: _customerId,
          items: validItems
              .map((item) => {
                    'product_id': item.productId,
                    'product_unit_id': item.selectedUnit?.id,
                    'quantity': item.quantity,
                    'unit_price': item.unitPrice,
                  })
              .toList(),
          courierCharge: _courierCharge,
          paidAmount: _isCredit ? _paidAmount : _totalAmount,
          isCredit: _isCredit,
          saleType: _saleType,
          saleDate: DateFormat('yyyy-MM-dd').format(_saleDate),
        );
      } else {
        saleId = await _transactionService.recordSale(
          customerId: _customerId,
          items: validItems
              .map((item) => {
                    'product_id': item.productId,
                    'product_unit_id': item.selectedUnit?.id,
                    'quantity': item.quantity,
                    'unit_price': item.unitPrice,
                  })
              .toList(),
          courierCharge: _courierCharge,
          paidAmount: _isCredit ? _paidAmount : _totalAmount,
          isCredit: _isCredit,
          saleDate: DateFormat('yyyy-MM-dd').format(_saleDate),
          createdBy: widget.currentUser['id'] as int?,
          saleType: _saleType,
        );
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => InvoiceScreen(saleId: saleId)),
      );
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
                                  '${p['name']}${(p['product_code'] as String? ?? '').isNotEmpty ? " [${p['product_code']}]" : ""} (স্টক: ${p['stock']} ${p['unit']})',
                                  overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (val) {
                      final product = _products.firstWhere((p) => p['id'] == val);
                      final autoPrice = _saleType == 'wholesale'
                          ? product['wholesale_price']
                          : product['retail_price'];
                      setState(() {
                        item.productId = val;
                        item.productName = product['name'] as String;
                        item.baseUnit = product['unit'] as String;
                        item.availableStock = (product['stock'] as num).toDouble();
                        item.selectedUnit = null;
                        item.availableUnits = [];
                        if (autoPrice != null) {
                          item.unitPrice = (autoPrice as num).toDouble();
                          item.unitPriceController.text = _formatPrice(item.unitPrice);
                        }
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
                decoration: const InputDecoration(labelText: 'বিক্রয় একক'),
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
                    item.selectedUnit = u;
                    if (u?.sellingPrice != null) {
                      item.unitPrice = u!.sellingPrice!;
                      item.unitPriceController.text = _formatPrice(item.unitPrice);
                    }
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
                    controller: item.unitPriceController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: 'প্রতি ${item.displayUnitLabel} মূল্য'),
                    onChanged: (val) =>
                        setState(() => item.unitPrice = double.tryParse(val) ?? 0),
                  ),
                ),
              ],
            ),
            if (item.baseQuantity > item.availableStock && item.availableStock > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    '⚠️ স্টকে আছে মাত্র ${item.availableStock} ${item.baseUnit}'
                    ' (≈ ${item.maxQuantityInSelectedUnit.toStringAsFixed(2)} ${item.displayUnitLabel})',
                    style: const TextStyle(color: AppColors.danger, fontSize: 12)),
              ),
            if (item.quantity > 0 && item.unitPrice > 0) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                    'সাবটোটাল: ৳${(item.quantity * item.unitPrice).toStringAsFixed(0)}',
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
      appBar: AppBar(title: Text(_isEditMode ? 'বিক্রয় সম্পাদনা' : 'নতুন বিক্রয়')),
      bottomNavigationBar: _isEditMode
          ? null
          : AppBottomNav(currentTab: AppTab.sale, currentUser: widget.currentUser),
      body: _prefilling
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PartySelector(
            tableName: 'customers',
            label: 'কাস্টমার (ঐচ্ছিক)',
            onSelected: (id) => setState(() => _customerId = id),
            phoneRequired: true,
            initialId: _customerId,
          ),
          const SizedBox(height: 16),
          DateField(
            date: _saleDate,
            onChanged: (d) => setState(() => _saleDate = d),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'retail', label: Text('খুচরা'), icon: Icon(Icons.shopping_bag_outlined)),
              ButtonSegment(value: 'wholesale', label: Text('পাইকারি'), icon: Icon(Icons.local_shipping_outlined)),
            ],
            selected: {_saleType},
            onSelectionChanged: (selection) {
              setState(() => _saleType = selection.first);
              // ইতিমধ্যে বেছে নেওয়া পণ্যগুলোর দাম নতুন ধরন অনুযায়ী আপডেট করা
              // (pack unit-এর নিজস্ব fixed দাম থাকলে সেটাই অগ্রাধিকার পাবে)
              for (final item in _items) {
                if (item.productId == null) continue;
                if (item.selectedUnit?.sellingPrice != null) continue;
                final product = _products.firstWhere((p) => p['id'] == item.productId);
                final autoPrice =
                    _saleType == 'wholesale' ? product['wholesale_price'] : product['retail_price'];
                if (autoPrice != null) {
                  item.unitPrice = (autoPrice as num).toDouble();
                  item.unitPriceController.text = _formatPrice(item.unitPrice);
                }
              }
              setState(() {});
            },
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
          const SizedBox(height: 16),
          // §5.২ Progressive disclosure — courier charge বেশিরভাগ বিক্রয়ে
          // লাগে না (শুধু কুরিয়ারে পাঠানো হলে), তাই ডিফল্টে লুকানো থাকবে
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('আরও অপশন', style: TextStyle(fontSize: 14)),
              initiallyExpanded: _courierCharge > 0,
              children: [
                TextFormField(
                  initialValue:
                      _courierCharge > 0 ? _courierCharge.toStringAsFixed(0) : null,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'কুরিয়ার চার্জ (ইনভয়েসে দেখাবে, ক্যাশে প্রভাব নেই)'),
                  onChanged: (val) => setState(() => _courierCharge = double.tryParse(val) ?? 0),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('মোট টাকা (পণ্য)',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      Text('৳${_totalAmount.toStringAsFixed(0)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 18)),
                    ],
                  ),
                  if (_courierCharge > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('কুরিয়ার চার্জ (তথ্যগত)',
                              style: TextStyle(color: AppColors.textSecondary)),
                          Text('৳${_courierCharge.toStringAsFixed(0)}',
                              style: const TextStyle(color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('বাকিতে বিক্রয়'),
                    value: _isCredit,
                    onChanged: (val) => setState(() {
                      _isCredit = val;
                      if (!val) _paidAmount = _totalAmount;
                    }),
                  ),
                  if (_isCredit)
                    TextFormField(
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'কাস্টমার এখন কত টাকা দিচ্ছেন'),
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
                : Text(_isEditMode
                    ? 'পরিবর্তন সংরক্ষণ করুন'
                    : 'বিক্রয় সংরক্ষণ করুন ও ইনভয়েস দেখুন'),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
