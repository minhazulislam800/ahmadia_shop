// ============================================================
// invoice_list_screen.dart
// সব বিক্রয়ের একটা তালিকা — যেকোনো পুরনো ইনভয়েস আবার খুলে
// দেখা/প্রিন্ট/শেয়ার করার সুবিধা
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../utils/app_theme.dart';
import 'invoice_screen.dart';
import 'sale_entry_screen.dart';

class InvoiceListScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const InvoiceListScreen({super.key, required this.currentUser});

  @override
  State<InvoiceListScreen> createState() => _InvoiceListScreenState();
}

class _InvoiceListScreenState extends State<InvoiceListScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();
  final _currencyFormat = NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  final _searchController = TextEditingController();

  bool get _isMaster => widget.currentUser['role'] == 'master';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final result = await db.rawQuery('''
      SELECT s.*, c.name as customer_name
      FROM sales s
      LEFT JOIN customers c ON c.id = s.customer_id
      ORDER BY s.sale_date DESC, s.id DESC
    ''');
    if (!mounted) return;
    setState(() {
      _sales = result;
      _filtered = result;
      _loading = false;
    });
  }

  void _filter(String query) {
    if (query.isEmpty) {
      setState(() => _filtered = _sales);
      return;
    }
    setState(() {
      _filtered = _sales.where((s) {
        final customerName = (s['customer_name'] as String? ?? '').toLowerCase();
        final id = s['id'].toString();
        return customerName.contains(query.toLowerCase()) || id == query;
      }).toList();
    });
  }

  // §5: destructive action-এর আগে বাধ্যতামূলক confirmation
  Future<void> _confirmAndDelete(Map<String, dynamic> sale) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('বিক্রয় #${sale['id']} ডিলিট করবেন?'),
        content: Text(
            'বিক্রয় #${sale['id']} সম্পূর্ণভাবে বাতিল হয়ে যাবে — স্টক, ক্যাশ, বাকি ও লাভের হিসাব স্বয়ংক্রিয়ভাবে সমন্বয় হয়ে যাবে। এই কাজ ফিরিয়ে নেওয়া যাবে না।'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('বাতিল')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: const Text('ডিলিট করুন')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _transactionService.deleteSale(
          saleId: sale['id'] as int,
          deletedBy: widget.currentUser['id'] as int?);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('বিক্রয় ডিলিট করা হয়েছে')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('সব ইনভয়েস')),
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
                      hintText: 'কাস্টমারের নাম বা বিল নম্বর দিয়ে খুঁজুন...',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                Expanded(
                  child: _filtered.isEmpty
                      ? const Center(child: Text('কোনো ইনভয়েস পাওয়া যায়নি'))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _filtered.length,
                          itemBuilder: (ctx, i) {
                            final s = _filtered[i];
                            final total = (s['total_amount'] as num).toDouble();
                            final paid = (s['paid_amount'] as num).toDouble();
                            final due = total - paid;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: AppColors.primaryLight,
                                  child: Text('#${s['id']}',
                                      style: const TextStyle(
                                          fontSize: 11, color: AppColors.primary)),
                                ),
                                title: Text(
                                    s['customer_name'] as String? ?? 'ওয়াক-ইন কাস্টমার'),
                                subtitle: Text(
                                    '${s['sale_date']} • ${_currencyFormat.format(total)}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    due > 0
                                        ? Text('বাকি ${_currencyFormat.format(due)}',
                                            style: const TextStyle(
                                                color: AppColors.danger, fontSize: 12))
                                        : const Icon(Icons.check_circle_outline,
                                            color: AppColors.success),
                                    if (_isMaster)
                                      IconButton(
                                        icon: const Icon(Icons.edit_outlined,
                                            size: 20, color: AppColors.textSecondary),
                                        tooltip: 'সম্পাদনা করুন (Master)',
                                        onPressed: () async {
                                          await Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                  builder: (_) => SaleEntryScreen(
                                                      currentUser: widget.currentUser,
                                                      editSaleId: s['id'] as int)));
                                          _load();
                                        },
                                      ),
                                    if (_isMaster)
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            size: 20, color: AppColors.danger),
                                        tooltip: 'ডিলিট করুন (Master)',
                                        onPressed: () => _confirmAndDelete(s),
                                      ),
                                  ],
                                ),
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => InvoiceScreen(saleId: s['id'] as int))),
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
