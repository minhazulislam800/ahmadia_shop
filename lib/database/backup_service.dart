// ============================================================
// backup_service.dart
// সম্পূর্ণ SQLite ডাটাবেস ফাইলটাকে এনক্রিপ্ট করে একটা .backup
// ফাইলে পরিণত করে (পাসওয়ার্ড-প্রোটেক্টেড)। এই ফাইল Android-এর
// শেয়ার-শিট দিয়ে Google Drive/WhatsApp/ফোন স্টোরেজ যেকোনো
// জায়গায় পাঠানো যায় — আলাদা করে Google Drive API সংযুক্ত করার
// দরকার নেই, ফোনে Drive অ্যাপ ইনস্টল থাকলে শেয়ার-শিটেই সেটা
// অপশন হিসেবে দেখা যাবে।
//
// *** Phase 3 সংশোধন (§8) ***: আগে backup password সরাসরি AES key
// হিসেবে ব্যবহার হতো — অর্থাৎ login password দিয়ে backup নিলে,
// পরে login password বদলালে পুরনো backup ফাইল আর decrypt করা
// যেত না। এখন প্রতিটা backup ফাইল **নিজে থেকে স্বয়ংসম্পূর্ণ**
// (self-contained): একটা random data-key দিয়ে আসল ডেটা এনক্রিপ্ট
// হয়, আর সেই data-key-কে ব্যবহারকারীর (তখনকার) login password
// দিয়ে "wrap" করে ফাইলের ভেতরেই রাখা হয়। ফলে —
//   - আলাদা কোনো backup password মনে রাখতে হয় না, login password-ই যথেষ্ট
//   - সেই নির্দিষ্ট backup ফাইলটা restore করতে তখনকার (backup নেওয়ার
//     সময়ের) password লাগবে — যদি সাম্প্রতিক backup হয় এবং তারপর
//     password না বদলে থাকে, সেটা এখনকার login password-ই হবে।
//   - Password পরিবর্তনের পর *নতুন* backup ঠিকই নতুন password দিয়ে
//     কাজ করবে; শুধু পুরনো backup restore করতে সেই সময়কার password
//     লাগবে — এটা crypto-গত একটা স্বাভাবিক সীমাবদ্ধতা, সম্পূর্ণ এড়ানো
//     সম্ভব না কোনো অতিরিক্ত recovery-key ব্যবস্থা ছাড়া।
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:intl/intl.dart';
import 'db_helper.dart';

class BackupService {
  static const int _maxRotatingBackups = 12;
  static const int _autoBackupIntervalDays = 10;

  /// এতদিনের বেশি ব্যাকআপ না হলে হোম/ব্যাকআপ স্ক্রিনে সতর্কতা দেখানো হয়
  /// (অটো-ব্যাকআপের ১০ দিনের চক্রের চেয়ে একটু বেশি)
  static const int staleWarningDays = 11;

  static const String _fingerprintKey = 'last_backup_fingerprint';
  static const String _createdAtKey = 'backup_created_at';

  /// পাসওয়ার্ড থেকে ৩২ বাইটের একটা এনক্রিপশন কী তৈরি করা (SHA-256)
  enc.Key _deriveKey(String password) {
    final hash = sha256.convert(utf8.encode(password)).bytes;
    return enc.Key(Uint8List.fromList(hash));
  }

  /// ডেটা এনক্রিপ্ট/ডিক্রিপ্ট করতে ব্যবহৃত হবে এমন একটা random ৩২-বাইট কী
  Uint8List _generateDataKey() {
    // IV.fromSecureRandom() আগে থেকেই এই ফাইলে ব্যবহৃত হচ্ছিল (প্রমাণিত
    // API) — একই প্যাটার্নে Key.fromSecureRandom() ব্যবহার করা হচ্ছে,
    // যাতে encrypt প্যাকেজের কম-পরিচিত কোনো ক্লাসের ওপর নির্ভর করতে না হয়
    return Uint8List.fromList(enc.Key.fromSecureRandom(32).bytes);
  }

