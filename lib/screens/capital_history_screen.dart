// ============================================================
// capital_history_screen.dart
// মূলধন ও পার্টনারদের সব লেনদেনের হিস্টোরি + রিপোর্ট — কোন পার্টনার
// কবে কত বিনিয়োগ করেছেন, মূলধন বা লাভ থেকে কত তুলেছেন, আর
// বর্তমান ব্যালেন্স কত। তারিখ/পার্টনার/ধরন অনুযায়ী ফিল্টার করা যায়।
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';

class CapitalHistoryScreen extends StatefulWidget {
  /// null হলে সব পার্টনারের হিস্টোরি দেখাবে
  final int? partnerId;
  const CapitalHistoryScreen({super.key, this.partnerId});

  @override
  State<CapitalHistoryScreen> createState() => _CapitalHistoryScreenState();
}

class _CapitalHistoryScreenState extends State<CapitalHistoryScreen> {
  final _dbHelper = DBHelper.instance;
  final _currencyFormat =
      NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);
  final _dateFormat = DateFormat('yyyy-MM-dd');

  static const Map<String, String> _typeLabels = {
    'invest': 'বিনিয়োগ',
    'withdraw_capital': 'মূলধন উত্তোলন',
    'withdraw_profit': 'লাভ উত্তোলন',
  };

  bool _loading = true;
  List<Map<String, dynamic>> _partners = [];
  List<Map<String, dynamic>> _rows = [];
  Map<int, double> _balances = {};

  int? _partnerId;
  String? _type;
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _partnerId = widget.partnerId;
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

    final where = <String>[];
    final args = <Object?>[];
    if (_partnerId != null) {
      where.add('ct.partner_id = ?');
      args.add(_partnerId);
    }
    if (_type != null) {
      where.add('ct.type = ?');
      args.add(_type);
    }
    if (_from != null) {
      where.add('ct.transaction_date >= ?');
      args.add(_dateFormat.format(_from!));
    }
    if (_to != null) {
      where.add('ct.transaction_date <= ?');
      args.add(_dateFormat.format(_to!));
    }

    final rows = await db.rawQuery('''
      SELECT ct.id, ct.partner_id, ct.type, ct.amount, ct.transaction_date,
             ct.note, p.name AS partner_name
      FROM capital_transactions ct
      JOIN partners p ON p.id = ct.partner_id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY ct.transaction_date DESC, ct.id DESC
    ''', args);

    if (!mounted) return;
    setState(() {
      _partners = partners;
      _balances = balances;
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = (isFrom ? _from : _to) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
    _load();
  }

  double _sumOf(List<Map<String, dynamic>> rows, String type) {
    double total = 0;
    for (final r in rows) {
      if (r['type'] == type) total += (r['amount'] as num).toDouble();
    }
    return total;
  }

  Widget _summaryTile(String label, double amount, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(_currencyFormat.format(amount),
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _partnerReportCard(Map<String, dynamic> partner) {
    final id = partner['id'] as int;
    final mine = _rows.where((r) => r['partner_id'] == id).toList();
    final balance = _balances[id] ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(partner['name'] as String,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                Text('${partner['profit_share_percent']}% ভাগ',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _summaryTile('বিনিয়োগ', _sumOf(mine, 'invest'),
                    AppColors.success),
                _summaryTile('মূলধন উত্তোলন', _sumOf(mine, 'withdraw_capital'),
                    AppColors.danger),
                _summaryTile('লাভ উত্তোলন', _sumOf(mine, 'withdraw_profit'),
                    AppColors.warning),
              ],
            ),
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('বর্তমান ব্যালেন্স',
                    style: TextStyle(color: AppColors.textSecondary)),
                Text(_currencyFormat.format(balance),
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: balance < 0
                            ? AppColors.danger
                            : AppColors.textPrimary)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visiblePartners = _partnerId == null
        ? _partners
        : _partners.where((p) => p['id'] == _partnerId).toList();
    final hasFilter = _type != null || _from != null || _to != null;

    return Scaffold(
      appBar: AppBar(title: const Text('মূলধন হিস্টোরি ও রিপোর্ট')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<int?>(
                  value: _partnerId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'পার্টনার'),
                  items: [
                    const DropdownMenuItem<int?>(
                        value: null, child: Text('সব পার্টনার')),
                    ..._partners.map((p) => DropdownMenuItem<int?>(
                        value: p['id'] as int,
                        child: Text(p['name'] as String))),
                  ],
                  onChanged: (v) {
                    setState(() => _partnerId = v);
                    _load();
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  value: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'লেনদেনের ধরন'),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('সব ধরন')),
                    ..._typeLabels.entries.map((e) =>
                        DropdownMenuItem<String?>(
                            value: e.key, child: Text(e.value))),
                  ],
                  onChanged: (v) {
                    setState(() => _type = v);
                    _load();
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickDate(isFrom: true),
                        icon: const Icon(Icons.calendar_today_outlined, size: 16),
                        label: Text(_from == null
                            ? 'শুরুর তারিখ'
                            : _dateFormat.format(_from!)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickDate(isFrom: false),
                        icon: const Icon(Icons.calendar_today_outlined, size: 16),
                        label: Text(_to == null
                            ? 'শেষ তারিখ'
                            : _dateFormat.format(_to!)),
                      ),
                    ),
                  ],
                ),
                if (hasFilter)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          _type = null;
                          _from = null;
                          _to = null;
                        });
                        _load();
                      },
                      child: const Text('ফিল্টার মুছুন'),
                    ),
                  ),
                const SizedBox(height: 16),
                const Text('পার্টনার রিপোর্ট',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (visiblePartners.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('কোনো পার্টনার পাওয়া যায়নি'),
                  ),
                ...visiblePartners.map(_partnerReportCard),
                const SizedBox(height: 8),
                Text('লেনদেনের হিস্টোরি (${_rows.length}টি)',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (_rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('কোনো লেনদেন নেই')),
                  )
                else
                  Card(
                    child: Column(
                      children: _rows.map((r) {
                        final type = r['type'] as String;
                        final isIn = type == 'invest';
                        final amount = (r['amount'] as num).toDouble();
                        final note = (r['note'] as String? ?? '').trim();
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            isIn
                                ? Icons.arrow_downward_rounded
                                : Icons.arrow_upward_rounded,
                            color: isIn ? AppColors.success : AppColors.danger,
                          ),
                          title: Text(
                              '${r['partner_name']} — ${_typeLabels[type] ?? type}'),
                          subtitle: Text(
                              '${r['transaction_date']}${note.isNotEmpty ? ' • $note' : ''}'),
                          trailing: Text(
                            '${isIn ? '+' : '-'}${_currencyFormat.format(amount)}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color:
                                  isIn ? AppColors.success : AppColors.danger,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
