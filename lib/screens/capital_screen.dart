// ============================================================
// capital_screen.dart
// পার্টনারদের ব্যালেন্স দেখা, নতুন বিনিয়োগ/উত্তোলন (ক্যাপিটাল বা
// লাভ থেকে — দুটো আলাদা অপশন) এন্ট্রি করা
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../utils/app_theme.dart';
import '../widgets/date_field.dart';
import 'capital_history_screen.dart';

class CapitalScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const CapitalScreen({super.key, required this.currentUser});

  @override
  State<CapitalScreen> createState() => _CapitalScreenState();
}

class _CapitalScreenState extends State<CapitalScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();
  final _currencyFormat = NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);

  List<Map<String, dynamic>> _partners = [];
  Map<int, double> _balances = {};
  double _availableProfit = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final partners = await db.query('partners', orderBy: 'id ASC');
    final balances = <int, double>{};
    for (final p in partners) {
      balances[p['id'] as int] =
          await _dbHelper.getPartnerBalance(db, p['id'] as int);
    }
    final availableProfit = await _dbHelper.getAvailableProfit(db);

    if (!mounted) return;
    setState(() {
      _partners = partners;
      _balances = balances;
      _availableProfit = availableProfit;
      _loading = false;
    });
  }

  Future<void> _showTransactionDialog(Map<String, dynamic> partner) async {
    String type = 'invest';
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    DateTime date = DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('${partner['name']} — লেনদেন'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('বিনিয়োগ (ক্যাশ ঢুকবে)'),
                  value: 'invest',
                  groupValue: type,
                  onChanged: (v) => setDialogState(() => type = v!),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('মূলধন উত্তোলন'),
                  value: 'withdraw_capital',
                  groupValue: type,
                  onChanged: (v) => setDialogState(() => type = v!),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                      'লাভ উত্তোলন (উত্তোলনযোগ্য: ${_currencyFormat.format(_availableProfit)})'),
                  value: 'withdraw_profit',
                  groupValue: type,
                  onChanged: (v) => setDialogState(() => type = v!),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'টাকার পরিমাণ'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(labelText: 'নোট (ঐচ্ছিক)'),
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
                await _transactionService.recordCapitalTransaction(
                  partnerId: partner['id'] as int,
                  type: type,
                  amount: amount,
                  date: DateFormat('yyyy-MM-dd').format(date),
                  note: noteController.text.trim(),
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

  Future<void> _renamePartner(Map<String, dynamic> partner) async {
    final controller = TextEditingController(text: partner['name'] as String);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('পার্টনারের নাম পরিবর্তন'),
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final db = await _dbHelper.database;
              await db.update('partners', {'name': controller.text.trim()},
                  where: 'id = ?', whereArgs: [partner['id']]);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('মূলধন ও পার্টনার হিসাব'),
        actions: [
          IconButton(
            tooltip: 'হিস্টোরি ও রিপোর্ট',
            icon: const Icon(Icons.history_rounded),
            onPressed: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => CapitalHistoryScreen(currentUser: widget.currentUser)));
              _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: AppColors.primaryLight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('উত্তোলনযোগ্য অবশিষ্ট লাভ (মোট)'),
                        Text(_currencyFormat.format(_availableProfit),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ..._partners.map((p) {
                  final balance = _balances[p['id']] ?? 0;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Text(p['name'] as String,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700, fontSize: 16)),
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                    onPressed: () => _renamePartner(p),
                                  ),
                                ],
                              ),
                              Text('${p['profit_share_percent']}% ভাগ',
                                  style: const TextStyle(color: AppColors.textSecondary)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text('বর্তমান ব্যালেন্স',
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                          Text(_currencyFormat.format(balance),
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: balance < 0 ? AppColors.danger : AppColors.textPrimary)),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _showTransactionDialog(p),
                                  icon: const Icon(Icons.add),
                                  label: const Text('বিনিয়োগ/উত্তোলন এন্ট্রি'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => CapitalHistoryScreen(
                                            currentUser: widget.currentUser,
                                            partnerId: p['id'] as int))),
                                icon: const Icon(Icons.history_rounded),
                                label: const Text('হিস্টোরি'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}
