// ============================================================
// customer_ledger_screen.dart
// কাস্টমারের তালিকা (বাকি অনুযায়ী), প্রতিজনের সম্পূর্ণ কেনাকাটার
// ইতিহাস, আর বাকি থাকলে হোয়াটসঅ্যাপে রিমাইন্ডার পাঠানোর বাটন
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../database/db_helper.dart';
import '../database/transaction_service.dart';
import '../utils/app_theme.dart';
import '../widgets/date_field.dart';

class CustomerLedgerScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const CustomerLedgerScreen({super.key, required this.currentUser});

  @override
  State<CustomerLedgerScreen> createState() => _CustomerLedgerScreenState();
}

class _CustomerLedgerScreenState extends State<CustomerLedgerScreen> {
  final _dbHelper = DBHelper.instance;
  final _transactionService = TransactionService();
  final _currencyFormat = NumberFormat.currency(locale: 'bn_BD', symbol: '৳ ', decimalDigits: 0);
  List<Map<String, dynamic>> _customers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await _dbHelper.database;
    final result = await db.rawQuery('''
      SELECT c.*,
        COALESCE((SELECT SUM(total_amount) FROM sales WHERE customer_id = c.id), 0) as total_purchase,
        COALESCE((SELECT SUM(total_amount - paid_amount) FROM sales WHERE customer_id = c.id AND is_credit = 1), 0)
        - COALESCE((SELECT SUM(amount) FROM due_payments WHERE party_type = 'customer' AND party_id = c.id), 0) as due
      FROM customers c
      ORDER BY due DESC
    ''');
    if (!mounted) return;
    setState(() {
      _customers = result;
      _loading = false;
    });
  }

  Future<void> _showCollectPaymentDialog(Map<String, dynamic> customer, double due) async {
    final amountController = TextEditingController();
    DateTime paymentDate = DateTime.now();
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) => AlertDialog(
        title: Text('${customer['name']} — বাকি আদায়'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('মোট বাকি: ${_currencyFormat.format(due)}'),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'কত টাকা পাচ্ছেন'),
            ),
            const SizedBox(height: 12),
            DateField(
              date: paymentDate,
              onChanged: (d) => setDialogState(() => paymentDate = d),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final amount = double.tryParse(amountController.text) ?? 0;
              if (amount <= 0) return;
              if (amount > due + 0.005) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: Text(
                        'বাকির চেয়ে বেশি নেওয়া যাবে না (বাকি: ${_currencyFormat.format(due)})')));
                return;
              }
              await _transactionService.recordDuePayment(
                partyType: 'customer',
                partyId: customer['id'] as int,
                referenceType: 'manual',
                referenceId: null,
                amount: amount,
                date: DateFormat('yyyy-MM-dd').format(paymentDate),
                createdBy: widget.currentUser['id'] as int?,
              );
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _load();
            },
            child: const Text('আদায় সংরক্ষণ করুন'),
          ),
        ],
      )),
    );
  }

  Future<void> _sendWhatsAppReminder(Map<String, dynamic> customer, double due) async {
    final phone = (customer['phone'] as String? ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('এই কাস্টমারের ফোন নম্বর নেই')));
      return;
    }
    final message = Uri.encodeComponent(
        'প্রিয় ${customer['name']}, আপনার কাছে ${_currencyFormat.format(due)} টাকা বাকি আছে। '
        'দয়া করে সুবিধামতো সময়ে পরিশোধ করুন। ধন্যবাদ — Ahmadia Shop');
    // বাংলাদেশি নম্বর হলে +88 যোগ করা (যদি আগে থেকে না থাকে)
    final fullPhone = phone.startsWith('88') ? phone : '88$phone';
    final url = Uri.parse('https://wa.me/$fullPhone?text=$message');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('হোয়াটসঅ্যাপ খোলা যায়নি')));
    }
  }

  bool get _isMaster => widget.currentUser['role'] == 'master';

  // ফোন নম্বর normalize করা (party_selector.dart-এর নিয়ম অনুযায়ী,
  // ডুপ্লিকেট-চেকের সময় সামঞ্জস্যপূর্ণ রাখতে)
  String _normalizePhone(String phone) => phone.replaceAll(RegExp(r'[^0-9]'), '');

  // §6: নাম/ফোন/ঠিকানা edit — পুরনো বিক্রয়ের ইতিহাসে কোনো প্রভাব পড়বে না
  // (sale.customer_id একই থাকে, শুধু customers row-এর তথ্য বদলায়)
  Future<void> _showEditCustomerDialog(Map<String, dynamic> customer) async {
    final nameController = TextEditingController(text: customer['name'] as String);
    final phoneController =
        TextEditingController(text: customer['phone'] as String? ?? '');
    final addressController =
        TextEditingController(text: customer['address'] as String? ?? '');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('কাস্টমার তথ্য সম্পাদনা'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'নাম')),
            const SizedBox(height: 12),
            TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'ফোন নম্বর')),
            const SizedBox(height: 12),
            TextField(
                controller: addressController,
                decoration: const InputDecoration(labelText: 'ঠিকানা (ঐচ্ছিক)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final phone = _normalizePhone(phoneController.text.trim());
              if (name.isEmpty || phone.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('নাম ও ফোন নম্বর আবশ্যক')));
                return;
              }
              final db = await _dbHelper.database;
              await db.update(
                  'customers',
                  {
                    'name': name,
                    'phone': phoneController.text.trim(),
                    'address': addressController.text.trim(),
                  },
                  where: 'id = ?',
                  whereArgs: [customer['id']]);
              await _dbHelper.logActivity(
                  userId: widget.currentUser['id'] as int?,
                  action: 'update',
                  entityType: 'customer',
                  entityId: customer['id'] as int,
                  details: 'কাস্টমার তথ্য সম্পাদনা: $name');
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

  // §6: নিষ্ক্রিয় করা (হার্ড ডিলিট নয়) — পুরনো sale-এ customer_id
  // রেফারেন্স অক্ষত থাকে, শুধু নতুন বিক্রয়ের সময় পিক-লিস্টে আর দেখাবে না
  Future<void> _confirmDeactivate(Map<String, dynamic> customer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${customer['name']}-কে নিষ্ক্রিয় করবেন?'),
        content: const Text(
            'এই কাস্টমার নতুন বিক্রয়ের সময় আর তালিকায় দেখাবে না, কিন্তু আগের সব বিক্রয়/হিসাব অক্ষত থাকবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: const Text('নিষ্ক্রিয় করুন')),
        ],
      ),
    );
    if (confirmed != true) return;
    final db = await _dbHelper.database;
    await db.update('customers', {'is_active': 0},
        where: 'id = ?', whereArgs: [customer['id']]);
    await _dbHelper.logActivity(
        userId: widget.currentUser['id'] as int?,
        action: 'delete',
        entityType: 'customer',
        entityId: customer['id'] as int,
        details: 'কাস্টমার নিষ্ক্রিয় করা হলো: ${customer['name']}');
    if (!mounted) return;
    Navigator.pop(context); // detail bottom sheet বন্ধ করা
    _load();
  }

  Future<void> _showCustomerDetail(Map<String, dynamic> customer) async {
    final db = await _dbHelper.database;
    final sales = await db.query('sales',
        where: 'customer_id = ?', whereArgs: [customer['id']], orderBy: 'sale_date DESC');
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(customer['name'] as String,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 18)),
                        Text(customer['phone'] as String? ?? '',
                            style: const TextStyle(color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'তথ্য সম্পাদনা',
                    onPressed: () => _showEditCustomerDialog(customer),
                  ),
                  if (_isMaster)
                    IconButton(
                      icon: const Icon(Icons.person_off_outlined,
                          size: 20, color: AppColors.danger),
                      tooltip: 'নিষ্ক্রিয় করুন (Master)',
                      onPressed: () => _confirmDeactivate(customer),
                    ),
                ],
              ),
              const Divider(height: 24),
              Expanded(
                child: sales.isEmpty
                    ? const Center(child: Text('কোনো কেনাকাটার ইতিহাস নেই'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: sales.length,
                        itemBuilder: (ctx, i) {
                          final s = sales[i];
                          final total = (s['total_amount'] as num).toDouble();
                          final paid = (s['paid_amount'] as num).toDouble();
                          return ListTile(
                            title: Text('বিক্রয় #${s['id']} — ${s['sale_date']}'),
                            subtitle: Text(
                                'মোট: ৳${total.toStringAsFixed(0)} • পরিশোধিত: ৳${paid.toStringAsFixed(0)}'),
                            trailing: total > paid
                                ? Text('বাকি: ৳${(total - paid).toStringAsFixed(0)}',
                                    style: const TextStyle(color: AppColors.danger))
                                : const Icon(Icons.check_circle_outline,
                                    color: AppColors.success),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('কাস্টমার লেজার')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _customers.isEmpty
              ? const Center(child: Text('কোনো কাস্টমার নেই'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _customers.length,
                  itemBuilder: (ctx, i) {
                    final c = _customers[i];
                    final due = (c['due'] as num).toDouble();
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        onTap: () => _showCustomerDetail(c),
                        title: Text(c['name'] as String),
                        subtitle: Text(
                            'মোট কেনাকাটা: ${_currencyFormat.format((c['total_purchase'] as num).toDouble())}'),
                        trailing: due > 0
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(_currencyFormat.format(due),
                                      style: const TextStyle(
                                          color: AppColors.danger,
                                          fontWeight: FontWeight.w600)),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: () => _showCollectPaymentDialog(c, due),
                                        style: TextButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            minimumSize: const Size(0, 0)),
                                        child: const Text('আদায়',
                                            style: TextStyle(fontSize: 12)),
                                      ),
                                      const SizedBox(width: 8),
                                      TextButton.icon(
                                        onPressed: () => _sendWhatsAppReminder(c, due),
                                        icon: const Icon(Icons.chat_outlined, size: 16),
                                        label: const Text('রিমাইন্ড',
                                            style: TextStyle(fontSize: 12)),
                                        style: TextButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            minimumSize: const Size(0, 0)),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : const Icon(Icons.check_circle_outline,
                                color: AppColors.success),
                      ),
                    );
                  },
                ),
    );
  }
}
