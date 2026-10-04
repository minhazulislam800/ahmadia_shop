// ============================================================
// transaction_report_screen.dart
// মূল ব্রিফের §10/§11/§12 অনুযায়ী — Sales Report ও Purchase Report,
// দুটোই এই একই widget দিয়ে চালানো হয় (mode অনুযায়ী), যাতে filter/
// table/export লজিক দুইবার আলাদাভাবে লিখতে না হয় ও দুই রিপোর্ট
// একই রকম আচরণ করে।
// ============================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/safe_share.dart';
import 'package:excel/excel.dart' as excel_lib;
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/report_pdf.dart';
import '../utils/txn_items.dart';

enum ReportMode { sale, purchase }

class TransactionReportScreen extends StatefulWidget {
  final ReportMode mode;
  const TransactionReportScreen({super.key, required this.mode});

  @override
  State<TransactionReportScreen> createState() => _TransactionReportScreenState();
}

class _TransactionReportScreenState extends State<TransactionReportScreen> {
  final _dbHelper = DBHelper.instance;
  final _currencyFormat =
      NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);

  bool get _isSale => widget.mode == ReportMode.sale;
  String get _title => _isSale ? 'বিক্রয় রিপোর্ট' : 'ক্রয় রিপোর্ট';
  String get _partyLabel => _isSale ? 'কাস্টমার' : 'সাপ্লায়ার';
  String get _tableName => _isSale ? 'sales' : 'purchases';
  String get _partyTable => _isSale ? 'customers' : 'suppliers';
  String get _partyIdCol => _isSale ? 'customer_id' : 'supplier_id';
  String get _dateCol => _isSale ? 'sale_date' : 'purchase_date';

  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  // প্রতিটা বিল/ক্রয়ের লাইন: পণ্য, পরিমাণ+একক, রেট, মোট
  Map<int, List<TxnItemLine>> _items = {};
  List<Map<String, dynamic>> _parties = [];
  List<Map<String, dynamic>> _products = [];

  // §11: Excel-এর মতো sortable table — client-side sort (রো সংখ্যা কম,
  // তাই আলাদা করে DB-তে ORDER BY পাল্টানোর দরকার নেই)
  int? _sortColumnIndex;
  bool _sortAscending = true;

  void _sortBy<T extends Comparable>(
      int columnIndex, bool ascending, T Function(Map<String, dynamic>) key) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
      _rows.sort((a, b) =>
          ascending ? key(a).compareTo(key(b)) : key(b).compareTo(key(a)));
    });
  }

  // §10: default-এ গত ১ মাস
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();
  int? _partyFilter;
  int? _productFilter;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadFilters();
    _load();
  }

  Future<void> _loadFilters() async {
    final db = await _dbHelper.database;
    final parties = await db.query(_partyTable, orderBy: 'name ASC');
    final products = await db.query('products', orderBy: 'name ASC');
    if (!mounted) return;
    setState(() {
      _parties = parties;
      _products = products;
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final from = DateFormat('yyyy-MM-dd').format(_fromDate);
    final to = DateFormat('yyyy-MM-dd').format(_toDate);

    final whereClauses = <String>['t.$_dateCol BETWEEN ? AND ?'];
    final args = <Object?>[from, to];
    if (_partyFilter != null) {
      whereClauses.add('t.$_partyIdCol = ?');
      args.add(_partyFilter);
    }
    if (_searchQuery.trim().isNotEmpty) {
      whereClauses.add('p.name LIKE ?');
      args.add('%${_searchQuery.trim()}%');
    }
    if (_productFilter != null) {
      whereClauses.add('p.id = ?');
      args.add(_productFilter);
    }

    final itemsTable = _isSale ? 'sale_items' : 'purchase_batches';
    final fkCol = _isSale ? 'sale_id' : 'purchase_id';
    final qtyCol = _isSale ? 'base_quantity' : 'quantity';

    // প্রতিটা transaction-এর সারাংশ: পণ্যের নাম-তালিকা, মোট quantity,
    // মোট টাকা — Excel-এর মতো এক-লাইনে দেখানোর জন্য
    final result = await db.rawQuery('''
      SELECT t.id, t.$_dateCol as tx_date, t.total_amount, t.paid_amount, t.is_credit,
             pt.name as party_name,
             GROUP_CONCAT(DISTINCT p.name) as product_names,
             SUM(i.$qtyCol) as total_qty
      FROM $_tableName t
      LEFT JOIN $_partyTable pt ON pt.id = t.$_partyIdCol
      JOIN $itemsTable i ON i.$fkCol = t.id
      JOIN products p ON p.id = i.product_id
      WHERE ${whereClauses.join(' AND ')}
      GROUP BY t.id
      ORDER BY t.$_dateCol DESC, t.id DESC
    ''', args);

    final ids = result.map((r) => r['id'] as int).toList();
    final items = _isSale
        ? await TxnItems.forSales(db, ids)
        : await TxnItems.forPurchases(db, ids);

    if (!mounted) return;
    setState(() {
      _rows = result;
      _items = items;
      _loading = false;
    });
  }

  double get _totalAmount =>
      _rows.fold(0, (sum, r) => sum + ((r['total_amount'] as num?)?.toDouble() ?? 0));
  double get _totalDue => _rows.fold(0, (sum, r) {
        final total = (r['total_amount'] as num?)?.toDouble() ?? 0;
        final paid = (r['paid_amount'] as num?)?.toDouble() ?? 0;
        final isCredit = (r['is_credit'] as int? ?? 0) == 1;
        return sum + (isCredit ? (total - paid) : 0);
      });

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _fromDate, end: _toDate),
    );
    if (picked == null) return;
    setState(() {
      _fromDate = picked.start;
      _toDate = picked.end;
    });
    _load();
  }

  // ---------------- §12: PDF/Excel Export ----------------

  Future<void> _exportPdf() async {
    final from = DateFormat('dd MMM yyyy').format(_fromDate);
    final to = DateFormat('dd MMM yyyy').format(_toDate);

    // প্রতিটা বিলের প্রতিটা লাইন: পণ্য, পরিমাণ+একক, রেট, মোট; তারপর বিলের মোট
    final tableRows = <List<String>>[];
    final boldRows = <int>{};
    for (final r in _rows) {
      final id = r['id'] as int;
      final lines = _items[id] ?? const <TxnItemLine>[];
      final total = (r['total_amount'] as num?)?.toDouble() ?? 0;
      final paid = (r['paid_amount'] as num?)?.toDouble() ?? 0;
      final isCredit = (r['is_credit'] as int? ?? 0) == 1;
      final due = isCredit ? total - paid : 0;
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        tableRows.add([
          i == 0 ? '${r['tx_date']}' : '',
          i == 0 ? '#$id' : '',
          i == 0 ? '${r['party_name'] ?? 'নগদ'}' : '',
          l.productName,
          l.quantityText,
          l.rateText,
          l.totalText,
        ]);
      }
      boldRows.add(tableRows.length);
      tableRows.add([
        '',
        '',
        '',
        due > 0
            ? 'বিলের মোট (বাকি ৳${due.toStringAsFixed(0)})'
            : 'বিলের মোট',
        '',
        '',
        '৳${total.toStringAsFixed(0)}',
      ]);
    }

    // বাংলা ঠিকভাবে দেখানোর জন্য পাতাগুলো ছবি করে PDF বানানো হয়
    final bytes = await ReportPdf.build(
      title: '$_title — Ahmadia Shop',
      subtitles: ['সময়কাল: $from — $to'],
      blocks: [
        ReportTable(
          headers: ['তারিখ', 'বিল', _partyLabel, 'পণ্য', 'পরিমাণ', 'রেট', 'টাকা'],
          flex: const [1.15, 0.6, 1.2, 1.5, 1.15, 0.8, 0.95],
          rightAlign: const [false, false, false, false, false, true, true],
          rows: tableRows,
          boldRows: boldRows,
        ),
        const ReportSpace(12),
        ReportKeyValue('মোট', '৳${_totalAmount.toStringAsFixed(0)}', bold: true),
        ReportKeyValue('মোট বাকি', '৳${_totalDue.toStringAsFixed(0)}'),
      ],
    );

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${_isSale ? "sales" : "purchase"}_report.pdf');
    await file.writeAsBytes(bytes);
    await SafeShare.files([file.path], text: _title);
  }

  Future<void> _exportExcel() async {
    final wb = excel_lib.Excel.createExcel();
    final sheet = wb[_title];
    excel_lib.TextCellValue t(String v) => excel_lib.TextCellValue(v);
    sheet.appendRow([
      t('তারিখ'),
      t('বিল #'),
      t(_partyLabel),
      t('পণ্য'),
      t('পরিমাণ'),
      t('একক'),
      t('রেট'),
      t('লাইনের টাকা'),
      t('বিলের মোট'),
      t('পরিশোধিত'),
      t('বাকি'),
    ]);
    for (final r in _rows) {
      final id = r['id'] as int;
      final lines = _items[id] ?? const <TxnItemLine>[];
      final total = (r['total_amount'] as num?)?.toDouble() ?? 0;
      final paid = (r['paid_amount'] as num?)?.toDouble() ?? 0;
      final isCredit = (r['is_credit'] as int? ?? 0) == 1;
      final due = isCredit ? total - paid : 0.0;
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        final first = i == 0; // বিলের মোট/বাকি শুধু প্রথম সারিতে — যোগ করলে দ্বিগুণ না হয়
        sheet.appendRow([
          t('${r['tx_date']}'),
          excel_lib.IntCellValue(id),
          t('${r['party_name'] ?? 'নগদ'}'),
          t(l.productName),
          excel_lib.DoubleCellValue(l.quantity),
          t(l.unit),
          excel_lib.DoubleCellValue(l.rate),
          excel_lib.DoubleCellValue(l.total),
          first ? excel_lib.DoubleCellValue(total) : t(''),
          first ? excel_lib.DoubleCellValue(paid) : t(''),
          first ? excel_lib.DoubleCellValue(due) : t(''),
        ]);
      }
    }
    sheet.appendRow([
      t(''), t(''), t(''), t(''), t(''), t(''), t(''),
      t('সর্বমোট'),
      excel_lib.DoubleCellValue(_totalAmount),
      t(''),
      excel_lib.DoubleCellValue(_totalDue),
    ]);

    final bytes = wb.encode();
    if (bytes == null) return;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${_isSale ? "sales" : "purchase"}_report.xlsx');
    await file.writeAsBytes(bytes);
    await SafeShare.files([file.path], text: '$_title (Excel)');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'PDF এক্সপোর্ট',
            onPressed: _rows.isEmpty ? null : _exportPdf,
          ),
          IconButton(
            icon: const Icon(Icons.table_chart_outlined),
            tooltip: 'Excel এক্সপোর্ট',
            onPressed: _rows.isEmpty ? null : _exportExcel,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickDateRange,
                        icon: const Icon(Icons.date_range, size: 18),
                        label: Text(
                            '${DateFormat('dd MMM').format(_fromDate)} — ${DateFormat('dd MMM yyyy').format(_toDate)}',
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int?>(
                        value: _partyFilter,
                        isExpanded: true,
                        decoration: InputDecoration(
                            labelText: _partyLabel, isDense: true),
                        items: [
                          const DropdownMenuItem<int?>(value: null, child: Text('সবাই')),
                          ..._parties.map((p) => DropdownMenuItem<int?>(
                              value: p['id'] as int, child: Text(p['name'] as String))),
                        ],
                        onChanged: (v) {
                          setState(() => _partyFilter = v);
                          _load();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int?>(
                        value: _productFilter,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'পণ্য', isDense: true),
                        items: [
                          const DropdownMenuItem<int?>(value: null, child: Text('সব পণ্য')),
                          ..._products.map((p) => DropdownMenuItem<int?>(
                              value: p['id'] as int, child: Text(p['name'] as String))),
                        ],
                        onChanged: (v) {
                          setState(() => _productFilter = v);
                          _load();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'পণ্যের নাম দিয়ে খুঁজুন',
                      isDense: true),
                  onChanged: (v) {
                    setState(() => _searchQuery = v);
                    _load();
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${_rows.length}টা এন্ট্রি',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                Text('মোট: ${_currencyFormat.format(_totalAmount)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? const Center(child: Text('এই ফিল্টারে কোনো এন্ট্রি নেই'))
                    : Scrollbar(
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            child: DataTable(
                              sortColumnIndex: _sortColumnIndex,
                              sortAscending: _sortAscending,
                              headingRowColor: WidgetStateProperty.all(AppColors.primaryLight),
                              dataRowMinHeight: 48,
                              dataRowMaxHeight: double.infinity,
                              columnSpacing: 20,
                              columns: [
                                DataColumn(
                                    label: const Text('#'),
                                    numeric: true,
                                    onSort: (i, asc) => _sortBy(i, asc, (r) => r['id'] as int)),
                                DataColumn(
                                    label: Text(_partyLabel),
                                    onSort: (i, asc) => _sortBy(
                                        i, asc, (r) => (r['party_name'] as String?) ?? 'নগদ')),
                                const DataColumn(label: Text('পণ্য')),
                                DataColumn(
                                    label: const Text('তারিখ'),
                                    onSort: (i, asc) =>
                                        _sortBy(i, asc, (r) => r['tx_date'] as String)),
                                DataColumn(
                                    label: const Text('মোট'),
                                    numeric: true,
                                    onSort: (i, asc) => _sortBy(
                                        i, asc, (r) => (r['total_amount'] as num?) ?? 0)),
                                const DataColumn(label: Text('বাকি'), numeric: true),
                              ],
                              rows: _rows.map((r) {
                                final total = (r['total_amount'] as num?)?.toDouble() ?? 0;
                                final paid = (r['paid_amount'] as num?)?.toDouble() ?? 0;
                                final isCredit = (r['is_credit'] as int? ?? 0) == 1;
                                final due = isCredit ? total - paid : 0;
                                return DataRow(cells: [
                                  DataCell(Text('${r['id']}')),
                                  DataCell(Text('${r['party_name'] ?? 'নগদ'}')),
                                  DataCell(SizedBox(
                                      width: 250,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 6),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: (_items[r['id'] as int] ??
                                                  const <TxnItemLine>[])
                                              .map((l) => Padding(
                                                    padding: const EdgeInsets.only(bottom: 2),
                                                    child: Text(l.summary,
                                                        style: const TextStyle(fontSize: 12.5)),
                                                  ))
                                              .toList(),
                                        ),
                                      ))),
                                  DataCell(Text('${r['tx_date']}')),
                                  DataCell(Text(_currencyFormat.format(total))),
                                  DataCell(due > 0
                                      ? Text(_currencyFormat.format(due),
                                          style: const TextStyle(color: AppColors.danger))
                                      : const Text('—')),
                                ]);
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
