// ============================================================
// forgot_password_screen.dart
// পাসওয়ার্ড রিকভারির দুইটা পথ:
//  ১. সিকিউরিটি প্রশ্নের উত্তর (মাস্টার/নরমাল দুইজনের জন্যই)
//  ২. ইমার্জেন্সি রিকভারি কোড (শুধু মাস্টারের জন্য, যদি প্রশ্নের
//     উত্তরও ভুলে যান — সেটআপের সময় একবার দেখানো কোড)
// ============================================================

import 'package:flutter/material.dart';
import '../database/auth_service.dart';
import '../utils/app_theme.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _authService = AuthService();
  final _usernameController = TextEditingController();
  final _answerController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _recoveryCodeController = TextEditingController();
  final _recoveryNewPasswordController = TextEditingController();

  String? _securityQuestion;
  bool _questionFetched = false;
  bool _answerVerified = false;
  String? _error;
  bool _showRecoveryCodePath = false;
  String? _recoveryError;

  Future<void> _fetchQuestion() async {
    final user = await _authService.getSecurityQuestion(_usernameController.text.trim());
    if (user == null) {
      setState(() => _error = 'এই নামে কোনো ইউজার পাওয়া যায়নি');
      return;
    }
    setState(() {
      _securityQuestion = user['security_question'] as String?;
      _questionFetched = true;
      _error = null;
    });
  }

  Future<void> _verifyAnswer() async {
    final ok = await _authService.verifySecurityAnswer(
        _usernameController.text.trim(), _answerController.text);
    if (!ok) {
      setState(() => _error = 'উত্তর মিলছে না, আবার চেষ্টা করুন');
      return;
    }
    setState(() {
      _answerVerified = true;
      _error = null;
    });
  }

  Future<void> _resetPassword() async {
    if (_newPasswordController.text.length < 4) {
      setState(() => _error = 'পাসওয়ার্ড কমপক্ষে ৪ অক্ষরের হতে হবে');
      return;
    }
    await _authService.resetPassword(
        _usernameController.text.trim(), _newPasswordController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('পাসওয়ার্ড সফলভাবে পরিবর্তন হয়েছে')));
    Navigator.of(context).pop();
  }

  Future<void> _resetWithRecoveryCode() async {
    if (_recoveryNewPasswordController.text.length < 4) {
      setState(() => _recoveryError = 'পাসওয়ার্ড কমপক্ষে ৪ অক্ষরের হতে হবে');
      return;
    }
    final success = await _authService.resetPasswordWithRecoveryCode(
        _recoveryCodeController.text, _recoveryNewPasswordController.text);
    if (!success) {
      setState(() => _recoveryError = 'রিকভারি কোড ভুল');
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ মাস্টার পাসওয়ার্ড সফলভাবে রিসেট হয়েছে')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('পাসওয়ার্ড রিকভারি')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_showRecoveryCodePath) ...[
              TextField(
                controller: _usernameController,
                enabled: !_questionFetched,
                decoration: const InputDecoration(labelText: 'ইউজারনেম'),
              ),
              const SizedBox(height: 12),
              if (!_questionFetched)
                ElevatedButton(
                    onPressed: _fetchQuestion, child: const Text('পরবর্তী ধাপ')),
              if (_questionFetched && !_answerVerified) ...[
                const SizedBox(height: 8),
                Text(_securityQuestion ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                TextField(
                  controller: _answerController,
                  decoration: const InputDecoration(labelText: 'উত্তর লিখুন'),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                    onPressed: _verifyAnswer, child: const Text('যাচাই করুন')),
              ],
              if (_answerVerified) ...[
                const SizedBox(height: 8),
                const Text('✅ উত্তর সঠিক — নতুন পাসওয়ার্ড দিন'),
                const SizedBox(height: 12),
                TextField(
                  controller: _newPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'নতুন পাসওয়ার্ড'),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                    onPressed: _resetPassword,
                    child: const Text('পাসওয়ার্ড পরিবর্তন করুন')),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ],
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'সিকিউরিটি প্রশ্নের উত্তরও ভুলে গেছেন? মাস্টার একাউন্টের জন্য '
                'ইমার্জেন্সি রিকভারি কোড ব্যবহার করতে পারেন (সেটআপের সময় '
                'একবার দেখানো হয়েছিল)।',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => setState(() => _showRecoveryCodePath = true),
                child: const Text('রিকভারি কোড ব্যবহার করুন (শুধু মাস্টার)'),
              ),
            ] else ...[
              const Text('ইমার্জেন্সি রিকভারি কোড দিয়ে মাস্টার পাসওয়ার্ড রিসেট',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 12),
              TextField(
                controller: _recoveryCodeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'রিকভারি কোড (যেমন: AB3XZ-9KLMN)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _recoveryNewPasswordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'নতুন পাসওয়ার্ড'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _resetWithRecoveryCode,
                child: const Text('পাসওয়ার্ড রিসেট করুন'),
              ),
              if (_recoveryError != null) ...[
                const SizedBox(height: 12),
                Text(_recoveryError!, style: const TextStyle(color: AppColors.danger)),
              ],
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => _showRecoveryCodePath = false),
                child: const Text('← সিকিউরিটি প্রশ্নের পথে ফিরে যান'),
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'নোট: মাস্টার ইউজার লগইন করেও অন্য ইউজারের পাসওয়ার্ড সরাসরি '
              'রিসেট করে দিতে পারবেন (সেটিংস মেনু থেকে)।',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
