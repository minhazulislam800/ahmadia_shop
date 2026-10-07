// ============================================================
// expense_report_screen.dart
// খরচ রিপোর্ট — সময়কাল ও ক্যাটাগরি ধরে খরচের হিসাব।
// ক্যাশ-খরচের (ভাড়া, বেতন ইত্যাদি) পাশাপাশি চাইলে স্টক নষ্ট/গিফট/ঘাটতি বাবদ
// ক্ষতিও আলাদা অংশে দেখায় — কারণ এগুলো ক্যাশ থেকে বের হয় না, কিন্তু নিট লাভ কমায়।
// PDF ও Excel এক্সপোর্ট আছে।
// ============================================================

import 'dart:io';
import 'package:excel/excel.dart' as excel_lib;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/report_pdf.dart';
import '../utils/safe_share.dart';

const Map<String, String> _reasonLabels = {
  'damaged': 'নষ্ট পণ্য',
  'shortage': 'ঘাটতি',
  'gift': 'Gift',
  'sample': 'Sample',
  'internal_use': 'Internal use',
  'excess_found': 'অতিরিক্ত পাওয়া',
  'other': 'অন্যান্য',
};

class ExpenseReportScreen extends StatefulWidget {
  const ExpenseReportScreen({super.key});

  @override
  State<ExpenseReportScreen> createState() => _ExpenseReportScreenState();
}

