// ============================================================
// product.dart
// Product মডেল — এতদিন app-এ raw Map<String,dynamic> দিয়ে product
// রেকর্ড হ্যান্ডেল হতো (কোনো টাইপ-সেফ ক্লাস ছিল না)। এখন থেকে সব
// জায়গায় এই ক্লাসই ব্যবহার হবে, যাতে ভুল field-name/typo compile
// সময়ে ধরা পড়ে, raw Map-এর ভেতর ঢুকে মান খোঁজা না লাগে।
//
// NOTE (Phase 1 prep): `unit` ফিল্ডটা আপাতত বর্তমান schema অনুযায়ী
// একক unit রাখছে। Phase 1-এ multi-unit (product_units টেবিল) যোগ
// হলে এই ক্লাসে `List<ProductUnit> units` যোগ করতে হবে এবং
// `unit`/`retailPrice`/`wholesalePrice`-কে base-unit রেফারেন্স
// হিসেবে রিফ্যাক্টর করতে হবে। এখনই সেই পরিবর্তন করা হয়নি, যাতে
// Phase 0 বর্তমান কাজ করা ফিচার না ভাঙে।
// ============================================================

class Product {
  final int? id;
  final String name;
  final String? productCode;
  final int? categoryId;
  final String unit;
  final double lowStockThreshold;
  final double? retailPrice;
  final double? wholesalePrice;
  final bool isActive;
  final String createdAt;
  final String? syncId;

  const Product({
    this.id,
    required this.name,
    this.productCode,
    this.categoryId,
    required this.unit,
    this.lowStockThreshold = 0,
    this.retailPrice,
    this.wholesalePrice,
    this.isActive = true,
    required this.createdAt,
    this.syncId,
  });

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id'] as int?,
      name: map['name'] as String,
      productCode: map['product_code'] as String?,
      categoryId: map['category_id'] as int?,
      unit: map['unit'] as String,
      lowStockThreshold: (map['low_stock_threshold'] as num?)?.toDouble() ?? 0,
      retailPrice: (map['retail_price'] as num?)?.toDouble(),
      wholesalePrice: (map['wholesale_price'] as num?)?.toDouble(),
      isActive: (map['is_active'] as int? ?? 1) == 1,
      createdAt: map['created_at'] as String,
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'name': name,
      'product_code': productCode,
      'category_id': categoryId,
      'unit': unit,
      'low_stock_threshold': lowStockThreshold,
      'retail_price': retailPrice,
      'wholesale_price': wholesalePrice,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }

  Product copyWith({
    int? id,
    String? name,
    String? productCode,
    int? categoryId,
    String? unit,
    double? lowStockThreshold,
    double? retailPrice,
    double? wholesalePrice,
    bool? isActive,
    String? createdAt,
    String? syncId,
  }) {
    return Product(
      id: id ?? this.id,
      name: name ?? this.name,
      productCode: productCode ?? this.productCode,
      categoryId: categoryId ?? this.categoryId,
      unit: unit ?? this.unit,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
      retailPrice: retailPrice ?? this.retailPrice,
      wholesalePrice: wholesalePrice ?? this.wholesalePrice,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      syncId: syncId ?? this.syncId,
    );
  }
}
