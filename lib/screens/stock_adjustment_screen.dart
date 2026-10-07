// ============================================================
// stock_adjustment_screen.dart
// মূল ব্রিফের §7 অনুযায়ী আলাদা "Stock Adjustment" মেনু — নষ্ট/ঘাটতি/
// অতিরিক্ত পাওয়া/Gift/Sample/Internal use ইত্যাদি কারণে stock
// সমন্বয় করার জন্য। ব্যাকএন্ড (TransactionService.recordStockAdjustment)
// Phase 1-এই multi-unit-aware করা হয়েছে — এই screen শুধু তার UI।
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../models/product_unit.dart';
import '../utils/app_theme.dart';
import '../widgets/date_field.dart';

class StockAdjustmentScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const StockAdjustmentScreen({super.key, required this.currentUser});

  @override
  State<StockAdjustmentScreen> createState() => _StockAdjustmentScreenState();
}

// UI-তে দেখানোর জন্য reason-এর বাংলা লেবেল + এর sign (স্টক কমবে/বাড়বে)।
// 'other'-এর জন্য sign নির্দিষ্ট নয় — ব্যবহারকারী নিজে বেছে নেবে।
class _ReasonOption {
  final String value;
  final String label;
  final bool? decreasesStock; // true=কমে, false=বাড়ে, null='other' (নিজে বাছাই)
  const _ReasonOption(this.value, this.label, this.decreasesStock);
}

const List<_ReasonOption> _reasonOptions = [
  _ReasonOption('damaged', 'নষ্ট পণ্য', true),
  _ReasonOption('shortage', 'ঘাটতি', true),
  _ReasonOption('gift', 'Gift', true),
  _ReasonOption('sample', 'Sample', true),
  _ReasonOption('internal_use', 'Internal use', true),
  _ReasonOption('excess_found', 'অতিরিক্ত পাওয়া', false),
  _ReasonOption('other', 'অন্যান্য', null),
];

