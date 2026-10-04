// ============================================================
// shop_logo.dart
// দোকানের লোগো (অ্যাপ আইকনের "A" চিহ্ন) দেখানোর widget — লগইন
// স্ক্রিনে ব্যবহার হয়। লোগো ফাইল কোনো কারণে না পাওয়া গেলে আগের
// দোকানের আইকন দেখায়।
// ============================================================

import 'package:flutter/material.dart';
import '../utils/app_theme.dart';

class ShopLogo extends StatelessWidget {
  static const String assetPath = 'assets/images/logo_icon.png';

  final double size;
  final double radius;

  const ShopLogo({super.key, this.size = 96, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(Icons.storefront_rounded,
            size: size / 2, color: AppColors.primary),
      ),
    );
  }
}
