// ============================================================
// auth_service.dart
// লগইন, পাসওয়ার্ড হ্যাশিং, প্রথমবার অ্যাপ চালুর সময় মাস্টার/নরমাল
// ইউজার সেটআপ, আর পাসওয়ার্ড রিকভারি লজিক
// ============================================================

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'db_helper.dart';

class AuthService {
  final DBHelper _dbHelper = DBHelper.instance;

  String _hash(String text) {
    final bytes = utf8.encode(text);
    return sha256.convert(bytes).toString();
  }

  /// অ্যাপ প্রথমবার চালু হলে (কোনো ইউজার নেই) — মাস্টার ও নরমাল
  /// দুইজনের ইউজারনেম/পাসওয়ার্ড/সিকিউরিটি প্রশ্ন সেট করার জন্য
  Future<void> setupInitialUsers({
    required String masterUsername,
    required String masterPassword,
    required String masterSecurityQ,
    required String masterSecurityA,
    required String normalUsername,
    required String normalPassword,
    required String normalSecurityQ,
    required String normalSecurityA,
  }) async {
    final db = await _dbHelper.database;
    await db.insert('users', {
      'username': masterUsername,
      'password_hash': _hash(masterPassword),
      'role': 'master',
      'security_question': masterSecurityQ,
      'security_answer_hash': _hash(masterSecurityA.toLowerCase().trim()),
    });
    await db.insert('users', {
      'username': normalUsername,
      'password_hash': _hash(normalPassword),
      'role': 'normal',
      'security_question': normalSecurityQ,
      'security_answer_hash': _hash(normalSecurityA.toLowerCase().trim()),
    });
  }

  // ------------------------------------------------------------
  // লগইন সেশন — একবার লগইন করলে অ্যাপ বন্ধ করে আবার খুললেও আর
  // পাসওয়ার্ড টাইপ করতে হবে না। সেশন শুধু "লগ আউট" চাপলেই মুছে যায়।
  // কোনো নতুন টেবিল/কলাম লাগে না — আগের app_settings টেবিলেই থাকে।
  // ------------------------------------------------------------
  static const String _sessionKey = 'session_user_id';

  Future<void> saveSession(int userId) async {
    final db = await _dbHelper.database;
    await db.rawInsert(
        'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
        [_sessionKey, userId.toString()]);
  }

  /// সেভ করা সেশন থাকলে সেই ইউজারের তথ্য ফেরত দেয়, নাহলে null
  Future<Map<String, dynamic>?> restoreSession() async {
    final db = await _dbHelper.database;
    final rows = await db
        .query('app_settings', where: 'key = ?', whereArgs: [_sessionKey]);
    if (rows.isEmpty) return null;
    final userId = int.tryParse((rows.first['value'] as String?) ?? '');
    if (userId == null) return null;
    final users = await db.query('users', where: 'id = ?', whereArgs: [userId]);
    if (users.isEmpty) return null;
    return users.first;
  }

  Future<void> clearSession() async {
    final db = await _dbHelper.database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: [_sessionKey]);
  }

  Future<bool> hasUsers() async {
    final db = await _dbHelper.database;
    final result = await db.query('users', limit: 1);
    return result.isNotEmpty;
  }

  /// লগইন — সফল হলে ইউজারের তথ্য রিটার্ন করবে, ব্যর্থ হলে null
  Future<Map<String, dynamic>?> login(String username, String password) async {
    final db = await _dbHelper.database;
    final result = await db.query(
      'users',
      where: 'username = ? AND password_hash = ?',
      whereArgs: [username, _hash(password)],
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  /// সিকিউরিটি প্রশ্নের উত্তর মিলিয়ে দেখা (পাসওয়ার্ড রিকভারির প্রথম ধাপ)
  Future<bool> verifySecurityAnswer(String username, String answer) async {
    final db = await _dbHelper.database;
    final result = await db.query('users', where: 'username = ?', whereArgs: [username]);
    if (result.isEmpty) return false;
    final storedHash = result.first['security_answer_hash'] as String?;
    if (storedHash == null) return false;
    return storedHash == _hash(answer.toLowerCase().trim());
  }

  /// পাসওয়ার্ড রিসেট — সিকিউরিটি উত্তর সঠিক হলে, অথবা মাস্টার অন্যজনের
  /// পাসওয়ার্ড রিসেট করলে (UI স্তরে যাচাই হবে মাস্টার লগইন করা আছে কিনা)
  Future<void> resetPassword(String username, String newPassword) async {
    final db = await _dbHelper.database;
    await db.update('users', {'password_hash': _hash(newPassword)},
        where: 'username = ?', whereArgs: [username]);
  }

  Future<Map<String, dynamic>?> getSecurityQuestion(String username) async {
    final db = await _dbHelper.database;
    final result = await db.query('users', where: 'username = ?', whereArgs: [username]);
    if (result.isEmpty) return null;
    return result.first;
  }

  // ------------------------------------------------------------
  // ইমার্জেন্সি রিকভারি কোড — শুধুমাত্র মাস্টারের জন্য। পাসওয়ার্ড
  // ও সিকিউরিটি প্রশ্নের উত্তর দুটোই ভুলে গেলে এই একমাত্র শেষ
  // উপায়। সেটআপের সময় একবার প্লেইন-টেক্সট দেখানো হয় (লিখে রাখতে
  // বলা হবে), এরপর শুধু হ্যাশ সংরক্ষিত থাকে — কখনো আর দেখানো যাবে না।
  // ------------------------------------------------------------

  String _generateRecoveryCode() {
    final random = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // দ্ব্যর্থহীন অক্ষর (0/O, 1/I বাদ)
    final part1 = List.generate(5, (_) => chars[random.nextInt(chars.length)]).join();
    final part2 = List.generate(5, (_) => chars[random.nextInt(chars.length)]).join();
    return '$part1-$part2';
  }

  /// মাস্টার ইউজারের জন্য একটা নতুন রিকভারি কোড তৈরি করে সেভ করে,
  /// প্লেইন-টেক্সট কোডটা একবারই রিটার্ন করে (এটাই একমাত্র সুযোগ
  /// ব্যবহারকারীকে দেখানোর — পরে আর রিট্রিভ করা যাবে না)
  Future<String> generateRecoveryCodeForMaster() async {
    final db = await _dbHelper.database;
    final code = _generateRecoveryCode();
    await db.update(
        'users', {'recovery_code_hash': _hash(code)},
        where: 'role = ?', whereArgs: ['master']);
    return code;
  }

  /// রিকভারি কোড দিয়ে সরাসরি পাসওয়ার্ড রিসেট করা (মাস্টার একাউন্টে)
  Future<bool> resetPasswordWithRecoveryCode(String code, String newPassword) async {
    final db = await _dbHelper.database;
    final masterRows = await db.query('users', where: 'role = ?', whereArgs: ['master']);
    if (masterRows.isEmpty) return false;
    final master = masterRows.first;
    final storedHash = master['recovery_code_hash'] as String?;
    if (storedHash == null || storedHash != _hash(code.trim().toUpperCase())) {
      return false;
    }
    await db.update('users', {'password_hash': _hash(newPassword)},
        where: 'id = ?', whereArgs: [master['id']]);
    return true;
  }
}
