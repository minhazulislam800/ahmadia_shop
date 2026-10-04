// ============================================================
// supplier_ledger_screen.dart
// সাপ্লায়ারের তালিকা (দেনা অনুযায়ী), প্রতিজনের ক্রয়ের ইতিহাস,
// আর দেনা শোধ করার বাটন
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../utils/app_theme.dart';
import '../widgets/date_field.dart';
import 'purchase_entry_screen.dart';

class SupplierLedgerScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const SupplierLedgerScreen({super.key, required this.currentUser});

  @override
  State<SupplierLedgerScreen> createState() => _SupplierLedgerScreenState();
}

class _SupplierLedgerScreenState extends State<SupplierLedgerScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();
  final _currencyFormat = NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);
  List<Map<String, dynamic>> _suppliers = [];
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
      SELECT s.*,
        COALESCE((SELECT SUM(total_amount) FROM purchases WHERE supplier_id = s.id), 0) as total_purchase,
        COALESCE((SELECT SUM(total_amount - paid_amount) FROM purchases WHERE supplier_id = s.id AND is_credit = 1), 0)
        - COALESCE((SELECT SUM(amount) FROM due_payments WHERE party_type = 'supplier' AND party_id = s.id), 0) as due
      FROM suppliers s
      ORDER BY due DESC
    ''');
    if (!mounted) return;
    setState(() {
      _suppliers = result;
      _loading = false;
    });
  }

  Future<void> _showPayDueDialog(Map<String, dynamic> supplier, double due) async {
    final amountController = TextEditingController();
    DateTime paymentDate = DateTime.now();
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) => AlertDialog(
        title: Text('${supplier['name']} — দেনা শোধ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('মোট দেনা: ${_currencyFormat.format(due)}'),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'কত টাকা দিচ্ছেন'),
            ),
            const SizedBox(height: 12),
            DateField(
              date: paymentDate,
              onChanged: (d) => setDialogState(() => paymentDate = d),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final amount = double.tryParse(amountController.text) ?? 0;
              if (amount <= 0) return;
              if (amount > due + 0.005) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: Text(
                        'দেনার চেয়ে বেশি দেওয়া যাবে না (দেনা: ${_currencyFormat.format(due)})')));
                return;
              }
              await _transactionService.recordDuePayment(
                partyType: 'supplier',
                partyId: supplier['id'] as int,
                referenceType: 'manual',
                referenceId: null,
                amount: amount,
                date: DateFormat('yyyy-MM-dd').format(paymentDate),
                createdBy: widget.currentUser['id'] as int?,
              );
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _load();
            },
            child: const Text('পরিশোধ সংরক্ষণ করুন'),
          ),
        ],
      )),
    );
  }

  bool get _isMaster => widget.currentUser['role'] == 'master';

  // §6: নাম/ফোন/ঠিকানা edit — পুরনো ক্রয়ের ইতিহাসে কোনো প্রভাব পড়বে না
  Future<void> _showEditSupplierDialog(Map<String, dynamic> supplier) async {
    final nameController = TextEditingController(text: supplier['name'] as String);
    final phoneController =
        TextEditingController(text: supplier['phone'] as String? ?? '');
    final addressController =
        TextEditingController(text: supplier['address'] as String? ?? '');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('সাপ্লায়ার তথ্য সম্পাদনা'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'নাম')),
            const SizedBox(height: 12),
            TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration:
                    const InputDecoration(labelText: 'ফোন নম্বর (ঐচ্ছিক)')),
            const SizedBox(height: 12),
            TextField(
                controller: addressController,
                decoration: const InputDecoration(labelText: 'ঠিকানা (ঐচ্ছিক)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(const SnackBar(content: Text('নাম আবশ্যক')));
                return;
              }
              final db = await _dbHelper.database;
              await db.update(
                  'suppliers',
                  {
                    'name': name,
                    'phone': phoneController.text.trim(),
                    'address': addressController.text.trim(),
                  },
                  where: 'id = ?',
                  whereArgs: [supplier['id']]);
              await _dbHelper.logActivity(
                  userId: widget.currentUser['id'] as int?,
                  action: 'update',
                  entityType: 'supplier',
                  entityId: supplier['id'] as int,
                  details: 'সাপ্লায়ার তথ্য সম্পাদনা: $name');
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _load();
            },
            child: const Text('সংরক্ষণ করুন'),
          ),
        ],
      ),
    );
  }

  // §6: নিষ্ক্রিয় করা (হার্ড ডিলিট নয়) — পুরনো purchase-এ supplier_id
  // রেফারেন্স অক্ষত থাকে
  Future<void> _confirmDeactivate(Map<String, dynamic> supplier) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${supplier['name']}-কে নিষ্ক্রিয় করবেন?'),
        content: const Text(
            'এই সাপ্লায়ার নতুন ক্রয়ের সময় আর তালিকায় দেখাবে না, কিন্তু আগের সব ক্রয়/হিসাব অক্ষত থাকবে।'),
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
    await db.update('suppliers', {'is_active': 0},
        where: 'id = ?', whereArgs: [supplier['id']]);
    await _dbHelper.logActivity(
        userId: widget.currentUser['id'] as int?,
        action: 'delete',
        entityType: 'supplier',
        entityId: supplier['id'] as int,
        details: 'সাপ্লায়ার নিষ্ক্রিয় করা হলো: ${supplier['name']}');
    if (!mounted) return;
    Navigator.pop(context);
    _load();
  }

  Future<void> _showSupplierDetail(Map<String, dynamic> supplier) async {
    final db = await _dbHelper.database;
    final purchases = await db.query('purchases',
        where: 'supplier_id = ?', whereArgs: [supplier['id']], orderBy: 'purchase_date DESC');
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(supplier['name'] as String,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 18)),
                        Text(supplier['phone'] as String? ?? '',
                            style: const TextStyle(color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'তথ্য সম্পাদনা',
                    onPressed: () => _showEditSupplierDialog(supplier),
                  ),
                  if (_isMaster)
                    IconButton(
                      icon: const Icon(Icons.person_off_outlined,
                          size: 20, color: AppColors.danger),
                      tooltip: 'নিষ্ক্রিয় করুন (Master)',
                      onPressed: () => _confirmDeactivate(supplier),
                    ),
                ],
              ),
              const Divider(height: 24),
              Expanded(
                child: purchases.isEmpty
                    ? const Center(child: Text('কোনো ক্রয়ের ইতিহাস নেই'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: purchases.length,
                        itemBuilder: (ctx, i) {
                          final p = purchases[i];
                          final total = (p['total_amount'] as num).toDouble();
                          final paid = (p['paid_amount'] as num).toDouble();
                          return ListTile(
                            title: Text('ক্রয় #${p['id']} — ${p['purchase_date']}'),
                            subtitle: Text(
                                'মোট: ৳${total.toStringAsFixed(0)} • পরিশোধিত: ৳${paid.toStringAsFixed(0)}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                total > paid
                                    ? Text('দেনা: ৳${(total - paid).toStringAsFixed(0)}',
                                        style: const TextStyle(color: AppColors.danger, fontSize: 12))
                                    : const Icon(Icons.check_circle_outline,
                                        color: AppColors.success, size: 20),
                                if (_isMaster)
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined,
                                        size: 20, color: AppColors.textSecondary),
                                    tooltip: 'সম্পাদনা (Master)',
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) => PurchaseEntryScreen(
                                                  currentUser: widget.currentUser,
                                                  editPurchaseId: p['id'] as int)));
                                      _load();
                                    },
                                  ),
                                if (_isMaster)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20, color: AppColors.danger),
                                    tooltip: 'ডিলিট (Master)',
                                    onPressed: () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (dctx) => AlertDialog(
                                          title: Text('ক্রয় #${p['id']} ডিলিট করবেন?'),
                                          content: const Text(
                                              'এই ক্রয়ের সব stock/হিসাব রিভার্স হয়ে যাবে। ইতিমধ্যে বিক্রি হয়ে যাওয়া মাল থাকলে ডিলিট আটকে যাবে। এই কাজ ফিরিয়ে নেওয়া যাবে না।'),
                                          actions: [
                                            TextButton(
                                                onPressed: () => Navigator.pop(dctx, false),
                                                child: const Text('বাতিল')),
                                            FilledButton(
                                                onPressed: () => Navigator.pop(dctx, true),
                                                style: FilledButton.styleFrom(
                                                    backgroundColor: AppColors.danger),
                                                child: const Text('ডিলিট করুন')),
                                          ],
                                        ),
                                      );
                                      if (confirmed != true) return;
                                      try {
                                        await _transactionService.deletePurchase(
                                            purchaseId: p['id'] as int,
                                            deletedBy: widget.currentUser['id'] as int?);
                                        if (!context.mounted) return;
                                        Navigator.pop(ctx);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('ক্রয় ডিলিট করা হয়েছে')));
                                        _load();
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                            content: Text(
                                                e.toString().replaceFirst('Exception: ', ''))));
                                      }
                                    },
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('সাপ্লায়ার লেজার')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _suppliers.isEmpty
              ? const Center(child: Text('কোনো সাপ্লায়ার নেই'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _suppliers.length,
                  itemBuilder: (ctx, i) {
                    final s = _suppliers[i];
                    final due = (s['due'] as num).toDouble();
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        onTap: () => _showSupplierDetail(s),
                        title: Text(s['name'] as String),
                        subtitle: Text(
                            'মোট ক্রয়: ${_currencyFormat.format((s['total_purchase'] as num).toDouble())}'),
                        trailing: due > 0
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(_currencyFormat.format(due),
                                      style: const TextStyle(
                                          color: AppColors.danger, fontWeight: FontWeight.w600)),
                                  TextButton(
                                    onPressed: () => _showPayDueDialog(s, due),
                                    style: TextButton.styleFrom(
                                        padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                                    child: const Text('শোধ করুন', style: TextStyle(fontSize: 12)),
                                  ),
                                ],
                              )
                            : const Icon(Icons.check_circle_outline,
                                color: AppColors.success),
                      ),
                    );
                  },
                ),
    );
  }
}