  /// [dbBytes]-কে এনক্রিপ্ট করে self-contained ফরম্যাটে সাজায়:
  /// [wrapIv(16)][wrappedKeyLen(2, big-endian)][wrappedKey][dataIv(16)][encryptedData]
  Uint8List _buildBackupBytes(List<int> dbBytes, String password) {
    final dataKeyBytes = _generateDataKey();
    final dataKey = enc.Key(dataKeyBytes);

    // data-key-কে password দিয়ে wrap করা
    final wrapIv = enc.IV.fromSecureRandom(16);
    final wrapEncrypter =
        enc.Encrypter(enc.AES(_deriveKey(password), mode: enc.AESMode.cbc));
    final wrappedKey = wrapEncrypter.encryptBytes(dataKeyBytes, iv: wrapIv);

    // আসল ডেটা data-key দিয়ে এনক্রিপ্ট করা
    final dataIv = enc.IV.fromSecureRandom(16);
    final dataEncrypter = enc.Encrypter(enc.AES(dataKey, mode: enc.AESMode.cbc));
    final encryptedData = dataEncrypter.encryptBytes(dbBytes, iv: dataIv);

    final wrappedKeyLen = wrappedKey.bytes.length;
    final header = ByteData(2)..setUint16(0, wrappedKeyLen, Endian.big);

    return Uint8List.fromList([
      ...wrapIv.bytes,
      ...header.buffer.asUint8List(),
      ...wrappedKey.bytes,
      ...dataIv.bytes,
      ...encryptedData.bytes,
    ]);
  }

