// ============================================================
// bulk_import_screen.dart
// CSV ফাইল থেকে একসাথে অনেক পণ্য ইমপোর্ট করা — ১০০+ পণ্য হাতে
// হাতে টাইপ না করে একটা ফাইল থেকে দ্রুত যোগ করার সুবিধা
// ============================================================

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/sync_id.dart';

class BulkImportScreen extends StatefulWidget {
  const BulkImportScreen({super.key});

  @override
  State<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends State<BulkImportScreen> {
  final _dbHelper = DBHelper.instance;
  bool _working = false;
  List<String> _log = [];

  Future<void> _downloadTemplate() async {
    const csvContent =
        'নাম,পণ্য কোড,ক্যাটাগরি,ইউনিট,লো-স্টক সীমা,খুচরা দাম,পাইকারি দাম\n'
        'উদাহরণ: চিনি,SUG-001,মুদি,কেজি,10,75,70\n';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/product_import_template.csv');
    await file.writeAsString(csvContent);
    await Share.shareXFiles([XFile(file.path)], text: 'পণ্য ইমপোর্ট টেমপ্লেট');
  }

  Future<void> _pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['csv']);
    if (result == null || result.files.single.path == null) return;

    setState(() {
      _working = true;
      _log = [];
    });

    try {
      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final lines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();

      if (lines.isEmpty) {
        setState(() => _log.add('❌ ফাইল খালি'));
        return;
      }

      // প্রথম লাইন হেডার ধরে বাদ দেওয়া হচ্ছে (নাম,ক্যাটাগরি,ইউনিট,...)
      final dataLines = lines.skip(1).toList();
      final db = await _dbHelper.database;

      int successCount = 0;
      int skipCount = 0;
      final newLog = <String>[];

      for (final line in dataLines) {
        final parts = line.split(',').map((p) => p.trim()).toList();
        if (parts.isEmpty || parts[0].isEmpty) continue;

        final name = parts[0];
        final code = parts.length > 1 ? parts[1] : '';
        final category = parts.length > 2 ? parts[2] : '';
        final unit = parts.length > 3 && parts[3].isNotEmpty ? parts[3] : 'পিস';
        final threshold = parts.length > 4 ? double.tryParse(parts[4]) ?? 0 : 0.0;
        final retailPrice = parts.length > 5 ? double.tryParse(parts[5]) : null;
        final wholesalePrice = parts.length > 6 ? double.tryParse(parts[6]) : null;

        if (code.isEmpty) {
          skipCount++;
          newLog.add('⏭️ "$name" — পণ্য কোড দেওয়া নেই, বাদ দেওয়া হলো');
          continue;
        }

        // ডুপ্লিকেট কোড চেক (কোডই আসল ইউনিক পরিচয়)
        final existingByCode = await db.query('products',
            where: 'LOWER(product_code) = ? AND is_active = 1',
            whereArgs: [code.toLowerCase()]);
        if (existingByCode.isNotEmpty) {
          skipCount++;
          newLog.add('⏭️ কোড "$code" ("$name") আগে থেকেই আছে, বাদ দেওয়া হলো');
          continue;
        }

        int? categoryId;
        if (category.isNotEmpty) {
          final existingCat =
              await db.query('categories', where: 'name = ?', whereArgs: [category]);
          if (existingCat.isNotEmpty) {
            categoryId = existingCat.first['id'] as int;
          } else {
            categoryId =
                await db.insert('categories', {'name': category, 'sync_id': generateSyncId()});
          }
        }

        await db.insert('products', {
          'name': name,
          'product_code': code,
          'category_id': categoryId,
          'unit': unit,
          'low_stock_threshold': threshold,
          'retail_price': retailPrice,
          'wholesale_price': wholesalePrice,
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
          'sync_id': generateSyncId(),
        });
        successCount++;
      }

      newLog.insert(0, '✅ মোট $successCount টি পণ্য যোগ হয়েছে, $skipCount টি বাদ দেওয়া হয়েছে (ডুপ্লিকেট/কোড-বিহীন)');
      setState(() => _log = newLog);
    } catch (e) {
      setState(() => _log = ['❌ ইমপোর্ট ব্যর্থ: $e']);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('বাল্ক পণ্য ইমপোর্ট')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ধাপ ১: টেমপ্লেট ডাউনলোড করুন',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    const Text(
                      'একটা CSV টেমপ্লেট পাবেন — Excel বা Google Sheets দিয়ে খুলে '
                      'আপনার সব পণ্যের তথ্য ভরে CSV আকারে সেভ করুন',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _downloadTemplate,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('টেমপ্লেট ডাউনলোড করুন'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ধাপ ২: ভরাট করা CSV ফাইল আপলোড করুন',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    const Text(
                      'কলাম ক্রম: নাম, পণ্য কোড, ক্যাটাগরি, ইউনিট, লো-স্টক সীমা, খুচরা দাম, পাইকারি দাম — '
                      'নাম ও কোড আবশ্যক, বাকি সব ঐচ্ছিক। একই কোডের পণ্য থাকলে বাদ দেওয়া হবে।',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _working ? null : _pickAndImport,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('CSV ফাইল বেছে নিয়ে ইমপোর্ট করুন'),
                    ),
                  ],
                ),
              ),
            ),
            if (_working) ...[
              const SizedBox(height: 20),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 16),
              Expanded(
                child: Card(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _log.length,
                    itemBuilder: (ctx, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(_log[i], style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
