// ============================================================
// bulk_import_screen.dart
// Excel (.xlsx) বা CSV ফাইল থেকে একসাথে অনেক পণ্য ইমপোর্ট।
// ফাইলের হেডিং আমাদের নামের সাথে না মিললেও সমস্যা নেই — কোন কলাম কোন
// তথ্য তা ড্রপডাউন থেকে বেছে দেওয়া যায় (মিলে যাওয়া হেডিং নিজে থেকেই বসে)।
// ============================================================

import 'dart:io';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/safe_share.dart';
import '../utils/sync_id.dart';

// ইমপোর্টের ক্ষেত্রগুলো: কী, নাম, আবশ্যক কি না, মিলিয়ে নেওয়ার সম্ভাব্য হেডিং
class _Field {
  final String key;
  final String label;
  final bool required;
  final List<String> synonyms;
  const _Field(this.key, this.label, this.required, this.synonyms);
}

const List<_Field> _fields = [
  _Field('name', 'নাম', true,
      ['নাম', 'পণ্যের নাম', 'পণ্য', 'name', 'product', 'product name', 'item', 'item name']),
  _Field('code', 'পণ্য কোড', true,
      ['পণ্য কোড', 'কোড', 'code', 'product code', 'sku', 'item code', 'barcode']),
  _Field('category', 'ক্যাটাগরি', false,
      ['ক্যাটাগরি', 'ধরন', 'ক্যাটেগরি', 'category', 'type', 'group']),
  _Field('unit', 'ইউনিট', false, ['ইউনিট', 'একক', 'unit', 'uom']),
  _Field('threshold', 'লো-স্টক সীমা', false,
      ['লো-স্টক সীমা', 'লো স্টক', 'সীমা', 'low stock', 'threshold', 'min stock', 'reorder']),
  _Field('retail', 'খুচরা দাম', false,
      ['খুচরা দাম', 'খুচরা', 'বিক্রয় মূল্য', 'দাম', 'retail', 'retail price', 'price', 'mrp']),
  _Field('wholesale', 'পাইকারি দাম', false,
      ['পাইকারি দাম', 'পাইকারি', 'wholesale', 'wholesale price']),
];

class BulkImportScreen extends StatefulWidget {
  const BulkImportScreen({super.key});

