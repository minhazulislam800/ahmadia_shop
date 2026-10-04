// ============================================================
// app_theme.dart
// "স্মুথ, ক্লিন, মিনিমাল" ডিজাইনের জন্য কেন্দ্রীয় থিম সেটআপ।
// রং, ফন্ট, কার্ড/বাটন স্টাইল — সব এখান থেকে নিয়ন্ত্রিত হয়,
// যাতে পুরো অ্যাপে ভিজ্যুয়াল ধারাবাহিকতা থাকে।
// ============================================================

import 'package:flutter/material.dart';

// নোট: আগে এখানে google_fonts প্যাকেজ দিয়ে "Hind Siliguri" ফন্ট আনা
// হতো, কিন্তু সেটা প্রথমবার ব্যবহারের সময় ইন্টারনেট থেকে ফন্ট
// ডাউনলোড করার চেষ্টা করে — যেটা অ্যাপের "সম্পূর্ণ অফলাইন" নীতির
// বিরুদ্ধে যায়। তার বদলে অ্যান্ড্রয়েডের নিজস্ব সিস্টেম ফন্ট
// ব্যবহার করা হচ্ছে (Noto Sans Bengali, প্রায় সব অ্যান্ড্রয়েড
// ফোনে আগে থেকেই ইনস্টল করা থাকে) — কোনো নেট ছাড়াই বাংলা টেক্সট
// সঠিকভাবে দেখাবে।

class AppColors {
  // মূল রং — শান্ত, পেশাদার সবুজ-নীল টোন (আর্থিক অ্যাপের জন্য
  // উপযুক্ত, চোখে আরামদায়ক)
  static const Color primary = Color(0xFF0F6E5C); // গভীর সবুজ
  static const Color primaryLight = Color(0xFFE6F4F1);
  static const Color background = Color(0xFFF7F8FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF1A1D1F);
  static const Color textSecondary = Color(0xFF6F767E);
  static const Color success = Color(0xFF1F9254); // লাভ
  static const Color danger = Color(0xFFD44333); // লোকসান/বাকি
  static const Color warning = Color(0xFFE8A33D); // লো-স্টক সতর্কতা
  static const Color border = Color(0xFFE4E7EB);
}

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
      ),
      textTheme: const TextTheme().apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.background,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
        titleTextStyle: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      cardTheme: CardTheme(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}
