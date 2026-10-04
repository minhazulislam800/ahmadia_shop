// ============================================================
// dashboard_screen.dart
// অ্যাপের হোমপেজ — ক্যাশ, বাকি, ইনভেন্টরি ভ্যালু, নিট প্রফিট,
// লো-স্টক সতর্কতা এক নজরে, আর সব মডিউলে যাওয়ার শর্টকাট
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../database/backup_service.dart';
import '../utils/app_theme.dart';
import '../utils/crash_log.dart';
import '../utils/route_observer.dart';
import 'product_screen.dart';
import 'expense_screen.dart';
import 'capital_screen.dart';
import 'backup_screen.dart';
import 'returns_screen.dart';
import 'customer_ledger_screen.dart';
import 'supplier_ledger_screen.dart';
import 'settings_screen.dart';
import 'invoice_list_screen.dart';
import 'bulk_import_screen.dart';
import 'stock_adjustment_screen.dart';
import '../widgets/app_bottom_nav.dart';

class DashboardScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const DashboardScreen({super.key, required this.currentUser});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with RouteAware {
  final _dbHelper = DBHelper.instance;
  final _backupService = BackupService();
  final _currencyFormat = NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);

  bool _loading = true;
  double _cash = 0;
  double _receivables = 0;
  double _payables = 0;
  double _inventoryValue = 0;
  double _netProfit = 0;
  double _availableProfit = 0;
  List<Map<String, dynamic>> _lowStock = [];
  DateTime? _lastBackupTime;

  @override
  void initState() {
    super.initState();
    _loadData();
    _runAutoBackup();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) CrashLog.showPreviousIfAny(context);
    });
  }

  // অ্যাপ খুললেই চেক: ১০ দিনের বেশি হলে এবং ডেটা বদলে থাকলে নিজে থেকে
  // ফোনের স্টোরেজে ব্যাকআপ। ব্যর্থ হলে চুপচাপ থাকে, কাজ আটকায় না।
  Future<void> _runAutoBackup() async {
    try {
      // স্ক্রিন পুরোপুরি দাঁড়িয়ে যাওয়ার পরে ভারী কাজটা শুরু হোক
      await Future.delayed(const Duration(seconds: 6));
      if (!mounted) return;
      final changed = await _backupService.autoBackupIfNeeded();
      if (changed && mounted) _loadData();
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  // বিক্রয়/ক্রয়/অন্য কোনো স্ক্রিন থেকে হোমে ফিরলে সংখ্যাগুলো নতুন করে লোড হবে
  @override
  void didPopNext() {
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;

    final cash = await _dbHelper.getCurrentCash(db);
    final receivables = await _dbHelper.getTotalReceivables(db);
    final payables = await _dbHelper.getTotalPayables(db);
    final inventoryValue = await _dbHelper.getInventoryValue(db);
    final netProfit = await _dbHelper.getNetProfit(db);
    final availableProfit = await _dbHelper.getAvailableProfit(db);
    final lowStock = await _dbHelper.getLowStockProducts(db);
    final lastBackupTime = await _backupService.getLastBackupTime();

    if (!mounted) return;
    setState(() {
      _cash = cash;
      _receivables = receivables;
      _payables = payables;
      _inventoryValue = inventoryValue;
      _netProfit = netProfit;
      _availableProfit = availableProfit;
      _lowStock = lowStock;
      _lastBackupTime = lastBackupTime;
      _loading = false;
    });
  }

  Widget _statCard(String title, double amount, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
              _currencyFormat.format(amount),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: amount < 0 ? AppColors.danger : AppColors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickAction(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final role = widget.currentUser['role'] == 'master' ? 'মাস্টার' : 'নরমাল';

    return Scaffold(
      bottomNavigationBar: AppBottomNav(currentTab: AppTab.dashboard, currentUser: widget.currentUser),
      appBar: AppBar(
        title: const Text('Ahmadia Shop'),
        actions: [
          // সার্চ আইকন সরানো হয়েছে — এখন bottom nav-এর "খুঁজুন" ট্যাবেই আছে
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(
                  builder: (_) => SettingsScreen(currentUser: widget.currentUser)));
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadData,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('স্বাগতম, ${widget.currentUser['username']} ($role)',
                      style: const TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 12),

                  if (_lastBackupTime == null ||
                      DateTime.now().difference(_lastBackupTime!).inDays >=
                          BackupService.staleWarningDays)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.warning.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded,
                              color: AppColors.warning, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _lastBackupTime == null
                                  ? 'এখনো কোনো ব্যাকআপ নেওয়া হয়নি'
                                  : 'ব্যাকআপের অনেক দিন হয়ে গেছে',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              await Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => BackupScreen(currentUser: widget.currentUser)));
                              _loadData();
                            },
                            child: const Text('এখনই নিন', style: TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    ),

                  // নিট প্রফিট — সবচেয়ে গুরুত্বপূর্ণ সংখ্যা, বড় করে দেখানো
                  Card(
                    color: _netProfit >= 0
                        ? AppColors.success.withOpacity(0.08)
                        : AppColors.danger.withOpacity(0.08),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _netProfit >= 0 ? 'নিট লাভ' : 'নিট লোকসান',
                            style: const TextStyle(color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _currencyFormat.format(_netProfit.abs()),
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: _netProfit >= 0
                                  ? AppColors.success
                                  : AppColors.danger,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'উত্তোলনযোগ্য অবশিষ্ট লাভ: ${_currencyFormat.format(_availableProfit)}',
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.4,
                    children: [
                      _statCard('ক্যাশ ইন হ্যান্ড', _cash,
                          Icons.account_balance_wallet_outlined, AppColors.primary),
                      _statCard('ইনভেন্টরি ভ্যালু', _inventoryValue,
                          Icons.inventory_2_outlined, AppColors.primary),
                      _statCard('মোট পাওনা (কাস্টমার)', _receivables,
                          Icons.arrow_downward_rounded, AppColors.success),
                      _statCard('মোট দেনা (সাপ্লায়ার)', _payables,
                          Icons.arrow_upward_rounded, AppColors.danger),
                    ],
                  ),

                  if (_lowStock.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: AppColors.warning, size: 18),
                        const SizedBox(width: 6),
                        Text('লো-স্টক সতর্কতা (${_lowStock.length}টি পণ্য)',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Column(
                        children: _lowStock.map((p) {
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.inventory_2_outlined,
                                color: AppColors.warning),
                            title: Text(p['name'] as String),
                            trailing: Text(
                                '${p['current_stock']} ${p['unit']}',
                                style: const TextStyle(
                                    color: AppColors.warning,
                                    fontWeight: FontWeight.w600)),
                          );
                        }).toList(),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),
                  const Text('দ্রুত অ্যাকশন',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.9,
                    children: [
                      // ক্রয়/বিক্রয়/রিপোর্ট এখন bottom navigation bar-এ
                      // সবসময় এক-ট্যাপ দূরত্বে আছে (§5.৩) — তাই এখানে
                      // grid-এ আর ডুপ্লিকেট রাখা হয়নি, clutter কমাতে
                      _quickAction('পণ্য', Icons.category_outlined, () async {
                        await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => ProductScreen(
                                currentUser: widget.currentUser)));
                        _loadData();
                      }),
                      _quickAction('খরচ', Icons.receipt_long_outlined, () async {
                        await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => ExpenseScreen(
                                currentUser: widget.currentUser)));
                        _loadData();
                      }),
                      _quickAction('মূলধন', Icons.account_balance_outlined, () async {
                        await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => CapitalScreen(
                                currentUser: widget.currentUser)));
                        _loadData();
                      }),
                      _quickAction('ইনভয়েস', Icons.description_outlined, () {
                        Navigator.push(context, MaterialPageRoute(
                            builder: (_) => InvoiceListScreen(
                                currentUser: widget.currentUser)));
                      }),
                      _quickAction('ব্যাকআপ', Icons.cloud_upload_outlined, () async {
                        await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => BackupScreen(currentUser: widget.currentUser)));
                        _loadData();
                      }),
                      _quickAction('রিটার্ন', Icons.keyboard_return_outlined, () async {
                        await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => ReturnsScreen(
                                currentUser: widget.currentUser)));
                        _loadData();
                      }),
                      _quickAction('কাস্টমার', Icons.people_outline, () {
                        Navigator.push(context, MaterialPageRoute(
                            builder: (_) => CustomerLedgerScreen(
                                currentUser: widget.currentUser)));
                      }),
                      _quickAction('সাপ্লায়ার', Icons.local_shipping_outlined, () {
                        Navigator.push(context, MaterialPageRoute(
                            builder: (_) => SupplierLedgerScreen(
                                currentUser: widget.currentUser)));
                      }),
                      _quickAction('বাল্ক ইমপোর্ট', Icons.upload_file_outlined, () async {
                        await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => const BulkImportScreen()));
                        _loadData();
                      }),
                      _quickAction('স্টক সমন্বয়', Icons.inventory_2_outlined, () async {
                        await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => StockAdjustmentScreen(
                                currentUser: widget.currentUser)));
                        _loadData();
                      }),
                    ],
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
}
