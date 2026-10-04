// ============================================================
// import_backup_screen.dart
// ব্যাকআপ ফাইল থেকে ডেটা ইমপোর্ট/আপডেট করার স্ক্রিন। দুইভাবে খোলে:
//   ১) হোয়াটসঅ্যাপ ইত্যাদি থেকে ফাইলটা "Open with" করলে
//   ২) নতুন ইনস্টলে সেটআপ/লগইন স্ক্রিনের "ব্যাকআপ থেকে রিস্টোর" বাটন থেকে
// পাসওয়ার্ড দিলে ব্যাকআপের তারিখ দেখিয়ে নিশ্চিত করতে বলে; বাতিলও করা যায়।
// ============================================================

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/backup_service.dart';
import '../utils/app_theme.dart';
import 'login_screen.dart';

class ImportBackupScreen extends StatefulWidget {
  final String path;
  final String? displayName;
  const ImportBackupScreen({super.key, required this.path, this.displayName});

  /// ফাইল বেছে নিয়ে ইমপোর্ট স্ক্রিন খোলা (সেটআপ/লগইন স্ক্রিনের বাটনের জন্য)
  static Future<void> pickAndOpen(BuildContext context) async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.any, allowMultiple: false);
    if (result == null || result.files.single.path == null) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ImportBackupScreen(
          path: result.files.single.path!, displayName: result.files.single.name),
    ));
  }

  @override
  State<ImportBackupScreen> createState() => _ImportBackupScreenState();
}

class _ImportBackupScreenState extends State<ImportBackupScreen> {
  final _backupService = BackupService();
  final _passwordController = TextEditingController();
  final _dateFormat = DateFormat('yyyy-MM-dd  hh:mm a');

  bool _working = false;
  bool _obscure = true;
  String? _error;

  DateTime? get _fileNameDate =>
      BackupService.parseDateFromFileName(widget.displayName ?? '');

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = 'পাসওয়ার্ড দিন');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });

    DateTime? backupDate;
    try {
      backupDate = await _backupService.inspectBackup(widget.path, password);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error =
            'পাসওয়ার্ড ভুল, অথবা এটা Ahmadia Shop-এর ব্যাকআপ ফাইল নয়, অথবা ফাইল নষ্ট';
      });
      return;
    }

    final shownDate = backupDate ?? _fileNameDate;
    if (!mounted) return;
    setState(() => _working = false);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ডেটা আপডেট করবেন?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('এই ব্যাকআপের তারিখ:',
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            Text(
              shownDate == null ? 'তারিখ জানা যায়নি' : _dateFormat.format(shownDate),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
            ),
            const SizedBox(height: 14),
            const Text(
                'আপডেট করলে এই ফোনের বর্তমান সব ডেটা মুছে গিয়ে এই ব্যাকআপের ডেটা বসবে।'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('বাতিল')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('আপডেট করুন')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _working = true);
    try {
      await _backupService.restoreAndReset(widget.path, password);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = 'আপডেট ব্যর্থ: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _working = false);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('✅ আপডেট সম্পন্ন'),
        content: const Text(
            'ডেটা সফলভাবে ফিরিয়ে আনা হয়েছে। এখন আপনার আগের ইউজারনেম ও পাসওয়ার্ড দিয়ে লগইন করুন।'),
        actions: [
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('ঠিক আছে')),
        ],
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nameDate = _fileNameDate;
    return Scaffold(
      appBar: AppBar(title: const Text('ব্যাকআপ থেকে আপডেট')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ব্যাকআপ ফাইল',
                        style: TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 4),
                    Text(widget.displayName ?? widget.path.split('/').last,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    const Text('ব্যাকআপের তারিখ',
                        style: TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 4),
                    Text(
                      nameDate == null
                          ? 'পাসওয়ার্ড দেওয়ার পর দেখা যাবে'
                          : _dateFormat.format(nameDate),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF4E5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'আপডেট করলে এই ফোনের বর্তমান সব ডেটা মুছে গিয়ে এই ব্যাকআপের ডেটা বসবে। '
                'না চাইলে "বাতিল" চাপুন।',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'ব্যাকআপের পাসওয়ার্ড',
                helperText: 'ব্যাকআপ নেওয়ার সময়কার (মাস্টার) ইউজারের পাসওয়ার্ড',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _working ? null : _update(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 20),
            if (_working)
              const Center(child: CircularProgressIndicator())
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('বাতিল'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _update,
                      child: const Text('আপডেট করুন'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
