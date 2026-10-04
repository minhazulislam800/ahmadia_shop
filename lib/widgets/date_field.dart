// ============================================================
// date_field.dart
// যেকোনো লেনদেনের ফর্মে তারিখ বাছাই করার জন্য একটাই reusable
// ফিল্ড — ট্যাপ করলে ক্যালেন্ডার খোলে। ডিফল্টে আজকের তারিখ থাকে,
// তাই তারিখ না বদলালে আগের মতোই আজকের তারিখে সেভ হবে।
// ============================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DateField extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onChanged;
  final String label;

  const DateField({
    super.key,
    required this.date,
    required this.onChanged,
    this.label = 'তারিখ',
  });

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    // আজকের পরের তারিখ নেওয়া হয় না — রিপোর্টগুলো আজ পর্যন্তই দেখায়
    final lastDate = DateTime(now.year, now.month, now.day);
    final firstDate = DateTime(2000);
    var initial = date;
    if (initial.isAfter(lastDate)) initial = lastDate;
    if (initial.isBefore(firstDate)) initial = firstDate;

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 20),
        ),
        child: Text(DateFormat('yyyy-MM-dd').format(date)),
      ),
    );
  }
}
