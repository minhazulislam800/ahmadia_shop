// ============================================================
// returns_screen.dart
// বিক্রয় ফেরত ও ক্রয় ফেরত — দুই ট্যাবে ভাগ করা
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/return_service.dart';
import '../widgets/date_field.dart';

class ReturnsScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const ReturnsScreen({super.key, required this.currentUser});

  @override
  State<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends State<ReturnsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('রিটার্ন/ফেরত'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'বিক্রয় ফেরত'),
            Tab(text: 'ক্রয় ফেরত'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _SaleReturnTab(currentUser: widget.currentUser),
          _PurchaseReturnTab(currentUser: widget.currentUser),
        ],
      ),
    );
  }
}

// ================= বিক্রয় ফেরত ট্যাব =================
class _SaleReturnTab extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const _SaleReturnTab({required this.currentUser});

  @override
  State<_SaleReturnTab> createState() => _SaleReturnTabState();
}

class _SaleReturnTabState extends State<_SaleReturnTab> {
  final _dbHelper = DBHelper.instance;
  final _returnService = ReturnService();
  List<Map<String, dynamic>> _saleItems = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final result = await db.rawQuery('''
      SELECT si.id as sale_item_id, si.quantity, si.unit_price,
             p.name as product_name, p.unit as base_unit,
             pu.unit_label as pack_unit_label,
             s.sale_date, s.id as sale_id, s.is_credit,
             COALESCE((SELECT SUM(sr.quantity) FROM sale_returns sr WHERE sr.sale_item_id = si.id), 0) as already_returned
      FROM sale_items si
      JOIN products p ON p.id = si.product_id
      JOIN sales s ON s.id = si.sale_id
      LEFT JOIN product_units pu ON pu.id = si.product_unit_id
      ORDER BY s.sale_date DESC, si.id DESC
      LIMIT 50
    ''');
    if (!mounted) return;
    setState(() {
      _saleItems = result;
      _loading = false;
    });
  }

  Future<void> _showReturnDialog(Map<String, dynamic> item) async {
    final maxReturnable = (item['quantity'] as num).toDouble() -
        (item['already_returned'] as num).toDouble();
    final qtyController = TextEditingController();
    bool refundToCash = true;
    // নগদ বিক্রয়ে ক্যাশ ফেরত বাধ্যতামূলক; শুধু বাকির বিক্রয়ে বাকি থেকে সমন্বয় চলে
    final isCreditSale = (item['is_credit'] as int? ?? 0) == 1;
    DateTime returnDt = DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('${item['product_name']} — ফেরত'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('সর্বোচ্চ ফেরতযোগ্য: $maxReturnable ${(item['pack_unit_label'] as String?) ?? item['base_unit']}'),
              const SizedBox(height: 12),
              TextField(
                controller: qtyController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'ফেরত পরিমাণ'),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('ক্যাশ থেকে ফেরত দিচ্ছি'),
                subtitle: Text(isCreditSale
                    ? 'বন্ধ রাখলে শুধু বাকির হিসাব সমন্বয় হবে'
                    : 'নগদ বিক্রয় — ক্যাশ ফেরত দিতে হবে'),
                value: refundToCash,
                onChanged: isCreditSale
                    ? (v) => setDialogState(() => refundToCash = v)
                    : null,
              ),
              const SizedBox(height: 4),
              DateField(
                date: returnDt,
                onChanged: (d) => setDialogState(() => returnDt = d),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final qty = double.tryParse(qtyController.text) ?? 0;
                if (qty <= 0 || qty > maxReturnable) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('সঠিক পরিমাণ দিন')));
                  return;
                }
                try {
                  await _returnService.recordSaleReturn(
                    saleItemId: item['sale_item_id'] as int,
                    quantity: qty,
                    refundToCash: refundToCash,
                    returnDate: DateFormat('yyyy-MM-dd').format(returnDt),
                    createdBy: widget.currentUser['id'] as int?,
                  );
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  _load();
                } catch (e) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx)
                      .showSnackBar(SnackBar(content: Text('$e')));
                }
              },
              child: const Text('ফেরত সংরক্ষণ করুন'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final items = _saleItems
        .where((i) =>
            (i['quantity'] as num).toDouble() >
            (i['already_returned'] as num).toDouble())
        .toList();
    if (items.isEmpty) {
      return const Center(child: Text('ফেরতযোগ্য কোনো বিক্রয় নেই'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            title: Text(item['product_name'] as String),
            subtitle: Text(
                'বিক্রয় #${item['sale_id']} • ${item['sale_date']} • ${item['quantity']} ${(item['pack_unit_label'] as String?) ?? item['base_unit']}'),
            trailing: TextButton(
              onPressed: () => _showReturnDialog(item),
              child: const Text('ফেরত'),
            ),
          ),
        );
      },
    );
  }
}

