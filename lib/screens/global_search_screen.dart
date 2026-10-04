// ============================================================
// global_search_screen.dart
// একটা সার্চ বক্সে টাইপ করলেই পণ্য, কাস্টমার, সাপ্লায়ার, ক্রয়,
// বিক্রয় — সব জায়গায় একসাথে খুঁজে ফলাফল দেখাবে
// ============================================================

import 'package:flutter/material.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import 'customer_ledger_screen.dart';
import 'supplier_ledger_screen.dart';
import 'product_screen.dart';
import '../widgets/app_bottom_nav.dart';

class GlobalSearchScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const GlobalSearchScreen({super.key, required this.currentUser});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final _dbHelper = DBHelper.instance;
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _purchases = [];
  bool _searching = false;
  bool _hasSearched = false;

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _products = [];
        _customers = [];
        _suppliers = [];
        _sales = [];
        _purchases = [];
        _hasSearched = false;
      });
      return;
    }

    setState(() => _searching = true);
    final db = await _dbHelper.database;
    final q = '%${query.trim()}%';

    final products = await db.query('products',
        where: '(name LIKE ? OR product_code LIKE ?) AND is_active = 1',
        whereArgs: [q, q], limit: 10);

    final customers = await db.query('customers',
        where: 'name LIKE ? OR phone LIKE ?', whereArgs: [q, q], limit: 10);

    final suppliers = await db.query('suppliers',
        where: 'name LIKE ? OR phone LIKE ?', whereArgs: [q, q], limit: 10);

    // বিক্রয় — কাস্টমারের নাম বা ইনভয়েস আইডি দিয়ে খোঁজা
    final sales = await db.rawQuery('''
      SELECT s.*, c.name as customer_name
      FROM sales s
      LEFT JOIN customers c ON c.id = s.customer_id
      WHERE c.name LIKE ? OR CAST(s.id as TEXT) = ?
      ORDER BY s.sale_date DESC
      LIMIT 10
    ''', [q, query.trim()]);

    final purchases = await db.rawQuery('''
      SELECT p.*, s.name as supplier_name
      FROM purchases p
      LEFT JOIN suppliers s ON s.id = p.supplier_id
      WHERE s.name LIKE ? OR CAST(p.id as TEXT) = ?
      ORDER BY p.purchase_date DESC
      LIMIT 10
    ''', [q, query.trim()]);

    if (!mounted) return;
    setState(() {
      _products = products;
      _customers = customers;
      _suppliers = suppliers;
      _sales = sales;
      _purchases = purchases;
      _searching = false;
      _hasSearched = true;
    });
  }

  Widget _sectionHeader(String title, int count) {
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text('$title ($count)',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalResults = _products.length +
        _customers.length +
        _suppliers.length +
        _sales.length +
        _purchases.length;

    return Scaffold(
      bottomNavigationBar: AppBottomNav(currentTab: AppTab.search, currentUser: widget.currentUser),
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          onChanged: _search,
          decoration: const InputDecoration(
            hintText: 'পণ্য, কাস্টমার, সাপ্লায়ার, বিল নম্বর খুঁজুন...',
            border: InputBorder.none,
          ),
        ),
      ),
      body: _searching
          ? const Center(child: CircularProgressIndicator())
          : !_hasSearched
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'পণ্যের নাম, কাস্টমার/সাপ্লায়ারের নাম বা ফোন নম্বর, '
                        'অথবা বিল নম্বর দিয়ে খুঁজুন',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                )
              : totalResults == 0
                  ? const Center(child: Text('কোনো ফলাফল পাওয়া যায়নি'))
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        _sectionHeader('পণ্য', _products.length),
                        ..._products.map((p) => Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              child: ListTile(
                                leading: const Icon(Icons.category_outlined),
                                title: Text(p['name'] as String),
                                subtitle: (p['product_code'] as String? ?? '').isNotEmpty
                                    ? Text('কোড: ${p['product_code']}')
                                    : null,
                                onTap: () => Navigator.push(context, MaterialPageRoute(
                                    builder: (_) => ProductScreen(currentUser: widget.currentUser))),
                              ),
                            )),
                        _sectionHeader('কাস্টমার', _customers.length),
                        ..._customers.map((c) => Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              child: ListTile(
                                leading: const Icon(Icons.person_outline),
                                title: Text(c['name'] as String),
                                subtitle: Text(c['phone'] as String? ?? ''),
                                onTap: () => Navigator.push(context, MaterialPageRoute(
                                    builder: (_) => CustomerLedgerScreen(currentUser: widget.currentUser))),
                              ),
                            )),
                        _sectionHeader('সাপ্লায়ার', _suppliers.length),
                        ..._suppliers.map((s) => Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              child: ListTile(
                                leading: const Icon(Icons.local_shipping_outlined),
                                title: Text(s['name'] as String),
                                subtitle: Text(s['phone'] as String? ?? ''),
                                onTap: () => Navigator.push(context, MaterialPageRoute(
                                    builder: (_) => SupplierLedgerScreen(currentUser: widget.currentUser))),
                              ),
                            )),
                        _sectionHeader('বিক্রয়', _sales.length),
                        ..._sales.map((s) => Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              child: ListTile(
                                leading: const Icon(Icons.point_of_sale_outlined),
                                title: Text('বিক্রয় #${s['id']} — ${s['customer_name'] ?? 'ওয়াক-ইন কাস্টমার'}'),
                                subtitle: Text('${s['sale_date']} • ৳${s['total_amount']}'),
                              ),
                            )),
                        _sectionHeader('ক্রয়', _purchases.length),
                        ..._purchases.map((p) => Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              child: ListTile(
                                leading: const Icon(Icons.shopping_cart_outlined),
                                title: Text('ক্রয় #${p['id']} — ${p['supplier_name'] ?? 'অজানা সাপ্লায়ার'}'),
                                subtitle: Text('${p['purchase_date']} • ৳${p['total_amount']}'),
                              ),
                            )),
                        const SizedBox(height: 20),
                      ],
                    ),
    );
  }
}
