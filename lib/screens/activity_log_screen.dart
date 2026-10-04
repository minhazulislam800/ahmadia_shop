// ============================================================
// activity_log_screen.dart
// কে, কবে, কী এন্ট্রি/এডিট/ডিলিট করলো তার ইতিহাস দেখা
// (শুধু মাস্টার ইউজার দেখতে পাবে — ড্যাশবোর্ড থেকে নিয়ন্ত্রিত হবে)
// Phase 4 (§14): user/action/module/date অনুযায়ী স্মার্ট ফিল্টার
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';

class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  final _dbHelper = DBHelper.instance;
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  int? _userFilter;
  String? _actionFilter;
  String? _moduleFilter;
  DateTime? _fromDate;
  DateTime? _toDate;

  static const _actionOptions = ['create', 'update', 'delete'];
  static const _moduleOptions = [
    'sale', 'purchase', 'product', 'customer', 'supplier',
    'stock_adjustment', 'expense', 'capital_transaction',
    'sale_return', 'purchase_return', 'due_payment',
  ];

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _load();
  }

  Future<void> _loadUsers() async {
    final db = await _dbHelper.database;
    final users = await db.query('users', orderBy: 'username ASC');
    if (!mounted) return;
    setState(() => _users = users);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;

    final where = <String>[];
    final args = <Object?>[];
    if (_userFilter != null) {
      where.add('al.user_id = ?');
      args.add(_userFilter);
    }
    if (_actionFilter != null) {
      where.add('al.action = ?');
      args.add(_actionFilter);
    }
    if (_moduleFilter != null) {
      where.add('al.entity_type = ?');
      args.add(_moduleFilter);
    }
    if (_fromDate != null) {
      where.add('al.timestamp >= ?');
      args.add(DateFormat('yyyy-MM-dd').format(_fromDate!));
    }
    if (_toDate != null) {
      where.add("al.timestamp <= ?");
      args.add('${DateFormat('yyyy-MM-dd').format(_toDate!)}T23:59:59');
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    final result = await db.rawQuery('''
      SELECT al.*, u.username, u.role
      FROM activity_log al
      LEFT JOIN users u ON u.id = al.user_id
      $whereSql
      ORDER BY al.timestamp DESC
      LIMIT 200
    ''', args);
    if (!mounted) return;
    setState(() {
      _logs = result;
      _loading = false;
    });
  }

  bool get _hasActiveFilter =>
      _userFilter != null ||
      _actionFilter != null ||
      _moduleFilter != null ||
      _fromDate != null ||
      _toDate != null;

  void _clearFilters() {
    setState(() {
      _userFilter = null;
      _actionFilter = null;
      _moduleFilter = null;
      _fromDate = null;
      _toDate = null;
    });
    _load();
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'create':
        return 'তৈরি';
      case 'update':
        return 'সম্পাদনা';
      case 'delete':
        return 'ডিলিট/নিষ্ক্রিয়';
      default:
        return action;
    }
  }

  IconData _iconFor(String entityType) {
    switch (entityType) {
      case 'purchase':
        return Icons.shopping_cart_outlined;
      case 'sale':
        return Icons.point_of_sale_outlined;
      case 'expense':
        return Icons.receipt_long_outlined;
      case 'capital_transaction':
        return Icons.account_balance_outlined;
      case 'sale_return':
      case 'purchase_return':
        return Icons.keyboard_return_outlined;
      case 'product':
        return Icons.inventory_2_outlined;
      case 'customer':
      case 'supplier':
        return Icons.person_outline;
      case 'stock_adjustment':
        return Icons.tune;
      default:
        return Icons.edit_note_outlined;
    }
  }

  String _entityLabel(String entityType) {
    const map = {
      'purchase': 'ক্রয়',
      'sale': 'বিক্রয়',
      'expense': 'খরচ',
      'capital_transaction': 'মূলধন লেনদেন',
      'sale_return': 'বিক্রয় ফেরত',
      'purchase_return': 'ক্রয় ফেরত',
      'due_payment': 'বাকি পরিশোধ',
      'stock_adjustment': 'স্টক সমন্বয়',
      'product': 'পণ্য',
      'customer': 'কাস্টমার',
      'supplier': 'সাপ্লায়ার',
    };
    return map[entityType] ?? entityType;
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _fromDate = picked;
      } else {
        _toDate = picked;
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('অ্যাক্টিভিটি লগ'),
        actions: [
          if (_hasActiveFilter)
            TextButton(
              onPressed: _clearFilters,
              child: const Text('ফিল্টার মুছুন',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChipDropdown<int?>(
                    label: 'ইউজার',
                    value: _userFilter,
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('সবাই')),
                      ..._users.map((u) => DropdownMenuItem<int?>(
                          value: u['id'] as int, child: Text(u['username'] as String))),
                    ],
                    onChanged: (v) {
                      setState(() => _userFilter = v);
                      _load();
                    },
                  ),
                  const SizedBox(width: 8),
                  _filterChipDropdown<String?>(
                    label: 'কাজ',
                    value: _actionFilter,
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('সব')),
                      ..._actionOptions.map((a) =>
                          DropdownMenuItem<String?>(value: a, child: Text(_actionLabel(a)))),
                    ],
                    onChanged: (v) {
                      setState(() => _actionFilter = v);
                      _load();
                    },
                  ),
                  const SizedBox(width: 8),
                  _filterChipDropdown<String?>(
                    label: 'মডিউল',
                    value: _moduleFilter,
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('সব')),
                      ..._moduleOptions.map((m) =>
                          DropdownMenuItem<String?>(value: m, child: Text(_entityLabel(m)))),
                    ],
                    onChanged: (v) {
                      setState(() => _moduleFilter = v);
                      _load();
                    },
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: Text(_fromDate == null
                        ? 'তারিখ থেকে'
                        : DateFormat('dd MMM').format(_fromDate!)),
                    onPressed: () => _pickDate(isFrom: true),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: Text(_toDate == null
                        ? 'তারিখ পর্যন্ত'
                        : DateFormat('dd MMM').format(_toDate!)),
                    onPressed: () => _pickDate(isFrom: false),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _logs.isEmpty
                    ? const Center(child: Text('এই ফিল্টারে কোনো অ্যাক্টিভিটি নেই'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _logs.length,
                        itemBuilder: (ctx, i) {
                          final log = _logs[i];
                          final role = log['role'] == 'master' ? 'মাস্টার' : 'নরমাল';
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(_iconFor(log['entity_type'] as String),
                                  color: AppColors.primary),
                              title: Text(
                                  '${_entityLabel(log['entity_type'] as String)} — ${_actionLabel(log['action'] as String)}'),
                              subtitle: Text(
                                  '${log['username'] ?? 'অজানা'} ($role) • ${log['details'] ?? ''}'),
                              trailing: Text(
                                (log['timestamp'] as String).substring(0, 16).replaceAll('T', ' '),
                                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
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

  Widget _filterChipDropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.textSecondary.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(label, style: const TextStyle(fontSize: 13)),
          isDense: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
