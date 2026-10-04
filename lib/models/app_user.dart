// নাম "AppUser" রাখা হয়েছে ("User" নয়) যাতে Flutter/অন্য প্যাকেজের
// কোনো ভবিষ্যৎ User ক্লাসের সাথে সংঘর্ষ না হয়।
class AppUser {
  final int? id;
  final String username;
  final String passwordHash;
  final String role; // 'master' | 'normal'
  final String? securityQuestion;
  final String? securityAnswerHash;
  final String? recoveryCodeHash;

  const AppUser({
    this.id,
    required this.username,
    required this.passwordHash,
    required this.role,
    this.securityQuestion,
    this.securityAnswerHash,
    this.recoveryCodeHash,
  });

  bool get isMaster => role == 'master';

  factory AppUser.fromMap(Map<String, dynamic> map) {
    return AppUser(
      id: map['id'] as int?,
      username: map['username'] as String,
      passwordHash: map['password_hash'] as String,
      role: map['role'] as String,
      securityQuestion: map['security_question'] as String?,
      securityAnswerHash: map['security_answer_hash'] as String?,
      recoveryCodeHash: map['recovery_code_hash'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'username': username,
      'password_hash': passwordHash,
      'role': role,
      'security_question': securityQuestion,
      'security_answer_hash': securityAnswerHash,
      'recovery_code_hash': recoveryCodeHash,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }
}
