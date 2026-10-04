// ============================================================
// party_selector.dart
// কাস্টমার বা সাপ্লায়ার বেছে নেওয়া/নতুন যোগ করার জন্য
// পুনঃব্যবহারযোগ্য ড্রপডাউন উইজেট
// ============================================================

import 'package:flutter/material.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/sync_id.dart';

class PartySelector extends StatefulWidget {
  final String tableName; // 'customers' অথবা 'suppliers'
  final String label;
  final ValueChanged<int?> onSelected;
  final bool phoneRequired;
  final int? initialId; // edit mode-এ আগে থেকে নির্বাচিত পার্টি দেখানোর জন্য

  const PartySelector({
    super.key,
    required this.tableName,
    required this.label,
    required this.onSelected,
    this.phoneRequired = false,
    this.initialId,
  });

  @override
  State<PartySelector> createState() => _PartySelectorState();
}

class _PartySelectorState extends State<PartySelector> {
  final _dbHelper = DBHelper.instance;
  List<Map<String, dynamic>> _parties = [];
  int? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialId;
    _load();
  }

  Future<void> _load() async {
    final db = await _dbHelper.database;
    final result = await db.query(widget.tableName,
        where: 'is_active = 1', orderBy: 'name ASC');
    // edit mode-এ নির্বাচিত পার্টি ইতিমধ্যে নিষ্ক্রিয় হয়ে থাকলেও (soft-
    // delete) dropdown-এ দেখানো দরকার, নাহলে "not found" এর মতো আচরণ করবে
    if (widget.initialId != null &&
        !result.any((r) => r['id'] == widget.initialId)) {
      final inactive = await db.query(widget.tableName,
          where: 'id = ?', whereArgs: [widget.initialId]);
      if (inactive.isNotEmpty) result.addAll(inactive);
    }
    if (!mounted) return;
    setState(() => _parties = result);
  }

  /// ফোন নম্বর থেকে শুধু সংখ্যা রাখে (স্পেস/ড্যাশ/+৮৮ ইত্যাদি বাদ দিয়ে
  /// সবসময় একই ফরম্যাটে তুলনা করার জন্য)
  String _normalizePhone(String phone) {
    var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('88') && digits.length > 11) {
      digits = digits.substring(2);
    }
    return digits;
  }

  Future<void> _showAddDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final addressController = TextEditingController();
    String? errorText;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('নতুন ${widget.label} যোগ করুন'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'নাম'),
                  autofocus: true),
              const SizedBox(height: 12),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: widget.phoneRequired ? 'ফোন নম্বর (আবশ্যক)' : 'ফোন (ঐচ্ছিক)',
                  helperText: widget.phoneRequired
                      ? 'ফোন নম্বর দিয়েই সিস্টেম বুঝবে এটা কোন কাস্টমার — তাই এটা আবশ্যক'
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: addressController,
                  decoration: const InputDecoration(labelText: 'ঠিকানা (ঐচ্ছিক)')),
              if (errorText != null) ...[
                const SizedBox(height: 8),
                Text(errorText!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final phone = phoneController.text.trim();
                if (name.isEmpty) return;

                if (widget.phoneRequired && phone.isEmpty) {
                  setDialogState(() => errorText = 'ফোন নম্বর দেওয়া আবশ্যক');
                  return;
                }

                final db = await _dbHelper.database;

                // একই ফোন নম্বরে আগে থেকে কেউ থাকলে সতর্ক করা (ডুপ্লিকেট এড়াতে)
                if (phone.isNotEmpty) {
                  final normalizedNew = _normalizePhone(phone);
                  final existingSameName = _parties.where((p) {
                    final existingPhone = p['phone'] as String? ?? '';
                    return existingPhone.isNotEmpty &&
                        _normalizePhone(existingPhone) == normalizedNew;
                  }).toList();
                  if (existingSameName.isNotEmpty) {
                    if (!ctx.mounted) return;
                    final useExisting = await showDialog<bool>(
                      context: ctx,
                      builder: (dctx) => AlertDialog(
                        title: const Text('⚠️ এই ফোন নম্বরে আগে থেকেই একজন আছে'),
                        content: Text(
                            '"${existingSameName.first['name']}" নামে এই নম্বরে আগে থেকেই একটা এন্ট্রি আছে। '
                            'সেটাই বেছে নেবেন, নাকি নতুন এন্ট্রি হিসেবে যোগ করবেন?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(dctx, true),
                              child: const Text('আগেরটাই বেছে নিন')),
                          ElevatedButton(
                              onPressed: () => Navigator.pop(dctx, false),
                              child: const Text('নতুন করে যোগ করুন')),
                        ],
                      ),
                    );
                    if (useExisting == true) {
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      setState(() => _selectedId = existingSameName.first['id'] as int);
                      widget.onSelected(existingSameName.first['id'] as int);
                      return;
                    }
                  }
                }

                final id = await db.insert(widget.tableName, {
                  'name': name,
                  'phone': phone,
                  'address': addressController.text.trim(),
                  'sync_id': generateSyncId(),
                });
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _load();
                setState(() => _selectedId = id);
                widget.onSelected(id);
              },
              child: const Text('যোগ করুন'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            value: _selectedId,
            isExpanded: true,
            decoration: InputDecoration(labelText: widget.label),
            items: _parties
                .map((p) => DropdownMenuItem<int>(
                      value: p['id'] as int,
                      child: Text(p['name'] as String, overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
            onChanged: (val) {
              setState(() => _selectedId = val);
              widget.onSelected(val);
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: _showAddDialog,
          tooltip: 'নতুন ${widget.label}',
        ),
      ],
    );
  }
}

