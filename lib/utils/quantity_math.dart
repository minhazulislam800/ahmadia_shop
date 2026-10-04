// ============================================================
// quantity_math.dart
// Phase 1 (multi-unit) আসার পর quantity/weight নিয়ে বারবার গুণ-ভাগ-
// যোগ-বিয়োগ হবে (pack → base unit conversion, FIFO batch থেকে কাটা,
// stock যোগফল...)। শুধু `double` দিয়ে এসব করলে floating-point rounding
// error জমতে জমতে stock/হিসাবে ছোট কিন্তু বিরক্তিকর গরমিল দেখা দেয়
// (যেমন 0.1 + 0.2 == 0.30000000000000004)।
//
// সমাধান: সব quantity/weight-ভিত্তিক arithmetic-এর ফলাফল সবসময় এই
// helper দিয়ে fixed precision-এ round করে নিতে হবে, raw double রেজাল্ট
// সরাসরি database-এ বা পরের হিসাবে ব্যবহার করা যাবে না।
//
// নিয়ম: প্রতিটা quantity-সম্পর্কিত হিসাবের (যোগ/বিয়োগ/গুণ) ফলাফলের ওপর
// QuantityMath.round() কল করতে হবে।
// ============================================================

class QuantityMath {
  QuantityMath._();

  /// কতটা দশমিক ঘর পর্যন্ত নির্ভুলতা রাখা হবে। gram-এর মতো ছোট এককের
  /// জন্যও ৩ দশমিক ঘর যথেষ্ট (যেমন 0.001 kg = 1 gram)। প্রয়োজন হলে
  /// ভবিষ্যতে বাড়ানো যাবে, কিন্তু পুরো app-এ একই মান ব্যবহার করতে হবে।
  static const int decimalPlaces = 3;

  static double _factor() {
    var f = 1.0;
    for (var i = 0; i < decimalPlaces; i++) {
      f *= 10;
    }
    return f;
  }

  /// একটা quantity-কে নির্দিষ্ট precision-এ round করে — floating-point
  /// drift জমা হওয়া আটকাতে প্রতিটা arithmetic operation-এর পর এটা
  /// ব্যবহার করতে হবে।
  static double round(double value) {
    final factor = _factor();
    return (value * factor).round() / factor;
  }

  /// দুই বা ততোধিক quantity যোগ করে সাথে সাথে round করে দেয়
  static double add(double a, double b) => round(a + b);

  /// বিয়োগ করে round করে দেয়
  static double subtract(double a, double b) => round(a - b);

  /// pack quantity কে base unit-এ কনভার্ট করে round করে দেয়
  static double toBase(double packQuantity, double conversionFactorToBase) =>
      round(packQuantity * conversionFactorToBase);

  /// দুইটা quantity প্রায় সমান কিনা (floating-point তুলনা নিরাপদে করার জন্য
  /// — সরাসরি `a == b` ব্যবহার করা যাবে না, কারণ rounding-এর পরেও
  /// মাইক্রো-পার্থক্য থাকতে পারে)
  static bool approxEqual(double a, double b) =>
      (round(a) - round(b)).abs() < (1 / _factor()) / 2;

  /// stock-এ পর্যাপ্ত quantity আছে কিনা চেক করার সময় ব্যবহার করতে হবে
  /// (negative-stock prevention-এর জন্য, সরাসরি `available < needed` না
  /// লিখে এটা ব্যবহার করলে rounding-জনিত false-negative এড়ানো যাবে)
  static bool hasEnough(double available, double needed) =>
      round(available) >= round(needed) || approxEqual(available, needed);
}
