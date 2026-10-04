// ============================================================
// login_screen.dart
// অ্যাপ চালু হলে প্রথমে এই স্ক্রিন দেখা যাবে।
// প্রথমবার (কোনো ইউজার না থাকলে) সেটআপ ফর্ম দেখাবে,
// এরপর থেকে সবসময় ইউজারনেম+পাসওয়ার্ড লগইন ফর্ম দেখাবে।
// ============================================================

import 'package:flutter/material.dart';
import '../database/auth_service.dart';
import '../utils/app_theme.dart';
import 'first_time_setup_screen.dart';
import 'dashboard_screen.dart';
import 'forgot_password_screen.dart';
import '../widgets/shop_logo.dart';
import '../utils/crash_log.dart';
import '../utils/incoming_file.dart';
import 'import_backup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _authService = AuthService();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = true;
  String? _startupError;
  bool _hasUsers = false;
  String? _errorText;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _checkFirstTime();
  }

  // শুরুর ধাপে (ডাটাবেস খোলা, সেভ করা লগইন) কোনো সমস্যা হলে অ্যাপ বন্ধ না হয়ে
  // ত্রুটির বিবরণ দেখায় এবং "আবার চেষ্টা" করার সুযোগ দেয়
  Future<void> _checkFirstTime() async {
    try {
      await _startup();
    } catch (e, st) {
      CrashLog.record(e, st);
      if (!mounted) return;
      setState(() {
        _startupError = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _startup() async {
    final hasUsers = await _authService.hasUsers();

    // আগে লগইন করা থাকলে সরাসরি হোমে যাওয়া — পাসওয়ার্ড আবার টাইপ করতে হবে না
    if (hasUsers) {
      final savedUser = await _authService.restoreSession();
      if (savedUser != null) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) => DashboardScreen(currentUser: savedUser)),
        );
        // "Open with" করে ব্যাকআপ ফাইল খোলা হয়ে থাকলে ইমপোর্ট স্ক্রিন দেখানো
        WidgetsBinding.instance
            .addPostFrameCallback((_) => IncomingFileService.consumeInitial());
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _hasUsers = hasUsers;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      IncomingFileService.consumeInitial();
      if (mounted) CrashLog.showPreviousIfAny(context);
    });
  }

  Future<void> _login() async {
    setState(() => _errorText = null);
    final user = await _authService.login(
      _usernameController.text.trim(),
      _passwordController.text,
    );
    if (user == null) {
      setState(() => _errorText = 'ইউজারনেম বা পাসওয়ার্ড ভুল হয়েছে');
      return;
    }

    await _authService.saveSession(user['id'] as int);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => DashboardScreen(currentUser: user)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_startupError != null) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
                const SizedBox(height: 12),
                const Text('অ্যাপ চালু করতে সমস্যা হয়েছে',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 12),
                SelectableText(_startupError!,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _startupError = null;
                      _loading = true;
                    });
                    _checkFirstTime();
                  },
                  child: const Text('আবার চেষ্টা করুন'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_hasUsers) {
      // প্রথমবার — মাস্টার/নরমাল ইউজার সেটআপ করতে হবে
      return FirstTimeSetupScreen(onSetupComplete: _checkFirstTime);
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 60),
                  const Center(child: ShopLogo()),
                  const SizedBox(height: 20),
                  Text(
                    'Ahmadia Shop',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'দোকান ব্যবস্থাপনা সিস্টেম',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 40),
                  TextField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'ইউজারনেম',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      labelText: 'পাসওয়ার্ড',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () =>
                            setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(_errorText!,
                        style: const TextStyle(color: AppColors.danger)),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _login,
                    child: const Text('লগইন করুন'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const ForgotPasswordScreen()));
                    },
                    child: const Text('পাসওয়ার্ড ভুলে গেছেন?'),
                  ),
                  TextButton.icon(
                    onPressed: () => ImportBackupScreen.pickAndOpen(context),
                    icon: const Icon(Icons.restore_outlined, size: 18),
                    label: const Text('ব্যাকআপ ফাইল থেকে ডেটা রিস্টোর'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