  /// পাসওয়ার্ডের SHA-256 hex — AuthService যেভাবে password_hash রাখে ঠিক সেভাবে
  String _passwordHash(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  /// SQLite ফাইলের শুরুর ১৬ বাইট — ডিক্রিপ্ট সঠিক হয়েছে কি না যাচাইয়ের জন্য
  bool _looksLikeSqlite(List<int> bytes) {
    const header = 'SQLite format 3';
    if (bytes.length < header.length) return false;
    for (var i = 0; i < header.length; i++) {
      if (bytes[i] != header.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// হাতে নেওয়া ব্যাকআপ → সরাসরি পাসওয়ার্ড দিয়ে লক করা।
  /// অটো ব্যাকআপ → পাসওয়ার্ডের hash দিয়ে লক করা (কারণ লগইন সেশন সেভ
  /// থাকলে পাসওয়ার্ড টাইপ করা থাকে না)। দুই ধরনের ফাইলই একই পাসওয়ার্ড
  /// দিয়ে খোলা যায় — তাই দুটো পদ্ধতিই চেষ্টা করা হয়।
  Future<List<int>> _parseAndDecryptBackupBytes(
      Uint8List allBytes, String password) async {
    for (final candidate in [password, _passwordHash(password)]) {
      try {
        final result = await _tryDecrypt(allBytes, candidate);
        if (_looksLikeSqlite(result)) return result;
      } catch (_) {
        // এই পদ্ধতিতে খোলেনি — পরেরটা চেষ্টা করা হবে
      }
    }
    throw Exception(
        'পাসওয়ার্ড ভুল, অথবা ফাইল নষ্ট হয়ে গেছে, অথবা এই ব্যাকআপ ভিন্ন একটা পাসওয়ার্ড দিয়ে নেওয়া হয়েছিল');
  }

  Future<List<int>> _tryDecrypt(Uint8List allBytes, String password) async {
    {
      var offset = 0;
      final wrapIv = enc.IV(Uint8List.fromList(allBytes.sublist(0, 16)));
      offset += 16;
      final wrappedKeyLen =
          ByteData.sublistView(allBytes, offset, offset + 2).getUint16(0, Endian.big);
      offset += 2;
      final wrappedKeyBytes = allBytes.sublist(offset, offset + wrappedKeyLen);
      offset += wrappedKeyLen;
      final dataIv = enc.IV(Uint8List.fromList(allBytes.sublist(offset, offset + 16)));
      offset += 16;
      final encryptedDataBytes = allBytes.sublist(offset);

      final wrapEncrypter =
          enc.Encrypter(enc.AES(_deriveKey(password), mode: enc.AESMode.cbc));
      final dataKeyBytes = wrapEncrypter.decryptBytes(
          enc.Encrypted(Uint8List.fromList(wrappedKeyBytes)),
          iv: wrapIv);

      final dataEncrypter =
          enc.Encrypter(enc.AES(enc.Key(Uint8List.fromList(dataKeyBytes)), mode: enc.AESMode.cbc));
      return dataEncrypter.decryptBytes(
          enc.Encrypted(Uint8List.fromList(encryptedDataBytes)),
          iv: dataIv);
    }
  }

  /// বর্তমান ডাটাবেস ফাইলকে এনক্রিপ্ট করে একটা টেম্প ফাইলে সেভ
  /// করে সেই ফাইলের path রিটার্ন করে (শেয়ার/সেভ করার জন্য প্রস্তুত)
  Future<String> createEncryptedBackup(String password) async {
    await _stampBackupCreated();
    final dbPath = await getDatabasesPath();
    final dbFile = File(join(dbPath, 'ahmadia_shop.db'));
    final dbBytes = await dbFile.readAsBytes();

    final outputBytes = _buildBackupBytes(dbBytes, password);

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
    final backupFile =
        File(join(tempDir.path, 'AhmadiaShop_Backup_$timestamp.backup'));
    await backupFile.writeAsBytes(outputBytes);

    await markBackupDone();
    return backupFile.path;
  }

  /// এনক্রিপ্টেড ব্যাকআপ ফাইল থেকে ডাটাবেস রিস্টোর করা (সম্পূর্ণ
  /// প্রতিস্থাপন — বর্তমান সব ডেটা মুছে যাবে)
  /// (ভুল পাসওয়ার্ড হলে Exception ছুঁড়ে দেবে)
  Future<void> restoreFromBackup(String backupFilePath, String password) async {
    final decryptedBytes = await _decryptBackupFile(backupFilePath, password);

    // বর্তমান ডাটাবেস কানেকশন বন্ধ করে ফাইল প্রতিস্থাপন করতে হবে
    final dbPath = await getDatabasesPath();
    final dbFile = File(join(dbPath, 'ahmadia_shop.db'));

    // আগের সব ডাটাবেস কানেকশন বন্ধ করা (নিরাপদে ফাইল বদলানোর জন্য)
    await databaseFactory.deleteDatabase(dbFile.path).catchError((_) {});
    await dbFile.writeAsBytes(decryptedBytes);
  }

  /// এনক্রিপ্টেড ব্যাকআপ ফাইল ডিক্রিপ্ট করে একটা টেম্প .db ফাইলে
  /// সেভ করে সেই path রিটার্ন করে — মার্জ করার জন্য ব্যবহার হবে
  /// (বর্তমান ডাটাবেস স্পর্শ না করে)
  Future<String> decryptToTempFile(String backupFilePath, String password) async {
    final decryptedBytes = await _decryptBackupFile(backupFilePath, password);
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(join(
        tempDir.path, 'merge_import_${DateTime.now().millisecondsSinceEpoch}.db'));
    await tempFile.writeAsBytes(decryptedBytes);
    return tempFile.path;
  }

  Future<List<int>> _decryptBackupFile(
      String backupFilePath, String password) async {
    final backupFile = File(backupFilePath);
    final allBytes = await backupFile.readAsBytes();
    return _parseAndDecryptBackupBytes(allBytes, password);
  }

  /// ব্যাকআপ ফাইলের ভেতরের ডেটাতেই তার তৈরির সময় লিখে দেওয়া — ফাইলের
  /// নাম বদলে গেলেও রিস্টোরের সময় সঠিক তারিখ দেখানো যায়
  Future<void> _stampBackupCreated() async {
    final db = await DBHelper.instance.database;
    await db.rawInsert(
        'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
        [_createdAtKey, DateTime.now().toIso8601String()]);
  }

  /// ফাইলের নামে থাকা তারিখ (AhmadiaShop_Backup_2026-10-03_10-23.backup)
  static DateTime? parseDateFromFileName(String name) {
    final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})').firstMatch(name);
    if (m == null) return null;
    return DateTime.tryParse(
        '${m.group(1)}-${m.group(2)}-${m.group(3)} ${m.group(4)}:${m.group(5)}:00');
  }

  /// ব্যাকআপ ফাইল পাসওয়ার্ড দিয়ে খুলে দেখে (বর্তমান ডেটায় হাত না দিয়ে) —
  /// ভুল পাসওয়ার্ড/নষ্ট ফাইল হলে Exception, ঠিক হলে ব্যাকআপ তৈরির সময়
  /// (পুরনো ফরম্যাটের ফাইলে না থাকলে null)
  Future<DateTime?> inspectBackup(String backupFilePath, String password) async {
    final bytes = await _decryptBackupFile(backupFilePath, password);
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(join(
        tempDir.path, 'inspect_${DateTime.now().millisecondsSinceEpoch}.db'));
    await tempFile.writeAsBytes(bytes);
    Database? db;
    try {
      db = await openDatabase(tempFile.path, readOnly: true, singleInstance: false);
      final rows = await db.query('app_settings',
          where: 'key = ?', whereArgs: [_createdAtKey]);
      if (rows.isEmpty) return null;
      return DateTime.tryParse((rows.first['value'] as String?) ?? '');
    } catch (_) {
      return null;
    } finally {
      try {
        await db?.close();
      } catch (_) {}
      try {
        await tempFile.delete();
      } catch (_) {}
    }
  }

  /// ব্যাকআপ ফাইল দিয়ে বর্তমান ডেটা সম্পূর্ণ প্রতিস্থাপন — অ্যাপ রিস্টার্ট
  /// ছাড়াই। আগে ফাইল ডিক্রিপ্ট হয় (ভুল পাসওয়ার্ড হলে বর্তমান ডেটা অক্ষত
  /// থাকে)। সংরক্ষিত লগইন সেশন মুছে ফেলা হয়, তাই এরপর লগইন করতে হবে।
  Future<void> restoreAndReset(String backupFilePath, String password) async {
    final bytes = await _decryptBackupFile(backupFilePath, password);

    await DBHelper.instance.closeConnection();
    final dbPath = await getDatabasesPath();
    final dbFile = File(join(dbPath, 'ahmadia_shop.db'));
    await databaseFactory.deleteDatabase(dbFile.path).catchError((_) {});
    await dbFile.writeAsBytes(bytes, flush: true);

    final db = await DBHelper.instance.database;
    await db.delete('app_settings',
        where: 'key = ?', whereArgs: ['session_user_id']);
  }

  /// শেষ ব্যাকআপের সময় সংরক্ষণ করা (ব্যাকআপ রিমাইন্ডারের জন্য)
  Future<void> markBackupDone() async {
    final db = await DBHelper.instance.database;
    await db.update(
        'app_settings',
        {'value': DateTime.now().toIso8601String()},
        where: 'key = ?',
        whereArgs: ['last_backup_at']);
    // এই মুহূর্তের ডেটার "ছাপ" মনে রাখা — পরে তুলনা করে বোঝা যাবে
    // ব্যাকআপের পর কিছু বদলেছে কি না
    await db.rawInsert(
        'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
        [_fingerprintKey, await _computeFingerprint()]);
  }

  /// পুরো ডেটার একটা SHA-256 ছাপ। ব্যাকআপের সময় বা সেশনের মতো
  /// অ্যাপ-নিজের বদলানো সেটিংস বাদ দেওয়া হয়, যাতে শুধু আসল
  /// ব্যবসার ডেটা বদলালেই ছাপ বদলায়।
  Future<String> _computeFingerprint() async {
    final db = await DBHelper.instance.database;
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name");
    final parts = <String>[];
    for (final t in tables) {
      final name = t['name'] as String;
      final List<Map<String, Object?>> rows;
      if (name == 'app_settings') {
        rows = await db.rawQuery(
            'SELECT key, value FROM app_settings WHERE key NOT IN (?, ?, ?, ?, ?) '
            'ORDER BY key',
            ['last_backup_at', _fingerprintKey, 'session_user_id', _createdAtKey, 'last_backup_check_at']);
      } else {
        rows = await db.rawQuery('SELECT * FROM "$name" ORDER BY rowid');
      }
      final buffer = StringBuffer(name);
      for (final r in rows) {
        buffer.write('|${r.toString()}');
      }
      parts.add(sha256.convert(utf8.encode(buffer.toString())).toString());
    }
    return sha256.convert(utf8.encode(parts.join(','))).toString();
  }

  Future<String?> _getStoredFingerprint() async {
    final db = await DBHelper.instance.database;
    final rows = await db
        .query('app_settings', where: 'key = ?', whereArgs: [_fingerprintKey]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// মাস্টার ইউজারের password_hash — অটো ব্যাকআপ এটা দিয়ে লক হয়
  Future<String?> _masterPasswordHash() async {
    final db = await DBHelper.instance.database;
    var rows = await db.query('users',
        where: 'role = ?', whereArgs: ['master'], orderBy: 'id ASC', limit: 1);
    if (rows.isEmpty) {
      rows = await db.query('users', orderBy: 'id ASC', limit: 1);
    }
    if (rows.isEmpty) return null;
    return rows.first['password_hash'] as String?;
  }

  /// শেষ ব্যাকআপ কতদিন আগে হয়েছিল (কখনো না হলে null)
  Future<DateTime?> getLastBackupTime() async {
    final db = await DBHelper.instance.database;
    final rows =
        await db.query('app_settings', where: 'key = ?', whereArgs: ['last_backup_at']);
    if (rows.isEmpty) return null;
    final value = rows.first['value'] as String?;
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  // ============================================================
  // §9 — Automatic Local Backup (৭ দিনে একবার, সর্বোচ্চ ১২টা রাখা)
  // ============================================================

  /// ডেডিকেটেড, সহজে খুঁজে পাওয়া যায় এমন লোকাল ব্যাকআপ ফোল্ডার
  Future<Directory> _getRotatingBackupDir() async {
    // Android-এ getExternalStorageDirectory() ব্যবহার করা হচ্ছে যাতে
    // ফোল্ডারটা ফাইল ম্যানেজার দিয়ে সহজে খুঁজে পাওয়া যায় (App-এর নিজস্ব
    // external storage-এর ভেতরে); অন্য প্ল্যাটফর্মে ডকুমেন্টস ফোল্ডারে।
    Directory base;
    try {
      base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(join(base.path, 'AhmadiaShop_Backups'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// শেষ ব্যাকআপের পর ১০ দিনের বেশি হলে ডেটা বদলেছে কি না দেখে —
  /// বদলে থাকলে ফোনের স্টোরেজে (AhmadiaShop_Backups ফোল্ডারে) নতুন
  /// ব্যাকআপ রাখে; না বদলে থাকলে কিছুই করে না (শুধু "যাচাই হয়েছে"
  /// হিসেবে তারিখ আপডেট হয়, কারণ আগের ব্যাকআপই এখনো হুবহু আপ-টু-ডেট)।
  /// অ্যাপ খোলার সময় কল হয়; কোনো background service লাগে না।
  /// ব্যাকআপের তথ্য বদলালে (নতুন ফাইল হলে বা "যাচাই হয়েছে" তারিখ
  /// আপডেট হলে) true ফেরত দেয়।
  Future<bool> autoBackupIfNeeded() async {
    final last = await getLastBackupTime();
    if (last != null &&
        DateTime.now().difference(last).inDays < _autoBackupIntervalDays) {
      return false; // এখনো সময় হয়নি
    }

    final stored = await _getStoredFingerprint();
    final current = await _computeFingerprint();
    if (last != null && stored != null && stored == current) {
      // কিছু বদলায়নি — নতুন ফাইল দরকার নেই
      final db = await DBHelper.instance.database;
      await db.update(
          'app_settings', {'value': DateTime.now().toIso8601String()},
          where: 'key = ?', whereArgs: ['last_backup_at']);
      return true;
    }

    final secret = await _masterPasswordHash();
    if (secret == null) return false;
    await createRotatingBackup(secret);
    return true;
  }

  /// সেটিংস থেকে শেয়ারের জন্য: সবচেয়ে নতুন ব্যাকআপ ফাইল। একটাও না
  /// থাকলে এখনই একটা বানিয়ে নেয়। (এই ফাইল খুলতে মাস্টার ইউজারের
  /// পাসওয়ার্ড লাগবে)
  Future<String?> getLatestBackupPathOrCreate() async {
    final files = await listRotatingBackups();
    if (files.isNotEmpty) return files.first.path;
    final secret = await _masterPasswordHash();
    if (secret == null) return null;
    return createRotatingBackup(secret);
  }

  /// ডেডিকেটেড ফোল্ডারে একটা backup তৈরি করে, সর্বোচ্চ ১২টার বেশি
  /// হয়ে গেলে সবচেয়ে পুরনোটা মুছে ফেলে (rotation)
  Future<String> createRotatingBackup(String password) async {
    await _stampBackupCreated();
    final dbPath = await getDatabasesPath();
    final dbFile = File(join(dbPath, 'ahmadia_shop.db'));
    final dbBytes = await dbFile.readAsBytes();
    final outputBytes = _buildBackupBytes(dbBytes, password);

    final dir = await _getRotatingBackupDir();
    final timestamp = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
    final backupFile = File(join(dir.path, 'AhmadiaShop_Backup_$timestamp.backup'));
    await backupFile.writeAsBytes(outputBytes);

    await markBackupDone();
    await _enforceRotationLimit(dir);
    return backupFile.path;
  }

  Future<void> _enforceRotationLimit(Directory dir) async {
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.backup'))
        .toList();
    // ফাইলনামে টাইমস্ট্যাম্প থাকায় নাম অনুযায়ী sort করলেই কালানুক্রমিক হয়ে যায়
    files.sort((a, b) => a.path.compareTo(b.path));
    while (files.length > _maxRotatingBackups) {
      final oldest = files.removeAt(0);
      try {
        await oldest.delete();
      } catch (_) {
        // মুছতে ব্যর্থ হলেও বাকি প্রক্রিয়া চলতে থাকবে
      }
    }
  }

  /// ডেডিকেটেড ফোল্ডারের সব rotating backup-এর তালিকা (নতুন আগে)
  Future<List<File>> listRotatingBackups() async {
    final dir = await _getRotatingBackupDir();
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.backup'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