  @override
  State<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends State<BulkImportScreen> {
  final _dbHelper = DBHelper.instance;
  bool _working = false;
  List<String> _log = [];

  // ফাইল পড়ার পরের অবস্থা
  List<List<String>> _rows = []; // প্রথম সারি = হেডিং
  String? _fileName;
  List<String> _sheetNames = [];
  String? _sheetName;
  excel_lib.Excel? _excel;
  // ক্ষেত্র কী → কলামের নম্বর (null = ম্যাপ করা হয়নি)
  final Map<String, int?> _mapping = {};
  bool _autoCode = false;

  Future<void> _downloadTemplate() async {
    final wb = excel_lib.Excel.createExcel();
    final sheet = wb['পণ্য'];
    sheet.appendRow(_fields.map((f) => excel_lib.TextCellValue(f.label)).toList());
    sheet.appendRow([
      excel_lib.TextCellValue('চিনি'),
      excel_lib.TextCellValue('SUG-001'),
      excel_lib.TextCellValue('মুদি'),
      excel_lib.TextCellValue('কেজি'),
      excel_lib.DoubleCellValue(10),
      excel_lib.DoubleCellValue(75),
      excel_lib.DoubleCellValue(70),
    ]);
    wb.delete('Sheet1');
    final bytes = wb.encode();
    if (bytes == null) return;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/product_import_template.xlsx');
    await file.writeAsBytes(bytes);
    await SafeShare.files([file.path], text: 'পণ্য ইমপোর্ট টেমপ্লেট (Excel)');
  }

  // ---------- ফাইল পড়া ----------

  String _cellText(excel_lib.Data? cell) {
    final v = cell?.value;
    if (v == null) return '';
    final s = v.toString().trim();
    // Excel-এর সংখ্যা 75 → "75.0" হলে ".0" বাদ
    return RegExp(r'^-?\d+\.0$').hasMatch(s) ? s.substring(0, s.length - 2) : s;
  }

  List<List<String>> _sheetRows(String name) {
    final sheet = _excel!.tables[name];
    if (sheet == null) return [];
    final out = <List<String>>[];
    for (final row in sheet.rows) {
      final cells = row.map(_cellText).toList();
      if (cells.every((c) => c.isEmpty)) continue; // পুরো ফাঁকা সারি বাদ
      out.add(cells);
    }
    return out;
  }

  // CSV: কমা-ভাগ, "..." কোটের ভেতরের কমা/নতুন-লাইন ঠিকভাবে সামলায়
  List<List<String>> _parseCsv(String content) {
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;
    final text = content.replaceFirst('\uFEFF', '');
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          cell.write(ch);
        }
      } else if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        row.add(cell.toString().trim());
        cell.clear();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString().trim());
        cell.clear();
        if (row.any((c) => c.isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        cell.write(ch);
      }
    }
    row.add(cell.toString().trim());
    if (row.any((c) => c.isNotEmpty)) rows.add(row);
    return rows;
  }

  String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s_\-:.]+'), ' ').trim();

  // হেডিং মিলিয়ে নিজে থেকে ম্যাপ করা (একটা কলাম একাধিক ক্ষেত্রে বসে না)
  void _autoMap() {
    _mapping.clear();
    if (_rows.isEmpty) return;
    final headers = _rows.first.map(_norm).toList();
    final used = <int>{};
    for (final f in _fields) {
      int? found;
      for (final syn in f.synonyms) {
        final idx = headers.indexOf(_norm(syn));
        if (idx >= 0 && !used.contains(idx)) {
          found = idx;
          break;
        }
      }
      _mapping[f.key] = found;
      if (found != null) used.add(found);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['xlsx', 'csv']);
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final name = result.files.single.name;

    setState(() {
      _working = true;
      _log = [];
    });
    try {
      final file = File(path);
      if (name.toLowerCase().endsWith('.csv')) {
        final content = await file.readAsString();
        _excel = null;
        _sheetNames = [];
        _sheetName = null;
        _rows = _parseCsv(content);
      } else {
        final bytes = await file.readAsBytes();
        _excel = excel_lib.Excel.decodeBytes(bytes);
        _sheetNames = _excel!.tables.keys.toList();
        // প্রথম যে শিটে ডেটা আছে সেটা
        _sheetName = _sheetNames.firstWhere(
            (n) => _sheetRows(n).isNotEmpty,
            orElse: () => _sheetNames.isEmpty ? '' : _sheetNames.first);
        _rows = _sheetName == null || _sheetName!.isEmpty ? [] : _sheetRows(_sheetName!);
      }
      _fileName = name;
      if (_rows.length < 2) {
        _log = ['❌ ফাইলে হেডিং ও অন্তত একটা পণ্যের সারি থাকতে হবে'];
        _rows = [];
      } else {
        _autoMap();
      }
    } catch (e) {
      _rows = [];
      _log = ['❌ ফাইল পড়া যায়নি: $e\n(.xls হলে Excel-এ খুলে .xlsx হিসেবে সেভ করে নিন)'];
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _changeSheet(String name) {
    setState(() {
      _sheetName = name;
      _rows = _sheetRows(name);
      _log = _rows.length < 2 ? ['❌ এই শিটে ডেটা নেই'] : [];
      if (_rows.length >= 2) _autoMap();
    });
  }

  // ---------- ইমপোর্ট ----------

  String _cell(List<String> row, String key) {
    final idx = _mapping[key];
    if (idx == null || idx >= row.length) return '';
    return row[idx].trim();
  }

  Future<void> _runImport() async {
    final missing = _fields
        .where((f) => f.required && _mapping[f.key] == null)
        .where((f) => !(f.key == 'code' && _autoCode))
        .map((f) => f.label)
        .toList();
    if (missing.isNotEmpty) {
      setState(() => _log = ['❌ এই তথ্যের কলাম বেছে দিন: ${missing.join(', ')}']);
      return;
    }

    setState(() {
      _working = true;
      _log = [];
    });

    try {
      final db = await _dbHelper.database;
      var successCount = 0;
      var skipCount = 0;
      final newLog = <String>[];
      var autoCounter = 0;

      for (final row in _rows.skip(1)) {
        final name = _cell(row, 'name');
        if (name.isEmpty) continue;
        var code = _cell(row, 'code');
        final category = _cell(row, 'category');
        final unitRaw = _cell(row, 'unit');
        final unit = unitRaw.isNotEmpty ? unitRaw : 'পিস';
        final threshold = double.tryParse(_cell(row, 'threshold')) ?? 0.0;
        final retail = double.tryParse(_cell(row, 'retail'));
        final wholesale = double.tryParse(_cell(row, 'wholesale'));

        if (code.isEmpty) {
          if (_autoCode) {
            // বিদ্যমান কোডের সাথে না মেলা পর্যন্ত নতুন কোড বানানো
            while (true) {
              autoCounter++;
              code = 'P-${autoCounter.toString().padLeft(4, '0')}';
              final clash = await db.query('products',
                  where: 'LOWER(product_code) = ?', whereArgs: [code.toLowerCase()]);
              if (clash.isEmpty) break;
            }
          } else {
            skipCount++;
            newLog.add('⏭️ "$name" — পণ্য কোড দেওয়া নেই, বাদ দেওয়া হলো');
            continue;
          }
        }

        final existing = await db.query('products',
            where: 'LOWER(product_code) = ? AND is_active = 1',
            whereArgs: [code.toLowerCase()]);
        if (existing.isNotEmpty) {
          skipCount++;
          newLog.add('⏭️ কোড "$code" ("$name") আগে থেকেই আছে, বাদ দেওয়া হলো');
          continue;
        }

        int? categoryId;
        if (category.isNotEmpty) {
          final cat = await db.query('categories', where: 'name = ?', whereArgs: [category]);
          categoryId = cat.isNotEmpty
              ? cat.first['id'] as int
              : await db.insert('categories', {'name': category, 'sync_id': generateSyncId()});
        }

        await db.insert('products', {
          'name': name,
          'product_code': code,
          'category_id': categoryId,
          'unit': unit,
          'low_stock_threshold': threshold,
          'retail_price': retail,
          'wholesale_price': wholesale,
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
          'sync_id': generateSyncId(),
        });
        successCount++;
      }

      newLog.insert(0,
          '✅ মোট $successCount টি পণ্য যোগ হয়েছে, $skipCount টি বাদ দেওয়া হয়েছে (ডুপ্লিকেট/কোড-বিহীন)');
      setState(() => _log = newLog);
    } catch (e) {
      setState(() => _log = ['❌ ইমপোর্ট ব্যর্থ: $e']);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  // ---------- UI ----------

  Widget _mappingCard() {
    final headers = _rows.first;
    final sample = _rows.length > 1 ? _rows[1] : const <String>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ধাপ ৩: কলাম মিলিয়ে নিন — ${_rows.length - 1}টা সারি পাওয়া গেছে',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
                'প্রতিটা তথ্যের জন্য ফাইলের কোন কলাম, তা বেছে দিন। হেডিং মিললে নিজে থেকেই বসে গেছে।',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            if (_sheetNames.length > 1) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _sheetName,
                decoration: const InputDecoration(labelText: 'শিট', isDense: true),
                items: _sheetNames
                    .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                    .toList(),
                onChanged: (v) => v == null ? null : _changeSheet(v),
              ),
            ],
            const SizedBox(height: 12),
            ..._fields.map((f) {
              final idx = _mapping[f.key];
              final preview = (idx != null && idx < sample.length) ? sample[idx] : '';
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<int?>(
                  value: idx,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: f.required ? '${f.label} (আবশ্যক)' : f.label,
                    isDense: true,
                    helperText: preview.isEmpty ? null : 'যেমন: $preview',
                  ),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('— নেই / বাদ —')),
                    ...List.generate(headers.length, (i) {
                      final h = headers[i].isEmpty ? 'কলাম ${i + 1}' : headers[i];
                      return DropdownMenuItem<int?>(value: i, child: Text(h, overflow: TextOverflow.ellipsis));
                    }),
                  ],
                  onChanged: (v) => setState(() => _mapping[f.key] = v),
                ),
              );
            }),
            CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _autoCode,
                onChanged: (v) => setState(() => _autoCode = v ?? false),
                title: const Text('কোড না থাকলে নিজে থেকে কোড দিন (P-0001, P-0002…)',
                    style: TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _working ? null : _runImport,
              icon: const Icon(Icons.playlist_add_check),
              label: Text('${_rows.length - 1}টা পণ্য ইমপোর্ট করুন'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('বাল্ক পণ্য ইমপোর্ট')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ধাপ ১: টেমপ্লেট (ঐচ্ছিক)',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text(
                    'নিজের Excel ফাইল থাকলে টেমপ্লেট লাগবে না — যেকোনো হেডিংয়ের ফাইলই চলবে, '
                    'পরে কলাম মিলিয়ে নেওয়া যাবে।',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _downloadTemplate,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Excel টেমপ্লেট ডাউনলোড করুন'),
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
                  const Text('ধাপ ২: Excel (.xlsx) বা CSV ফাইল বেছে নিন',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text(
                    'প্রথম সারি হেডিং হতে হবে। নাম ও পণ্য কোড আবশ্যক, বাকি সব ঐচ্ছিক। '
                    'একই কোডের পণ্য থাকলে বাদ দেওয়া হবে।',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _working ? null : _pickFile,
                    icon: const Icon(Icons.upload_file_outlined),
                    label: Text(_fileName == null ? 'ফাইল বেছে নিন' : 'অন্য ফাইল বেছে নিন'),
                  ),
                  if (_fileName != null && _rows.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('📄 $_fileName', style: const TextStyle(fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),
          if (_rows.length >= 2) ...[
            const SizedBox(height: 16),
            _mappingCard(),
          ],
          if (_working) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _log
                      .map((l) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(l, style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
