// ============================================================
// settings_screen.dart
// দোকানের ব্র্যান্ডিং তথ্য এডিট (নাম/ঠিকানা/ফোন/লোগো), মাস্টার
// থেকে অন্য ইউজারের পাসওয়ার্ড রিসেট, অ্যাক্টিভিটি লগ ও লগ-আউট
// ============================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/safe_share.dart';
import '../database/auth_service.dart';
import '../database/backup_service.dart';
import '../database/db_helper.dart';
import '../utils/app_theme.dart';
import '../utils/shop_defaults.dart';
import 'activity_log_screen.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const SettingsScreen({super.key, required this.currentUser});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _dbHelper = DBHelper.instance;
  final _authService = AuthService();
  final _backupService = BackupService();
  bool _sharingBackup = false;

  final _shopNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  String? _logoPath;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  // সবচেয়ে নতুন ব্যাকআপ ফাইলটা শেয়ার-শিটে খোলে (Drive/WhatsApp/ফাইল
  // সেভ ইত্যাদি); একটাও না থাকলে আগে একটা বানিয়ে নেয়
  Future<void> _shareLatestBackup() async {
    setState(() => _sharingBackup = true);
    try {
      final path = await _backupService.getLatestBackupPathOrCreate();
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ব্যাকআপ তৈরি করা যায়নি')));
        return;
      }
      await SafeShare.files([path], text: 'Ahmadia Shop ব্যাকআপ');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('ব্যাকআপ শেয়ার ব্যর্থ: $e')));
    } finally {
      if (mounted) setState(() => _sharingBackup = false);
    }
  }

  Future<void> _loadSettings() async {
    final db = await _dbHelper.database;
    final rows = await db.query('app_settings');
    final map = {for (final r in rows) r['key'] as String: r['value'] as String? ?? ''};
    setState(() {
      _shopNameController.text = map['shop_name'] ?? 'Ahmadia Shop';
      // ফাঁকা থাকলে ডিফল্ট ঠিকানা/ফোন দেখায় (সংরক্ষণ করলে এটাই সেভ হয়)
      final savedAddress = (map['shop_address'] ?? '').trim();
      final savedPhone = (map['shop_phone'] ?? '').trim();
      _addressController.text =
          savedAddress.isEmpty ? ShopDefaults.address : savedAddress;
      _phoneController.text = savedPhone.isEmpty ? ShopDefaults.phone : savedPhone;
      _logoPath = map['shop_logo_path']?.isNotEmpty == true ? map['shop_logo_path'] : null;
      _loading = false;
    });
  }

  Future<void> _saveSettings() async {
    final db = await _dbHelper.database;
    await db.update('app_settings', {'value': _shopNameController.text.trim()},
        where: 'key = ?', whereArgs: ['shop_name']);
    await db.update('app_settings', {'value': _addressController.text.trim()},
        where: 'key = ?', whereArgs: ['shop_address']);
    await db.update('app_settings', {'value': _phoneController.text.trim()},
        where: 'key = ?', whereArgs: ['shop_phone']);
    await db.update('app_settings', {'value': _logoPath ?? ''},
        where: 'key = ?', whereArgs: ['shop_logo_path']);

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('✅ সেটিংস সংরক্ষিত হয়েছে')));
  }

  Future<void> _pickLogo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      setState(() => _logoPath = result.files.single.path);
    }
  }

  Future<void> _resetOtherUserPassword() async {
    // শুধু মাস্টার এই ফিচার দেখবে (ড্যাশবোর্ড/UI থেকে নিয়ন্ত্রিত)
    final db = await _dbHelper.database;
    final otherUsers = await db.query('users',
        where: 'id != ?', whereArgs: [widget.currentUser['id']]);
    if (otherUsers.isEmpty) return;
    final otherUser = otherUsers.first;

    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${otherUser['username']}-এর পাসওয়ার্ড রিসেট'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'নতুন পাসওয়ার্ড'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.length < 4) return;
              await _authService.resetPassword(
                  otherUser['username'] as String, controller.text);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('✅ পাসওয়ার্ড পরিবর্তন হয়েছে')));
            },
            child: const Text('রিসেট করুন'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMaster = widget.currentUser['role'] == 'master';

    return Scaffold(
      appBar: AppBar(title: const Text('সেটিংস')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('দোকানের তথ্য', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_logoPath != null)
                          Center(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.file(File(_logoPath!), height: 80, width: 80, fit: BoxFit.cover),
                            ),
                          ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _pickLogo,
                          icon: const Icon(Icons.image_outlined),
                          label: Text(_logoPath == null ? 'লোগো যোগ করুন' : 'লোগো পরিবর্তন করুন'),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _shopNameController,
                          decoration: const InputDecoration(labelText: 'দোকানের নাম'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _addressController,
                          decoration: const InputDecoration(labelText: 'ঠিকানা'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _phoneController,
                          decoration: const InputDecoration(labelText: 'ফোন নম্বর'),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _saveSettings,
                          child: const Text('সংরক্ষণ করুন'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text('ব্যাকআপ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: _sharingBackup
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.share_outlined),
                    title: const Text('সর্বশেষ ব্যাকআপ শেয়ার করুন'),
                    subtitle: const Text(
                        'ফোনে সেভ থাকা সবচেয়ে নতুন ব্যাকআপ ফাইল পাঠান বা সেভ করুন'),
                    onTap: _sharingBackup ? null : _shareLatestBackup,
                  ),
                ),
                const SizedBox(height: 24),
                if (isMaster) ...[
                  const Text('নিরাপত্তা', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.lock_reset_outlined),
                      title: const Text('অন্য ইউজারের পাসওয়ার্ড রিসেট'),
                      subtitle: const Text('শুধু মাস্টার এই কাজ করতে পারবেন'),
                      onTap: _resetOtherUserPassword,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.history_outlined),
                      title: const Text('অ্যাক্টিভিটি লগ'),
                      subtitle: const Text('কে কী এডিট/ডিলিট করেছে দেখুন'),
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const ActivityLogScreen())),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.logout, color: AppColors.danger),
                    title: const Text('লগ আউট', style: TextStyle(color: AppColors.danger)),
                    onTap: () async {
                      await AuthService().clearSession();
                      if (!context.mounted) return;
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (_) => const LoginScreen()),
                        (route) => false,
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