// ================= ক্রয় ফেরত ট্যাব =================
class _PurchaseReturnTab extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const _PurchaseReturnTab({required this.currentUser});

  @override
  State<_PurchaseReturnTab> createState() => _PurchaseReturnTabState();
}

class _PurchaseReturnTabState extends State<_PurchaseReturnTab> {
  final _dbHelper = DBHelper.instance;
  final _returnService = ReturnService();
  List<Map<String, dynamic>> _batches = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final result = await db.rawQuery('''
      SELECT pb.id as batch_id, pb.remaining_quantity, pb.unit_cost, pb.batch_date,
             p.name as product_name, p.unit,
             COALESCE(pr.is_credit, 0) as is_credit
      FROM purchase_batches pb
      JOIN products p ON p.id = pb.product_id
      LEFT JOIN purchases pr ON pr.id = pb.purchase_id
      WHERE pb.remaining_quantity > 0
      ORDER BY pb.batch_date DESC
      LIMIT 50
    ''');
    if (!mounted) return;
    setState(() {
      _batches = result;
      _loading = false;
    });
  }

  Future<void> _showReturnDialog(Map<String, dynamic> batch) async {
    final maxReturnable = (batch['remaining_quantity'] as num).toDouble();
    final qtyController = TextEditingController();
    bool refundToCash = true;
    // নগদে কেনা মালের ফেরতে ক্যাশ ফেরত বাধ্যতামূলক; শুধু বাকির ক্রয়ে দেনা থেকে সমন্বয় চলে
    final isCreditPurchase = (batch['is_credit'] as int? ?? 0) == 1;
    DateTime returnDt = DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('${batch['product_name']} — সাপ্লায়ারে ফেরত'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('স্টকে আছে: $maxReturnable ${batch['unit']}'),
              const SizedBox(height: 12),
              TextField(
                controller: qtyController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'ফেরত পরিমাণ'),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('সাপ্লায়ার থেকে ক্যাশ ফেরত পাচ্ছি'),
                subtitle: Text(isCreditPurchase
                    ? 'বন্ধ রাখলে শুধু দেনার হিসাব সমন্বয় হবে'
                    : 'নগদে কেনা — ক্যাশ ফেরত নিতে হবে'),
                value: refundToCash,
                onChanged: isCreditPurchase
                    ? (v) => setDialogState(() => refundToCash = v)
                    : null,
              ),
              const SizedBox(height: 4),
              DateField(
                date: returnDt,
                onChanged: (d) => setDialogState(() => returnDt = d),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final qty = double.tryParse(qtyController.text) ?? 0;
                if (qty <= 0 || qty > maxReturnable) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('সঠিক পরিমাণ দিন')));
                  return;
                }
                try {
                  await _returnService.recordPurchaseReturn(
                    purchaseBatchId: batch['batch_id'] as int,
                    quantity: qty,
                    refundToCash: refundToCash,
                    returnDate: DateFormat('yyyy-MM-dd').format(returnDt),
                    createdBy: widget.currentUser['id'] as int?,
                  );
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  _load();
                } catch (e) {
                  ScaffoldMessenger.of(ctx)
                      .showSnackBar(SnackBar(content: Text('$e')));
                }
              },
              child: const Text('ফেরত সংরক্ষণ করুন'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_batches.isEmpty) {
      return const Center(child: Text('ফেরতযোগ্য কোনো ক্রয় নেই'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _batches.length,
      itemBuilder: (ctx, i) {
        final batch = _batches[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            title: Text(batch['product_name'] as String),
            subtitle: Text(
                '${batch['batch_date']} • স্টক: ${batch['remaining_quantity']} ${batch['unit']}'),
            trailing: TextButton(
              onPressed: () => _showReturnDialog(batch),
              child: const Text('ফেরত'),
            ),
          ),
        );
      },
    );
  }
}
