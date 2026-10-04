// ============================================================
// backup_screen.dart
// ব্যাকআপ তৈরি করে শেয়ার করা (Google Drive/ফোন স্টোরেজ/যেকোনো
// অ্যাপে), পুরনো ব্যাকআপ থেকে সম্পূর্ণ রিস্টোর (প্রতিস্থাপন), আর
// দুই ডিভাইসের ডেটা প্রকৃতপক্ষে "মার্জ" করার অপশন
// ============================================================

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../utils/safe_share.dart';
import '../database/auth_service.dart';
import '../database/backup_service.dart';
import '../database/merge_service.dart';
import '../utils/app_theme.dart';

class BackupScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const BackupScreen({super.key, required this.currentUser});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _backupService = BackupService();
  final _mergeService = MergeService();
  final _authService = AuthService();
  bool _working = false;
  DateTime? _lastBackupTime;

  @override
  void initState() {
    super.initState();
    _loadLastBackupTime();
  }

  Future<void> _loadLastBackupTime() async {
    final time = await _backupService.getLastBackupTime();
    if (!mounted) return;
    setState(() => _lastBackupTime = time);
  }

  String _lastBackupText() {
    if (_lastBackupTime == null) return 'এখনো কোনো ব্যাকআপ নেওয়া হয়নি';
    final days = DateTime.now().difference(_lastBackupTime!).inDays;
    if (days == 0) return 'আজই ব্যাকআপ নেওয়া হয়েছে';
    if (days == 1) return 'গতকাল ব্যাকআপ নেওয়া হয়েছিল';
    return '$days দিন আগে ব্যাকআপ নেওয়া হয়েছিল';
  }

  // §8: আলাদা backup password চাওয়ার বদলে বর্তমান লগইন করা
  // ব্যবহারকারীর নিজের password যাচাই করে নেওয়া হয় — নতুন কিছু মনে
  // রাখতে হয় না। [forRestore]=true হলে ভিন্ন হালকা বার্তা দেখানো হয়,
  // কারণ সেক্ষেত্রে backup ফাইল নেওয়ার সময়কার password লাগতে পারে।
  Future<String?> _confirmLoginPassword({required bool forRestore}) async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(forRestore
              ? 'আপনার লগইন পাসওয়ার্ড দিন'
              : 'নিশ্চিতকরণের জন্য আপনার লগইন পাসওয়ার্ড দিন'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'পাসওয়ার্ড'),
              ),
              if (forRestore) ...[
                const SizedBox(height: 8),
                const Text(
                    'এই backup যখন নেওয়া হয়েছিল তখনকার পাসওয়ার্ড দিন — সাধারণত এটাই আপনার বর্তমান পাসওয়ার্ড, যদি না তারপর পাসওয়ার্ড বদলে থাকে।',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                final entered = controller.text;
                if (entered.isEmpty) return;
                if (!forRestore) {
                  // ম্যানুয়াল/অটো ব্যাকআপ নেওয়ার সময় এটা যে সত্যিই এই
                  // ব্যবহারকারীর বর্তমান লগইন পাসওয়ার্ড তা যাচাই করে নেওয়া
                  // হচ্ছে — নাহলে ভুল পাসওয়ার্ড দিয়ে ব্যাকআপ নিয়ে ফেললে
                  // ব্যবহারকারী টেরই পাবেন না যতক্ষণ না restore করতে গিয়ে
                  // আটকাবেন
                  final valid = await _authService.login(
                      widget.currentUser['username'] as String, entered);
                  if (valid == null) {
                    setDialogState(() => error = 'পাসওয়ার্ড মিলছে না');
                    return;
                  }
                }
                if (!ctx.mounted) return;
                Navigator.pop(ctx, entered);
              },
              child: const Text('নিশ্চিত করুন'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<void> _createBackup() async {
    final password = await _confirmLoginPassword(forRestore: false);
    if (password == null) return;

    setState(() => _working = true);
    try {
      final path = await _backupService.createEncryptedBackup(password);
      if (!mounted) return;
      await _loadLastBackupTime();
      // Android শেয়ার-শিট খুলবে — এখান থেকে Google Drive, WhatsApp,
      // ফাইল ম্যানেজার (ফোন স্টোরেজে সেভ), বা যেকোনো অ্যাপ বেছে নেওয়া যাবে
      await SafeShare.files([path],
          text: 'Ahmadia Shop ব্যাকআপ ফাইল — নিরাপদ জায়গায় সংরক্ষণ করুন');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('ব্যাকআপ তৈরি করতে সমস্যা: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restoreBackup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ সতর্কতা — সম্পূর্ণ প্রতিস্থাপন'),
        content: const Text(
            'এটা "রিস্টোর" (প্রতিস্থাপন) — বর্তমান অ্যাপের সব ডেটা মুছে গিয়ে '
            'ব্যাকআপ ফাইলের ডেটা দিয়ে সম্পূর্ণ প্রতিস্থাপিত হবে।\n\n'
            'যদি এই ফোনে ইতিমধ্যে কিছু এন্ট্রি দেওয়া থাকে যেগুলো ব্যাকআপ ফাইলে নেই, '
            'সেগুলো হারিয়ে যাবে। দুই ডিভাইসের এন্ট্রি একসাথে রাখতে চাইলে বরং '
            '"দুই ডিভাইসের ডেটা মার্জ করুন" অপশনটা ব্যবহার করুন।\n\n'
            'এগিয়ে যেতে চান?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('হ্যাঁ, প্রতিস্থাপন করুন'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final result = await FilePicker.platform
        .pickFiles(type: FileType.any, allowMultiple: false);
    if (result == null || result.files.single.path == null) return;

    final password = await _confirmLoginPassword(forRestore: true);
    if (password == null || password.isEmpty) return;

    setState(() => _working = true);
    try {
      await _backupService.restoreFromBackup(
          result.files.single.path!, password);
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('✅ রিস্টোর সম্পন্ন'),
          content: const Text(
              'ডেটা সফলভাবে ফিরিয়ে আনা হয়েছে। পরিবর্তন সম্পূর্ণভাবে কার্যকর হতে '
              'অ্যাপ বন্ধ করে আবার চালু করুন।'),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ঠিক আছে'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('রিস্টোর ব্যর্থ: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _mergeBackup() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.any, allowMultiple: false);
    if (result == null || result.files.single.path == null) return;

    final password = await _confirmLoginPassword(forRestore: true);
    if (password == null || password.isEmpty) return;

    setState(() => _working = true);
    try {
      final tempDbPath =
          await _backupService.decryptToTempFile(result.files.single.path!, password);
      final report = await _mergeService.merge(tempDbPath);

      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('✅ মার্জ সম্পন্ন'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('মোট ${report.totalInserted}টি নতুন এন্ট্রি যোগ হয়েছে।'),
                const SizedBox(height: 8),
                ...report.insertedCounts.entries
                    .where((e) => e.value > 0)
                    .map((e) => Text('• ${e.key}: ${e.value}টি')),
                if (report.possibleDuplicates.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('⚠️ সম্ভাব্য ডুপ্লিকেট (একই নাম একাধিকবার):',
                      style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.warning)),
                  const SizedBox(height: 4),
                  ...report.possibleDuplicates.map((d) => Text('• $d', style: const TextStyle(fontSize: 12))),
                  const SizedBox(height: 6),
                  const Text(
                    'এগুলো ম্যানুয়ালি চেক করে দেখুন — একই পণ্য/কাস্টমার/সাপ্লায়ার '
                    'দুই ডিভাইসে আলাদাভাবে তৈরি হয়ে থাকলে এখানে দেখাবে।',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ঠিক আছে'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('মার্জ ব্যর্থ: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOverdue = _lastBackupTime == null ||
        DateTime.now().difference(_lastBackupTime!).inDays >=
            BackupService.staleWarningDays;

    return Scaffold(
      appBar: AppBar(title: const Text('ব্যাকআপ ও রিস্টোর')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isOverdue)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.warning.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_lastBackupTime == null
                          ? 'এখনো কোনো ব্যাকআপ নেওয়া হয়নি — এখনই একটা ব্যাকআপ নিন'
                          : '${_lastBackupText()} — নতুন ব্যাকআপ নেওয়ার সময় হয়েছে'),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_lastBackupText(),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.cloud_upload_outlined,
                        color: AppColors.primary, size: 32),
                    const SizedBox(height: 12),
                    const Text('নতুন ব্যাকআপ তৈরি করুন',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 6),
                    const Text(
                      'এটা একটা এনক্রিপ্টেড ব্যাকআপ ফাইল তৈরি করবে। এরপর যে '
                      'শেয়ার-মেনু খুলবে সেখান থেকে Google Drive বেছে নিয়ে '
                      'সেভ করুন (ফোনে Drive অ্যাপ থাকলে), অথবা ফোন স্টোরেজে/অন্য '
                      'কোথাও সেভ করুন।',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _working ? null : _createBackup,
                      icon: const Icon(Icons.backup_outlined),
                      label: const Text('ব্যাকআপ তৈরি করুন'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: AppColors.primaryLight,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.merge_outlined,
                        color: AppColors.primary, size: 32),
                    const SizedBox(height: 12),
                    const Text('দুই ডিভাইসের ডেটা মার্জ করুন',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 6),
                    const Text(
                      'পার্টনারের ফোনের ব্যাকআপ এই ফোনে এনে দিলে, দুই ফোনের '
                      'সব এন্ট্রি (ডুপ্লিকেট ছাড়া) একসাথে মিলে যাবে — কোনো '
                      'ডেটা মুছে যাবে না। এটাই সাধারণত ব্যবহার করা উচিত '
                      '(রিস্টোরের বদলে) যখন দুইজনই এন্ট্রি দিয়েছেন।',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _working ? null : _mergeBackup,
                      icon: const Icon(Icons.merge_type_outlined),
                      label: const Text('ব্যাকআপ ফাইল মার্জ করুন'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.restore_outlined,
                        color: AppColors.warning, size: 32),
                    const SizedBox(height: 12),
                    const Text('সম্পূর্ণ রিস্টোর (প্রতিস্থাপন)',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 6),
                    const Text(
                      'বর্তমান ডেটা মুছে ব্যাকআপ ফাইলের ডেটা দিয়ে সম্পূর্ণ '
                      'প্রতিস্থাপন হবে। শুধু তখনই ব্যবহার করুন যখন এই ফোনে '
                      'কোনো নতুন এন্ট্রি নেই (যেমন ফোন পাল্টানোর সময়)।',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _working ? null : _restoreBackup,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('ব্যাকআপ ফাইল বেছে নিন'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _RotatingBackupsSection(backupService: _backupService),
            if (_working) ...[
              const SizedBox(height: 20),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}

// §9: dedicated ফোল্ডারে থাকা automatic (rotating) backup-গুলোর
// একটা সংক্ষিপ্ত তালিকা — কতগুলো আছে (সর্বোচ্চ ১২), সবচেয়ে সাম্প্রতিকটা
// কবে নেওয়া হয়েছিল, এইটুকু দেখানোই যথেষ্ট (পুরো ফাইল ম্যানেজমেন্ট UI
// এখানে দরকার নেই — dedicated ফোল্ডারেই ফাইলগুলো ফাইল ম্যানেজার দিয়ে
// সরাসরি দেখা যাবে)
class _RotatingBackupsSection extends StatelessWidget {
  final BackupService backupService;
  const _RotatingBackupsSection({required this.backupService});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<File>>(
      future: backupService.listRotatingBackups(),
      builder: (context, snapshot) {
        final files = snapshot.data ?? [];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.history, color: AppColors.textSecondary, size: 20),
                    SizedBox(width: 8),
                    Text('স্বয়ংক্রিয় ব্যাকআপ (প্রতি ৭ দিনে, সর্বোচ্চ ১২টা)',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 8),
                if (!snapshot.hasData)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: LinearProgressIndicator(),
                  )
                else if (files.isEmpty)
                  const Text('এখনো কোনো স্বয়ংক্রিয় ব্যাকআপ নেওয়া হয়নি — পরের বার লগইন করলে প্রথমটা তৈরি হবে।',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
                else
                  Text('বর্তমানে ${files.length}টি সংরক্ষিত আছে — সবচেয়ে নতুন: ${files.first.uri.pathSegments.last}',
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        );
      },
    );
  }
}
