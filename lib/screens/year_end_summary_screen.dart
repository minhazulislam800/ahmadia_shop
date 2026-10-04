// ============================================================
// year_end_summary_screen.dart
// একটা নির্দিষ্ট বছরের সম্পূর্ণ হিসাব — মোট বিক্রয়, ক্রয়, খরচ,
// গ্রস/নিট প্রফিট, প্রতি পার্টনারের চূড়ান্ত ভাগ — এক জায়গায়,
// PDF আকারে এক্সপোর্ট করার সুবিধাসহ
// ============================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/report_pdf.dart';

class YearEndSummaryScreen extends StatefulWidget {
  const YearEndSummaryScreen({super.key});

  @override
  State<YearEndSummaryScreen> createState() => _YearEndSummaryScreenState();
}

class _YearEndSummaryScreenState extends State<YearEndSummaryScreen> {
  final _dbHelper = DBHelper.instance;
  final _currencyFormat =
      NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);

  int _selectedYear = DateTime.now().year;
  bool _loading = true;

  double _totalSales = 0;
  double _totalPurchases = 0;
  double _grossProfit = 0;
  double _totalExpenses = 0;
  double _stockAdjustment = 0; // নষ্ট/গিফট/নমুনা বাবদ ক্ষতি (ঋণাত্মক) বা অতিরিক্ত পাওয়া (ধনাত্মক)
  double _netProfit = 0;
  int _totalSalesCount = 0;
  int _totalPurchaseCount = 0;
  List<Map<String, dynamic>> _partners = [];
  List<Map<String, dynamic>> _expenseByCategory = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final yearStr = _selectedYear.toString();

    final salesResult = await db.rawQuery('''
      SELECT COUNT(*) as cnt, COALESCE(SUM(total_amount), 0) as total
      FROM sales WHERE strftime('%Y', sale_date) = ?
    ''', [yearStr]);
    // নগদে ফেরত দেওয়া বিক্রয়-ফেরত বাদ দিয়ে নিট বিক্রয় (বাকির সাথে সমন্বয় করা
    // ফেরত sales.total_amount-এ আগেই বাদ গেছে)
    final saleRefundResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total FROM cash_ledger
      WHERE reference_type = 'sale_return' AND strftime('%Y', transaction_date) = ?
    ''', [yearStr]);
    _totalSales = (salesResult.first['total'] as num).toDouble() -
        (saleRefundResult.first['total'] as num).toDouble();
    _totalSalesCount = salesResult.first['cnt'] as int;

    final purchaseResult = await db.rawQuery('''
      SELECT COUNT(*) as cnt, COALESCE(SUM(total_amount), 0) as total
      FROM purchases WHERE strftime('%Y', purchase_date) = ?
    ''', [yearStr]);
    final purchaseRefundResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total FROM cash_ledger
      WHERE reference_type = 'purchase_return' AND strftime('%Y', transaction_date) = ?
    ''', [yearStr]);
    _totalPurchases = (purchaseResult.first['total'] as num).toDouble() -
        (purchaseRefundResult.first['total'] as num).toDouble();
    _totalPurchaseCount = purchaseResult.first['cnt'] as int;

    final grossResult = await db.rawQuery('''
      SELECT COALESCE(SUM((si.unit_price * si.quantity) - si.total_cost), 0) as profit
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE strftime('%Y', s.sale_date) = ?
    ''', [yearStr]);
    // বিক্রয় ফেরতে যে লাভটুকু ফেরত গেছে সেটা বাদ (ফেরতের বছর অনুযায়ী) —
    // ড্যাশবোর্ডের গ্রস প্রফিটের সাথে মিল রাখতে
    final returnsResult = await db.rawQuery('''
      SELECT COALESCE(SUM(refund_amount - cost_amount), 0) as total
      FROM sale_returns WHERE strftime('%Y', return_date) = ?
    ''', [yearStr]);
    _grossProfit = (grossResult.first['profit'] as num).toDouble() -
        (returnsResult.first['total'] as num).toDouble();

    final adjustmentResult = await db.rawQuery('''
      SELECT COALESCE(SUM(CASE WHEN base_quantity > 0 THEN total_cost
                               ELSE -total_cost END), 0) as total
      FROM stock_adjustments WHERE strftime('%Y', adjustment_date) = ?
    ''', [yearStr]);
    _stockAdjustment = (adjustmentResult.first['total'] as num).toDouble();

    final expenseResult = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total
      FROM expenses WHERE strftime('%Y', expense_date) = ?
    ''', [yearStr]);
    _totalExpenses = (expenseResult.first['total'] as num).toDouble();

    final expenseByCategory = await db.rawQuery('''
      SELECT category, COALESCE(SUM(amount), 0) as total
      FROM expenses WHERE strftime('%Y', expense_date) = ?
      GROUP BY category ORDER BY total DESC
    ''', [yearStr]);

    _netProfit = _grossProfit - _totalExpenses + _stockAdjustment;

    final partners = await db.query('partners', orderBy: 'id ASC');
    final partnersWithShare = partners.map((p) {
      final share = (p['profit_share_percent'] as num).toDouble();
      return {
        ...p,
        'year_share': _netProfit * (share / 100),
      };
    }).toList();

    if (!mounted) return;
    setState(() {
      _partners = partnersWithShare;
      _expenseByCategory = expenseByCategory;
      _loading = false;
    });
  }

  Future<void> _exportPdf() async {
    String taka(double v) => '৳${v.toStringAsFixed(0)}';
    String label(String l, int? count) => count != null ? '$l ($count টি)' : l;

    // বাংলা ঠিকভাবে দেখানোর জন্য পাতাগুলো ছবি করে PDF বানানো হয়
    final bytes = await ReportPdf.build(
      title: 'বাৎসরিক সামারি — $_selectedYear',
      subtitles: const ['Ahmadia Shop'],
      blocks: [
        ReportKeyValue(label('মোট বিক্রয়', _totalSalesCount), taka(_totalSales)),
        ReportKeyValue(label('মোট ক্রয়', _totalPurchaseCount), taka(_totalPurchases)),
        ReportKeyValue('গ্রস প্রফিট', taka(_grossProfit)),
        ReportKeyValue('মোট খরচ', taka(_totalExpenses)),
        if (_stockAdjustment != 0)
          ReportKeyValue(
              _stockAdjustment < 0
                  ? 'স্টক নষ্ট/গিফট বাবদ ক্ষতি'
                  : 'স্টক অতিরিক্ত পাওয়া (লাভ)',
              taka(_stockAdjustment.abs())),
        const ReportDivider(),
        ReportKeyValue('নিট প্রফিট', taka(_netProfit), bold: true),
        const ReportSpace(12),
        const ReportHeading('পার্টনার-ভিত্তিক ভাগ'),
        ..._partners.map((p) => ReportKeyValue(
            '${p['name']} (${p['profit_share_percent']}%)',
            taka((p['year_share'] as num).toDouble()))),
        const ReportSpace(12),
        const ReportHeading('খরচের বিবরণ'),
        ..._expenseByCategory.map((e) => ReportKeyValue(
            e['category'] as String, taka((e['total'] as num).toDouble()))),
      ],
    );

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/year_end_summary_$_selectedYear.pdf');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)],
        text: '$_selectedYear সালের বাৎসরিক সামারি — Ahmadia Shop');
  }

  Widget _summaryRow(String label, double amount,
      {int? count, bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(count != null ? '$label ($count টি)' : label,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w700 : FontWeight.normal)),
          Text(_currencyFormat.format(amount),
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                  fontSize: bold ? 17 : 14,
                  color: color ?? AppColors.textPrimary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentYear = DateTime.now().year;
    final years = List.generate(6, (i) => currentYear - i);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ইয়ার-এন্ড সামারি'),
        actions: [
          IconButton(icon: const Icon(Icons.share_outlined), onPressed: _exportPdf),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<int>(
                  value: _selectedYear,
                  decoration: const InputDecoration(labelText: 'বছর বেছে নিন'),
                  items: years
                      .map((y) => DropdownMenuItem(value: y, child: Text('$y')))
                      .toList(),
                  onChanged: (val) {
                    setState(() => _selectedYear = val!);
                    _load();
                  },
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _summaryRow('মোট বিক্রয়', _totalSales, count: _totalSalesCount),
                        const Divider(),
                        _summaryRow('মোট ক্রয়', _totalPurchases, count: _totalPurchaseCount),
                        const Divider(),
                        _summaryRow('গ্রস প্রফিট', _grossProfit, color: AppColors.success),
                        const Divider(),
                        _summaryRow('মোট খরচ', _totalExpenses, color: AppColors.danger),
                        const Divider(),
                        if (_stockAdjustment != 0) ...[
                          _summaryRow(
                            _stockAdjustment < 0
                                ? 'স্টক নষ্ট/গিফট বাবদ ক্ষতি'
                                : 'স্টক অতিরিক্ত পাওয়া (লাভ)',
                            _stockAdjustment.abs(),
                            color: _stockAdjustment < 0
                                ? AppColors.danger
                                : AppColors.success,
                          ),
                          const Divider(),
                        ],
                        _summaryRow(
                          _netProfit >= 0 ? 'নিট প্রফিট' : 'নিট লোকসান',
                          _netProfit.abs(),
                          bold: true,
                          color: _netProfit >= 0 ? AppColors.success : AppColors.danger,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('পার্টনার-ভিত্তিক ভাগ',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: _partners.map((p) {
                        return _summaryRow(
                          '${p['name']} (${p['profit_share_percent']}%)',
                          (p['year_share'] as num).toDouble(),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (_expenseByCategory.isNotEmpty) ...[
                  const Text('খরচের বিবরণ (ক্যাটাগরি অনুযায়ী)',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: _expenseByCategory.map((e) {
                          return _summaryRow(
                              e['category'] as String, (e['total'] as num).toDouble());
                        }).toList(),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}