class _StockAdjustmentScreenState extends State<StockAdjustmentScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();
  final _currencyFormat =
      NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);

  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _recentAdjustments = [];
  bool _loading = true;
  bool _saving = false;

  int? _productId;
  String _baseUnit = '';
  double _availableStock = 0;
  ProductUnit? _selectedUnit;
  List<ProductUnit> _availableUnits = [];
  final _quantityController = TextEditingController();
  final _noteController = TextEditingController();
  final _estimatedCostController = TextEditingController();
  DateTime _adjustmentDate = DateTime.now();
  _ReasonOption _reason = _reasonOptions.first;
  bool _decreasesStock = true; // 'other' নির্বাচিত হলে toggle-এ ব্যবহারকারী বদলাতে পারবে

  @override
  void initState() {
    super.initState();
    _load();
  }

  // এন্ট্রি এডিট: কারণ, পরিমাণ, তারিখ, নোট বদলানো যায়। পণ্য ও স্টক
  // কমবে/বাড়বে — এই দিক বদলানো যায় না (উল্টোটা লাগলে নতুন এন্ট্রি দিন)
  Future<void> _showEditDialog(Map<String, dynamic> a) async {
    final qtySigned = (a['quantity'] as num).toDouble();
    final isLoss = (a['base_quantity'] as num).toDouble() < 0;
    final baseUnitName = a['base_unit'] as String;
    // এই পণ্যের সক্রিয় এককগুলো (কেজি/গ্রাম ইত্যাদি) — এডিটে এককও বদলানো যায়
    final unitRows = await (await _dbHelper.database).query('product_units',
        where: 'product_id = ? AND is_active = 1',
        whereArgs: [a['product_id']],
        orderBy: 'conversion_factor_to_base ASC');
    final units = unitRows.map((r) => ProductUnit.fromMap(r)).toList();
    int? selectedUnitId = a['product_unit_id'] as int?;
    final options = _reasonOptions
        .where((r) => r.decreasesStock == null || r.decreasesStock == isLoss)
        .toList();
    var reason = options.any((r) => r.value == a['reason'])
        ? a['reason'] as String
        : options.first.value;
    final qtyController = TextEditingController(
        text: qtySigned.abs().toString().replaceFirst(RegExp(r'\.0$'), ''));
    final noteController = TextEditingController(text: a['note'] as String? ?? '');
    DateTime date = DateTime.tryParse(a['adjustment_date'] as String) ?? DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('${a['product_name']} — সম্পাদনা'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(isLoss ? 'স্টক কমেছে (ক্ষতি/ব্যবহার)' : 'স্টক বেড়েছে (অতিরিক্ত পাওয়া)',
                    style: const TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: reason,
                  decoration: const InputDecoration(labelText: 'কারণ'),
                  items: options
                      .map((r) => DropdownMenuItem(value: r.value, child: Text(r.label)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => reason = v!),
                ),
                const SizedBox(height: 12),
                if (units.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: Text(baseUnitName),
                        selected: selectedUnitId == null,
                        onSelected: (_) =>
                            setDialogState(() => selectedUnitId = null),
                      ),
                      ...units.map((u) => ChoiceChip(
                            label: Text(u.unitLabel),
                            selected: selectedUnitId == u.id,
                            onSelected: (_) =>
                                setDialogState(() => selectedUnitId = u.id),
                          )),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText:
                          'পরিমাণ (${selectedUnitId == null ? baseUnitName : units.firstWhere((u) => u.id == selectedUnitId, orElse: () => units.first).unitLabel})'),
                ),
                const SizedBox(height: 12),
                DateField(
                  date: date,
                  onChanged: (d) => setDialogState(() => date = d),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(labelText: 'নোট (ঐচ্ছিক)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final qty = double.tryParse(qtyController.text) ?? 0;
                if (qty <= 0) return;
                try {
                  await _transactionService.editStockAdjustment(
                    adjustmentId: a['id'] as int,
                    newQuantityAbs: qty,
                    newProductUnitId: selectedUnitId,
                    reason: reason,
                    note: noteController.text.trim(),
                    date: DateFormat('yyyy-MM-dd').format(date),
                    editedBy: widget.currentUser['id'] as int?,
                  );
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  _load();
                } catch (e) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text(
                          '$e'.replaceFirst('Exception: ', ''))));
                }
              },
              child: const Text('সংরক্ষণ করুন'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _load() async {
    final db = await _dbHelper.database;
    final products = await db.rawQuery('''
      SELECT p.*, COALESCE(SUM(pb.remaining_quantity), 0) as current_stock
      FROM products p
      LEFT JOIN purchase_batches pb ON pb.product_id = p.id
      WHERE p.is_active = 1
      GROUP BY p.id
      ORDER BY p.name ASC
    ''');
    // §7: সাম্প্রতিক adjustment-গুলো — কারণ অনুযায়ী আলাদা করে বোঝার জন্য
    final recent = await db.rawQuery('''
      SELECT sa.*, p.name as product_name, p.unit as base_unit,
             pu.unit_label as pack_unit_label,
             u.username as created_by_name
      FROM stock_adjustments sa
      JOIN products p ON p.id = sa.product_id
      LEFT JOIN product_units pu ON pu.id = sa.product_unit_id
      LEFT JOIN users u ON u.id = sa.created_by
      ORDER BY sa.id DESC
      LIMIT 30
    ''');
    if (!mounted) return;
    setState(() {
      _products = products;
      _recentAdjustments = recent;
      _loading = false;
    });
  }

  Future<void> _loadUnitsForProduct(int productId) async {
    final db = await _dbHelper.database;
    final rows = await db.query('product_units',
        where: 'product_id = ? AND is_active = 1',
        whereArgs: [productId],
        orderBy: 'conversion_factor_to_base ASC');
    if (!mounted) return;
    setState(() => _availableUnits =
        rows.map((r) => ProductUnit.fromMap(r)).toList());
  }

  String get _unitLabel => _selectedUnit?.unitLabel ?? _baseUnit;

  Future<void> _save() async {
    final qty = double.tryParse(_quantityController.text.trim());
    if (_productId == null || qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('পণ্য ও সঠিক পরিমাণ দিন')));
      return;
    }

    final signedQty = _decreasesStock ? -qty : qty;
    final estimatedCost = _reason.value == 'excess_found'
        ? double.tryParse(_estimatedCostController.text.trim())
        : null;

    setState(() => _saving = true);
    try {
      await _transactionService.recordStockAdjustment(
        productId: _productId!,
        productUnitId: _selectedUnit?.id,
        quantity: signedQty,
        reason: _reason.value,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
        date: DateFormat('yyyy-MM-dd').format(_adjustmentDate),
        createdBy: widget.currentUser['id'] as int?,
        estimatedUnitCost: estimatedCost,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('স্টক অ্যাডজাস্টমেন্ট সংরক্ষিত হয়েছে')));
      setState(() {
        _productId = null;
        _selectedUnit = null;
        _availableUnits = [];
        _quantityController.clear();
        _noteController.clear();
        _estimatedCostController.clear();
        _reason = _reasonOptions.first;
        _decreasesStock = true;
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('ব্যর্থ: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('স্টক অ্যাডজাস্টমেন্ট')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('নতুন এন্ট্রি',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16)),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          value: _productId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'পণ্য'),
                          items: _products
                              .map((p) => DropdownMenuItem<int>(
                                    value: p['id'] as int,
                                    child: Text(
                                        '${p['name']} (স্টক: ${p['current_stock']} ${p['unit']})',
                                        overflow: TextOverflow.ellipsis),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            final product =
                                _products.firstWhere((p) => p['id'] == val);
                            setState(() {
                              _productId = val;
                              _baseUnit = product['unit'] as String;
                              _availableStock =
                                  (product['current_stock'] as num).toDouble();
                              _selectedUnit = null;
                              _availableUnits = [];
                            });
                            _loadUnitsForProduct(val as int);
                          },
                        ),
                        if (_availableUnits.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Text('একক',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.textSecondary)),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              ChoiceChip(
                                label: Text(_baseUnit),
                                selected: _selectedUnit == null,
                                onSelected: (_) =>
                                    setState(() => _selectedUnit = null),
                              ),
                              ..._availableUnits.map((u) => ChoiceChip(
                                    label: Text(u.unitLabel),
                                    selected: _selectedUnit == u,
                                    onSelected: (_) =>
                                        setState(() => _selectedUnit = u),
                                  )),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                        DropdownButtonFormField<_ReasonOption>(
                          value: _reason,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'কারণ'),
                          items: _reasonOptions
                              .map((r) => DropdownMenuItem(
                                  value: r, child: Text(r.label)))
                              .toList(),
                          onChanged: (r) {
                            if (r == null) return;
                            setState(() {
                              _reason = r;
                              if (r.decreasesStock != null) {
                                _decreasesStock = r.decreasesStock!;
                              }
                            });
                          },
                        ),
                        if (_reason.value == 'other') ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('স্টক: '),
                              ChoiceChip(
                                label: const Text('কমছে'),
                                selected: _decreasesStock,
                                onSelected: (v) =>
                                    setState(() => _decreasesStock = true),
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: const Text('বাড়ছে'),
                                selected: !_decreasesStock,
                                onSelected: (v) =>
                                    setState(() => _decreasesStock = false),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _quantityController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                              labelText: 'পরিমাণ ($_unitLabel)'),
                        ),
                        if (!_decreasesStock && _reason.value == 'excess_found') ...[
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _estimatedCostController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                                labelText:
                                    'অনুমিত ক্রয়মূল্য প্রতি $_unitLabel (ঐচ্ছিক, না দিলে ৳0 ধরা হবে)'),
                          ),
                        ],
                        const SizedBox(height: 8),
                        DateField(
                          date: _adjustmentDate,
                          onChanged: (d) => setState(() => _adjustmentDate = d),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _noteController,
                          decoration:
                              const InputDecoration(labelText: 'নোট (ঐচ্ছিক)'),
                        ),
                        if (_decreasesStock &&
                            _productId != null &&
                            _availableStock > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                                'স্টকে আছে: $_availableStock $_baseUnit',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary)),
                          ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Text('সংরক্ষণ করুন'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('সাম্প্রতিক এন্ট্রি',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 8),
                if (_recentAdjustments.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('এখনো কোনো এন্ট্রি নেই।'),
                  )
                else
                  ..._recentAdjustments.map((a) {
                    final qty = (a['quantity'] as num).toDouble();
                    final label = (a['pack_unit_label'] as String?) ??
                        (a['base_unit'] as String);
                    final reasonLabel = _reasonOptions
                        .firstWhere((r) => r.value == a['reason'],
                            orElse: () => _ReasonOption(
                                a['reason'] as String, a['reason'] as String, null))
                        .label;
                    final cost = (a['total_cost'] as num?)?.toDouble() ?? 0;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        dense: true,
                        onTap: () => _showEditDialog(a),
                        title: Text('${a['product_name']} — $reasonLabel'),
                        subtitle: Text(
                            '${qty > 0 ? "+" : ""}$qty $label • ${a['adjustment_date']}'
                            '${a['created_by_name'] != null ? " • ${a['created_by_name']}" : ""}'
                            '${(a['note'] as String?)?.isNotEmpty == true ? "\n${a['note']}" : ""}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (cost != 0)
                              Text(_currencyFormat.format(cost),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            const SizedBox(width: 4),
                            const Icon(Icons.edit_outlined,
                                size: 16, color: AppColors.textSecondary),
                          ],
                        ),
                        isThreeLine: (a['note'] as String?)?.isNotEmpty == true,
                      ),
                    );
                  }),
              ],
            ),
    );
  }
}
