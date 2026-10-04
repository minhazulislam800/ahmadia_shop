// ============================================================
// add_party_dialog.dart
// কাস্টমার/সাপ্লায়ারের তালিকা পেজ থেকেই নতুন কাস্টমার/সাপ্লায়ার যোগ
// করার ডায়ালগ (বিক্রয়/ক্রয়ের স্ক্রিনের PartySelector-এর একই নিয়মে:
// কাস্টমারের ফোন আবশ্যক, একই ফোন নম্বর থাকলে সতর্কতা)।
// ============================================================

import 'package:flutter/material.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/sync_id.dart';

String _normalizePhone(String phone) {
  var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.startsWith('88') && digits.length > 11) digits = digits.substring(2);
  return digits;
}

/// নতুন পার্টি যোগ হলে true ফেরত দেয়
Future<bool> showAddPartyDialog(
  BuildContext context, {
  required String tableName, // customers / suppliers
  required String label, // কাস্টমার / সাপ্লায়ার
  required bool phoneRequired,
  int? userId,
}) async {
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final addressController = TextEditingController();
  String? errorText;
  var added = false;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text('নতুন $label যোগ করুন'),
        content: SingleChildScrollView(
          child: Column(
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
                    labelText: phoneRequired ? 'ফোন নম্বর (আবশ্যক)' : 'ফোন (ঐচ্ছিক)'),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: addressController,
                  decoration: const InputDecoration(labelText: 'ঠিকানা (ঐচ্ছিক)')),
              if (errorText != null) ...[
                const SizedBox(height: 8),
                Text(errorText!,
                    style: const TextStyle(color: AppColors.danger, fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final phone = phoneController.text.trim();
              if (name.isEmpty) {
                setDialogState(() => errorText = 'নাম দিন');
                return;
              }
              if (phoneRequired && phone.isEmpty) {
                setDialogState(() => errorText = 'ফোন নম্বর দেওয়া আবশ্যক');
                return;
              }
              final db = await DBHelper.instance.database;

              if (phone.isNotEmpty) {
                final normalized = _normalizePhone(phone);
                final all = await db.query(tableName, where: 'is_active = 1');
                final same = all.where((p) {
                  final existing = p['phone'] as String? ?? '';
                  return existing.isNotEmpty && _normalizePhone(existing) == normalized;
                }).toList();
                if (same.isNotEmpty) {
                  if (!ctx.mounted) return;
                  final proceed = await showDialog<bool>(
                    context: ctx,
                    builder: (dctx) => AlertDialog(
                      title: const Text('⚠️ এই ফোন নম্বরে আগে থেকেই একজন আছে'),
                      content: Text(
                          '"${same.first['name']}" নামে এই নম্বরে আগে থেকেই একটা এন্ট্রি আছে। তবুও নতুন করে যোগ করবেন?'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dctx, false),
                            child: const Text('না')),
                        ElevatedButton(
                            onPressed: () => Navigator.pop(dctx, true),
                            child: const Text('হ্যাঁ, যোগ করুন')),
                      ],
                    ),
                  );
                  if (proceed != true) return;
                }
              }

              final id = await db.insert(tableName, {
                'name': name,
                'phone': phone,
                'address': addressController.text.trim(),
                'sync_id': generateSyncId(),
              });
              await DBHelper.instance.logActivity(
                  userId: userId,
                  action: 'create',
                  entityType: tableName == 'customers' ? 'customer' : 'supplier',
                  entityId: id,
                  details: 'নতুন $label: $name');
              added = true;
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            child: const Text('যোগ করুন'),
          ),
        ],
      ),
    ),
  );
  return added;
}
