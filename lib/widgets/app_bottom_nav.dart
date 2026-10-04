// ============================================================
// app_bottom_nav.dart
// Phase 5 (§5.৩ Navigation) — সবচেয়ে বেশি ব্যবহৃত ৫টা কাজ
// (Dashboard, Sale, Purchase, Reports, Search) সবসময় এক-ট্যাপ
// দূরত্বে রাখার জন্য একটাই consistent bottom navigation bar,
// যেটা সব প্রধান screen-এ reuse হবে।
//
// ডিজাইন সিদ্ধান্ত: এখানে IndexedStack-ভিত্তিক "tab preserve
// state" প্যাটার্ন ব্যবহার করা হয়নি (যেটা অনেক বেশি জায়গায়
// routing পরিবর্তন দাবি করত, ঝুঁকিপূর্ণ)। বরং প্রতিটা ট্যাবে
// ট্যাপ করলে pushReplacement হয় — এটা standard bottom-nav UX-ই
// (home tab-ও তালিকায় থাকায় সবসময় সহজে "শুরুতে" ফেরা যায়),
// আর existing push/pop navigation logic-এর সাথে সাংঘর্ষিক না।
// ============================================================

import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import '../screens/dashboard_screen.dart';
import '../screens/sale_entry_screen.dart';
import '../screens/purchase_entry_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/global_search_screen.dart';

enum AppTab { dashboard, sale, purchase, reports, search }

class AppBottomNav extends StatelessWidget {
  final AppTab currentTab;
  final Map<String, dynamic> currentUser;

  const AppBottomNav({super.key, required this.currentTab, required this.currentUser});

  void _go(BuildContext context, AppTab tab) {
    if (tab == currentTab) return; // ইতিমধ্যে এই ট্যাবেই আছে, কিছু করার দরকার নেই

    if (tab == AppTab.dashboard) {
      // হোমে ফিরলে মাঝের সব স্ক্রিন সরিয়ে নতুন করে হোম খোলা হয়
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
            builder: (_) => DashboardScreen(currentUser: currentUser)),
        (route) => false,
      );
      return;
    }

    late Widget target;
    switch (tab) {
      case AppTab.dashboard:
        target = DashboardScreen(currentUser: currentUser);
        break;
      case AppTab.sale:
        target = SaleEntryScreen(currentUser: currentUser);
        break;
      case AppTab.purchase:
        target = PurchaseEntryScreen(currentUser: currentUser);
        break;
      case AppTab.reports:
        target = ReportsScreen(currentUser: currentUser);
        break;
      case AppTab.search:
        target = GlobalSearchScreen(currentUser: currentUser);
        break;
    }
    final route = MaterialPageRoute(builder: (_) => target);
    if (currentTab == AppTab.dashboard) {
      // হোমের ওপর নতুন স্ক্রিন খোলা হয় — ব্যাক চাপলে হোমে ফেরা যায়
      Navigator.push(context, route);
    } else {
      // এক ট্যাব থেকে আরেক ট্যাবে গেলে শুধু ওপরের স্ক্রিনটা বদলায়,
      // নিচে হোম থেকেই যায় — তাই ব্যাক চাপলে অ্যাপ বন্ধ হয় না
      Navigator.pushReplacement(context, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentTab.index,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.textSecondary,
      showUnselectedLabels: true,
      onTap: (i) => _go(context, AppTab.values[i]),
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'হোম'),
        BottomNavigationBarItem(icon: Icon(Icons.point_of_sale_outlined), label: 'বিক্রয়'),
        BottomNavigationBarItem(icon: Icon(Icons.shopping_cart_outlined), label: 'ক্রয়'),
        BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined), label: 'রিপোর্ট'),
        BottomNavigationBarItem(icon: Icon(Icons.search_outlined), label: 'খুঁজুন'),
      ],
    );
  }
}
