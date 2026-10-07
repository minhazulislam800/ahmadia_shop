// ============================================================
// reports_screen.dart
// মাসিক বিক্রয়/লাভ ট্রেন্ড গ্রাফ, বেস্ট-সেলিং পণ্য, আর
// ইনভেন্টরি রিপোর্ট PDF/Excel এক্সপোর্ট
// ============================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/safe_share.dart';
import 'package:excel/excel.dart' as excel_lib;
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/full_export.dart';
import '../utils/report_pdf.dart';
import 'expense_report_screen.dart';
import 'transaction_report_screen.dart';
import 'year_end_summary_screen.dart';
import '../widgets/app_bottom_nav.dart';

class ReportsScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const ReportsScreen({super.key, required this.currentUser});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _dbHelper = DBHelper.instance;

  bool _loading = true;
  List<Map<String, dynamic>> _monthlyData = [];
  List<Map<String, dynamic>> _bestSelling = [];
  List<Map<String, dynamic>> _inventory = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;

    // মাসিক নিট লাভের ট্রেন্ড (গত ৬ মাস) = বিক্রয়ের লাভ − ফেরতে যাওয়া লাভ
    // − খরচ ± স্টক সমন্বয়, প্রতিটা মাসের নিজস্ব তারিখ ধরে — তাই সব মাসের
    // যোগফল ড্যাশবোর্ডের নিট প্রফিটের সাথে মেলে
    final profitByMonth = <String, double>{};
    void addMonthly(List<Map<String, Object?>> rows, double sign) {
      for (final r in rows) {
        final month = r['month'] as String?;
        if (month == null) continue;
        profitByMonth[month] = (profitByMonth[month] ?? 0) +
            sign * ((r['total'] as num?)?.toDouble() ?? 0);
      }
    }

    addMonthly(
        await db.rawQuery('''
      SELECT strftime('%Y-%m', s.sale_date) as month,
             SUM((si.unit_price * si.quantity) - si.total_cost) as total
      FROM sale_items si JOIN sales s ON s.id = si.sale_id
      GROUP BY month
    '''),
        1);
    addMonthly(
        await db.rawQuery('''
      SELECT strftime('%Y-%m', return_date) as month,
             SUM(refund_amount - cost_amount) as total
      FROM sale_returns GROUP BY month
    '''),
        -1);
    addMonthly(
        await db.rawQuery('''
      SELECT strftime('%Y-%m', expense_date) as month, SUM(amount) as total
      FROM expenses GROUP BY month
    '''),
        -1);
    addMonthly(
        await db.rawQuery('''
      SELECT strftime('%Y-%m', adjustment_date) as month,
             SUM(CASE WHEN base_quantity > 0 THEN total_cost
                      ELSE -total_cost END) as total
      FROM stock_adjustments GROUP BY month
    '''),
        1);
    final sortedMonths = profitByMonth.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final monthly = sortedMonths
        .take(6)
        .map((m) => <String, dynamic>{'month': m, 'profit': profitByMonth[m]})
        .toList();

    // বেস্ট-সেলিং পণ্য (পরিমাণ অনুযায়ী) — ফেরত বাদ দিয়ে নিট পরিমাণ ও লাভ
    // Phase 1 (multi-unit) সংশোধন: si.quantity বিক্রিত unit-এ থাকে
    // (pack হলে pack-সংখ্যা) — বিভিন্ন বিক্রয় বিভিন্ন unit-এ হলে
    // সরাসরি SUM(si.quantity) করলে ভুল/অর্থহীন যোগফল হতো (যেমন
    // "2 pack" + "3 kg" যোগ করে ফেলা)। si.base_quantity সবসময়
    // product-এর base unit-এই থাকে বলে সেটাই এখানে ব্যবহার করা হচ্ছে,
    // ফলাফল p.unit (base unit) দিয়ে সঠিকভাবে লেবেল করা যাচ্ছে।
    final bestSelling = await db.rawQuery('''
      SELECT p.name, p.unit,
             SUM(si.base_quantity - COALESCE((SELECT SUM(sr.quantity) FROM sale_returns sr
                 WHERE sr.sale_item_id = si.id), 0) * si.base_quantity / si.quantity) as total_qty,
             SUM((si.unit_price * si.quantity) - si.total_cost
                 - COALESCE((SELECT SUM(sr.refund_amount - sr.cost_amount) FROM sale_returns sr
                 WHERE sr.sale_item_id = si.id), 0)) as total_profit
      FROM sale_items si
      JOIN products p ON p.id = si.product_id
      GROUP BY si.product_id
      ORDER BY total_qty DESC
      LIMIT 10
    ''');

    // বর্তমান ইনভেন্টরি
    final inventory = await db.rawQuery('''
      SELECT p.name, p.unit,
             COALESCE(SUM(pb.remaining_quantity), 0) as stock,
             COALESCE(SUM(pb.remaining_quantity * pb.unit_cost), 0) as value
      FROM products p
      LEFT JOIN purchase_batches pb ON pb.product_id = p.id
      WHERE p.is_active = 1
      GROUP BY p.id
      ORDER BY p.name ASC
    ''');

    if (!mounted) return;
    setState(() {
      _monthlyData = monthly.reversed.toList();
      _bestSelling = bestSelling;
      _inventory = inventory;
      _loading = false;
    });
  }

  Future<void> _exportInventoryPdf() async {
    // বাংলা ঠিকভাবে দেখানোর জন্য পাতাগুলো ছবি করে PDF বানানো হয়
    final bytes = await ReportPdf.build(
      title: 'ইনভেন্টরি রিপোর্ট — Ahmadia Shop',
      subtitles: ['তারিখ: ${DateFormat('yyyy-MM-dd').format(DateTime.now())}'],
      blocks: [
        ReportTable(
          headers: const ['পণ্য', 'স্টক', 'মূল্য'],
          flex: const [2.4, 1.4, 1.2],
          rightAlign: const [false, false, true],
          rows: _inventory
              .map((item) => [
                    '${item['name']}',
                    '${item['stock']} ${item['unit']}',
                    '৳${(item['value'] as num).toStringAsFixed(0)}',
                  ])
              .toList(),
        ),
      ],
    );

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/inventory_report.pdf');
    await file.writeAsBytes(bytes);
    await SafeShare.files([file.path], text: 'ইনভেন্টরি রিপোর্ট');
  }

  Future<void> _exportInventoryExcel() async {
    final wb = excel_lib.Excel.createExcel();
    final sheet = wb['ইনভেন্টরি'];
    sheet.appendRow(['পণ্য', 'স্টক', 'ইউনিট', 'মূল্য'].map((e) => excel_lib.TextCellValue(e)).toList());
    for (final item in _inventory) {
      sheet.appendRow([
        excel_lib.TextCellValue(item['name'] as String),
        excel_lib.DoubleCellValue((item['stock'] as num).toDouble()),
        excel_lib.TextCellValue(item['unit'] as String),
        excel_lib.DoubleCellValue((item['value'] as num).toDouble()),
      ]);
    }
    final bytes = wb.encode();
    if (bytes == null) return;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/inventory_report.xlsx');
    await file.writeAsBytes(bytes);
    await SafeShare.files([file.path], text: 'ইনভেন্টরি রিপোর্ট (Excel)');
  }

  bool _exportingAll = false;

  // অ্যাপের সব তথ্য একটা Excel ওয়ার্কবুকে (প্রতি বিষয়ের আলাদা শিট)
  Future<void> _exportEverything() async {
    if (_exportingAll) return;
    setState(() => _exportingAll = true);
    try {
      final bytes = await FullExport.build();
      if (bytes == null) throw Exception('ফাইল তৈরি করা যায়নি');
      final dir = await getTemporaryDirectory();
      final stamp = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
      final file = File('${dir.path}/AhmadiaShop_সব_তথ্য_$stamp.xlsx');
      await file.writeAsBytes(bytes);
      await SafeShare.files([file.path], text: 'Ahmadia Shop — সব তথ্য (Excel)');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('এক্সপোর্ট ব্যর্থ: $e')));
    } finally {
      if (mounted) setState(() => _exportingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('রিপোর্ট')),
      bottomNavigationBar: AppBottomNav(currentTab: AppTab.reports, currentUser: widget.currentUser),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: _exportingAll
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download_for_offline_outlined,
                            color: AppColors.primary),
                    title: const Text('সব তথ্য Excel-এ এক্সপোর্ট',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'বিক্রয়, ক্রয়, খরচ, মূলধন, কাস্টমার, পণ্য, স্টক, ক্যাশ — সব একটা ফাইলে, প্রতিটার আলাদা শিটে'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _exportingAll ? null : _exportEverything,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: AppColors.primaryLight,
                  child: ListTile(
                    leading: const Icon(Icons.calendar_month_outlined,
                        color: AppColors.primary),
                    title: const Text('ইয়ার-এন্ড সামারি',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('বছর বেছে নিয়ে সম্পূর্ণ বাৎসরিক হিসাব দেখুন'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const YearEndSummaryScreen())),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.point_of_sale_outlined),
                    title: const Text('বিক্রয় রিপোর্ট'),
                    subtitle: const Text('ফিল্টার, PDF/Excel এক্সপোর্ট সহ বিস্তারিত তালিকা'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                const TransactionReportScreen(mode: ReportMode.sale))),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.shopping_cart_outlined),
                    title: const Text('ক্রয় রিপোর্ট'),
                    subtitle: const Text('ফিল্টার, PDF/Excel এক্সপোর্ট সহ বিস্তারিত তালিকা'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                const TransactionReportScreen(mode: ReportMode.purchase))),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('খরচ রিপোর্ট'),
                    subtitle: const Text(
                        'ক্যাটাগরি অনুযায়ী খরচ, স্টক নষ্ট/গিফটের ক্ষতিসহ — PDF/Excel'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ExpenseReportScreen())),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('মাসিক বিক্রয় ও লাভের ট্রেন্ড',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 12),
                if (_monthlyData.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('এখনো পর্যাপ্ত ডেটা নেই'),
                  )
                else
                  SizedBox(
                    height: 220,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: BarChart(
                          BarChartData(
                            alignment: BarChartAlignment.spaceAround,
                            titlesData: FlTitlesData(
                              leftTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget: (value, meta) {
                                    final i = value.toInt();
                                    if (i < 0 || i >= _monthlyData.length) {
                                      return const SizedBox();
                                    }
                                    final month = _monthlyData[i]['month'] as String;
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(month.substring(5),
                                          style: const TextStyle(fontSize: 10)),
                                    );
                                  },
                                ),
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            gridData: const FlGridData(show: false),
                            barGroups: _monthlyData.asMap().entries.map((e) {
                              final profit =
                                  (e.value['profit'] as num?)?.toDouble() ?? 0;
                              return BarChartGroupData(x: e.key, barRods: [
                                BarChartRodData(
                                  toY: profit,
                                  color: profit >= 0
                                      ? AppColors.success
                                      : AppColors.danger,
                                  width: 18,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ]);
                            }).toList(),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                const Text('বেস্ট-সেলিং পণ্য',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: _bestSelling.isEmpty
                        ? [const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('এখনো কোনো বিক্রয় নেই'))]
                        : _bestSelling.asMap().entries.map((e) {
                            final item = e.value;
                            return ListTile(
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: AppColors.primaryLight,
                                child: Text('${e.key + 1}',
                                    style: const TextStyle(fontSize: 12, color: AppColors.primary)),
                              ),
                              title: Text(item['name'] as String),
                              subtitle: Text('বিক্রি: ${item['total_qty']} ${item['unit']}'),
                              trailing: Text(
                                  '৳${(item['total_profit'] as num).toStringAsFixed(0)} লাভ',
                                  style: const TextStyle(color: AppColors.success)),
                            );
                          }).toList(),
                  ),
                ),
                const SizedBox(height: 24),
                const Text('ইনভেন্টরি রিপোর্ট এক্সপোর্ট',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _exportInventoryPdf,
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('PDF'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _exportInventoryExcel,
                        icon: const Icon(Icons.table_chart_outlined),
                        label: const Text('Excel'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}