class _ExpenseReportScreenState extends State<ExpenseReportScreen> {
  final _dbHelper = DBHelper.instance;
  final _money =
      NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);
  final _dateFmt = DateFormat('yyyy-MM-dd');

  late DateTime _from;
  late DateTime _to;
  String? _category; // null = সব
  bool _includeStock = true;
  bool _loading = true;

  List<String> _allCategories = [];
  List<Map<String, dynamic>> _expenses = [];
  List<Map<String, dynamic>> _adjustments = [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month, now.day);
    _load();
  }

  // ---------- ডেটা ----------

  double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

  double get _expenseTotal =>
      _expenses.fold(0.0, (a, e) => a + _d(e['amount']));

  /// স্টক সমন্বয়ের নিট প্রভাব: ক্ষতি (ঋণাত্মক) + অতিরিক্ত পাওয়ার লাভ (ধনাত্মক)
  double get _stockImpact => _adjustments.fold(
      0.0,
      (a, r) =>
          a + (_d(r['base_quantity']) > 0 ? _d(r['total_cost']) : -_d(r['total_cost'])));

  double get _stockLoss => -_stockImpact; // ধনাত্মক = ক্ষতি
  bool get _showStock => _includeStock && _category == null;
  double get _grandTotal => _expenseTotal + (_showStock ? _stockLoss : 0);

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final from = _dateFmt.format(_from);
    final to = _dateFmt.format(_to);

    final cats = await db.rawQuery(
        'SELECT DISTINCT category FROM expenses ORDER BY category');
    final args = <Object?>[from, to];
    var where = 'expense_date >= ? AND expense_date <= ?';
    if (_category != null) {
      where += ' AND category = ?';
      args.add(_category);
    }
    final expenses = await db.query('expenses',
        where: where, whereArgs: args, orderBy: 'expense_date DESC, id DESC');

    final adjustments = await db.rawQuery('''
      SELECT sa.*, p.name AS product_name, p.unit AS base_unit,
             pu.unit_label AS pack_unit_label
      FROM stock_adjustments sa
      JOIN products p ON p.id = sa.product_id
      LEFT JOIN product_units pu ON pu.id = sa.product_unit_id
      WHERE sa.adjustment_date >= ? AND sa.adjustment_date <= ?
      ORDER BY sa.adjustment_date DESC, sa.id DESC
    ''', [from, to]);

    if (!mounted) return;
    setState(() {
      _allCategories = cats.map((r) => r['category'] as String).toList();
      _expenses = expenses;
      _adjustments = adjustments;
      _loading = false;
    });
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked == null) return;
    setState(() {
      _from = picked.start;
      _to = picked.end;
    });
    _load();
  }

  void _quickRange(String kind) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      switch (kind) {
        case 'month':
          _from = DateTime(now.year, now.month, 1);
          _to = today;
          break;
        case 'last':
          _from = DateTime(now.year, now.month - 1, 1);
          _to = DateTime(now.year, now.month, 0);
          break;
        case 'year':
          _from = DateTime(now.year, 1, 1);
          _to = today;
          break;
      }
    });
    _load();
  }

  String _qtyText(Map<String, dynamic> a) {
    final q = _d(a['quantity']).abs();
    final unit = (a['pack_unit_label'] as String?) ?? (a['base_unit'] as String);
    final text = q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toString();
    return '$text $unit';
  }

  // ক্যাটাগরি অনুযায়ী যোগফল (বেশি থেকে কম)
  List<MapEntry<String, double>> get _byCategory {
    final m = <String, double>{};
    for (final e in _expenses) {
      final c = e['category'] as String;
      m[c] = (m[c] ?? 0) + _d(e['amount']);
    }
    final list = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  // স্টক সমন্বয়ের কারণ অনুযায়ী ক্ষতি
  List<MapEntry<String, double>> get _byReason {
    final m = <String, double>{};
    for (final a in _adjustments) {
      final r = _reasonLabels[a['reason']] ?? '${a['reason']}';
      final impact = _d(a['base_quantity']) > 0 ? -_d(a['total_cost']) : _d(a['total_cost']);
      m[r] = (m[r] ?? 0) + impact; // ধনাত্মক = ক্ষতি
    }
    final list = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  // ---------- এক্সপোর্ট ----------

  String get _rangeText =>
      '${DateFormat('dd MMM yyyy').format(_from)} — ${DateFormat('dd MMM yyyy').format(_to)}';

  Future<void> _exportPdf() async {
    final cats = _byCategory;
    final blocks = <ReportBlock>[
      ReportKeyValue('ক্যাশ খরচ (${_expenses.length}টি)', '৳${_expenseTotal.toStringAsFixed(0)}'),
      if (_showStock)
        ReportKeyValue(
            _stockLoss >= 0 ? 'স্টক নষ্ট/গিফট/ঘাটতি বাবদ ক্ষতি' : 'স্টক অতিরিক্ত পাওয়া (লাভ)',
            '৳${_stockLoss.abs().toStringAsFixed(0)}'),
      const ReportDivider(),
      ReportKeyValue(
          _showStock ? 'সর্বমোট খরচ ও ক্ষতি' : 'মোট খরচ', '৳${_grandTotal.toStringAsFixed(0)}',
          bold: true),
      const ReportSpace(10),
      if (cats.isNotEmpty) ...[
        const ReportHeading('ক্যাটাগরি অনুযায়ী খরচ'),
        ReportTable(
          headers: const ['ক্যাটাগরি', 'শতাংশ', 'টাকা'],
          flex: const [2.2, 0.9, 1.2],
          rightAlign: const [false, true, true],
          rows: cats
              .map((c) => [
                    c.key,
                    _expenseTotal > 0
                        ? '${(c.value / _expenseTotal * 100).toStringAsFixed(1)}%'
                        : '',
                    '৳${c.value.toStringAsFixed(0)}',
                  ])
              .toList(),
        ),
        const ReportSpace(10),
      ],
      if (_expenses.isNotEmpty) ...[
        const ReportHeading('খরচের তালিকা'),
        ReportTable(
          headers: const ['তারিখ', 'ক্যাটাগরি', 'বিস্তারিত', 'টাকা'],
          flex: const [1.2, 1.4, 1.8, 1.0],
          rightAlign: const [false, false, false, true],
          rows: _expenses
              .map((e) => [
                    '${e['expense_date']}',
                    '${e['category']}',
                    '${e['description'] ?? ''}',
                    '৳${_d(e['amount']).toStringAsFixed(0)}',
                  ])
              .toList(),
        ),
      ],
      if (_showStock && _adjustments.isNotEmpty) ...[
        const ReportSpace(10),
        const ReportHeading('স্টক সমন্বয় (নষ্ট/গিফট/ঘাটতি/অতিরিক্ত)'),
        ReportTable(
          headers: const ['তারিখ', 'পণ্য', 'কারণ', 'পরিমাণ', 'মূল্য'],
          flex: const [1.15, 1.6, 1.2, 1.0, 0.95],
          rightAlign: const [false, false, false, false, true],
          rows: _adjustments
              .map((a) => [
                    '${a['adjustment_date']}',
                    '${a['product_name']}',
                    _reasonLabels[a['reason']] ?? '${a['reason']}',
                    (_d(a['base_quantity']) < 0 ? '−' : '+') + _qtyText(a),
                    '৳${_d(a['total_cost']).toStringAsFixed(0)}',
                  ])
              .toList(),
        ),
      ],
    ];

    final bytes = await ReportPdf.build(
      title: 'খরচ রিপোর্ট — Ahmadia Shop',
      subtitles: [
        'সময়কাল: $_rangeText',
        if (_category != null) 'ক্যাটাগরি: $_category',
      ],
      blocks: blocks,
    );
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/expense_report.pdf');
    await file.writeAsBytes(bytes);
    await SafeShare.files([file.path], text: 'খরচ রিপোর্ট — $_rangeText');
  }

  Future<void> _exportExcel() async {
    final wb = excel_lib.Excel.createExcel();
    excel_lib.TextCellValue t(String v) => excel_lib.TextCellValue(v);
    excel_lib.DoubleCellValue n(double v) => excel_lib.DoubleCellValue(v);

    final summary = wb['সারাংশ'];
    summary.appendRow([t('সময়কাল'), t(_rangeText)]);
    if (_category != null) summary.appendRow([t('ক্যাটাগরি'), t(_category!)]);
    summary.appendRow([t('ক্যাশ খরচ'), n(_expenseTotal)]);
    if (_showStock) {
      summary.appendRow([t('স্টক নষ্ট/গিফট/ঘাটতি বাবদ ক্ষতি (ঋণাত্মক = লাভ)'), n(_stockLoss)]);
    }
    summary.appendRow([t(_showStock ? 'সর্বমোট খরচ ও ক্ষতি' : 'মোট খরচ'), n(_grandTotal)]);
    summary.appendRow([t('')]);
    summary.appendRow([t('ক্যাটাগরি'), t('টাকা'), t('শতাংশ')]);
    for (final c in _byCategory) {
      summary.appendRow([
        t(c.key),
        n(c.value),
        n(_expenseTotal > 0 ? c.value / _expenseTotal * 100 : 0),
      ]);
    }

    final sheet = wb['খরচ'];
    sheet.appendRow([t('তারিখ'), t('ক্যাটাগরি'), t('বিস্তারিত'), t('টাকা')]);
    for (final e in _expenses) {
      sheet.appendRow([
        t('${e['expense_date']}'),
        t('${e['category']}'),
        t('${e['description'] ?? ''}'),
        n(_d(e['amount'])),
      ]);
    }

    if (_showStock) {
      final adj = wb['স্টক সমন্বয়'];
      adj.appendRow([t('তারিখ'), t('পণ্য'), t('কারণ'), t('পরিমাণ'), t('একক'), t('মূল্য'), t('প্রভাব'), t('নোট')]);
      for (final a in _adjustments) {
        final isGain = _d(a['base_quantity']) > 0;
        adj.appendRow([
          t('${a['adjustment_date']}'),
          t('${a['product_name']}'),
          t(_reasonLabels[a['reason']] ?? '${a['reason']}'),
          n(_d(a['quantity'])),
          t((a['pack_unit_label'] as String?) ?? (a['base_unit'] as String)),
          n(_d(a['total_cost'])),
          t(isGain ? 'লাভ' : 'ক্ষতি'),
          t('${a['note'] ?? ''}'),
        ]);
      }
    }

    wb.delete('Sheet1');
    final bytes = wb.encode();
    if (bytes == null) return;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/expense_report.xlsx');
    await file.writeAsBytes(bytes);
    await SafeShare.files([file.path], text: 'খরচ রিপোর্ট — $_rangeText');
  }

  // ---------- UI ----------

  Widget _bar(String label, double value, double total, Color color) {
    final frac = total > 0 ? (value / total).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
              Text(
                  '${_money.format(value)}  (${(frac * 100).toStringAsFixed(0)}%)',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: frac, minHeight: 6, color: color,
                backgroundColor: AppColors.border),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(String label, double value, Color color, {String? note}) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 6),
              Text(_money.format(value),
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: color)),
              if (note != null)
                Text(note,
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasData = _expenses.isNotEmpty || (_showStock && _adjustments.isNotEmpty);
    final cats = _byCategory;
    final reasons = _byReason;
    return Scaffold(
      appBar: AppBar(
        title: const Text('খরচ রিপোর্ট'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'PDF এক্সপোর্ট',
            onPressed: hasData ? _exportPdf : null,
          ),
          IconButton(
            icon: const Icon(Icons.table_chart_outlined),
            tooltip: 'Excel এক্সপোর্ট',
            onPressed: hasData ? _exportExcel : null,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                OutlinedButton.icon(
                  onPressed: _pickRange,
                  icon: const Icon(Icons.date_range, size: 18),
                  label: Text(_rangeText),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ActionChip(label: const Text('এই মাস'), onPressed: () => _quickRange('month')),
                    ActionChip(label: const Text('গত মাস'), onPressed: () => _quickRange('last')),
                    ActionChip(label: const Text('এই বছর'), onPressed: () => _quickRange('year')),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  value: _allCategories.contains(_category) ? _category : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'ক্যাটাগরি', isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('সব ক্যাটাগরি')),
                    ..._allCategories
                        .map((c) => DropdownMenuItem<String?>(value: c, child: Text(c))),
                  ],
                  onChanged: (v) {
                    setState(() => _category = v);
                    _load();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _includeStock,
                  onChanged: _category != null
                      ? null
                      : (v) => setState(() => _includeStock = v),
                  title: const Text('স্টক নষ্ট/গিফট/ঘাটতিও দেখান',
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                      'ক্যাশ থেকে বের হয় না, কিন্তু নিট লাভ কমায় — তাই আলাদা অংশে',
                      style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _summaryCard('ক্যাশ খরচ', _expenseTotal, AppColors.danger,
                        note: '${_expenses.length}টি এন্ট্রি'),
                    if (_showStock)
                      _summaryCard(
                          _stockLoss >= 0 ? 'স্টক ক্ষতি' : 'স্টক লাভ',
                          _stockLoss.abs(),
                          _stockLoss >= 0 ? AppColors.warning : AppColors.success,
                          note: '${_adjustments.length}টি সমন্বয়'),
                  ],
                ),
                Card(
                  color: AppColors.primaryLight,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_showStock ? 'সর্বমোট খরচ ও ক্ষতি' : 'মোট খরচ',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(_money.format(_grandTotal),
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.primary)),
                      ],
                    ),
                  ),
                ),
                if (!hasData)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: Text('এই সময়ে কোনো খরচ নেই')),
                  ),
                if (cats.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('ক্যাটাগরি অনুযায়ী খরচ',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  ...cats.map((c) => _bar(c.key, c.value, _expenseTotal, AppColors.danger)),
                ],
                if (_showStock && reasons.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('স্টক সমন্বয় — কারণ অনুযায়ী ক্ষতি',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  ...reasons.where((r) => r.value > 0).map((r) =>
                      _bar(r.key, r.value, _stockLoss > 0 ? _stockLoss : 1, AppColors.warning)),
                ],
                if (_expenses.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('খরচের তালিকা (${_expenses.length}টি)',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Card(
                    child: Column(
                      children: _expenses.map((e) {
                        final desc = (e['description'] as String? ?? '').trim();
                        return ListTile(
                          dense: true,
                          title: Text('${e['category']}'),
                          subtitle: Text('${e['expense_date']}${desc.isNotEmpty ? ' • $desc' : ''}'),
                          trailing: Text(_money.format(_d(e['amount'])),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, color: AppColors.danger)),
                        );
                      }).toList(),
                    ),
                  ),
                ],
                if (_showStock && _adjustments.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('স্টক সমন্বয় (${_adjustments.length}টি)',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Card(
                    child: Column(
                      children: _adjustments.map((a) {
                        final gain = _d(a['base_quantity']) > 0;
                        return ListTile(
                          dense: true,
                          title: Text(
                              '${a['product_name']} — ${_reasonLabels[a['reason']] ?? a['reason']}'),
                          subtitle: Text(
                              '${a['adjustment_date']} • ${gain ? '+' : '−'}${_qtyText(a)}'),
                          trailing: Text(
                              '${gain ? '+' : '−'}${_money.format(_d(a['total_cost']))}',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: gain ? AppColors.success : AppColors.warning)),
                        );
                      }).toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
