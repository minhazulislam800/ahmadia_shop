// ============================================================
// first_time_setup_screen.dart
// অ্যাপ প্রথমবার চালুর সময় মাস্টার ও নরমাল — দুইজন ইউজারের
// ইউজারনেম, পাসওয়ার্ড ও সিকিউরিটি প্রশ্ন সেট করা হয়।
// এরপর থেকে এই স্ক্রিন আর দেখা যাবে না।
// ============================================================

import 'package:flutter/material.dart';
import '../database/auth_service.dart';
import '../utils/app_theme.dart';
import 'import_backup_screen.dart';

class FirstTimeSetupScreen extends StatefulWidget {
  final VoidCallback onSetupComplete;
  const FirstTimeSetupScreen({super.key, required this.onSetupComplete});

  @override
  State<FirstTimeSetupScreen> createState() => _FirstTimeSetupScreenState();
}

class _FirstTimeSetupScreenState extends State<FirstTimeSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService();

  final _masterUsername = TextEditingController();
  final _masterPassword = TextEditingController();
  final _masterSecQ = TextEditingController(text: 'আপনার প্রথম পণ্যের নাম কী?');
  final _masterSecA = TextEditingController();

  final _normalUsername = TextEditingController();
  final _normalPassword = TextEditingController();
  final _normalSecQ = TextEditingController(text: 'আপনার প্রিয় শহরের নাম কী?');
  final _normalSecA = TextEditingController();

  bool _saving = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_masterUsername.text.trim().toLowerCase() ==
        _normalUsername.text.trim().toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('মাস্টার ও নরমালের ইউজারনেম একই রাখা যাবে না — আলাদা দিন')));
      return;
    }

    setState(() => _saving = true);
    try {
      await _authService.setupInitialUsers(
        masterUsername: _masterUsername.text.trim(),
        masterPassword: _masterPassword.text,
        masterSecurityQ: _masterSecQ.text.trim(),
        masterSecurityA: _masterSecA.text,
        normalUsername: _normalUsername.text.trim(),
        normalPassword: _normalPassword.text,
        normalSecurityQ: _normalSecQ.text.trim(),
        normalSecurityA: _normalSecA.text,
      );
      final recoveryCode = await _authService.generateRecoveryCodeForMaster();
      if (!mounted) return;
      await _showRecoveryCodeDialog(recoveryCode);
      widget.onSetupComplete();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('সেটআপ ব্যর্থ হয়েছে: $e')));
    }
  }

  Future<void> _showRecoveryCodeDialog(String code) async {
    bool confirmed = false;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('🔑 জরুরি — রিকভারি কোড লিখে রাখুন'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'মাস্টার পাসওয়ার্ড ও সিকিউরিটি প্রশ্নের উত্তর — দুটোই ভুলে গেলে '
                'নিচের কোডটাই একমাত্র উপায় হবে অ্যাকাউন্ট আবার অ্যাক্সেস করার। '
                'এটা এখনই কাগজে লিখে/ছবি তুলে নিরাপদ জায়গায় রাখুন। '
                'এই কোড ভবিষ্যতে আর কখনো দেখানো হবে না।',
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  code,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 2),
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: confirmed,
                onChanged: (v) => setDialogState(() => confirmed = v ?? false),
                title: const Text('আমি কোডটা লিখে/সংরক্ষণ করে রেখেছি',
                    style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: confirmed ? () => Navigator.pop(ctx) : null,
              child: const Text('বুঝেছি, এগিয়ে যাই'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard(String title, String subtitle, List<Widget> fields) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            ...fields,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('প্রাথমিক সেটআপ')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Ahmadia Shop-এ স্বাগতম! শুরু করার আগে দুইজন ইউজার সেট করুন — '
                'একজন "মাস্টার" (সব এডিট/ডিলিট করতে পারবেন) আর একজন "নরমাল" '
                '(এন্ট্রি দিতে পারবেন, এডিট সবসময় পারবেন, ডিলিট শুধু ১ দিনের মধ্যে)।',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              Card(
                color: AppColors.primaryLight,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('আগে থেকে ব্যাকআপ আছে?',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      const Text(
                          'নতুন ফোনে বা নতুন করে ইনস্টল করে থাকলে আগের ব্যাকআপ ফাইল দিয়ে '
                          'সব ডেটা ফিরিয়ে আনুন — নতুন করে সেটআপ করতে হবে না।',
                          style: TextStyle(color: AppColors.textSecondary)),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => ImportBackupScreen.pickAndOpen(context),
                        icon: const Icon(Icons.restore_outlined),
                        label: const Text('ব্যাকআপ ফাইল থেকে রিস্টোর করুন'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _sectionCard('👑 মাস্টার ইউজার', 'সম্পূর্ণ নিয়ন্ত্রণ থাকবে', [
                TextFormField(
                  controller: _masterUsername,
                  decoration: const InputDecoration(labelText: 'ইউজারনেম'),
                  validator: (v) => (v == null || v.isEmpty) ? 'আবশ্যক' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _masterPassword,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'পাসওয়ার্ড'),
                  validator: (v) =>
                      (v == null || v.length < 4) ? 'কমপক্ষে ৪ অক্ষর' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _masterSecQ,
                  decoration:
                      const InputDecoration(labelText: 'সিকিউরিটি প্রশ্ন (পাসওয়ার্ড ভুলে গেলে কাজে লাগবে)'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _masterSecA,
                  decoration: const InputDecoration(labelText: 'সিকিউরিটি প্রশ্নের উত্তর'),
                  validator: (v) => (v == null || v.isEmpty) ? 'আবশ্যক' : null,
                ),
              ]),
              const SizedBox(height: 16),
              _sectionCard('👤 নরমাল ইউজার', 'দৈনন্দিন এন্ট্রির জন্য', [
                TextFormField(
                  controller: _normalUsername,
                  decoration: const InputDecoration(labelText: 'ইউজারনেম'),
                  validator: (v) => (v == null || v.isEmpty) ? 'আবশ্যক' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _normalPassword,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'পাসওয়ার্ড'),
                  validator: (v) =>
                      (v == null || v.length < 4) ? 'কমপক্ষে ৪ অক্ষর' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _normalSecQ,
                  decoration:
                      const InputDecoration(labelText: 'সিকিউরিটি প্রশ্ন'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _normalSecA,
                  decoration: const InputDecoration(labelText: 'সিকিউরিটি প্রশ্নের উত্তর'),
                  validator: (v) => (v == null || v.isEmpty) ? 'আবশ্যক' : null,
                ),
              ]),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('সেটআপ সম্পন্ন করুন'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
