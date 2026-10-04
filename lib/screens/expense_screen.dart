// ============================================================
// expense_screen.dart
// খরচের তালিকা ও নতুন খরচ যোগ করা — সাবমিট করলেই স্বয়ংক্রিয়ভাবে
// ক্যাশ থেকে বিয়োগ হয়ে যায় (TransactionService.recordExpense())
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../utils/app_theme.dart';
import '../widgets/date_field.dart';

const List<String> kExpenseCategories = [
  'দোকান ভাড়া',
  'বিদ্যুৎ বিল',
  'পরিবহন/কুরিয়ার',
  'ফোন বিল',
  'বেতন',
  'প্যাকেজিং',
  'অন্যান্য',
];

class ExpenseScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const ExpenseScreen({super.key, required this.currentUser});

  @override
  State<ExpenseScreen> createState() => _ExpenseScreenState();
}

class _ExpenseScreenState extends State<ExpenseScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();
  final _currencyFormat = NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);

  List<Map<String, dynamic>> _expenses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final result = await db.query('expenses', orderBy: 'expense_date DESC, id DESC');
    if (!mounted) return;
    setState(() {
      _expenses = result;
      _loading = false;
    });
  }

  Future<void> _showAddDialog() async {
    String category = kExpenseCategories.first;
    final amountController = TextEditingController();
    final descController = TextEditingController();
    DateTime date = DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('নতুন খরচ'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'ক্যাটাগরি'),
                  items: kExpenseCategories
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (val) => setDialogState(() => category = val!),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'টাকার পরিমাণ'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  decoration: const InputDecoration(labelText: 'বিস্তারিত (ঐচ্ছিক)'),
                ),
                const SizedBox(height: 12),
                DateField(
                  date: date,
                  onChanged: (d) => setDialogState(() => date = d),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final amount = double.tryParse(amountController.text) ?? 0;
                if (amount <= 0) return;
                await _transactionService.recordExpense(
                  category: category,
                  amount: amount,
                  description: descController.text.trim(),
                  expenseDate: DateFormat('yyyy-MM-dd').format(date),
                  createdBy: widget.currentUser['id'] as int?,
                );
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                _load();
              },
              child: const Text('সংরক্ষণ করুন'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _expenses.fold<double>(
        0, (sum, e) => sum + (e['amount'] as num).toDouble());

    return Scaffold(
      appBar: AppBar(title: const Text('খরচ')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        icon: const Icon(Icons.add),
        label: const Text('নতুন খরচ'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Card(
                  margin: const EdgeInsets.all(16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('মোট খরচ (সব সময়)',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        Text(_currencyFormat.format(total),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                                color: AppColors.danger)),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _expenses.isEmpty
                      ? const Center(child: Text('এখনো কোনো খরচ যোগ হয়নি'))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _expenses.length,
                          itemBuilder: (ctx, i) {
                            final e = _expenses[i];
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                title: Text(e['category'] as String),
                                subtitle: Text(
                                    '${e['expense_date']}${(e['description'] as String? ?? '').isNotEmpty ? " • ${e['description']}" : ""}'),
                                trailing: Text(
                                    _currencyFormat.format((e['amount'] as num).toDouble()),
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
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
